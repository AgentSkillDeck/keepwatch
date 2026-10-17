//! Lid-closed sessions on Linux: keep running with the lid shut, for a while.
//!
//! The session holds a logind block inhibitor on `handle-lid-switch:sleep:idle`
//! through the same `systemd-inhibit … cat` child as `awake`. If keepwatch
//! dies for any reason, even SIGKILL, `cat` reads EOF and logind drops the
//! lock, so a crash means the laptop sleeps normally. No root, no persistent
//! setting, nothing to undo.
//!
//! The rules mirror the macOS lid watchdog (`LidSession.swift`): sleep N hours
//! after the lid closes (opening it resets the timer), optionally at a clock
//! time, when agents finish, on low battery or unplugged, when too hot, and
//! never later than 12 hours after the start. `decide` is pure and tested;
//! the caller feeds it what it reads every few seconds.

use serde::{Deserialize, Serialize};

/// No session runs longer than this, whatever the plan says.
pub const HARD_CAP_SECONDS: f64 = 12.0 * 3600.0;
/// `lid start` without `--hours`.
pub const DEFAULT_HALF_HOURS: u32 = 6;
/// Battery floor: no start at or below it on battery, and the session ends at it.
pub const MIN_BATTERY_PERCENT: i64 = 20;
/// Any thermal zone at or above this (millidegrees Celsius) ends the session.
pub const MAX_TEMP_MILLIC: i64 = 95_000;
/// With "until agents are done", end once no agent has run for this long.
pub const AGENTS_GRACE_SECONDS: f64 = 120.0;

/// What a lid session should do.
#[derive(Debug, Clone, PartialEq)]
pub struct LidPlan {
    /// End this long after the lid closes (the timer restarts when it opens).
    pub after_closed_seconds: f64,
    /// End at this time (unix seconds).
    pub sleep_at: Option<i64>,
    /// End once no agent has run for `AGENTS_GRACE_SECONDS`.
    pub until_agents_done: bool,
    /// Keep going on battery (above the floor). Off: end when unplugged.
    pub allow_on_battery: bool,
}

impl LidPlan {
    /// A plan from half hours (1..=24; out-of-range values are clamped).
    pub fn new(half_hours: u32, sleep_at: Option<i64>, until_agents_done: bool, allow_on_battery: bool) -> Self {
        LidPlan {
            after_closed_seconds: f64::from(half_hours.clamp(1, 24)) * 1800.0,
            sleep_at,
            until_agents_done,
            allow_on_battery,
        }
    }

    /// "sleeps 3 h after the lid closes, at 01:00, when agents finish; ends if unplugged".
    pub fn describe(&self) -> String {
        let mut parts =
            vec![format!("sleeps {} after the lid closes", crate::duration::describe(self.after_closed_seconds))];
        if let Some(at) = self.sleep_at.and_then(local_hhmm) {
            parts.push(format!("at {at} at the latest"));
        }
        if self.until_agents_done {
            parts.push("when agents finish".into());
        }
        let battery = if self.allow_on_battery {
            format!("on battery down to {MIN_BATTERY_PERCENT}%")
        } else {
            "ends if unplugged".into()
        };
        format!("{}; {battery}", parts.join(", "))
    }
}

fn local_hhmm(unix: i64) -> Option<String> {
    use chrono::TimeZone;
    chrono::Local.timestamp_opt(unix, 0).single().map(|t| t.format("%H:%M").to_string())
}

/// What the caller saw, as of the latest rule tick.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct Observed {
    /// How long the lid has been closed this time (0 when open).
    pub lid_closed_for: f64,
    /// How long no agent has been running (since the start if none ever ran).
    pub no_agents_for: f64,
    pub on_battery: Option<bool>,
    pub battery_percent: Option<i64>,
    /// Hottest thermal zone, millidegrees Celsius.
    pub max_temp_millic: Option<i64>,
}

/// The clock, as seconds since the session started.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Now {
    /// Monotonic.
    pub elapsed: f64,
    /// Wall clock; can jump either way.
    pub wall_elapsed: f64,
    /// Wall clock, unix seconds (for `sleep_at`).
    pub wall: i64,
}

/// Why a lid session ended.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum EndReason {
    Thermal {
        millic: i64,
    },
    HardCap,
    SleepAt,
    OnBattery,
    LowBattery {
        percent: i64,
    },
    LidClosedLimit,
    AgentsDone,
    /// `keepwatch lid end`, or the tray's End.
    StopRequested,
    /// A new lid session took over: release, but never suspend.
    Replaced,
    /// Ctrl-C.
    Interrupted,
    /// The tray quit.
    Quit,
    /// systemd-inhibit exited, so logind isn't blocked any more.
    InhibitorLost,
}

