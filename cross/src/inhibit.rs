//! Holding the computer awake, and reading who else does.
//!
//! Linux: a `systemd-inhibit --what=idle:sleep --mode=block … cat` child whose
//! stdin is a pipe from keepwatch. If keepwatch exits for any reason, even
//! SIGKILL, `cat` reads EOF, exits, and logind drops the lock.
//! Windows: `SetThreadExecutionState` on the calling thread, which Windows
//! clears when the thread or process ends.
// The pure Linux parsers are compiled (and tested) everywhere, used live on Linux only.
#![cfg_attr(not(target_os = "linux"), allow(dead_code))]

/// One row of `systemd-inhibit --list`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Inhibitor {
    pub who: String,
    pub pid: Option<u32>,
    pub what: String,
    pub mode: String,
}

/// Parse `systemd-inhibit --list` (run with LC_ALL=C). Columns are sliced at
/// the header's positions, since WHO and WHY may contain spaces.
pub fn parse_inhibitors(text: &str) -> Vec<Inhibitor> {
    let mut lines = text.lines();
    let Some(header) = lines.find(|l| l.trim_start().starts_with("WHO")) else {
        return Vec::new();
    };
    let header: Vec<char> = header.chars().collect();
    let names = ["WHO", "UID", "USER", "PID", "COMM", "WHAT", "WHY", "MODE"];
    let mut starts: Vec<(usize, &str)> = Vec::new();
    let mut i = 0;
    while i < header.len() {
        let at_word = header.get(i).is_some_and(|c| !c.is_whitespace())
            && (i == 0 || header.get(i - 1).is_some_and(|c| c.is_whitespace()));
        if at_word {
            let word: String = header.iter().skip(i).take_while(|c| !c.is_whitespace()).collect();
            if let Some(n) = names.iter().find(|n| **n == word) {
                starts.push((i, n));
            }
        }
        i += 1;
    }
    let col = |row: &[char], name: &str| -> Option<String> {
        let idx = starts.iter().position(|(_, n)| *n == name)?;
        let (start, _) = *starts.get(idx)?;
        let end = starts.get(idx + 1).map_or(row.len(), |(s, _)| *s).min(row.len());
        Some(row.get(start..end)?.iter().collect::<String>().trim().to_string())
    };
    let mut out = Vec::new();
    for line in lines.take(4_096) {
        if line.trim().is_empty() || line.contains("inhibitors listed") {
            continue;
        }
        let row: Vec<char> = line.chars().collect();
        // MODE is always the last word; the rest is best effort.
        let Some(mode) = line.split_whitespace().last().map(str::to_string) else {
            continue;
        };
        let (Some(who), Some(what)) = (col(&row, "WHO"), col(&row, "WHAT")) else {
            continue;
        };
        let pid = col(&row, "PID").and_then(|p| p.parse().ok());
        out.push(Inhibitor { who, pid, what, mode });
    }
    out
}

/// Inhibitors that actually stop idle sleep: `block` mode, `idle` or `sleep`.
/// `delay` locks (NetworkManager, GNOME) only postpone sleep briefly.
pub fn prevented_by(list: &[Inhibitor]) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    for i in list {
        let blocks = i.mode == "block" && i.what.split(':').any(|w| w == "idle" || w == "sleep");
        if blocks && !out.contains(&i.who) {
            out.push(i.who.clone());
        }
    }
    out
}

/// What to hold.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Hold {
    /// Idle and sleep (`awake`, `run`).
    Awake,
    /// Also the lid switch (`lid start`): logind doesn't act on closing the lid.
    LidClosed,
}

impl Hold {
    /// The `systemd-inhibit --what=` list.
    pub fn what(self) -> &'static str {
        match self {
            Hold::Awake => "idle:sleep",
            Hold::LidClosed => "handle-lid-switch:sleep:idle",
        }
    }
}

/// Whether some app holds a block inhibitor on the lid switch, so closing the
/// lid won't suspend: the Linux counterpart of macOS `SleepDisabled`.
pub fn lid_switch_blocked(list: &[Inhibitor]) -> bool {
    list.iter().any(|i| i.mode == "block" && i.what.split(':').any(|w| w == "handle-lid-switch"))
}

