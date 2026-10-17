//! `keepwatch` for Linux and Windows: the same commands, JSON fields and exit
//! codes as the macOS CLI, as far as each platform allows. See `cli::USAGE`.
#![deny(unsafe_code)]

mod agents;
mod apps;
mod cli;
mod duration;
mod inhibit;
mod lock;
mod ports;
mod power;
mod privacy;
mod procs;
mod util;
#[cfg(windows)]
mod win;

use cli::{AwakeRequest, Command};
use serde::Serialize;
use std::collections::BTreeSet;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};

const VERSION: &str = "0.3.0";
const PLATFORM: &str = if cfg!(windows) { "windows" } else { "linux" };
const PLATFORM_NAME: &str = if cfg!(windows) { "Windows" } else { "Linux" };
/// After the last agent exits, `awake --agents` waits this long (as on macOS).
const AGENT_GRACE_SECONDS: f64 = 120.0;

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
        Command::LidStart { .. } | Command::LidEnd => not_yet("lid sessions"),
        Command::Security { .. } => not_yet("security"),
    }
}

fn not_yet(what: &str) -> i32 {
    err(&format!("{what} is not available on {PLATFORM_NAME} yet (macOS only for now)."));
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
    /// macOS `pmset disablesleep`; no equivalent is read yet.
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
    let mut agent_names: Vec<String> = agents::running_agents(&own_running(&procs)).into_keys().collect();
    agent_names.sort();
    let me = std::process::id();
    // Another keepwatch of ours that is holding (`awake` or `run`).
    let other_keepwatch = procs.iter().any(|p| {
        p.own
            && p.pid != me
            && p.name.eq_ignore_ascii_case("keepwatch")
            && matches!(p.arguments.first().map(String::as_str), Some("awake" | "run"))
            && !p.arguments.iter().any(|a| a == "--off")
    });
    #[cfg(target_os = "linux")]
    let (prevented_by, inhibitor_holding) = match inhibit::current_inhibitors() {
        Some(l) => (Some(inhibit::prevented_by(&l)), l.iter().any(|i| i.who == "keepwatch" && i.mode == "block")),
        None => (None, false),
    };
    // `powercfg /requests` needs an administrator, so other apps' requests are unknown.
    #[cfg(not(target_os = "linux"))]
    let (prevented_by, inhibitor_holding): (Option<Vec<String>>, bool) = (None, false);
    let holding = other_keepwatch || inhibitor_holding;
    let pr = privacy::current();
    StatusReport {
        version: VERSION.into(),
        platform: PLATFORM.into(),
        app_running: false,
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
        sleep: SleepJson { sleep_disabled: None, prevented_by, keepwatch_holding: holding },
        agents: agent_names,
        privacy: PrivacyJson {
            mic_in_use: pr.mic_in_use,
            camera_in_use: pr.camera_in_use,
            mic_muted: None,
            mic_users: pr.mic_users,
        },
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
        lines.push(format!("App       not available on {PLATFORM_NAME} yet"));
        lines.join("\n")
    }
}

// MARK: - agents

fn own_running(procs: &[procs::Proc]) -> Vec<agents::RunningProcess> {
    procs.iter().filter(|p| p.own && agents::is_candidate(&p.name)).map(procs::Proc::running).collect()
}

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

struct Session {
    pid: u32,
    agent: &'static str,
    folder: Option<String>,
    started: Option<u64>,
    cpu_ms: u64,
}