impl EndReason {
    /// Stable code for the log and `lastEndReason`.
    pub fn code(self) -> &'static str {
        match self {
            EndReason::Thermal { .. } => "thermal",
            EndReason::HardCap => "hard-cap",
            EndReason::SleepAt => "sleep-at",
            EndReason::OnBattery => "on-battery",
            EndReason::LowBattery { .. } => "low-battery",
            EndReason::LidClosedLimit => "lid-closed-limit",
            EndReason::AgentsDone => "agents-done",
            EndReason::StopRequested => "stop-requested",
            EndReason::Replaced => "replaced",
            EndReason::Interrupted => "interrupted",
            EndReason::Quit => "tray-quit",
            EndReason::InhibitorLost => "inhibitor-lost",
        }
    }

    pub fn describe(self) -> String {
        match self {
            EndReason::Thermal { millic } => format!("it's running hot ({} °C)", millic / 1000),
            EndReason::HardCap => "the 12-hour limit was reached".into(),
            EndReason::SleepAt => "it's the time you chose".into(),
            EndReason::OnBattery => "the power adapter was unplugged".into(),
            EndReason::LowBattery { percent } => format!("the battery is at {percent}%"),
            EndReason::LidClosedLimit => "the lid was closed for the time you chose".into(),
            EndReason::AgentsDone => "all agents finished".into(),
            EndReason::StopRequested => "you ended it".into(),
            EndReason::Replaced => "a new lid session replaced it".into(),
            EndReason::Interrupted => "it was interrupted (Ctrl-C)".into(),
            EndReason::Quit => "the tray app quit".into(),
            EndReason::InhibitorLost => "the lid lock was lost (systemd-inhibit exited)".into(),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Decision {
    Continue,
    End(EndReason),
}

/// `value >= limit`, and true for NaN too, so a malformed reading ends the
/// session rather than extending it.
fn reached(value: f64, limit: f64) -> bool {
    value.partial_cmp(&limit) != Some(std::cmp::Ordering::Less)
}

/// The rule engine. Checked in order of how urgent the reason is.
pub fn decide(plan: &LidPlan, obs: &Observed, now: &Now) -> Decision {
    if let Some(t) = obs.max_temp_millic.filter(|t| *t >= MAX_TEMP_MILLIC) {
        return Decision::End(EndReason::Thermal { millic: t });
    }
    // Either clock reaching the cap ends it, so a clock set back can't extend a session.
    if reached(now.elapsed, HARD_CAP_SECONDS) || now.wall_elapsed >= HARD_CAP_SECONDS {
        return Decision::End(EndReason::HardCap);
    }
    if plan.sleep_at.is_some_and(|at| now.wall >= at) {
        return Decision::End(EndReason::SleepAt);
    }
    if obs.on_battery == Some(true) {
        if !plan.allow_on_battery {
            return Decision::End(EndReason::OnBattery);
        }
        if let Some(p) = obs.battery_percent.filter(|p| *p <= MIN_BATTERY_PERCENT) {
            return Decision::End(EndReason::LowBattery { percent: p });
        }
    }
    let limit = if plan.after_closed_seconds.is_finite() { plan.after_closed_seconds } else { 0.0 };
    if reached(obs.lid_closed_for, limit.min(HARD_CAP_SECONDS)) {
        return Decision::End(EndReason::LidClosedLimit);
    }
    if plan.until_agents_done && reached(obs.no_agents_for, AGENTS_GRACE_SECONDS) {
        return Decision::End(EndReason::AgentsDone);
    }
    Decision::Continue
}

/// Whether a session may start now. `lid` None (can't read it) refuses: a lid
/// session the timer can't see is the one that runs flat in a bag.
pub fn can_start(
    plan: &LidPlan,
    lid: Option<bool>,
    on_battery: Option<bool>,
    battery_percent: Option<i64>,
    max_temp_millic: Option<i64>,
) -> Result<(), String> {
    if lid.is_none() {
        return Err("can't read whether the lid is open or closed here (no /proc/acpi/button/lid and no \
                    logind LidClosed), so a lid session can't keep track of it"
            .into());
    }
    if let Some(t) = max_temp_millic.filter(|t| *t >= MAX_TEMP_MILLIC) {
        return Err(format!("this computer is running hot ({} °C); not starting a lid session", t / 1000));
    }
    if on_battery == Some(true) {
        if !plan.allow_on_battery {
            return Err("this computer is on battery and --no-battery was given; plug it in first".into());
        }
        match battery_percent {
            Some(p) if p > MIN_BATTERY_PERCENT => {}
            Some(p) => {
                return Err(format!(
                    "the battery is at {p}%; a lid session on battery needs more than {MIN_BATTERY_PERCENT}%. Plug it in first"
                ))
            }
            None => return Err("on battery and the charge can't be read; plug it in first".into()),
        }
    }
    Ok(())
}

/// A change in lid state the caller may want to tell the user about.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LidChange {
    Closed,
    Opened,
}

/// Turns samples into the durations `decide` needs. An unknown lid reading
/// keeps the last known state (a flapping read neither starts nor resets the
/// timer); an unknown agent list keeps the last time one was seen.
#[derive(Debug, Clone, PartialEq)]
pub struct Tracker {
    lid: Option<bool>,
    closed_since: Option<f64>,
    last_agent_seen: f64,
}

impl Tracker {
    /// `lid` is the state at the start.
    pub fn new(lid: Option<bool>, elapsed: f64) -> Self {
        let closed_since = (lid == Some(true)).then_some(elapsed);
        Tracker { lid, closed_since, last_agent_seen: elapsed }
    }

    pub fn observe_lid(&mut self, sample: Option<bool>, elapsed: f64) -> Option<LidChange> {
        let closed = sample?;
        let change = match (self.lid, closed) {
            (Some(true), true) | (Some(false), false) => None,
            (_, true) => {
                self.closed_since = Some(elapsed);
                Some(LidChange::Closed)
            }
            (_, false) => {
                self.closed_since = None;
                Some(LidChange::Opened)
            }
        };
        self.lid = Some(closed);
        change
    }

    pub fn observe_agents(&mut self, running: Option<bool>, elapsed: f64) {
        if running == Some(true) {
            self.last_agent_seen = elapsed;
        }
    }

    pub fn lid_closed(&self) -> Option<bool> {
        self.lid
    }

    pub fn lid_closed_for(&self, elapsed: f64) -> f64 {
        self.closed_since.map_or(0.0, |s| (elapsed - s).max(0.0))
    }

    pub fn no_agents_for(&self, elapsed: f64) -> f64 {
        (elapsed - self.last_agent_seen).max(0.0)
    }
}

/// What the owner writes next to the lock, and `lid status --json` /
/// `status --json` (`lidSession`) report. Times are ISO 8601 UTC.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LidSessionJson {
    pub active: bool,
    /// "cli" or "tray".
    pub owner: Option<String>,
    pub pid: Option<u32>,
    pub started_at: Option<String>,
    pub after_lid_closed_minutes: Option<i64>,
    pub sleep_at: Option<String>,
    pub until_agents_done: Option<bool>,
    pub allow_on_battery: Option<bool>,
    pub min_battery_percent: Option<i64>,
    pub hard_cap_at: Option<String>,
    /// When the lid was last seen closing, if it is closed now.
    pub lid_closed_since: Option<String>,
    pub last_ended_at: Option<String>,
    pub last_end_reason: Option<String>,
}

