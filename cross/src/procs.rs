//! Process snapshots through `sysinfo` (it reads `/proc` on Linux and the
//! Toolhelp/NT APIs on Windows), and the one place that signals a process.

use crate::agents::{self, RunningProcess};
use sysinfo::{Pid, ProcessRefreshKind, ProcessStatus, ProcessesToUpdate, System, UpdateKind};

/// Upper bound on processes we look at, as in the Swift `ProcessList`.
pub const MAX_PROCESSES: usize = 16_384;

#[derive(Debug, Clone)]
pub struct Proc {
    pub pid: u32,
    /// Executable name without `.exe`.
    pub name: String,
    /// argv[1..].
    pub arguments: Vec<String>,
    pub exe: Option<String>,
    pub cwd: Option<String>,
    /// Unix seconds.
    pub started: Option<u64>,
    /// Owned by the user running keepwatch.
    pub own: bool,
    /// Resident memory in bytes.
    pub memory: u64,
    /// Accumulated CPU time in milliseconds.
    pub cpu_ms: u64,
}

impl Proc {
    pub fn running(&self) -> RunningProcess {
        RunningProcess { pid: self.pid, name: self.name.clone(), arguments: self.arguments.clone() }
    }
}

fn refresh_kind(details: bool) -> ProcessRefreshKind {
    let kind = ProcessRefreshKind::nothing().with_user(UpdateKind::Always).with_cmd(UpdateKind::Always);
    if details {
        kind.with_cwd(UpdateKind::Always).with_exe(UpdateKind::Always).with_memory().with_cpu()
    } else {
        kind
    }
}

/// All visible processes (at most `MAX_PROCESSES`), sorted by pid, with
/// folder, executable, memory and CPU time.
pub fn snapshot() -> Vec<Proc> {
    let mut sys = System::new();
    sys.refresh_processes_specifics(ProcessesToUpdate::All, true, refresh_kind(true));
    collect(&sys)
}

/// Names, arguments and owners only: cheap enough to poll every 2 s.
pub fn snapshot_light() -> Vec<Proc> {
    let mut sys = System::new();
    sys.refresh_processes_specifics(ProcessesToUpdate::All, true, refresh_kind(false));
    collect(&sys)
}

/// The listed pids only, fresh, for re-checks and CPU sampling.
pub fn snapshot_of(pids: &[u32]) -> Vec<Proc> {
    let mut sys = System::new();
    // Also refresh ourselves, to know our own user id.
    // No duplicates: sysinfo drops a pid listed twice.
    let mut list: Vec<Pid> = pids.iter().map(|p| Pid::from_u32(*p)).collect();
    list.push(Pid::from_u32(std::process::id()));
    list.sort_unstable();
    list.dedup();
    sys.refresh_processes_specifics(ProcessesToUpdate::Some(&list), true, refresh_kind(true));
    collect(&sys).into_iter().filter(|p| pids.contains(&p.pid)).collect()
}

fn collect(sys: &System) -> Vec<Proc> {
    let me = sys.process(Pid::from_u32(std::process::id())).and_then(|p| p.user_id()).cloned();
    let mut out: Vec<Proc> = sys
        .processes()
        .values()
        // An exited process waiting to be reaped is not running anything.
        .filter(|p| !matches!(p.status(), ProcessStatus::Zombie | ProcessStatus::Dead))
        .take(MAX_PROCESSES)
        .map(|p| {
            let comm = p.name().to_string_lossy();
            let argv: Vec<String> = p.cmd().iter().map(|a| a.to_string_lossy().into_owned()).collect();
            let name = full_name(agents::normalize_name(&comm), argv.first().map(String::as_str));
            Proc {
                pid: p.pid().as_u32(),
                name,
                arguments: argv.into_iter().skip(1).collect(),
                exe: p.exe().map(|e| e.to_string_lossy().into_owned()),
                cwd: p.cwd().map(|c| c.to_string_lossy().into_owned()).filter(|c| !c.is_empty()),
                started: Some(p.start_time()).filter(|t| *t > 0),
                own: match (&me, p.user_id()) {
                    (Some(me), Some(u)) => me == u,
                    _ => false,
                },
                memory: p.memory(),
                cpu_ms: p.accumulated_cpu_time(),
            }
        })
        .collect();
    out.sort_by_key(|p| p.pid);
    out
}

