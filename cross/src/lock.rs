//! Per-user lock files that let `awake --off` and `lid end` (and the tray)
//! find a running session. They live in the user's runtime dir
//! (`$XDG_RUNTIME_DIR/keepwatch` on Linux, `%TEMP%\keepwatch` on Windows), or
//! a private 0700 folder in the temp dir.
//!
//! A lock names a pid and its start time. A pid is only signalled or asked to
//! stop after checking it is still our own `keepwatch awake` / `keepwatch lid
//! start`, or our own `keepwatch-tray`, with the recorded start time, so a
//! reused pid is never touched.
//!
//! Stopping: a CLI `awake` is sent SIGTERM (its inhibitor goes with it). Lid
//! sessions and the tray are asked through a stop file naming their pid, so
//! they can log why they ended and suspend if the lid is shut; the tray is
//! never signalled, since that would end the tray itself.

use std::path::PathBuf;
use std::time::{Duration, Instant};

/// Which session a lock is for.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Kind {
    Awake,
    Lid,
}

impl Kind {
    fn base(self) -> &'static str {
        match self {
            Kind::Awake => "awake",
            Kind::Lid => "lid",
        }
    }
    fn lock_name(self) -> String {
        format!("{}.pid", self.base())
    }
    fn stop_name(self) -> String {
        format!("{}.stop", self.base())
    }
    fn state_name(self) -> String {
        format!("{}.json", self.base())
    }
}

/// The name of the tray binary, as the process list shows it (fits `comm`'s 15 bytes).
pub const TRAY_NAME: &str = "keepwatch-tray";

/// Who holds a session.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Owner {
    Cli,
    Tray,
}

impl Owner {
    pub fn as_str(self) -> &'static str {
        match self {
            Owner::Cli => "cli",
            Owner::Tray => "tray",
        }
    }
}

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

/// Whether a process matches a lock: our own `keepwatch awake` (or `lid`), or
/// our own `keepwatch-tray`, with the same start time (±1 s). Returns the owner.
pub fn matches(kind: Kind, lock: &LockInfo, p: &crate::procs::Proc) -> Option<Owner> {
    if p.pid != lock.pid || !p.own || !p.started.is_some_and(|s| s.abs_diff(lock.started) <= 1) {
        return None;
    }
    if p.name.eq_ignore_ascii_case(TRAY_NAME) {
        return Some(Owner::Tray);
    }
    let args: Vec<&str> = p.arguments.iter().take(2).map(String::as_str).collect();
    let command = match kind {
        Kind::Awake => args.first() == Some(&"awake"),
        Kind::Lid => args == ["lid", "start"],
    };
    let cli = p.name.eq_ignore_ascii_case("keepwatch") && command;
    cli.then_some(Owner::Cli)
}

/// The lock directory, created if needed. None if it can't be made private.
pub fn lock_dir() -> Option<PathBuf> {
    #[cfg(unix)]
    {
        use std::os::unix::fs::{DirBuilderExt, MetadataExt, PermissionsExt};
        let uid = crate::util::my_uid()?;
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

pub fn read(kind: Kind) -> Option<LockInfo> {
    let path = lock_dir()?.join(kind.lock_name());
    parse_lock(&crate::util::read_regular_capped(&path, 4096)?)
}

/// Record this process as the owner of `kind`.
pub fn write(kind: Kind, info: LockInfo) -> std::io::Result<()> {
    let dir = lock_dir().ok_or_else(|| std::io::Error::other("no private folder for the lock file"))?;
    crate::util::write_atomic(&dir, &kind.lock_name(), format!("{} {}\n", info.pid, info.started).as_bytes())
}

/// Remove the lock (and its state file) if it still names `pid`.
pub fn remove_if(kind: Kind, pid: u32) {
    if read(kind).is_some_and(|l| l.pid == pid) {
        remove(kind);
    }
}

/// Remove the lock and its state unconditionally (stale, or its owner just stopped).
pub fn remove(kind: Kind) {
    if let Some(dir) = lock_dir() {
        let _ = std::fs::remove_file(dir.join(kind.lock_name()));
        let _ = std::fs::remove_file(dir.join(kind.state_name()));
    }
}

/// A live session holder: its pid and whether it is the CLI or the tray.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Live {
    pub pid: u32,
    pub owner: Owner,
}

/// The live owner recorded in the lock, re-checked now. A stale lock is removed.
pub fn live(kind: Kind) -> Option<Live> {
    let lock = read(kind)?;
    let owner = crate::procs::snapshot_of(&[lock.pid]).iter().find_map(|p| matches(kind, &lock, p));
    match owner {
        Some(owner) => Some(Live { pid: lock.pid, owner }),
        None => {
            remove(kind);
            None
        }
    }
}

/// Why a session is asked to stop.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum StopIntent {
    /// The user ended it (`lid end`, `awake --off`, the tray's End).
    End,
    /// A new session takes over: a lid session must not suspend on the way out.
    Replace,
}

