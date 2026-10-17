//! A keep-awake session (`keepwatch awake`, or the tray's Keep awake menu),
//! as a value the caller drives: `check` about once a second, `agents_tick`
//! when it has a fresh list of agents, then `finish`. The CLI and the tray use
//! the same code, so either can stop the other's session through the lock.

use crate::agents::AgentsWatch;
use crate::inhibit::{Hold, Holder};
use crate::lock::{self, Kind, LockInfo, Owner};
use serde::{Deserialize, Serialize};
use std::collections::BTreeSet;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

/// After the last agent exits, "while agents run" waits this long (as on macOS).
pub const AGENT_GRACE_SECONDS: f64 = 120.0;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AwakeMode {
    Minutes(u32),
    Indefinitely,
    WhileAgentsRun,
}

/// Why a keep-awake session ended.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AwakeEnd {
    TimeUp,
    AgentsFinished,
    /// `awake --off`, the tray's Turn off, or a newer request replaced it.
    StopRequested,
    /// systemd-inhibit exited, so the lock was lost.
    Lost,
}

/// What the owner writes next to the lock, so others can show the session.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AwakeState {
    pub owner: String,
    pub pid: u32,
    /// "timed", "indefinitely" or "agents".
    pub mode: String,
    pub started_at: Option<String>,
    /// Unix seconds, for timed sessions.
    pub ends_at: Option<i64>,
}

pub fn unix_now() -> i64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map_or(0, |d| i64::try_from(d.as_secs()).unwrap_or(i64::MAX))
}

pub struct AwakeSession {
    holder: Option<Holder>,
    mode: AwakeMode,
    pid: u32,
    deadline: Option<Instant>,
    ends_at: Option<i64>,
    watch: AgentsWatch,
    clock: Instant,
    ever_seen: bool,
}

impl AwakeSession {
    /// Take the inhibitor and record this process in the lock. A lock write
    /// failure isn't fatal: the session holds, `--off` just can't find it.
    pub fn start(mode: AwakeMode, owner: Owner) -> Result<(AwakeSession, Option<String>), String> {
        let label = match mode {
            AwakeMode::Minutes(m) => format!("keepwatch awake: {m} min"),
            AwakeMode::WhileAgentsRun => "keepwatch awake: while agents run".into(),
            AwakeMode::Indefinitely => "keepwatch awake: until stopped".into(),
        };
        let holder = Holder::start(&label, false, Hold::Awake)?;
        let pid = std::process::id();
        let now = Instant::now();
        let (deadline, ends_at) = match mode {
            AwakeMode::Minutes(m) => {
                let secs = u64::from(m).saturating_mul(60);
                (now.checked_add(Duration::from_secs(secs)), Some(unix_now().saturating_add_unsigned(secs)))
            }
            _ => (None, None),
        };
        // Clear an old stop request and write the details before the lock: once
        // the lock exists, a stop request is real and the details are readable.
        if lock::stop_requested(Kind::Awake, pid).is_some() {
            lock::clear_stop(Kind::Awake);
        }
        let state = AwakeState {
            owner: owner.as_str().into(),
            pid,
            mode: match mode {
                AwakeMode::Minutes(_) => "timed",
                AwakeMode::Indefinitely => "indefinitely",
                AwakeMode::WhileAgentsRun => "agents",
            }
            .into(),
            started_at: u64::try_from(unix_now()).ok().and_then(crate::util::iso8601),
            ends_at,
        };
        let _ = lock::write_state(Kind::Awake, &crate::util::json_string(&state));
        let mut warning = None;
        if let Err(e) = lock::write(Kind::Awake, LockInfo { pid, started: crate::procs::own_start_time() }) {
            warning = Some(format!("'keepwatch awake --off' won't find this one: {e}"));
        }
        let session = AwakeSession {
            holder: Some(holder),
            mode,
            pid,
            deadline,
            ends_at,
            watch: AgentsWatch::new(AGENT_GRACE_SECONDS),
            clock: now,
            ever_seen: false,
        };
        Ok((session, warning))
    }

    pub fn mode(&self) -> AwakeMode {
        self.mode
    }

    /// Unix seconds when a timed session ends.
    pub fn ends_at(&self) -> Option<i64> {
        self.ends_at
    }

    /// The cheap checks: inhibitor alive, stop requested, time up.
    pub fn check(&mut self) -> Option<AwakeEnd> {
        if !self.holder.as_mut().is_some_and(Holder::alive) {
            return Some(AwakeEnd::Lost);
        }
        if lock::stop_requested(Kind::Awake, self.pid).is_some() {
            return Some(AwakeEnd::StopRequested);
        }
        if self.deadline.is_some_and(|d| Instant::now() >= d) {
            return Some(AwakeEnd::TimeUp);
        }
        None
    }

    /// Feed the running agents ("while agents run" only). Returns the agents
    /// that just finished, and the end once all are done and the grace is over.
    pub fn agents_tick(&mut self, running: &BTreeSet<String>) -> (Vec<String>, Option<AwakeEnd>) {
        if self.mode != AwakeMode::WhileAgentsRun {
            return (Vec::new(), None);
        }
        self.ever_seen |= !running.is_empty();
        let tick = self.watch.tick(self.clock.elapsed().as_secs_f64(), running);
        let end = (self.ever_seen && !tick.hold).then_some(AwakeEnd::AgentsFinished);
        (tick.finished, end)
    }

    /// Release the inhibitor and the lock.
    pub fn finish(mut self) {
        self.release();
    }

    fn release(&mut self) {
        if let Some(h) = self.holder.take() {
            h.release();
        }
        lock::remove_if(Kind::Awake, self.pid);
        if lock::stop_requested(Kind::Awake, self.pid).is_some() {
            lock::clear_stop(Kind::Awake);
        }
    }
}

impl Drop for AwakeSession {
    fn drop(&mut self) {
        self.release();
    }
}

/// A running keep-awake session someone else (CLI or tray) holds, as read
/// from the lock and state files.
pub fn other_awake() -> Option<(lock::Live, Option<AwakeState>)> {
    let live = lock::live(Kind::Awake)?;
    if live.pid == std::process::id() {
        return None;
    }
    let state = lock::read_state(Kind::Awake)
        .and_then(|t| serde_json::from_str::<AwakeState>(&t).ok())
        .filter(|s| s.pid == live.pid);
    Some((live, state))
}