fn iso(unix: i64) -> Option<String> {
    u64::try_from(unix).ok().and_then(crate::util::iso8601)
}

/// The session description for a plan started at `start` (unix seconds).
pub fn session_json(plan: &LidPlan, owner: crate::lock::Owner, pid: u32, start: i64) -> LidSessionJson {
    LidSessionJson {
        active: true,
        owner: Some(owner.as_str().into()),
        pid: Some(pid),
        started_at: iso(start),
        // after_closed_seconds is 1800..=43200, so the cast is exact.
        after_lid_closed_minutes: Some((plan.after_closed_seconds / 60.0).round() as i64),
        sleep_at: plan.sleep_at.and_then(iso),
        until_agents_done: Some(plan.until_agents_done),
        allow_on_battery: Some(plan.allow_on_battery),
        min_battery_percent: Some(MIN_BATTERY_PERCENT),
        // HARD_CAP_SECONDS is a whole number of seconds.
        hard_cap_at: iso(start.saturating_add(HARD_CAP_SECONDS as i64)),
        ..Default::default()
    }
}

// MARK: - the session log

/// The log is cut to its newest half once it passes this size.
pub const MAX_LOG_BYTES: u64 = 1024 * 1024;

/// The newer half of `text`, starting at a line boundary.
pub fn keep_newest_half(text: &str) -> &str {
    // Start one byte early, so a line beginning exactly at the middle is kept.
    let from = (text.len() / 2).saturating_sub(1);
    match text.as_bytes().iter().skip(from).position(|b| *b == b'\n') {
        // '\n' is ASCII, so the byte after it is a char boundary.
        Some(i) => text.get(from.saturating_add(i).saturating_add(1)..).unwrap_or(""),
        None => "",
    }
}

/// The last "ended" entry of the log: (time, reason code).
pub fn last_end(text: &str) -> Option<(String, String)> {
    text.lines().rev().find_map(|line| {
        let (time, rest) = line.split_once(' ')?;
        let rest = rest.strip_prefix("ended ")?;
        let code: String = rest.chars().take_while(|c| c.is_ascii_lowercase() || *c == '-').collect();
        (!code.is_empty()).then(|| (time.to_string(), code))
    })
}

/// `$XDG_STATE_HOME/keepwatch/lid.log`, default `~/.local/state/keepwatch/lid.log`.
pub fn log_path() -> Option<std::path::PathBuf> {
    let base = std::env::var_os("XDG_STATE_HOME")
        .map(std::path::PathBuf::from)
        .filter(|p| p.is_absolute())
        .or_else(|| crate::util::home_dir().map(|h| std::path::Path::new(&h).join(".local").join("state")))?;
    base.is_absolute().then(|| base.join("keepwatch").join("lid.log"))
}