/// A `systemd-inhibit` failure, explained. polkit refusals get a clear message.
pub fn explain_failure(hold: Hold, stderr: &str) -> String {
    let msg = crate::util::clean_line(stderr.trim(), 300);
    let lower = msg.to_lowercase();
    let refused = ["access denied", "not authorized", "authentication", "permission denied", "not allowed"]
        .iter()
        .any(|m| lower.contains(m));
    match (hold, refused) {
        (Hold::LidClosed, true) => format!(
            "the system refused to let keepwatch hold the lid switch ({msg}). Your polkit policy doesn't allow \
             this user to block lid-switch handling, so a lid session can't start; keepwatch never asks for root."
        ),
        (Hold::Awake, true) => format!("the system refused the keep-awake lock ({msg})"),
        _ if msg.is_empty() => "couldn't keep this computer awake: systemd-inhibit exited".into(),
        _ => format!("couldn't keep this computer awake: {msg}"),
    }
}

/// The current inhibitor list, or None if it can't be read.
#[cfg(target_os = "linux")]
pub fn current_inhibitors() -> Option<Vec<Inhibitor>> {
    let program = crate::util::system_program("systemd-inhibit")?;
    let text = crate::util::run_capture(&program, &["--list", "--no-pager"], std::time::Duration::from_secs(3))?;
    Some(parse_inhibitors(&text))
}

#[cfg(target_os = "linux")]
pub use linux::Holder;

#[cfg(target_os = "linux")]
mod linux {
    use std::io::Read;
    use std::os::unix::process::CommandExt;
    use std::process::{Child, ChildStdin, Command, Stdio};
    use std::time::{Duration, Instant};

    pub struct Holder {
        child: Child,
        stdin: Option<ChildStdin>,
    }

    impl Holder {
        /// Take a block inhibitor for `hold`. `display` can't be honoured
        /// separately on Linux yet (screen blanking is up to the desktop).
        pub fn start(why: &str, _display: bool, hold: super::Hold) -> Result<Holder, String> {
            let missing = "systemd-inhibit isn't installed, so keepwatch can't keep this computer awake \
                           (it needs systemd-logind)";
            let program = crate::util::system_program("systemd-inhibit").ok_or(missing)?;
            let cat = crate::util::system_program("cat").ok_or("couldn't find cat in the system folders")?;
            let why = why.chars().filter(|c| !c.is_control()).take(120).collect::<String>();
            let mut child = Command::new(program)
                .args([&format!("--what={}", hold.what()), "--who=keepwatch", &format!("--why={why}"), "--mode=block"])
                .arg(cat)
                .env("LC_ALL", "C")
                .stdin(Stdio::piped())
                .stdout(Stdio::null())
                .stderr(Stdio::piped())
                // Own process group, so Ctrl-C in the terminal doesn't end the
                // hold before `run`'s child has finished.
                .process_group(0)
                .spawn()
                .map_err(|e| format!("couldn't start systemd-inhibit: {e}"))?;
            let stdin = child.stdin.take();
            let pid = child.id();
            // Spawning isn't holding: wait until logind lists us, or the helper fails.
            let started = Instant::now();
            loop {
                if let Ok(Some(_)) = child.try_wait() {
                    let mut msg = String::new();
                    if let Some(err) = child.stderr.take() {
                        let _ = err.take(4096).read_to_string(&mut msg);
                    }
                    return Err(super::explain_failure(hold, &msg));
                }
                let elapsed = started.elapsed();
                if elapsed >= Duration::from_millis(300) {
                    match super::current_inhibitors() {
                        Some(list) if list.iter().any(|i| i.who == "keepwatch" && i.pid == Some(pid)) => break,
                        // No way to confirm: if it is still running after a moment, it holds.
                        None => break,
                        Some(_) if elapsed >= Duration::from_secs(2) => break,
                        Some(_) => {}
                    }
                }
                std::thread::sleep(Duration::from_millis(100));
            }
            Ok(Holder { child, stdin })
        }

        /// Whether the inhibitor is still held.
        pub fn alive(&mut self) -> bool {
            matches!(self.child.try_wait(), Ok(None))
        }

