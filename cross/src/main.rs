//! `keepwatch` for Linux and Windows: the same commands, JSON fields and exit
//! codes as the macOS CLI, as far as each platform allows. See `cli::USAGE`.
#![deny(unsafe_code)]

use keepwatch::cli::{self, AwakeRequest, Command, LidRequest};
use keepwatch::lock::{self, Kind, Owner, StopIntent, StopResult};
use keepwatch::session::{AwakeEnd, AwakeMode, AwakeSession};
use keepwatch::{agents, apps, duration, inhibit, lid, ports, power, privacy, procs, util, VERSION};
use serde::Serialize;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};

const PLATFORM: &str = if cfg!(windows) { "windows" } else { "linux" };
const PLATFORM_NAME: &str = if cfg!(windows) { "Windows" } else { "Linux" };

fn out(s: &str) {
    println!("{s}");
}

fn err(s: &str) {
    eprintln!("keepwatch: {s}");
}

fn main() {
    let args: Vec<String> = std::env::args_os().skip(1).map(|a| a.to_string_lossy().into_owned()).collect();
    let code = match cli::parse(&args, &chrono::Local::now()) {
        Ok(command) => run(command),
        Err(e) => {
            err(&e.to_string());
            1
        }
    };
    std::process::exit(code);
}

fn run(command: Command) -> i32 {
    match command {
        Command::Help => {
            out(cli::USAGE);
            0
        }
        Command::Version => {
            out(&format!("keepwatch {VERSION}"));
            0
        }
        Command::Status { json } => {
            let report = status_report();
            out(&if json { util::json_string(&report) } else { report.text() });
            0
        }
        Command::Agents { json } => agents_command(json),
        Command::AgentStop { pid } => agent_stop(pid),
        Command::Ports { json } => ports_command(json),
        Command::Privacy { json } => privacy_command(json),
        Command::Apps { json } => apps_command(json),
        Command::Awake(request) => awake(request),
        Command::Run { command, display } => run_child(&command, display),
        Command::Mic { .. } => not_yet("mic mute|unmute"),
        Command::LidStart(request) => lid_start(request),
        Command::LidEnd => lid_end(),
        Command::LidStatus { json } => lid_status(json),
        Command::Security { .. } => not_yet("security"),
    }
}

fn not_yet(what: &str) -> i32 {
    let elsewhere = if what == "lid sessions" { "macOS and Linux only for now" } else { "macOS only for now" };
    err(&format!("{what} is not available on {PLATFORM_NAME} yet ({elsewhere})."));
    1
}

// MARK: - status