/// The user's agent sessions, oldest first.
fn sessions(procs: &[procs::Proc]) -> Vec<Session> {
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

/// Above this share of one core, a session counts as working (as on macOS).
const WORKING_THRESHOLD: f64 = 0.03;

fn agents_command(json: bool) -> i32 {
    let list = sessions(&procs::snapshot());
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
    let Some(session) = sessions(&procs::snapshot_light()).into_iter().find(|s| s.pid == pid) else {
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

/// Set on Ctrl-C, SIGTERM (`awake --off`) or SIGHUP.
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

fn own_start_time() -> u64 {
    let me = std::process::id();
    procs::snapshot_of(&[me]).first().and_then(|p| p.started).unwrap_or(0)
}

fn stop_running_awake(pid: u32) -> bool {
    if !procs::terminate(pid) {
        return false;
    }
    // Give it a moment to clean up after itself.
    for _ in 0..30 {
        if procs::snapshot_of(&[pid]).is_empty() {
            break;
        }
        std::thread::sleep(Duration::from_millis(100));
    }
    lock::remove_if(pid);
    true
}

fn awake(request: AwakeRequest) -> i32 {
    if request == AwakeRequest::Off {
        return match lock::live_awake() {
            Some(pid) if stop_running_awake(pid) => {
                out(&format!("Stopped 'keepwatch awake' (pid {pid}); your computer can sleep again."));
                0
            }
            Some(pid) => {
                err(&format!("couldn't stop 'keepwatch awake' (pid {pid})"));
                2
            }
            None => {
                out("Nothing to turn off: no 'keepwatch awake' is running for you.");
                0
            }
        };
    }
    let flag = stop_flag();
    // A new request replaces the running one, as it does in the macOS app.
    if let Some(pid) = lock::live_awake() {
        if stop_running_awake(pid) {
            out(&format!("Replaced the running 'keepwatch awake' (pid {pid})."));
        }
    }
    let label = match request {
        AwakeRequest::Minutes(m) => format!("keepwatch awake: {m} min"),
        AwakeRequest::WhileAgentsRun => "keepwatch awake: while agents run".into(),
        _ => "keepwatch awake: until stopped".into(),
    };
    let mut holder = match inhibit::Holder::start(&label, false) {
        Ok(h) => h,
        Err(e) => {
            err(&e);
            return 2;
        }
    };
    let me = std::process::id();
    if let Err(e) = lock::write(lock::LockInfo { pid: me, started: own_start_time() }) {
        err(&format!("'keepwatch awake --off' won't find this one: {e}"));
    }
    let mut lost = false;
    match request {
        AwakeRequest::Minutes(m) => {
            let secs = u64::from(m).saturating_mul(60);
            out(&format!(
                "Keeping your computer awake for {} (Ctrl-C or 'keepwatch awake --off' to stop)…",
                duration::describe(secs as f64)
            ));
            let end = Instant::now() + Duration::from_secs(secs);
            while !flag.load(Ordering::SeqCst) && Instant::now() < end {
                if !holder.alive() {
                    lost = true;
                    break;
                }
                nap(end.saturating_duration_since(Instant::now()).min(Duration::from_secs(2)), &flag);
            }
        }
        AwakeRequest::WhileAgentsRun => {
            out("Keeping your computer awake while agents run (Ctrl-C to stop)…");
            let mut watch = agents::AgentsWatch::new(AGENT_GRACE_SECONDS);
            let clock = Instant::now();
            let mut ever_seen = false;
            while !flag.load(Ordering::SeqCst) {
                if !holder.alive() {
                    lost = true;
                    break;
                }
                let running: BTreeSet<String> =
                    agents::running_agents(&own_running(&procs::snapshot_light())).into_keys().collect();
                ever_seen |= !running.is_empty();
                let tick = watch.tick(clock.elapsed().as_secs_f64(), &running);
                for name in &tick.finished {
                    out(&format!("{name} finished."));
                }
                if ever_seen && !tick.hold {
                    out("All agents finished; your computer can sleep again.");
                    break;
                }
                nap(Duration::from_secs(2), &flag);
            }
        }
        _ => {
            out("Keeping your computer awake until 'keepwatch awake --off' or Ctrl-C…");
            while !flag.load(Ordering::SeqCst) {
                if !holder.alive() {
                    lost = true;
                    break;
                }
                nap(Duration::from_secs(2), &flag);
            }
        }
    }
    holder.release();
    lock::remove_if(me);
    if lost {
        err("the keep-awake lock was lost (systemd-inhibit exited); your computer can sleep again");
        return 2;
    }
    if flag.load(Ordering::SeqCst) {
        out("Stopped; your computer can sleep again.");
    }
    0
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
    let mut holder = match inhibit::Holder::start(&format!("keepwatch run: {program}"), display) {
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