/// Linux truncates `comm` to 15 bytes; when argv[0]'s base name extends it,
/// use that instead ("cursor-agent-x" rather than "cursor-agent-"…).
fn full_name(comm: &str, argv0: Option<&str>) -> String {
    if comm.len() == 15 {
        if let Some(base) = argv0.map(|a| a.replace('\\', "/")) {
            let base = base.rsplit('/').next().unwrap_or_default().to_string();
            let base = agents::normalize_name(&base);
            if base.len() > 15 && base.starts_with(comm) {
                return base.to_string();
            }
        }
    }
    comm.to_string()
}

/// One of the user's agent sessions.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Session {
    pub pid: u32,
    pub agent: &'static str,
    pub folder: Option<String>,
    pub started: Option<u64>,
    pub cpu_ms: u64,
}

/// The user's agent sessions in `procs`, oldest first.
pub fn sessions(procs: &[Proc]) -> Vec<Session> {
    let mut s: Vec<Session> = procs
        .iter()
        .filter(|p| p.own)
        .filter_map(|p| {
            Some(Session {
                pid: p.pid,
                agent: agents::agent_name(&p.running())?,
                folder: p.cwd.clone(),
                started: p.started,
                cpu_ms: p.cpu_ms,
            })
        })
        .collect();
    s.sort_by_key(|x| (x.started.unwrap_or(u64::MAX), x.pid));
    s
}

/// The user's processes that could be agents, for `agents::running_agents`.
pub fn own_running(procs: &[Proc]) -> Vec<RunningProcess> {
    procs.iter().filter(|p| p.own && agents::is_candidate(&p.name)).map(Proc::running).collect()
}

/// Names of the user's running agents, now (a light snapshot).
pub fn running_agent_names() -> std::collections::BTreeSet<String> {
    agents::running_agents(&own_running(&snapshot_light())).into_keys().collect()
}

/// This process's start time (unix seconds), 0 if unknown.
pub fn own_start_time() -> u64 {
    let me = std::process::id();
    snapshot_of(&[me]).first().and_then(|p| p.started).unwrap_or(0)
}

/// Ask a process to quit: SIGTERM on Unix; on Windows there is no polite
/// signal for console programs, so it is ended (taskkill /F, i.e. TerminateProcess).
pub fn terminate(pid: u32) -> bool {
    if pid <= 1 || pid == std::process::id() {
        return false;
    }
    let mut sys = System::new();
    let target = Pid::from_u32(pid);
    sys.refresh_processes_specifics(ProcessesToUpdate::Some(&[target]), true, ProcessRefreshKind::nothing());
    let Some(p) = sys.process(target) else {
        return false;
    };
    #[cfg(windows)]
    let signal = sysinfo::Signal::Kill;
    #[cfg(not(windows))]
    let signal = sysinfo::Signal::Term;
    p.kill_with(signal).unwrap_or(false)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn long_names_come_from_argv0() {
        assert_eq!(full_name("my-long-agent-n", Some("/usr/bin/my-long-agent-name")), "my-long-agent-name");
        assert_eq!(full_name("my-long-agent-n", Some("/usr/bin/other")), "my-long-agent-n");
        assert_eq!(full_name("claude", Some("/usr/bin/whatever-long-name")), "claude");
        assert_eq!(full_name("my-long-agent-n", None), "my-long-agent-n");
    }

    #[test]
    fn sees_itself_and_refuses_to_signal_itself() {
        let me = std::process::id();
        let all = snapshot();
        let mine = all.iter().find(|p| p.pid == me).expect("own process is visible");
        assert!(mine.own);
        assert!(mine.started.is_some());
        assert!(!terminate(me));
        assert!(!terminate(1));
        assert!(!terminate(0));
        let one = snapshot_of(&[me]);
        assert_eq!(one.len(), 1);
        assert!(one.first().is_some_and(|p| p.own && p.started == mine.started));
    }
}