/// `keepwatch status --json`. Field names are the macOS `StatusReport`
/// contract; unknowns are null, never guessed. `platform` is added.
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct StatusReport {
    version: String,
    platform: String,
    app_running: bool,
    power: PowerJson,
    sleep: SleepJson,
    agents: Vec<String>,
    privacy: PrivacyJson,
    /// Linux lid-closed session (null on Windows). Not in the macOS contract.
    lid_session: Option<lid::LidSessionJson>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct PowerJson {
    battery_percent: Option<i64>,
    on_battery: Option<bool>,
    charging: Option<bool>,
    minutes_remaining: Option<i64>,
    health_percent: Option<i64>,
    cycle_count: Option<i64>,
    low_power_mode: Option<bool>,
    thermal: Option<String>,
    lid_closed: Option<bool>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct SleepJson {
    /// macOS `pmset disablesleep`. Linux: whether any app (a lid session,
    /// for one) holds a block inhibitor on the lid switch.
    sleep_disabled: Option<bool>,
    prevented_by: Option<Vec<String>>,
    keepwatch_holding: bool,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct PrivacyJson {
    mic_in_use: Option<bool>,
    camera_in_use: Option<bool>,
    mic_muted: Option<bool>,
    mic_users: Vec<String>,
}

fn status_report() -> StatusReport {
    let p = power::current();
    let procs = procs::snapshot_light();
    let mut agent_names: Vec<String> = agents::running_agents(&procs::own_running(&procs)).into_keys().collect();
    agent_names.sort();
    let me = std::process::id();
    // Another keepwatch of ours that is holding (`awake`, `run` or `lid start`).
    let other_keepwatch = procs.iter().any(|p| {
        p.own
            && p.pid != me
            && p.name.eq_ignore_ascii_case("keepwatch")
            && matches!(p.arguments.first().map(String::as_str), Some("awake" | "run"))
            && !p.arguments.iter().any(|a| a == "--off")
    });
    let tray_running = procs.iter().any(|p| p.own && p.name.eq_ignore_ascii_case(lock::TRAY_NAME));
    #[cfg(target_os = "linux")]
    let (prevented_by, inhibitor_holding, sleep_disabled) = match inhibit::current_inhibitors() {
        Some(l) => (
            Some(inhibit::prevented_by(&l)),
            l.iter().any(|i| i.who == "keepwatch" && i.mode == "block"),
            Some(inhibit::lid_switch_blocked(&l)),
        ),
        None => (None, false, None),
    };
    // `powercfg /requests` needs an administrator, so other apps' requests are unknown.
    #[cfg(not(target_os = "linux"))]
    let (prevented_by, inhibitor_holding, sleep_disabled): (Option<Vec<String>>, bool, Option<bool>) =
        (None, false, None);
    let lid_session = if cfg!(target_os = "linux") { Some(lid::current_json()) } else { None };
    let lid_active = lid_session.as_ref().is_some_and(|l| l.active);
    let awake_active = lock::live(Kind::Awake).is_some();
    let holding = other_keepwatch || inhibitor_holding || lid_active || awake_active;
    let pr = privacy::current();
    StatusReport {
        version: VERSION.into(),
        platform: PLATFORM.into(),
        app_running: tray_running,
        power: PowerJson {
            battery_percent: p.battery_percent,
            on_battery: p.on_battery,
            charging: p.charging,
            minutes_remaining: p.minutes_remaining,
            health_percent: p.health_percent,
            cycle_count: p.cycle_count,
            low_power_mode: p.low_power_mode,
            thermal: None,
            lid_closed: p.lid_closed,
        },
        sleep: SleepJson {
            sleep_disabled: sleep_disabled.map(|b| b || lid_active).or(lid_active.then_some(true)),
            prevented_by,
            keepwatch_holding: holding,
        },
        agents: agent_names,
        privacy: PrivacyJson {
            mic_in_use: pr.mic_in_use,
            camera_in_use: pr.camera_in_use,
            mic_muted: None,
            mic_users: pr.mic_users,
        },
        lid_session,
    }
}

fn on_off(v: Option<bool>) -> &'static str {
    match v {
        Some(true) => "IN USE",
        Some(false) => "off",
        None => "n/a",
    }
}

impl StatusReport {
    fn text(&self) -> String {
        let p = &self.power;
        let mut lines = Vec::new();
        let battery = p.battery_percent.map_or("n/a".to_string(), |b| format!("{b}%"));
        let source = match p.on_battery {
            Some(true) => " on battery",
            Some(false) => " on power adapter",
            None => "",
        };
        let charging = if p.charging == Some(true) { ", charging" } else { "" };
        let left = p.minutes_remaining.map_or(String::new(), |m| format!(", {} h {} min left", m / 60, m % 60));
        lines.push(format!("Power     {battery}{source}{charging}{left}"));
        if let Some(h) = p.health_percent {
            let cycles = p.cycle_count.map_or("?".to_string(), |c| c.to_string());
            lines.push(format!("Battery   {h}% health, {cycles} cycles"));
        }
        let saver = if p.low_power_mode == Some(true) { ", power saver on" } else { "" };
        lines.push(format!("Thermal   {}{saver}", p.thermal.as_deref().unwrap_or("n/a")));
        let lid = match p.lid_closed {
            Some(true) => "closed",
            Some(false) => "open",
            None => "n/a",
        };
        lines.push(format!("Lid       {lid}"));
        let sleep = match &self.sleep.prevented_by {
            None => "n/a (can't see what else keeps it awake)".to_string(),
            Some(v) if v.is_empty() => "normal".to_string(),
            Some(v) => format!("normal; kept awake by {}", v.join(", ")),
        };
        let holding = if self.sleep.keepwatch_holding { "; keepwatch is holding it awake" } else { "" };
        lines.push(format!("Sleep     {sleep}{holding}"));
        let agents = if self.agents.is_empty() { "none running".to_string() } else { self.agents.join(", ") };
        lines.push(format!("Agents    {agents}"));
        let mut privacy =
            format!("mic {}, camera {}", on_off(self.privacy.mic_in_use), on_off(self.privacy.camera_in_use));
        if !self.privacy.mic_users.is_empty() {
            privacy.push_str(&format!(" (mic: {})", self.privacy.mic_users.join(", ")));
        }
        lines.push(format!("Privacy   {privacy}"));
        if let Some(l) = &self.lid_session {
            lines.push(format!("Lid mode  {}", lid_line(l)));
        }
        if cfg!(windows) {
            lines.push(format!("App       not available on {PLATFORM_NAME} yet"));
        } else {
            lines
                .push(format!("App       keepwatch-tray {}", if self.app_running { "running" } else { "not running" }));
        }
        lines.join("\n")
    }
}

// MARK: - agents

#[derive(Serialize)]
struct AgentRow {
    agent: String,
    pid: u32,
    folder: Option<String>,
    started: Option<String>,
    activity: String,
    /// The agent's session name; not read on Linux and Windows yet.
    title: Option<String>,
}

/// Above this share of one core, a session counts as working (as on macOS).
const WORKING_THRESHOLD: f64 = 0.03;

fn agents_command(json: bool) -> i32 {
    let list = procs::sessions(&procs::snapshot());
    let started = Instant::now();
    let pids: Vec<u32> = list.iter().map(|s| s.pid).collect();
    let after = if list.is_empty() {
        Vec::new()
    } else {
        std::thread::sleep(Duration::from_secs(1));
        procs::snapshot_of(&pids)
    };
    let elapsed_ms = started.elapsed().as_millis().max(1) as f64;
    let rows: Vec<AgentRow> = list
        .iter()
        .map(|s| {
            let used = after.iter().find(|p| p.pid == s.pid).map_or(0, |p| p.cpu_ms.saturating_sub(s.cpu_ms));
            // u64 ms -> f64 is exact for any realistic CPU time.
            let working = (used as f64) / elapsed_ms >= WORKING_THRESHOLD;
            AgentRow {
                agent: s.agent.to_string(),
                pid: s.pid,
                folder: s.folder.clone(),
                started: s.started.and_then(util::iso8601),
                activity: if working { "working" } else { "idle" }.to_string(),
                title: None,
            }
        })
        .collect();
    if json {
        out(&util::json_string(&rows));
    } else if rows.is_empty() {
        out("No agents running.");
    } else {
        let home = util::home_dir();
        for r in &rows {
            let folder = r.folder.as_deref().map_or("?".to_string(), |f| util::abbreviate_home(f, home.as_deref()));
            out(&format!("{}  pid {}  {}  {}", r.agent, r.pid, r.activity, folder));
        }
    }
    0
}

fn agent_stop(pid: u32) -> i32 {
    let Some(session) = procs::sessions(&procs::snapshot_light()).into_iter().find(|s| s.pid == pid) else {
        err(&format!("pid {pid} is not a running agent session"));
        return 2;
    };
    // Re-check just before signalling: the pid must still be the same agent,
    // ours, with the same start time (a pid can be reused after it exits).
    let still = procs::snapshot_of(&[pid])
        .into_iter()
        .any(|p| p.own && agents::agent_name(&p.running()) == Some(session.agent) && p.started == session.started);
    if !still || !procs::terminate(pid) {
        err(&format!("couldn't stop pid {pid}"));
        return 2;
    }
    if cfg!(windows) {
        out(&format!("Ended {} (pid {pid}).", session.agent));
    } else {
        out(&format!("Asked {} (pid {pid}) to quit.", session.agent));
    }
    0
}

// MARK: - ports, privacy, apps

fn ports_command(json: bool) -> i32 {
    let rows = ports::current();
    if json {
        out(&util::json_string(&rows));
    } else if rows.is_empty() {
        out("Nothing of yours is listening.");
    } else {
        for p in &rows {
            let system = if p.system { "  (system)" } else { "" };
            out(&format!(":{:<6} {}  {}{system}", p.port, p.process, p.address));
        }
    }
    0
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct PrivacyReport {
    mic_in_use: Option<bool>,
    camera_in_use: Option<bool>,
    mic_muted: Option<bool>,
    mic_users: Vec<String>,
    /// On/off history is recorded by the macOS app; empty here.
    history: Vec<serde_json::Value>,
}

fn privacy_command(json: bool) -> i32 {
    let p = privacy::current();
    if json {
        out(&util::json_string(&PrivacyReport {
            mic_in_use: p.mic_in_use,
            camera_in_use: p.camera_in_use,
            mic_muted: None,
            mic_users: p.mic_users,
            history: Vec::new(),
        }));
    } else {
        let word = |v: Option<bool>| match v {
            Some(true) => "IN USE",
            Some(false) => "not in use",
            None => "unknown",
        };
        let users = if p.mic_users.is_empty() { String::new() } else { format!(" ({})", p.mic_users.join(", ")) };
        out(&format!("Mic {}{users}, camera {}", word(p.mic_in_use), word(p.camera_in_use)));
        out("  No history (the macOS app records it).");
    }
    0
}

fn apps_command(json: bool) -> i32 {
    let rows = apps::group(&procs::snapshot(), std::process::id(), 15, cfg!(windows));
    if json {
        out(&util::json_string(&rows));
    } else {
        for a in &rows {
            let n = if a.processes > 1 { format!(" ({} processes)", a.processes) } else { String::new() };
            let system = if a.system { "  system" } else { "" };
            out(&format!("{:>10}  {}{n}{system}", util::describe_bytes(a.bytes), a.name));
        }
    }
    0
}

// MARK: - keep awake

/// Set on Ctrl-C. SIGTERM (`awake --off`, `kill`) and SIGHUP keep their
/// default action and end keepwatch at once; the Linux inhibitor goes with it
/// (its `cat` reads EOF), and Windows drops the execution state with the process.
fn stop_flag() -> Arc<AtomicBool> {
    let flag = Arc::new(AtomicBool::new(false));
    let f = flag.clone();
    // Fails only if a handler is already set, which never happens here.
    let _ = ctrlc::set_handler(move || f.store(true, Ordering::SeqCst));
    flag
}

/// Sleep up to `d`, waking early when `flag` is set.
fn nap(d: Duration, flag: &AtomicBool) {
    let end = Instant::now() + d;
    while !flag.load(Ordering::SeqCst) {
        let left = end.saturating_duration_since(Instant::now());
        if left.is_zero() {
            break;
        }
        std::thread::sleep(left.min(Duration::from_millis(200)));
    }
}

fn awake(request: AwakeRequest) -> i32 {
    if request == AwakeRequest::Off {
        return match lock::stop(Kind::Awake, StopIntent::End) {
            StopResult::Stopped(l) => {
                let who = if l.owner == Owner::Tray { "the tray's keep-awake" } else { "'keepwatch awake'" };
                out(&format!("Stopped {who} (pid {}); your computer can sleep again.", l.pid));
                0
            }
            StopResult::Failed(l) => {
                err(&format!("couldn't stop 'keepwatch awake' (pid {})", l.pid));
                2
            }
            StopResult::NotRunning => {
                out("Nothing to turn off: no 'keepwatch awake' is running for you.");
                0
            }
        };
    }
    let flag = stop_flag();
    // A new request replaces the running one, as it does in the macOS app.
    if let StopResult::Stopped(l) = lock::stop(Kind::Awake, StopIntent::Replace) {
        out(&format!("Replaced the running 'keepwatch awake' (pid {}).", l.pid));
    }
    let mode = match request {
        AwakeRequest::Minutes(m) => AwakeMode::Minutes(m),
        AwakeRequest::WhileAgentsRun => AwakeMode::WhileAgentsRun,
        _ => AwakeMode::Indefinitely,
    };
    let mut session = match AwakeSession::start(mode, Owner::Cli) {
        Ok((s, warning)) => {
            if let Some(w) = warning {
                err(&w);
            }
            s
        }
        Err(e) => {
            err(&e);
            return 2;
        }
    };
    match mode {
        AwakeMode::Minutes(m) => out(&format!(
            "Keeping your computer awake for {} (Ctrl-C or 'keepwatch awake --off' to stop)…",
            duration::describe(f64::from(m) * 60.0)
        )),
        AwakeMode::WhileAgentsRun => out("Keeping your computer awake while agents run (Ctrl-C to stop)…"),
        AwakeMode::Indefinitely => out("Keeping your computer awake until 'keepwatch awake --off' or Ctrl-C…"),
    }
    let mut last_agents: Option<Instant> = None;
    let end = loop {
        if flag.load(Ordering::SeqCst) {
            break None;
        }
        if let Some(end) = session.check() {
            break Some(end);
        }
        if mode == AwakeMode::WhileAgentsRun && last_agents.is_none_or(|t| t.elapsed() >= Duration::from_secs(2)) {
            last_agents = Some(Instant::now());
            let (finished, end) = session.agents_tick(&procs::running_agent_names());
            for name in &finished {
                out(&format!("{name} finished."));
            }
            if end.is_some() {
                break end;
            }
        }
        nap(Duration::from_secs(1), &flag);
    };
    session.finish();
    match end {
        Some(AwakeEnd::Lost) => {
            err("the keep-awake lock was lost (systemd-inhibit exited); your computer can sleep again");
            2
        }
        Some(AwakeEnd::AgentsFinished) => {
            out("All agents finished; your computer can sleep again.");
            0
        }
        Some(AwakeEnd::StopRequested) => {
            out("Stopped; your computer can sleep again.");
            0
        }
        Some(AwakeEnd::TimeUp) => 0,
        None => {
            out("Stopped; your computer can sleep again.");
            0
        }
    }
}

// MARK: - lid sessions

fn lid_line(l: &lid::LidSessionJson) -> String {
    if l.active {
        let owner = if l.owner.as_deref() == Some("tray") { "the tray" } else { "keepwatch lid start" };
        let mut parts = vec![format!("on (pid {}, {owner})", l.pid.unwrap_or(0))];
        if let Some(m) = l.after_lid_closed_minutes {
            parts.push(format!("sleeps {} after the lid closes", duration::describe((m as f64) * 60.0)));
        }
        if l.lid_closed_since.is_some() {
            parts.push("lid closed now".into());
        }
        parts.join(", ")
    } else {
        match &l.last_end_reason {
            Some(r) => format!("off (last ended: {r})"),
            None => "off".into(),
        }
    }
}

#[cfg(not(target_os = "linux"))]
fn lid_start(_request: LidRequest) -> i32 {
    not_yet("lid sessions")
}

#[cfg(not(target_os = "linux"))]
fn lid_end() -> i32 {
    not_yet("lid sessions")
}

#[cfg(not(target_os = "linux"))]
fn lid_status(_json: bool) -> i32 {
    not_yet("lid sessions")
}

#[cfg(target_os = "linux")]
fn lid_status(json: bool) -> i32 {
    let l = lid::current_json();
    if json {
        out(&util::json_string(&l));
    } else {
        out(&format!("Lid session {}", lid_line(&l)));
    }
    0
}

#[cfg(target_os = "linux")]
fn lid_end() -> i32 {
    match lock::stop(Kind::Lid, StopIntent::End) {
        StopResult::Stopped(l) => {
            out(&format!("Ended the lid session (pid {}); the lid works normally again.", l.pid));
            0
        }
        StopResult::Failed(l) => {
            err(&format!("couldn't end the lid session (pid {})", l.pid));
            2
        }
        StopResult::NotRunning => {
            out("No lid session is running; the lid works normally.");
            0
        }
    }
}

#[cfg(target_os = "linux")]
fn lid_start(request: LidRequest) -> i32 {
    let flag = stop_flag();
    match lock::stop(Kind::Lid, StopIntent::Replace) {
        StopResult::Stopped(l) => out(&format!("Replaced the running lid session (pid {}).", l.pid)),
        StopResult::Failed(l) => {
            err(&format!("a lid session is already running (pid {}) and didn't stop; try 'keepwatch lid end'", l.pid));
            return 2;
        }
        StopResult::NotRunning => {}
    }
    let plan =
        lid::LidPlan::new(request.half_hours, request.sleep_at, request.until_agents_done, request.allow_on_battery);
    let mut session = match lid::LidSession::start(plan, Owner::Cli) {
        Ok(s) => s,
        Err(e) => {
            err(&e);
            return 2;
        }
    };
    out(&format!(
        "Lid session on: this computer keeps running with the lid closed. It {}, and after 12 h at most. \
         Ctrl-C or 'keepwatch lid end' to end it.",
        session.plan().describe()
    ));
    let tick = lid::rule_tick();
    let mut last_rules: Option<Instant> = None;
    let reason = loop {
        if flag.load(Ordering::SeqCst) {
            break lid::EndReason::Interrupted;
        }
        if let Some(r) = session.check() {
            break r;
        }
        if last_rules.is_none_or(|t| t.elapsed() >= tick) {
            last_rules = Some(Instant::now());
            let sensors = lid::read_sensors(session.plan().until_agents_done);
            let (change, end) = session.step(&sensors);
            match change {
                Some(lid::LidChange::Closed) => out(&format!(
                    "Lid closed: sleeping in {} unless it opens.",
                    duration::describe(session.closed_left().unwrap_or(0.0))
                )),
                Some(lid::LidChange::Opened) => out("Lid opened: the timer starts again when it closes."),
                None => {}
            }
            if let Some(r) = end {
                break r;
            }
        }
        nap(tick.min(Duration::from_secs(1)), &flag);
    };
    let outcome = session.finish(reason);
    out(&format!("Lid session ended: {}. {}", reason.describe(), outcome.describe()));
    if reason == lid::EndReason::InhibitorLost {
        2
    } else {
        0
    }
}

/// `PATH` lookup that also finds `npm.cmd`-style scripts on Windows, which
/// `std::process::Command` only finds as `.exe`.
fn resolve_program(name: &str, path: Option<&std::ffi::OsStr>, exts: &[String]) -> std::path::PathBuf {
    let has_dir = name.contains('/') || name.contains('\\');
    let has_ext = std::path::Path::new(name).extension().is_some();
    if has_dir || has_ext || exts.is_empty() {
        return name.into();
    }
    if let Some(path) = path {
        for dir in std::env::split_paths(path) {
            for ext in exts {
                let candidate = dir.join(format!("{name}{ext}"));
                if candidate.is_file() {
                    return candidate;
                }
            }
        }
    }
    name.into()
}

fn run_child(argv: &[String], display: bool) -> i32 {
    let Some(program) = argv.first() else {
        return 1;
    };
    // Ctrl-C reaches the child from the terminal; keepwatch ignores it and waits.
    let _ignore_ctrl_c = stop_flag();
    let mut holder = match inhibit::Holder::start(&format!("keepwatch run: {program}"), display, inhibit::Hold::Awake) {
        Ok(h) => h,
        Err(e) => {
            err(&e);
            return 2;
        }
    };
    let exts: Vec<String> = if cfg!(windows) {
        std::env::var("PATHEXT")
            .unwrap_or_else(|_| ".COM;.EXE;.BAT;.CMD".into())
            .split(';')
            .filter(|e| !e.is_empty())
            .map(str::to_string)
            .collect()
    } else {
        Vec::new()
    };
    let exe = resolve_program(program, std::env::var_os("PATH").as_deref(), &exts);
    let mut child = match std::process::Command::new(exe).args(argv.iter().skip(1)).spawn() {
        Ok(c) => c,
        Err(e) => {
            holder.release();
            err(&format!("couldn't start {program}: {e}"));
            // Like /usr/bin/env, which the macOS CLI runs commands through.
            return match e.kind() {
                std::io::ErrorKind::NotFound => 127,
                std::io::ErrorKind::PermissionDenied => 126,
                _ => 2,
            };
        }
    };
    let mut warned = false;
    let status = loop {
        match child.try_wait() {
            Ok(Some(status)) => break Some(status),
            Ok(None) => {}
            Err(_) => break child.wait().ok(),
        }
        if !warned && !holder.alive() {
            err("the keep-awake lock was lost (systemd-inhibit exited); the command keeps running");
            warned = true;
        }
        std::thread::sleep(Duration::from_millis(50));
    };
    holder.release();
    match status {
        Some(s) => exit_code(s),
        None => 2,
    }
}

/// The child's exit status; killed by a signal is 128 + signal, as shells report it.
fn exit_code(status: std::process::ExitStatus) -> i32 {
    if let Some(code) = status.code() {
        return code;
    }
    #[cfg(unix)]
    {
        use std::os::unix::process::ExitStatusExt;
        if let Some(sig) = status.signal() {
            return 128i32.saturating_add(sig);
        }
    }
    2
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn status_json_field_names_are_stable() {
        let r = StatusReport {
            version: "0".into(),
            platform: "linux".into(),
            app_running: false,
            power: PowerJson {
                battery_percent: Some(50),
                on_battery: Some(true),
                charging: Some(false),
                minutes_remaining: Some(90),
                health_percent: Some(90),
                cycle_count: Some(10),
                low_power_mode: None,
                thermal: None,
                lid_closed: Some(false),
            },
            sleep: SleepJson {
                sleep_disabled: None,
                prevented_by: Some(vec!["Firefox".into()]),
                keepwatch_holding: true,
            },
            agents: vec!["Codex".into()],
            privacy: PrivacyJson {
                mic_in_use: Some(false),
                camera_in_use: Some(false),
                mic_muted: None,
                mic_users: vec![],
            },
            lid_session: Some(lid::LidSessionJson::default()),
        };
        let json = util::json_string(&r);
        for key in [
            "version",
            "platform",
            "appRunning",
            "batteryPercent",
            "onBattery",
            "charging",
            "minutesRemaining",
            "healthPercent",
            "cycleCount",
            "lowPowerMode",
            "thermal",
            "lidClosed",
            "sleepDisabled",
            "preventedBy",
            "keepwatchHolding",
            "agents",
            "micInUse",
            "cameraInUse",
            "micMuted",
            "micUsers",
            "lidSession",
        ] {
            assert!(json.contains(&format!("\"{key}\"")), "{key}");
        }
        assert!(json.contains("\"thermal\": null"), "unknowns are null, not missing");
        let text = r.text();
        assert!(text.contains("Agents    Codex"), "{text}");
        assert!(text.contains("Power     50% on battery, 1 h 30 min left"), "{text}");
        assert!(text.contains("kept awake by Firefox"), "{text}");
    }

    #[test]
    fn resolves_windows_scripts_on_path() {
        let dir = std::env::temp_dir().join(format!("kw-resolve-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join("npm.cmd"), "@echo off\n").unwrap();
        let path = std::env::join_paths([dir.clone()]).unwrap();
        let exts = vec![".EXE".to_string(), ".cmd".to_string()];
        assert_eq!(resolve_program("npm", Some(&path), &exts), dir.join("npm.cmd"));
        assert_eq!(resolve_program("npm.cmd", Some(&path), &exts), std::path::PathBuf::from("npm.cmd"));
        assert_eq!(resolve_program("missing", Some(&path), &exts), std::path::PathBuf::from("missing"));
        assert_eq!(resolve_program("npm", Some(&path), &[]), std::path::PathBuf::from("npm"), "Unix: no PATHEXT");
        assert_eq!(resolve_program("./x", None, &exts), std::path::PathBuf::from("./x"));
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[cfg(unix)]
    #[test]
    fn exit_codes_pass_through() {
        use std::os::unix::process::ExitStatusExt;
        assert_eq!(exit_code(std::process::ExitStatus::from_raw(3 << 8)), 3);
        assert_eq!(exit_code(std::process::ExitStatus::from_raw(0)), 0);
        assert_eq!(exit_code(std::process::ExitStatus::from_raw(15)), 143, "SIGTERM: 128 + 15");
    }
}