/// Append one line (with a timestamp) to the session log. Mode 0600; never
/// follows a symlink; rotated by dropping the oldest half past 1 MB.
pub fn log(line: &str) -> std::io::Result<()> {
    use std::io::Write;
    let path = log_path().ok_or_else(|| std::io::Error::other("no home folder for the lid log"))?;
    let dir = path
        .parent()
        .and_then(crate::util::own_dir)
        .ok_or_else(|| std::io::Error::other("no private folder for the lid log"))?;
    if let Ok(meta) = std::fs::symlink_metadata(&path) {
        if meta.is_file() && meta.len() > MAX_LOG_BYTES {
            let text = crate::util::read_regular_capped(&path, MAX_LOG_BYTES.saturating_mul(4)).unwrap_or_default();
            crate::util::write_atomic(&dir, "lid.log", keep_newest_half(&text).as_bytes())?;
        }
    }
    let mut f = crate::util::open_append_private(&path)?;
    let now = chrono::Local::now().to_rfc3339_opts(chrono::SecondsFormat::Secs, false);
    writeln!(f, "{now} {}", crate::util::clean_line(line, 500))
}

/// The tail of the log (at most 8 KB), for `last_end`.
pub fn log_tail() -> Option<String> {
    use std::io::{Read, Seek, SeekFrom};
    let path = log_path()?;
    let meta = std::fs::symlink_metadata(&path).ok()?;
    if !meta.is_file() {
        return None;
    }
    let mut f = std::fs::File::open(&path).ok()?;
    f.seek(SeekFrom::Start(meta.len().saturating_sub(8192))).ok()?;
    let mut buf = Vec::new();
    f.take(8192).read_to_end(&mut buf).ok()?;
    Some(String::from_utf8_lossy(&buf).into_owned())
}

/// `lidSession` for `status --json` and `lid status --json`.
pub fn current_json() -> LidSessionJson {
    let mut j = LidSessionJson::default();
    if let Some(live) = crate::lock::live(crate::lock::Kind::Lid) {
        if let Some(state) = crate::lock::read_state(crate::lock::Kind::Lid)
            .and_then(|t| serde_json::from_str::<LidSessionJson>(&t).ok())
            .filter(|s| s.pid == Some(live.pid))
        {
            j = state;
        }
        j.active = true;
        j.pid = Some(live.pid);
        j.owner = Some(live.owner.as_str().into());
    }
    if let Some((at, reason)) = log_tail().as_deref().and_then(last_end) {
        j.last_ended_at = Some(at);
        j.last_end_reason = Some(reason);
    }
    j
}

/// What happened about sleep when a session ended.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SuspendOutcome {
    /// A new session took over, so nothing was suspended.
    Replaced,
    LidOpen,
    LidUnknown,
    /// logind counts it as docked and ignores the lid by default; so do we.
    Docked,
    Requested,
    Failed(String),
}

impl SuspendOutcome {
    pub fn describe(&self) -> String {
        match self {
            SuspendOutcome::Replaced => "The new session keeps it running.".into(),
            SuspendOutcome::LidOpen => "The lid is open, so it stays on; it can sleep normally again.".into(),
            SuspendOutcome::LidUnknown => "The lid state can't be read, so keepwatch didn't suspend it.".into(),
            SuspendOutcome::Docked => "It's docked, so it follows the system's docked setting.".into(),
            SuspendOutcome::Requested => "The lid is closed, so keepwatch asked it to suspend.".into(),
            SuspendOutcome::Failed(why) => format!(
                "The lid is closed but the suspend request failed ({why}); the system acts on the lid itself now that nothing blocks it."
            ),
        }
    }
}

/// How fast session time runs: debug builds read `KEEPWATCH_TEST_TIME_SCALE`
/// (1..=100000) so tests can run hours in seconds. Release: always 1.
pub fn time_scale() -> f64 {
    crate::util::test_override("TIME_SCALE")
        .and_then(|v| v.to_str().and_then(|s| s.parse::<f64>().ok()))
        .filter(|v| v.is_finite() && (1.0..=100_000.0).contains(v))
        .unwrap_or(1.0)
}

/// How often the rules run: 5 s; debug builds read `KEEPWATCH_TEST_LID_TICK_MS` (50..=5000).
pub fn rule_tick() -> std::time::Duration {
    let ms = crate::util::test_override("LID_TICK_MS")
        .and_then(|v| v.to_str().and_then(|s| s.parse::<u64>().ok()))
        .filter(|v| (50..=5000).contains(v))
        .unwrap_or(5000);
    std::time::Duration::from_millis(ms)
}

#[cfg(target_os = "linux")]
pub use live::{read_sensors, LidSession, Sensors};

#[cfg(target_os = "linux")]
mod live {
    use super::*;
    use crate::inhibit::{Hold, Holder};
    use crate::lock::{self, Kind, LockInfo, Owner};
    use crate::session::unix_now;
    use std::time::Instant;

    /// One reading of everything the rules look at.
    #[derive(Debug, Clone, Default)]
    pub struct Sensors {
        pub lid: Option<bool>,
        pub power: crate::power::Power,
        pub max_temp_millic: Option<i64>,
        /// None when not asked for.
        pub agents_running: Option<bool>,
    }