/// The stop file's text: "PID end" or "PID replace".
pub fn stop_text(pid: u32, intent: StopIntent) -> String {
    let word = match intent {
        StopIntent::End => "end",
        StopIntent::Replace => "replace",
    };
    format!("{pid} {word}\n")
}

/// Parse a stop file for `pid`. A request naming another pid (left from an
/// earlier session) is ignored; an unknown intent counts as End.
pub fn parse_stop(text: &str, pid: u32) -> Option<StopIntent> {
    let mut it = text.split_whitespace();
    let named: u32 = it.next()?.parse().ok()?;
    if named != pid {
        return None;
    }
    Some(if it.next() == Some("replace") { StopIntent::Replace } else { StopIntent::End })
}

/// Ask the owner `pid` to stop its `kind` session (it checks about once a second).
pub fn request_stop(kind: Kind, pid: u32, intent: StopIntent) -> std::io::Result<()> {
    let dir = lock_dir().ok_or_else(|| std::io::Error::other("no private folder for the stop file"))?;
    crate::util::write_atomic(&dir, &kind.stop_name(), stop_text(pid, intent).as_bytes())
}

/// Whether someone asked `pid` to stop its `kind` session, and why.
pub fn stop_requested(kind: Kind, pid: u32) -> Option<StopIntent> {
    let dir = lock_dir()?;
    parse_stop(&crate::util::read_regular_capped(&dir.join(kind.stop_name()), 64)?, pid)
}

/// Remove a stop request.
pub fn clear_stop(kind: Kind) {
    if let Some(dir) = lock_dir() {
        let _ = std::fs::remove_file(dir.join(kind.stop_name()));
    }
}

/// Write the owner's description of its session (small JSON) next to the lock.
pub fn write_state(kind: Kind, json: &str) -> std::io::Result<()> {
    let dir = lock_dir().ok_or_else(|| std::io::Error::other("no private folder for the state file"))?;
    crate::util::write_atomic(&dir, &kind.state_name(), json.as_bytes())
}

/// The owner's description of its session, at most 64 KB.
pub fn read_state(kind: Kind) -> Option<String> {
    crate::util::read_regular_capped(&lock_dir()?.join(kind.state_name()), 64 * 1024)
}

/// How `stop` went.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum StopResult {
    NotRunning,
    Stopped(Live),
    Failed(Live),
}

fn gone(kind: Kind, pid: u32) -> bool {
    procs_gone(pid) || read(kind).is_none_or(|l| l.pid != pid)
}

fn procs_gone(pid: u32) -> bool {
    crate::procs::snapshot_of(&[pid]).is_empty()
}

fn wait_until(timeout: Duration, mut done: impl FnMut() -> bool) -> bool {
    let start = Instant::now();
    loop {
        if done() {
            return true;
        }
        if start.elapsed() >= timeout {
            return false;
        }
        std::thread::sleep(Duration::from_millis(100));
    }
}

