//! Mic and camera in use, best effort. Linux: PulseAudio/PipeWire recording
//! streams from `pactl`, and `/dev/video*` held open by the user's own
//! processes. Windows: the CapabilityAccessManager consent store in HKCU,
//! where an app is using the device while `LastUsedTimeStop` is 0.
// The pure Linux parsers are compiled (and tested) everywhere, used live on Linux only.
#![cfg_attr(not(target_os = "linux"), allow(dead_code))]

#[derive(Debug, Clone, Default, PartialEq)]
pub struct Privacy {
    /// None when it can't be known (no pactl, registry unreadable).
    pub mic_in_use: Option<bool>,
    pub camera_in_use: Option<bool>,
    pub mic_users: Vec<String>,
}

/// One `Source Output` block of `pactl list source-outputs`.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct SourceOutput {
    pub source: Option<u32>,
    pub corked: bool,
    pub app: Option<String>,
    pub media_name: Option<String>,
}

/// Parse `pactl list source-outputs` (LC_ALL=C).
pub fn parse_source_outputs(text: &str) -> Vec<SourceOutput> {
    let mut out: Vec<SourceOutput> = Vec::new();
    for line in text.lines().take(100_000) {
        let t = line.trim();
        if t.starts_with("Source Output #") {
            if out.len() >= 1_024 {
                break;
            }
            out.push(SourceOutput::default());
            continue;
        }
        let Some(cur) = out.last_mut() else { continue };
        if let Some(v) = t.strip_prefix("Source:") {
            cur.source = v.trim().parse().ok();
        } else if let Some(v) = t.strip_prefix("Corked:") {
            cur.corked = v.trim() == "yes";
        } else if let Some((k, v)) = t.split_once(" = ") {
            let v = v.trim().trim_matches('"').to_string();
            match k.trim() {
                "application.name" => cur.app = Some(v),
                "media.name" => cur.media_name = Some(v),
                _ => {}
            }
        }
    }
    out
}

/// `pactl list short sources` -> indices of monitor sources (recording what
/// the speakers play, not a microphone).
pub fn parse_monitor_sources(text: &str) -> Vec<u32> {
    text.lines()
        .filter_map(|l| {
            let mut cols = l.split('\t');
            let idx = cols.next()?.trim().parse().ok()?;
            cols.next()?.ends_with(".monitor").then_some(idx)
        })
        .collect()
}

/// Mic in use, and by which apps: live recording streams from a real input.
/// Level meters ("Peak detect", e.g. pavucontrol) don't count.
pub fn mic_from_pactl(outputs: &[SourceOutput], monitors: &[u32]) -> (bool, Vec<String>) {
    let live: Vec<&SourceOutput> = outputs
        .iter()
        .filter(|o| !o.corked)
        .filter(|o| o.source.is_none_or(|s| !monitors.contains(&s)))
        .filter(|o| o.media_name.as_deref() != Some("Peak detect"))
        .collect();
    let mut users: Vec<String> = live.iter().filter_map(|o| o.app.clone()).collect();
    users.sort();
    users.dedup();
    (!live.is_empty(), users)
}

/// An app is using the device: it started and hasn't stopped.
#[cfg_attr(not(windows), allow(dead_code))]
pub fn consent_in_use(start: Option<u64>, stop: Option<u64>) -> bool {
    start.unwrap_or(0) != 0 && stop.unwrap_or(0) == 0
}

/// A readable name from a consent-store subkey: packaged apps are
/// "Name_publisherhash", desktop apps (under NonPackaged) are paths with `#`
/// for `\` ("C:#Program Files#Zoom#bin#Zoom.exe" -> "Zoom").
#[cfg_attr(not(windows), allow(dead_code))]
pub fn consent_app_name(key: &str, non_packaged: bool) -> String {
    if non_packaged {
        let last = key.rsplit('#').next().unwrap_or(key);
        crate::agents::normalize_name(last).to_string()
    } else {
        match key.rsplit_once('_') {
            Some((name, _)) if !name.is_empty() => name.to_string(),
            _ => key.to_string(),
        }
    }
}

/// `/proc/<pid>/fd` link target is a camera device.
pub fn is_video_device(link: &str) -> bool {
    link.strip_prefix("/dev/video").is_some_and(|n| !n.is_empty() && n.bytes().all(|b| b.is_ascii_digit()))
}

#[cfg(target_os = "linux")]
pub fn current() -> Privacy {
    use std::time::Duration;
    let mut p = Privacy::default();
    if let Some(pactl) = crate::util::system_program("pactl") {
        let outputs = crate::util::run_capture(&pactl, &["list", "source-outputs"], Duration::from_secs(3));
        let sources = crate::util::run_capture(&pactl, &["list", "short", "sources"], Duration::from_secs(3));
        if let Some(outputs) = outputs {
            let monitors = sources.map(|s| parse_monitor_sources(&s)).unwrap_or_default();
            let (in_use, users) = mic_from_pactl(&parse_source_outputs(&outputs), &monitors);
            p.mic_in_use = Some(in_use);
            p.mic_users = users;
        }
    }
    p.camera_in_use = Some(camera_open_by_own_process());
    p
}