    pub fn read_sensors(agents: bool) -> Sensors {
        Sensors {
            lid: crate::power::lid_closed(),
            power: crate::power::battery(),
            max_temp_millic: crate::power::max_temp_millic(),
            agents_running: agents.then(|| !crate::procs::running_agent_names().is_empty()),
        }
    }

    pub struct LidSession {
        holder: Option<Holder>,
        plan: LidPlan,
        pid: u32,
        clock: Instant,
        wall_start: i64,
        scale: f64,
        tracker: Tracker,
        state: LidSessionJson,
    }

    fn suspend_if_closed() -> SuspendOutcome {
        match crate::power::lid_closed() {
            Some(true) => {}
            Some(false) => return SuspendOutcome::LidOpen,
            None => return SuspendOutcome::LidUnknown,
        }
        if crate::power::docked() == Some(true) {
            return SuspendOutcome::Docked;
        }
        // With a stand-in lid (tests), only ever a stand-in systemctl.
        if crate::util::test_path("LID_STATE").is_some() && crate::util::test_path("SYSTEMCTL").is_none() {
            return SuspendOutcome::Failed("test lid without a stand-in systemctl".into());
        }
        let Some(systemctl) = crate::util::system_program("systemctl") else {
            return SuspendOutcome::Failed("systemctl isn't installed".into());
        };
        match crate::util::run_capture(&systemctl, &["suspend"], std::time::Duration::from_secs(15)) {
            Some(_) => SuspendOutcome::Requested,
            None => SuspendOutcome::Failed("systemctl suspend was refused or timed out".into()),
        }
    }

    impl LidSession {
        /// Check the start rules, take the inhibitor, record the lock and log it.
        pub fn start(plan: LidPlan, owner: Owner) -> Result<LidSession, String> {
            let sensors = read_sensors(false);
            can_start(
                &plan,
                sensors.lid,
                sensors.power.on_battery,
                sensors.power.battery_percent,
                sensors.max_temp_millic,
            )?;
            let holder = Holder::start("Lid-closed session", false, Hold::LidClosed)?;
            let pid = std::process::id();
            let wall_start = unix_now();
            // Details first, then the lock: anyone who sees the lock (`lid status`,
            // the tray) must also find the plan, never an active session without one.
            // An old stop request is cleared before the lock exists; once it
            // does, any request is a real `lid end` and must be honoured.
            if lock::stop_requested(Kind::Lid, pid).is_some() {
                lock::clear_stop(Kind::Lid);
            }
            let state = session_json(&plan, owner, pid, wall_start);
            let _ = lock::write_state(Kind::Lid, &crate::util::json_string(&state));
            if let Err(e) = lock::write(Kind::Lid, LockInfo { pid, started: crate::procs::own_start_time() }) {
                holder.release();
                return Err(format!("couldn't record the lid session, so 'keepwatch lid end' couldn't find it: {e}"));
            }
            // Debug-only: widen the moment just after the lock appears, so a
            // test can check that the plan is already readable then.
            if let Some(ms) = crate::util::test_override("LOCK_PAUSE_MS").and_then(|v| v.to_str()?.parse::<u64>().ok())
            {
                std::thread::sleep(std::time::Duration::from_millis(ms.min(5_000)));
            }
            let mut session = LidSession {
                holder: Some(holder),
                tracker: Tracker::new(sensors.lid, 0.0),
                state,
                plan,
                pid,
                clock: Instant::now(),
                wall_start,
                scale: time_scale(),
            };
            session.note_lid();
            let _ = super::log(&format!("started pid {pid} ({}): {}", owner.as_str(), session.plan.describe()));
            Ok(session)
        }

        pub fn plan(&self) -> &LidPlan {
            &self.plan
        }

        /// Session seconds since the start (scaled in debug tests).
        pub fn elapsed(&self) -> f64 {
            self.clock.elapsed().as_secs_f64() * self.scale
        }

        fn now(&self) -> Now {
            let wall = unix_now();
            // i64 seconds -> f64 is exact for any real clock.
            let wall_elapsed = (wall.saturating_sub(self.wall_start)) as f64 * self.scale;
            Now { elapsed: self.elapsed(), wall_elapsed, wall }
        }

        pub fn lid_closed(&self) -> Option<bool> {
            self.tracker.lid_closed()
        }

        /// Seconds left on the after-closing timer while the lid is closed.
        pub fn closed_left(&self) -> Option<f64> {
            (self.tracker.lid_closed() == Some(true))
                .then(|| (self.plan.after_closed_seconds - self.tracker.lid_closed_for(self.elapsed())).max(0.0))
        }

        fn note_lid(&mut self) {
            self.state.lid_closed_since = (self.tracker.lid_closed() == Some(true))
                .then(|| {
                    let ago = self.tracker.lid_closed_for(self.elapsed()) / self.scale;
                    // ago is finite and >= 0; whole seconds are enough.
                    iso(unix_now().saturating_sub(ago as i64))
                })
                .flatten();
            let _ = lock::write_state(Kind::Lid, &crate::util::json_string(&self.state));
        }