        pub fn release(mut self) {
            drop(self.stdin.take()); // EOF for `cat`: it exits and the lock goes away.
            let deadline = Instant::now() + Duration::from_secs(2);
            while Instant::now() < deadline {
                if !matches!(self.child.try_wait(), Ok(None)) {
                    return;
                }
                std::thread::sleep(Duration::from_millis(20));
            }
            let _ = self.child.kill();
            let _ = self.child.wait();
        }
    }
}

#[cfg(windows)]
pub struct Holder;

#[cfg(windows)]
impl Holder {
    pub fn start(_why: &str, display: bool, hold: Hold) -> Result<Holder, String> {
        if hold == Hold::LidClosed {
            return Err("lid sessions are not available on Windows yet".into());
        }
        if crate::win::keep_awake(true, display) {
            Ok(Holder)
        } else {
            Err("Windows refused the keep-awake request".into())
        }
    }

    pub fn alive(&mut self) -> bool {
        true
    }

    pub fn release(self) {
        crate::win::keep_awake(false, false);
    }
}

#[cfg(not(any(target_os = "linux", windows)))]
pub struct Holder;

#[cfg(not(any(target_os = "linux", windows)))]
impl Holder {
    pub fn start(_why: &str, _display: bool, _hold: Hold) -> Result<Holder, String> {
        Err("this build of keepwatch is for Linux and Windows; on macOS use the Swift keepwatch".into())
    }
    pub fn alive(&mut self) -> bool {
        false
    }
    pub fn release(self) {}
}

#[cfg(test)]
mod tests {
    use super::*;

    const LIST: &str = "\
WHO            UID  USER PID  COMM            WHAT                                                     WHY                                       MODE
ModemManager   0    root 774  ModemManager    sleep                                                    ModemManager needs to reset devices       delay
NetworkManager 0    root 715  NetworkManager  sleep                                                    NetworkManager needs to turn off networks delay
GNOME Shell    1000 me   2088 gnome-shell     sleep                                                    GNOME needs to lock the screen            delay
Firefox        1000 me   3100 firefox         idle                                                     playing video                             block
keepwatch      1000 me   9999 systemd-inhibit idle:sleep                                               keepwatch run: cargo                      block
Totem Player   1000 me   4000 totem           handle-lid-switch                                        lid                                       block

6 inhibitors listed.
";

    #[test]
    fn parses_inhibitor_list() {
        let l = parse_inhibitors(LIST);
        assert_eq!(l.len(), 6);
        assert_eq!(
            l[2],
            Inhibitor { who: "GNOME Shell".into(), pid: Some(2088), what: "sleep".into(), mode: "delay".into() }
        );
        assert_eq!(l[4].who, "keepwatch");
        assert_eq!(l[4].pid, Some(9999));
        assert_eq!(prevented_by(&l), vec!["Firefox".to_string(), "keepwatch".to_string()]);
        assert_eq!(parse_inhibitors(""), vec![]);
        assert_eq!(parse_inhibitors("No inhibitors.\n"), vec![]);
        assert_eq!(parse_inhibitors("WHO\nx\n"), vec![], "no WHAT column: nothing to report");
    }

    #[test]
    fn lid_switch_blocks_and_polkit_refusals() {
        let l = parse_inhibitors(LIST);
        assert!(lid_switch_blocked(&l), "Totem blocks the lid switch");
        assert!(!lid_switch_blocked(&l[..5]));
        let delay =
            vec![Inhibitor { who: "x".into(), pid: None, what: "handle-lid-switch".into(), mode: "delay".into() }];
        assert!(!lid_switch_blocked(&delay), "delay doesn't keep it running");
        let m = explain_failure(Hold::LidClosed, "Failed to inhibit: Access denied\n");
        assert!(m.contains("refused") && m.contains("polkit") && m.contains("Access denied"), "{m}");
        assert!(explain_failure(Hold::Awake, "").contains("systemd-inhibit exited"));
        assert!(explain_failure(Hold::LidClosed, "Failed to connect to bus").starts_with("couldn't keep"));
        assert_eq!(Hold::LidClosed.what(), "handle-lid-switch:sleep:idle");
    }

    #[test]
    fn short_and_unicode_rows_do_not_panic() {
        let text = "WHO UID USER PID COMM WHAT WHY MODE\nÜbersetzer 1000 ü 12 ü idle wörk block\nx\n\n";
        let l = parse_inhibitors(text);
        assert!(l.iter().all(|i| !i.mode.is_empty()));
    }
}