/// Whether any process we can read has a `/dev/video*` open.
#[cfg(target_os = "linux")]
fn camera_open_by_own_process() -> bool {
    let Ok(procs) = std::fs::read_dir("/proc") else {
        return false;
    };
    for entry in procs.flatten().take(crate::procs::MAX_PROCESSES) {
        let name = entry.file_name();
        if !name.to_string_lossy().bytes().all(|b| b.is_ascii_digit()) {
            continue;
        }
        let Ok(fds) = std::fs::read_dir(entry.path().join("fd")) else {
            continue;
        };
        for fd in fds.flatten().take(4_096) {
            if std::fs::read_link(fd.path()).is_ok_and(|l| is_video_device(&l.to_string_lossy())) {
                return true;
            }
        }
    }
    false
}

#[cfg(windows)]
pub fn current() -> Privacy {
    let mic = crate::win::consent_users("microphone");
    let cam = crate::win::consent_users("webcam");
    Privacy {
        mic_in_use: mic.as_ref().map(|u| !u.is_empty()),
        camera_in_use: cam.map(|u| !u.is_empty()),
        mic_users: mic.unwrap_or_default(),
    }
}

#[cfg(not(any(target_os = "linux", windows)))]
pub fn current() -> Privacy {
    Privacy::default()
}

#[cfg(test)]
mod tests {
    use super::*;

    const PACTL: &str = "Source Output #42
	Driver: protocol-native.c
	Owner Module: 10
	Client: 55
	Source: 1
	Sample Specification: s16le 1ch 44100Hz
	Corked: no
	Mute: no
	Properties:
		media.name = \"RecordStream\"
		application.name = \"Firefox\"
		application.process.id = \"1234\"

Source Output #43
	Source: 0
	Corked: no
	Properties:
		media.name = \"Peak detect\"
		application.name = \"Volume Control\"

Source Output #44
	Source: 2
	Corked: no
	Properties:
		application.name = \"OBS\"

Source Output #45
	Source: 1
	Corked: yes
	Properties:
		application.name = \"Zoom\"
";

    #[test]
    fn parses_pactl() {
        let outs = parse_source_outputs(PACTL);
        assert_eq!(outs.len(), 4);
        assert_eq!(
            outs[0],
            SourceOutput {
                source: Some(1),
                corked: false,
                app: Some("Firefox".into()),
                media_name: Some("RecordStream".into())
            }
        );
        let monitors = parse_monitor_sources("0\talsa_input.pci.analog-stereo\tPipeWire\ts32le 2ch 48000Hz\tRUNNING\n2\talsa_output.pci.analog-stereo.monitor\tPipeWire\ts32le 2ch 48000Hz\tIDLE\n");
        assert_eq!(monitors, vec![2]);
        assert_eq!(mic_from_pactl(&outs, &monitors), (true, vec!["Firefox".to_string()]));
        assert_eq!(
            mic_from_pactl(&outs[1..], &monitors),
            (false, vec![]),
            "meters, monitors and corked streams don't count"
        );
        assert_eq!(parse_source_outputs(""), vec![]);
        assert_eq!(parse_source_outputs("\tSource: 1\n"), vec![], "fields before a block are ignored");
    }

    #[test]
    fn consent_store_values() {
        assert!(consent_in_use(Some(133_000_000_000_000_000), Some(0)));
        assert!(consent_in_use(Some(133_000_000_000_000_000), None));
        assert!(!consent_in_use(Some(133_000_000_000_000_000), Some(133_000_000_000_000_100)));
        assert!(!consent_in_use(Some(0), Some(0)), "never used");
        assert!(!consent_in_use(None, None));
        assert_eq!(consent_app_name("Microsoft.WindowsCamera_8wekyb3d8bbwe", false), "Microsoft.WindowsCamera");
        assert_eq!(consent_app_name("C:#Program Files#Zoom#bin#Zoom.exe", true), "Zoom");
        assert_eq!(consent_app_name("plain", false), "plain");
        assert_eq!(consent_app_name("_x", false), "_x");
        assert_eq!(consent_app_name("", true), "");
    }

    #[test]
    fn video_devices() {
        assert!(is_video_device("/dev/video0"));
        assert!(is_video_device("/dev/video12"));
        assert!(!is_video_device("/dev/video"));
        assert!(!is_video_device("/dev/videox"));
        assert!(!is_video_device("/dev/null"));
    }
}