        /// The cheap checks, about once a second: the inhibitor, a stop request.
        pub fn check(&mut self) -> Option<EndReason> {
            if !self.holder.as_mut().is_some_and(Holder::alive) {
                return Some(EndReason::InhibitorLost);
            }
            lock::stop_requested(Kind::Lid, self.pid).map(|intent| match intent {
                lock::StopIntent::End => EndReason::StopRequested,
                lock::StopIntent::Replace => EndReason::Replaced,
            })
        }

        /// One rule tick with fresh readings.
        pub fn step(&mut self, s: &Sensors) -> (Option<LidChange>, Option<EndReason>) {
            let elapsed = self.elapsed();
            let change = self.tracker.observe_lid(s.lid, elapsed);
            if change.is_some() {
                self.note_lid();
            }
            self.tracker.observe_agents(s.agents_running, elapsed);
            let obs = Observed {
                lid_closed_for: self.tracker.lid_closed_for(elapsed),
                no_agents_for: self.tracker.no_agents_for(elapsed),
                on_battery: s.power.on_battery,
                battery_percent: s.power.battery_percent,
                max_temp_millic: s.max_temp_millic,
            };
            let end = match decide(&self.plan, &obs, &self.now()) {
                Decision::Continue => None,
                Decision::End(r) => Some(r),
            };
            (change, end)
        }

        /// Release the inhibitor and the lock, log why, then suspend if the lid is shut.
        pub fn finish(mut self, reason: EndReason) -> SuspendOutcome {
            self.release();
            let _ = super::log(&format!("ended {}: {}", reason.code(), reason.describe()));
            let outcome = if reason == EndReason::Replaced { SuspendOutcome::Replaced } else { suspend_if_closed() };
            let note = match &outcome {
                SuspendOutcome::Requested => "asked to suspend (lid closed)".to_string(),
                SuspendOutcome::Replaced => "replaced: not suspending".into(),
                SuspendOutcome::Failed(why) => format!("suspend request failed: {why}"),
                SuspendOutcome::Docked => "lid closed but docked: not suspending".into(),
                SuspendOutcome::LidOpen => "lid open: not suspending".into(),
                SuspendOutcome::LidUnknown => "lid state unknown: not suspending".into(),
            };
            let _ = super::log(&format!("after {}: {note}", reason.code()));
            outcome
        }

        fn release(&mut self) {
            if let Some(h) = self.holder.take() {
                h.release();
            }
            lock::remove_if(Kind::Lid, self.pid);
            if lock::stop_requested(Kind::Lid, self.pid).is_some() {
                lock::clear_stop(Kind::Lid);
            }
        }
    }

