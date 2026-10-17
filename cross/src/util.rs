//! Small bounded helpers: capped file reads, subprocesses with a deadline,
//! and JSON/date formatting.

use std::io::Read;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

/// Largest file or command output we read (1 MiB).
pub const MAX_READ: u64 = 1024 * 1024;

/// A text file, at most `MAX_READ` bytes, lossily decoded. None if unreadable.
pub fn read_capped(path: &Path) -> Option<String> {
    let file = std::fs::File::open(path).ok()?;
    let mut buf = Vec::new();
    file.take(MAX_READ).read_to_end(&mut buf).ok()?;
    Some(String::from_utf8_lossy(&buf).into_owned())
}

/// A sysfs-style single value, trimmed.
#[cfg_attr(not(target_os = "linux"), allow(dead_code))]
pub fn read_value(path: &Path) -> Option<String> {
    read_capped(path).map(|s| s.trim().to_string())
}

/// Folders system tools are taken from. PATH is not searched, so a
/// look-alike earlier on PATH can't stand in for `systemd-inhibit` or `pactl`.
#[cfg(not(windows))]
const SYSTEM_DIRS: &[&str] =
    &["/usr/bin", "/bin", "/usr/sbin", "/sbin", "/usr/local/bin", "/run/current-system/sw/bin"];

/// Absolute path of a system tool, or None if it isn't installed.
/// Debug builds (tests only) accept `KEEPWATCH_TEST_<NAME>` as a stand-in.
pub fn system_program(name: &str) -> Option<PathBuf> {
    #[cfg(debug_assertions)]
    {
        let var = format!("KEEPWATCH_TEST_{}", name.to_uppercase().replace('-', "_"));
        if let Some(p) = std::env::var_os(var).map(PathBuf::from).filter(|p| p.is_absolute()) {
            return Some(p);
        }
    }
    #[cfg(windows)]
    {
        let root = std::env::var_os("SystemRoot").map(PathBuf::from).unwrap_or_else(|| PathBuf::from("C:\\Windows"));
        Some(root.join("System32").join(format!("{name}.exe"))).filter(|p| p.is_file())
    }
    #[cfg(not(windows))]
    {
        SYSTEM_DIRS.iter().map(|d| Path::new(d).join(name)).find(|p| p.is_file())
    }
}

/// Run a command with `LC_ALL=C`, no stdin, and a deadline. Returns stdout
/// (capped at `MAX_READ`) if it exited successfully in time, else None.
pub fn run_capture(program: &Path, args: &[&str], timeout: Duration) -> Option<String> {
    let mut child = Command::new(program)
        .args(args)
        .env("LC_ALL", "C")
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .ok()?;
    let stdout = child.stdout.take()?;
    // Read on a thread so a chatty child can't block on a full pipe while we wait.
    let reader = std::thread::spawn(move || {
        let mut buf = Vec::new();
        let _ = stdout.take(MAX_READ).read_to_end(&mut buf);
        buf
    });
    let deadline = Instant::now() + timeout;
    let status = loop {
        match child.try_wait() {
            Ok(Some(status)) => break Some(status),
            Ok(None) if Instant::now() < deadline => std::thread::sleep(Duration::from_millis(20)),
            _ => {
                let _ = child.kill();
                let _ = child.wait();
                break None;
            }
        }
    };
    let out = reader.join().ok()?;
    match status {
        Some(s) if s.success() => Some(String::from_utf8_lossy(&out).into_owned()),
        _ => None,
    }
}

/// Unix seconds as ISO 8601 UTC ("2026-10-16T17:00:00Z"), like Swift's `.iso8601`.
pub fn iso8601(unix_seconds: u64) -> Option<String> {
    let secs = i64::try_from(unix_seconds).ok()?;
    chrono::DateTime::from_timestamp(secs, 0).map(|d| d.to_rfc3339_opts(chrono::SecondsFormat::Secs, true))
}

/// Pretty JSON with sorted keys (serde_json's `Value` map is a BTreeMap).
pub fn json_string<T: serde::Serialize>(value: &T) -> String {
    serde_json::to_value(value).and_then(|v| serde_json::to_string_pretty(&v)).unwrap_or_else(|_| "{}".into())
}

/// The user's home folder, if known.
pub fn home_dir() -> Option<String> {
    let var = if cfg!(windows) { "USERPROFILE" } else { "HOME" };
    std::env::var(var).ok().filter(|h| !h.is_empty())
}

/// `/home/me/proj` -> `~/proj`.
pub fn abbreviate_home(path: &str, home: Option<&str>) -> String {
    match home {
        Some(h) if path == h => "~".into(),
        Some(h) => match path.strip_prefix(h) {
            Some(rest) if rest.starts_with('/') || rest.starts_with('\\') => format!("~{rest}"),
            _ => path.into(),
        },
        None => path.into(),
    }
}

/// "1.4 GB", "312 MB", like ByteCountFormatter's memory style (base 1024).
pub fn describe_bytes(bytes: u64) -> String {
    const KB: f64 = 1024.0;
    // u64 -> f64 loses precision above 2^53, which doesn't matter for display.
    let b = bytes as f64;
    if b >= KB * KB * KB {
        format!("{:.1} GB", b / (KB * KB * KB))
    } else if b >= KB * KB {
        format!("{:.0} MB", b / (KB * KB))
    } else if b >= KB {
        format!("{:.0} KB", b / KB)
    } else {
        format!("{bytes} bytes")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn formats() {
        assert_eq!(iso8601(1_792_170_000).as_deref(), Some("2026-10-16T17:00:00Z"));
        assert_eq!(iso8601(u64::MAX), None);
        assert_eq!(abbreviate_home("/home/me", Some("/home/me")), "~");
        assert_eq!(abbreviate_home("/home/me/app", Some("/home/me")), "~/app");
        assert_eq!(abbreviate_home("/home/meow", Some("/home/me")), "/home/meow");
        assert_eq!(abbreviate_home("/srv", None), "/srv");
        assert_eq!(describe_bytes(1_503_238_553), "1.4 GB");
        assert_eq!(describe_bytes(327_155_712), "312 MB");
        assert_eq!(describe_bytes(10), "10 bytes");
        assert_eq!(describe_bytes(u64::MAX), "17179869184.0 GB");
    }

    #[test]
    fn json_keys_are_sorted() {
        #[derive(serde::Serialize)]
        struct S {
            b: u8,
            a: Option<u8>,
        }
        assert_eq!(json_string(&S { b: 1, a: None }), "{\n  \"a\": null,\n  \"b\": 1\n}");
    }
}