/// Stop the live `kind` session, whoever holds it (never this process).
pub fn stop(kind: Kind, intent: StopIntent) -> StopResult {
    let Some(live) = live(kind) else {
        return StopResult::NotRunning;
    };
    if live.pid == std::process::id() {
        return StopResult::Failed(live);
    }
    let sigterm = |live: Live| -> StopResult {
        if !crate::procs::terminate(live.pid) {
            return StopResult::Failed(live);
        }
        wait_until(Duration::from_secs(3), || procs_gone(live.pid));
        remove_if(kind, live.pid);
        StopResult::Stopped(live)
    };
    if kind == Kind::Awake && live.owner == Owner::Cli {
        return sigterm(live);
    }
    if request_stop(kind, live.pid, intent).is_ok() && wait_until(Duration::from_secs(10), || gone(kind, live.pid)) {
        clear_stop(kind);
        return StopResult::Stopped(live);
    }
    clear_stop(kind);
    match live.owner {
        // A CLI session that didn't answer: SIGTERM ends it, and its inhibitor with it.
        Owner::Cli => sigterm(live),
        Owner::Tray => StopResult::Failed(live),
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
        assert_eq!(parse_lock("4242 1792170000 extra\n"), Some(LockInfo { pid: 4242, started: 1_792_170_000 }));
        for bad in ["", "4242", "1 5", "0 5", "-3 5", "x y", "99999999999 1"] {
            assert_eq!(parse_lock(bad), None, "{bad}");
        }
    }

    #[test]
    fn stop_files_name_a_pid_and_an_intent() {
        assert_eq!(parse_stop(&stop_text(42, StopIntent::End), 42), Some(StopIntent::End));
        assert_eq!(parse_stop(&stop_text(42, StopIntent::Replace), 42), Some(StopIntent::Replace));
        assert_eq!(parse_stop("42\n", 42), Some(StopIntent::End), "older format: end");
        assert_eq!(parse_stop("42 bogus", 42), Some(StopIntent::End), "unknown intent: end");
        assert_eq!(parse_stop("43 replace", 42), None, "another session's request");
        assert_eq!(parse_stop("", 42), None);
        assert_eq!(parse_stop("x replace", 42), None);
    }

    #[test]
    fn only_our_own_session_with_the_same_start_matches() {
        let lock = LockInfo { pid: 50, started: 1000 };
        let awake = |p: &Proc| matches(Kind::Awake, &lock, p);
        assert_eq!(awake(&proc(50, "keepwatch", &["awake", "--for", "1m"], true, 1000)), Some(Owner::Cli));
        assert_eq!(awake(&proc(50, "keepwatch", &["awake"], true, 1001)), Some(Owner::Cli));
        assert_eq!(awake(&proc(50, "keepwatch", &["awake"], true, 2000)), None, "pid reused later");
        assert_eq!(awake(&proc(50, "bash", &["awake"], true, 1000)), None);
        assert_eq!(awake(&proc(50, "keepwatch", &["awake"], false, 1000)), None, "someone else's");
        assert_eq!(awake(&proc(50, "keepwatch", &["run", "--", "x"], true, 1000)), None);
        assert_eq!(awake(&proc(50, "keepwatch", &["lid", "start"], true, 1000)), None, "a lid session isn't awake");
        assert_eq!(awake(&proc(51, "keepwatch", &["awake"], true, 1000)), None);
        assert_eq!(awake(&proc(50, "keepwatch-tray", &[], true, 1000)), Some(Owner::Tray));
        assert_eq!(awake(&proc(50, "keepwatch-tray", &[], false, 1000)), None, "someone else's tray");
        assert_eq!(awake(&proc(50, "keepwatch-tray", &[], true, 3000)), None);
        let lid = |p: &Proc| matches(Kind::Lid, &lock, p);
        assert_eq!(lid(&proc(50, "keepwatch", &["lid", "start", "--hours", "3"], true, 1000)), Some(Owner::Cli));
        assert_eq!(lid(&proc(50, "keepwatch", &["awake"], true, 1000)), None);
        assert_eq!(lid(&proc(50, "keepwatch", &["lid", "status"], true, 1000)), None);
        assert_eq!(lid(&proc(50, "keepwatch-tray", &[], true, 1000)), Some(Owner::Tray));
    }
}