    impl Drop for LidSession {
        fn drop(&mut self) {
            self.release();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn plan() -> LidPlan {
        LidPlan::new(6, None, false, true)
    }

    fn now(elapsed: f64) -> Now {
        Now { elapsed, wall_elapsed: elapsed, wall: 1_800_000_000 }
    }

    fn plugged() -> Observed {
        Observed {
            on_battery: Some(false),
            battery_percent: Some(80),
            max_temp_millic: Some(50_000),
            ..Default::default()
        }
    }

    #[test]
    fn continues_on_a_normal_tick() {
        assert_eq!(decide(&plan(), &plugged(), &now(60.0)), Decision::Continue);
        assert_eq!(decide(&plan(), &Observed::default(), &now(0.0)), Decision::Continue, "unknowns don't end it");
    }

    #[test]
    fn after_lid_closed_timer_resets_when_the_lid_opens() {
        let p = LidPlan::new(1, None, false, true); // 30 min
        let mut t = Tracker::new(Some(false), 0.0);
        assert_eq!(t.observe_lid(Some(true), 100.0), Some(LidChange::Closed));
        let obs = |t: &Tracker, e: f64| Observed { lid_closed_for: t.lid_closed_for(e), ..plugged() };
        assert_eq!(decide(&p, &obs(&t, 100.0 + 1700.0), &now(1800.0)), Decision::Continue);
        // Open before the 30 min are up: the timer resets.
        assert_eq!(t.observe_lid(Some(false), 1850.0), Some(LidChange::Opened));
        assert_eq!(t.lid_closed_for(5000.0), 0.0);
        assert_eq!(t.observe_lid(Some(true), 2000.0), Some(LidChange::Closed));
        assert_eq!(decide(&p, &obs(&t, 3700.0), &now(3700.0)), Decision::Continue, "1700 s since closing again");
        assert_eq!(decide(&p, &obs(&t, 3800.0), &now(3800.0)), Decision::End(EndReason::LidClosedLimit));
        // Closed from the start: the timer starts at once.
        let t = Tracker::new(Some(true), 0.0);
        assert_eq!(decide(&p, &obs(&t, 1800.0), &now(1800.0)), Decision::End(EndReason::LidClosedLimit));
    }

    #[test]
    fn unknown_lid_readings_keep_the_last_state() {
        let mut t = Tracker::new(Some(true), 0.0);
        assert_eq!(t.observe_lid(None, 10.0), None);
        assert_eq!(t.lid_closed_for(20.0), 20.0, "a failed read doesn't reset the timer");
        assert_eq!(t.observe_lid(Some(true), 30.0), None);
        assert_eq!(t.lid_closed_for(40.0), 40.0);
        let mut open = Tracker::new(Some(false), 0.0);
        open.observe_lid(None, 10.0);
        assert_eq!(open.lid_closed_for(20.0), 0.0, "nor start it");
        let mut unknown = Tracker::new(None, 0.0);
        assert_eq!(unknown.observe_lid(Some(true), 5.0), Some(LidChange::Closed));
        assert_eq!(unknown.lid_closed_for(6.0), 1.0);
    }

    #[test]
    fn hard_cap_on_either_clock() {
        let p = LidPlan::new(24, None, false, true);
        assert_eq!(decide(&p, &plugged(), &now(HARD_CAP_SECONDS - 1.0)), Decision::Continue);
        assert_eq!(decide(&p, &plugged(), &now(HARD_CAP_SECONDS)), Decision::End(EndReason::HardCap));
        let wall_jumped = Now { elapsed: 10.0, wall_elapsed: HARD_CAP_SECONDS + 5.0, wall: 0 };
        assert_eq!(decide(&p, &plugged(), &wall_jumped), Decision::End(EndReason::HardCap));
        let wall_back = Now { elapsed: HARD_CAP_SECONDS, wall_elapsed: -86_400.0, wall: 0 };
        assert_eq!(decide(&p, &plugged(), &wall_back), Decision::End(EndReason::HardCap), "clock set back");
        let nan = Now { elapsed: f64::NAN, wall_elapsed: f64::NAN, wall: 0 };
        assert_eq!(decide(&p, &plugged(), &nan), Decision::End(EndReason::HardCap), "malformed clock ends it");
        // A 12 h lid timer never outlasts the cap either: the cap comes first.
        let closed = Observed { lid_closed_for: HARD_CAP_SECONDS, ..plugged() };
        assert_eq!(decide(&p, &closed, &now(HARD_CAP_SECONDS)), Decision::End(EndReason::HardCap));
    }

    #[test]
    fn battery_floor_and_plugged_in_rules() {
        let on_battery = |pct: Option<i64>| Observed { on_battery: Some(true), battery_percent: pct, ..plugged() };
        let p = plan();
        assert_eq!(decide(&p, &on_battery(Some(21)), &now(1.0)), Decision::Continue);
        assert_eq!(decide(&p, &on_battery(Some(20)), &now(1.0)), Decision::End(EndReason::LowBattery { percent: 20 }));
        assert_eq!(decide(&p, &on_battery(None), &now(1.0)), Decision::Continue, "unknown charge: as macOS");
        let plugged_low = Observed { on_battery: Some(false), battery_percent: Some(5), ..plugged() };
        assert_eq!(decide(&p, &plugged_low, &now(1.0)), Decision::Continue, "charging at 5% is fine");
        let no_battery = LidPlan { allow_on_battery: false, ..plan() };
        assert_eq!(decide(&no_battery, &on_battery(Some(99)), &now(1.0)), Decision::End(EndReason::OnBattery));
        assert_eq!(decide(&no_battery, &plugged(), &now(1.0)), Decision::Continue);
    }

    #[test]
    fn start_rules() {
        let p = plan();
        assert!(can_start(&p, Some(false), Some(false), Some(10), Some(40_000)).is_ok(), "plugged in at 10%");
        assert!(can_start(&p, Some(true), Some(true), Some(21), None).is_ok());
        assert!(can_start(&p, Some(false), Some(true), Some(20), None).unwrap_err().contains("20%"));
        assert!(can_start(&p, Some(false), Some(true), None, None).is_err(), "can't see the charge");
        assert!(can_start(&p, None, Some(false), None, None).unwrap_err().contains("lid"));
        assert!(can_start(&p, Some(false), Some(false), None, Some(95_000)).unwrap_err().contains("hot"));
        let no_battery = LidPlan { allow_on_battery: false, ..plan() };
        assert!(can_start(&no_battery, Some(false), Some(true), Some(90), None).unwrap_err().contains("--no-battery"));
        assert!(can_start(&no_battery, Some(false), None, None, None).is_ok(), "desktop or unknown adapter");
    }

    #[test]
    fn until_agents_done_with_grace() {
        let p = LidPlan { until_agents_done: true, ..plan() };
        let mut t = Tracker::new(Some(false), 0.0);
        let obs = |t: &Tracker, e: f64| Observed { no_agents_for: t.no_agents_for(e), ..plugged() };
        // No agent at the start: 2 minutes to start one, then it ends.
        assert_eq!(decide(&p, &obs(&t, 119.0), &now(119.0)), Decision::Continue);
        t.observe_agents(Some(true), 100.0);
        assert_eq!(decide(&p, &obs(&t, 200.0), &now(200.0)), Decision::Continue);
        t.observe_agents(None, 210.0);
        assert_eq!(
            decide(&p, &obs(&t, 219.0), &now(219.0)),
            Decision::Continue,
            "unknown list keeps the last sighting"
        );
        t.observe_agents(Some(false), 220.0);
        assert_eq!(decide(&p, &obs(&t, 220.0), &now(220.0)), Decision::End(EndReason::AgentsDone));
        let ignored = plan();
        assert_eq!(decide(&ignored, &obs(&t, 9000.0), &now(9000.0)), Decision::Continue, "off unless asked");
    }

    #[test]
    fn sleep_at_past_midnight() {
        use chrono::TimeZone;
        // 23:00 local (UTC here); --at 01:30 is tomorrow.
        let start = chrono::Utc.with_ymd_and_hms(2026, 10, 16, 23, 0, 0).single().unwrap();
        let at = crate::duration::next_occurrence("01:30", &start).unwrap().timestamp();
        assert_eq!(at - start.timestamp(), 9000);
        let p = LidPlan::new(24, Some(at), false, true);
        let at_wall = |wall: i64| Now { elapsed: 1.0, wall_elapsed: 1.0, wall };
        assert_eq!(decide(&p, &plugged(), &at_wall(start.timestamp())), Decision::Continue);
        assert_eq!(decide(&p, &plugged(), &at_wall(at - 1)), Decision::Continue);
        assert_eq!(decide(&p, &plugged(), &at_wall(at)), Decision::End(EndReason::SleepAt));
    }

    #[test]
    fn thermal_and_malformed_readings() {
        let hot = Observed { max_temp_millic: Some(95_000), ..plugged() };
        assert_eq!(decide(&plan(), &hot, &now(1.0)), Decision::End(EndReason::Thermal { millic: 95_000 }));
        let warm = Observed { max_temp_millic: Some(94_999), ..plugged() };
        assert_eq!(decide(&plan(), &warm, &now(1.0)), Decision::Continue);
        let nan = Observed { lid_closed_for: f64::NAN, ..plugged() };
        assert_eq!(
            decide(&plan(), &nan, &now(1.0)),
            Decision::End(EndReason::LidClosedLimit),
            "NaN ends, never extends"
        );
        let bad_plan = LidPlan { after_closed_seconds: f64::INFINITY, ..plan() };
        assert_eq!(decide(&bad_plan, &plugged(), &now(1.0)), Decision::End(EndReason::LidClosedLimit));
        let negative = Observed { battery_percent: Some(-5), on_battery: Some(true), ..plugged() };
        assert_eq!(decide(&plan(), &negative, &now(1.0)), Decision::End(EndReason::LowBattery { percent: -5 }));
    }

    #[test]
    fn plans_are_clamped_and_described() {
        assert_eq!(LidPlan::new(0, None, false, true).after_closed_seconds, 1800.0);
        assert_eq!(LidPlan::new(99, None, false, true).after_closed_seconds, HARD_CAP_SECONDS);
        assert_eq!(LidPlan::new(DEFAULT_HALF_HOURS, None, false, true).after_closed_seconds, 3.0 * 3600.0);
        let d = LidPlan::new(6, None, true, false).describe();
        assert!(
            d.contains("sleeps 3 h after the lid closes") && d.contains("agents") && d.contains("unplugged"),
            "{d}"
        );
        let j = session_json(&plan(), crate::lock::Owner::Cli, 42, 1_792_170_000);
        assert_eq!(j.after_lid_closed_minutes, Some(180));
        assert_eq!(j.hard_cap_at.as_deref(), Some("2026-10-17T05:00:00Z"));
        let text = crate::util::json_string(&j);
        for key in [
            "active",
            "owner",
            "startedAt",
            "afterLidClosedMinutes",
            "sleepAt",
            "untilAgentsDone",
            "allowOnBattery",
            "minBatteryPercent",
            "hardCapAt",
            "lidClosedSince",
            "lastEndedAt",
            "lastEndReason",
        ] {
            assert!(text.contains(&format!("\"{key}\"")), "{key}");
        }
    }

    #[test]
    fn log_rotation_and_last_end() {
        assert_eq!(keep_newest_half("a\nb\nc\nd\n"), "c\nd\n");
        assert_eq!(keep_newest_half(""), "");
        assert_eq!(keep_newest_half("no newline"), "");
        assert_eq!(keep_newest_half("ééééé\nü\n"), "ü\n", "cuts at a line, never inside a character");
        let log = "2026-10-17T01:00:00+02:00 started pid 5 (cli): x\n\
                   2026-10-17T02:00:00+02:00 ended low-battery: the battery is at 20%\n\
                   2026-10-17T02:00:01+02:00 after low-battery: asked to suspend (lid closed)\n";
        assert_eq!(last_end(log), Some(("2026-10-17T02:00:00+02:00".into(), "low-battery".into())));
        assert_eq!(last_end("garbage\n\n ended \nx ended : y"), None);
        assert_eq!(last_end(""), None);
    }
}
