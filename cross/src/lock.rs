//! The per-user lock file that lets `awake --off` find a running `awake`.
//! It lives in the user's runtime dir (`$XDG_RUNTIME_DIR/keepwatch` on Linux,
//! `%TEMP%\keepwatch` on Windows), or a private 0700 folder in the temp dir.
//! A pid is only signalled after checking it is still our own keepwatch
//! `awake` with the recorded start time, so a reused pid is never touched.

use std::path::PathBuf;

const LOCK_NAME: &str = "awake.pid";

/// The recorded owner of the lock: pid and start time (unix seconds).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct LockInfo {
    pub pid: u32,
    pub started: u64,
}

pub fn parse_lock(text: &str) -> Option<LockInfo> {
    let mut it = text.split_whitespace();
    let pid: u32 = it.next()?.parse().ok()?;
    let started: u64 = it.next()?.parse().ok()?;
    (pid > 1).then_some(LockInfo { pid, started })
}

/// Whether a process matches a lock: our own `keepwatch awake`, same start time (±1 s).
pub fn matches(lock: &LockInfo, p: &crate::procs::Proc) -> bool {
    p.pid == lock.pid
        && p.own
        && p.name.eq_ignore_ascii_case("keepwatch")
        && p.arguments.first().is_some_and(|a| a == "awake")
        && p.started.is_some_and(|s| s.abs_diff(lock.started) <= 1)
}

/// The lock directory, created if needed. None if it can't be made private.
pub fn lock_dir() -> Option<PathBuf> {
    #[cfg(unix)]
    {
        use std::os::unix::fs::{DirBuilderExt, MetadataExt, PermissionsExt};
        let uid = std::fs::metadata("/proc/self").ok()?.uid();
        let runtime = std::env::var_os("XDG_RUNTIME_DIR").map(PathBuf::from).filter(|p| p.is_absolute());
        let dir = match runtime {
            Some(r) => r.join("keepwatch"),
            None => std::env::temp_dir().join(format!("keepwatch-{uid}")),
        };
        let _ = std::fs::DirBuilder::new().mode(0o700).create(&dir);
        // Refuse a folder someone else made (a shared /tmp), or a symlink.
        let meta = std::fs::symlink_metadata(&dir).ok()?;
        let private = meta.is_dir() && meta.uid() == uid && meta.permissions().mode() & 0o077 == 0;
        private.then_some(dir)
    }
    #[cfg(not(unix))]
    {
        // %TEMP% is per user on Windows.
        let dir = std::env::temp_dir().join("keepwatch");
        let _ = std::fs::create_dir_all(&dir);
        let meta = std::fs::symlink_metadata(&dir).ok()?;
        (meta.is_dir() && !meta.file_type().is_symlink()).then_some(dir)
    }
}

pub fn read() -> Option<LockInfo> {
    let path = lock_dir()?.join(LOCK_NAME);
    let meta = std::fs::symlink_metadata(&path).ok()?;
    if !meta.is_file() || meta.len() > 4096 {
        return None;
    }
    parse_lock(&crate::util::read_capped(&path)?)
}

/// Record this process as the running `awake`.
pub fn write(info: LockInfo) -> std::io::Result<()> {
    use std::io::Write;
    let dir = lock_dir().ok_or_else(|| std::io::Error::other("no private folder for the lock file"))?;
    let path = dir.join(LOCK_NAME);
    let tmp = dir.join(format!("{LOCK_NAME}.{}", info.pid));
    let mut opts = std::fs::OpenOptions::new();
    opts.write(true).create(true).truncate(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        opts.mode(0o600);
    }
    let mut f = opts.open(&tmp)?;
    writeln!(f, "{} {}", info.pid, info.started)?;
    drop(f);
    std::fs::rename(&tmp, &path)
}

/// Remove the lock if it still names `pid`.
pub fn remove_if(pid: u32) {
    if read().is_some_and(|l| l.pid == pid) {
        if let Some(dir) = lock_dir() {
            let _ = std::fs::remove_file(dir.join(LOCK_NAME));
        }
    }
}

/// Remove the lock unconditionally (it is stale or we just stopped its owner).
pub fn remove() {
    if let Some(dir) = lock_dir() {
        let _ = std::fs::remove_file(dir.join(LOCK_NAME));
    }
}

/// The pid of a live `keepwatch awake` recorded in the lock, re-checked now.
/// A stale lock is removed.
pub fn live_awake() -> Option<u32> {
    let lock = read()?;
    let alive = crate::procs::snapshot_of(&[lock.pid]).iter().any(|p| matches(&lock, p));
    if alive {
        Some(lock.pid)
    } else {
        remove();
        None
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::procs::Proc;

    fn proc(pid: u32, name: &str, args: &[&str], own: bool, started: u64) -> Proc {
        Proc {
            pid,
            name: name.into(),
            arguments: args.iter().map(|s| s.to_string()).collect(),
            exe: None,
            cwd: None,
            started: Some(started),
            own,
            memory: 0,
            cpu_ms: 0,
        }
    }

    #[test]
    fn parses_lock_files() {
        assert_eq!(parse_lock("4242 1792170000\n"), Some(LockInfo { pid: 4242, started: 1_792_170_000 }));
        for bad in ["", "4242", "1 5", "0 5", "-3 5", "x y", "99999999999 1"] {
            assert_eq!(parse_lock(bad), None, "{bad}");
        }
    }

    #[test]
    fn only_our_own_awake_with_the_same_start_matches() {
        let lock = LockInfo { pid: 50, started: 1000 };
        assert!(matches(&lock, &proc(50, "keepwatch", &["awake", "--for", "1m"], true, 1000)));
        assert!(matches(&lock, &proc(50, "keepwatch", &["awake"], true, 1001)));
        assert!(!matches(&lock, &proc(50, "keepwatch", &["awake"], true, 2000)), "pid reused later");
        assert!(!matches(&lock, &proc(50, "bash", &["awake"], true, 1000)));
        assert!(!matches(&lock, &proc(50, "keepwatch", &["awake"], false, 1000)), "someone else's");
        assert!(!matches(&lock, &proc(50, "keepwatch", &["run", "--", "x"], true, 1000)));
        assert!(!matches(&lock, &proc(51, "keepwatch", &["awake"], true, 1000)));
    }
}
