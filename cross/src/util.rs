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

/// A debug-only test stand-in: `KEEPWATCH_TEST_<NAME>` when `enabled`.
/// Callers pass `cfg!(debug_assertions)`, so release builds never read these.
pub fn test_override_if(enabled: bool, name: &str) -> Option<std::ffi::OsString> {
    if !enabled {
        return None;
    }
    std::env::var_os(format!("KEEPWATCH_TEST_{name}")).filter(|v| !v.is_empty())
}

/// `test_override_if(cfg!(debug_assertions), name)`.
pub fn test_override(name: &str) -> Option<std::ffi::OsString> {
    test_override_if(cfg!(debug_assertions), name)
}

/// A debug-only stand-in path: absolute, or ignored.
pub fn test_path(name: &str) -> Option<PathBuf> {
    test_override(name).map(PathBuf::from).filter(|p| p.is_absolute())
}

/// Absolute path of a system tool, or None if it isn't installed.
/// Debug builds (tests only) accept `KEEPWATCH_TEST_<NAME>` as a stand-in.
pub fn system_program(name: &str) -> Option<PathBuf> {
    if let Some(p) = test_path(&name.to_uppercase().replace('-', "_")) {
        return Some(p);
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

/// Our own user id (Unix).
#[cfg(unix)]
pub fn my_uid() -> Option<u32> {
    use std::os::unix::fs::MetadataExt;
    std::fs::metadata("/proc/self").ok().map(|m| m.uid())
}

/// `dir`, created (mode 0700) if missing, if it is a real folder of ours that
/// others can't write to. Never a symlink.
pub fn own_dir(dir: &Path) -> Option<PathBuf> {
    #[cfg(unix)]
    {
        use std::os::unix::fs::{DirBuilderExt, MetadataExt, PermissionsExt};
        if !dir.is_absolute() {
            return None;
        }
        if let Some(parent) = dir.parent() {
            let _ = std::fs::create_dir_all(parent);
        }
        let _ = std::fs::DirBuilder::new().mode(0o700).create(dir);
        let meta = std::fs::symlink_metadata(dir).ok()?;
        let ok = meta.is_dir() && Some(meta.uid()) == my_uid() && meta.permissions().mode() & 0o022 == 0;
        ok.then(|| dir.to_path_buf())
    }
    #[cfg(not(unix))]
    {
        let _ = std::fs::create_dir_all(dir);
        let meta = std::fs::symlink_metadata(dir).ok()?;
        (meta.is_dir() && !meta.file_type().is_symlink()).then(|| dir.to_path_buf())
    }
}

/// Open options that never follow a symlink at the last path component, and
/// create files as 0600.
fn private_options() -> std::fs::OpenOptions {
    #[allow(unused_mut)]
    let mut opts = std::fs::OpenOptions::new();
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        opts.mode(0o600).custom_flags(libc::O_NOFOLLOW);
    }
    opts
}

/// Replace `dir/name` with `data` atomically (a 0600 temp file, then rename).
/// Neither the temp file nor the target is followed if it is a symlink: the
/// temp is created fresh and rename replaces a link, never its target.
pub fn write_atomic(dir: &Path, name: &str, data: &[u8]) -> std::io::Result<()> {
    use std::io::Write;
    let tmp = dir.join(format!(".{name}.{}.tmp", std::process::id()));
    let _ = std::fs::remove_file(&tmp);
    let mut f = private_options().write(true).create_new(true).open(&tmp)?;
    let written = f.write_all(data).and_then(|()| f.sync_all());
    drop(f);
    if let Err(e) = written.and_then(|()| std::fs::rename(&tmp, dir.join(name))) {
        let _ = std::fs::remove_file(&tmp);
        return Err(e);
    }
    Ok(())
}

/// Open `path` for appending (created 0600), refusing a symlink.
pub fn open_append_private(path: &Path) -> std::io::Result<std::fs::File> {
    private_options().append(true).create(true).open(path)
}

/// A regular file (not a symlink) of at most `cap` bytes, lossily decoded.
pub fn read_regular_capped(path: &Path, cap: u64) -> Option<String> {
    let meta = std::fs::symlink_metadata(path).ok()?;
    if !meta.is_file() || meta.len() > cap {
        return None;
    }
    let file = std::fs::File::open(path).ok()?;
    let mut buf = Vec::new();
    file.take(cap).read_to_end(&mut buf).ok()?;
    Some(String::from_utf8_lossy(&buf).into_owned())
}

/// Text from other software, made safe for one log or menu line: control
/// characters dropped, at most `max` characters.
pub fn clean_line(s: &str, max: usize) -> String {
    s.chars().filter(|c| !c.is_control()).take(max).collect()
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
    fn test_overrides_are_off_unless_enabled() {
        std::env::set_var("KEEPWATCH_TEST_UTIL_PROBE", "/x");
        assert_eq!(test_override_if(false, "UTIL_PROBE"), None, "release builds never read stand-ins");
        assert_eq!(test_override_if(true, "UTIL_PROBE").as_deref(), Some(std::ffi::OsStr::new("/x")));
        assert_eq!(test_override_if(true, "UTIL_PROBE_MISSING"), None);
        std::env::remove_var("KEEPWATCH_TEST_UTIL_PROBE");
    }

    #[cfg(unix)]
    #[test]
    fn atomic_writes_are_private_and_never_follow_links() {
        use std::os::unix::fs::PermissionsExt;
        let dir = std::env::temp_dir().join(format!("kw-util-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let dir = own_dir(&dir).expect("own dir");
        write_atomic(&dir, "a.txt", b"one").unwrap();
        assert_eq!(std::fs::read_to_string(dir.join("a.txt")).unwrap(), "one");
        assert_eq!(std::fs::metadata(dir.join("a.txt")).unwrap().permissions().mode() & 0o777, 0o600);
        // A symlink at the target is replaced, not written through.
        let victim = dir.join("victim");
        std::fs::write(&victim, "keep").unwrap();
        std::os::unix::fs::symlink(&victim, dir.join("b.txt")).unwrap();
        write_atomic(&dir, "b.txt", b"new").unwrap();
        assert_eq!(std::fs::read_to_string(&victim).unwrap(), "keep");
        assert!(!std::fs::symlink_metadata(dir.join("b.txt")).unwrap().file_type().is_symlink());
        // Appending refuses a symlink.
        std::os::unix::fs::symlink(&victim, dir.join("log")).unwrap();
        assert!(open_append_private(&dir.join("log")).is_err());
        assert_eq!(std::fs::read_to_string(&victim).unwrap(), "keep");
        assert_eq!(read_regular_capped(&dir.join("log"), 100), None, "symlinks aren't read");
        assert_eq!(read_regular_capped(&dir.join("a.txt"), 2), None, "too big");
        // A link as the folder itself is refused.
        std::os::unix::fs::symlink(&dir, dir.with_extension("link")).unwrap();
        assert_eq!(own_dir(&dir.with_extension("link")), None);
        assert_eq!(own_dir(Path::new("relative")), None);
        let _ = std::fs::remove_file(dir.with_extension("link"));
        let _ = std::fs::remove_dir_all(&dir);
        assert_eq!(clean_line("a\nb\u{1b}[31mc", 3), "ab[");
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
