//! The tray: a ksni StatusNotifierItem whose menu sends commands to one
//! controller thread. The controller owns the inhibitor children and the lock
//! files (the same `AwakeSession` / `LidSession` the CLI uses), so
//! `keepwatch awake --off` and `keepwatch lid end` stop the tray's sessions
//! too, and sessions started from a terminal show up here.

use crate::icon::{self, IconKind};
use crate::{autostart, notify::Notifier};
use keepwatch::lid::{self, EndReason, LidPlan, LidSession, LidSessionJson};
use keepwatch::lock::{self, Kind, Owner, StopResult};
use keepwatch::session::{self, AwakeEnd, AwakeMode, AwakeSession, AwakeState};
use keepwatch::{agents, duration, procs, util};
use ksni::blocking::TrayMethods;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{self, RecvTimeoutError, Sender};
use std::time::{Duration, Instant};

/// Menu commands, sent from ksni's D-Bus thread to the controller.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Cmd {
    Awake(AwakeMode),
    AwakeOff,
    LidStart { half_hours: u32 },
    LidEnd,
    SetEndWhenAgentsDone(bool),
    SetAllowOnBattery(bool),
    SetOpenAtLogin(bool),
    Quit,
}

/// Everything the menu shows. Rebuilt every few seconds; the tray is only
/// updated when it changes.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct View {
    pub status: Vec<String>,
    pub icon: Option<IconKind>,
    pub awake_on: bool,
    pub lid_on: bool,
    pub agents: Vec<String>,
    pub end_when_agents_done: bool,
    pub allow_on_battery: bool,
    pub open_at_login: bool,
}

/// Minutes, rounded up, as "2 h 41 min".
fn left(seconds: i64) -> String {
    let minutes = (seconds.max(0).saturating_add(59) / 60).max(1);
    // minutes * 60 is at most i64::MAX / 60 * 60 + 59: no overflow, and f64 is fine for display.
    duration::describe((minutes.saturating_mul(60)) as f64)
}

/// The keep-awake status line.
pub fn awake_line(state: Option<&AwakeState>, ours: bool, now: i64) -> String {
    let from = if ours { "" } else { " (from a terminal)" };
    match state {
        Some(s) if s.mode == "agents" => format!("Awake while agents run{from}"),
        Some(s) => match s.ends_at {
            Some(end) => format!("Awake · {} left{from}", left(end.saturating_sub(now))),
            None => format!("Awake until you turn it off{from}"),
        },
        None => format!("Awake{from}"),
    }
}

/// The lid-session status line.
pub fn lid_line(j: &LidSessionJson, ours: bool, now: i64) -> String {
    let from = if ours { "" } else { " (from a terminal)" };
    let after = j.after_lid_closed_minutes.unwrap_or(0).max(0);
    let closed_since =
        j.lid_closed_since.as_deref().and_then(|t| chrono::DateTime::parse_from_rfc3339(t).ok()).map(|t| t.timestamp());
    match closed_since {
        Some(since) => {
            let remaining = after.saturating_mul(60).saturating_sub(now.saturating_sub(since));
            format!("Lid session · sleeps in {}{from}", left(remaining))
        }
        None => {
            format!("Lid session · sleeps {} after closing{from}", duration::describe(after.saturating_mul(60) as f64))
        }
    }
}

struct Tray {
    tx: Sender<Cmd>,
    view: View,
    icons: [Vec<ksni::Icon>; 3],
    warned: AtomicBool,
}

fn icons(kind: IconKind) -> Vec<ksni::Icon> {
    icon::SIZES
        .iter()
        .map(|s| ksni::Icon {
            // SIZES are small constants.
            width: *s as i32,
            height: *s as i32,
            data: icon::render(kind, *s),
        })
        .collect()
}

impl Tray {
    fn send(&self, cmd: Cmd) {
        let _ = self.tx.send(cmd);
    }
}

impl ksni::Tray for Tray {
    const MENU_ON_ACTIVATE: bool = true;

    fn id(&self) -> String {
        "keepwatch-tray".into()
    }

    fn title(&self) -> String {
        "Keepwatch".into()
    }

    fn category(&self) -> ksni::Category {
        ksni::Category::ApplicationStatus
    }

    fn icon_pixmap(&self) -> Vec<ksni::Icon> {
        let i = match self.view.icon.unwrap_or(IconKind::Idle) {
            IconKind::Idle => 0,
            IconKind::Awake => 1,
            IconKind::Lid => 2,
        };
        self.icons.get(i).cloned().unwrap_or_default()
    }

    fn tool_tip(&self) -> ksni::ToolTip {
        ksni::ToolTip { title: "Keepwatch".into(), description: self.view.status.join("\n"), ..Default::default() }
    }

    fn watcher_offline(&self, _reason: ksni::OfflineReason) -> bool {
        if !self.warned.swap(true, Ordering::SeqCst) {
            eprintln!(
                "keepwatch-tray: no system tray is showing status icons right now. On stock GNOME, turn on \
                 the AppIndicator extension. keepwatch-tray keeps running and appears when a tray does."
            );
        }
        true
    }

    fn menu(&self) -> Vec<ksni::MenuItem<Self>> {
        use ksni::menu::{CheckmarkItem, StandardItem, SubMenu};
        let v = &self.view;
        let item = |label: &str, cmd: Cmd, enabled: bool| -> ksni::MenuItem<Self> {
            StandardItem {
                label: label.into(),
                enabled,
                activate: Box::new(move |t: &mut Self| t.send(cmd)),
                ..Default::default()
            }
            .into()
        };
        let info = |label: &str| -> ksni::MenuItem<Self> {
            StandardItem { label: label.into(), enabled: false, ..Default::default() }.into()
        };
        let mut menu: Vec<ksni::MenuItem<Self>> = if v.status.is_empty() {
            vec![info("Sleeping normally")]
        } else {
            v.status.iter().map(|s| info(s)).collect()
        };
        menu.push(ksni::MenuItem::Separator);
        menu.push(
            SubMenu {
                label: "Keep awake".into(),
                submenu: vec![
                    item("1 hour", Cmd::Awake(AwakeMode::Minutes(60)), true),
                    item("3 hours", Cmd::Awake(AwakeMode::Minutes(180)), true),
                    item("8 hours", Cmd::Awake(AwakeMode::Minutes(480)), true),
                    item("Until I turn it off", Cmd::Awake(AwakeMode::Indefinitely), true),
                    item("While agents run", Cmd::Awake(AwakeMode::WhileAgentsRun), true),
                    ksni::MenuItem::Separator,
                    item("Turn off", Cmd::AwakeOff, v.awake_on),
                ],
                ..Default::default()
            }
            .into(),
        );
        let (agents_done, battery) = (v.end_when_agents_done, v.allow_on_battery);
        menu.push(
            SubMenu {
                label: "Laptop closed".into(),
                submenu: vec![
                    item("Start for 1 hour", Cmd::LidStart { half_hours: 2 }, true),
                    item("Start for 3 hours", Cmd::LidStart { half_hours: 6 }, true),
                    item("Start for 6 hours", Cmd::LidStart { half_hours: 12 }, true),
                    item("Start for 12 hours", Cmd::LidStart { half_hours: 24 }, true),
                    ksni::MenuItem::Separator,
                    CheckmarkItem {
                        label: "End when agents finish".into(),
                        checked: agents_done,
                        activate: Box::new(move |t: &mut Self| {
                            t.view.end_when_agents_done = !agents_done;
                            t.send(Cmd::SetEndWhenAgentsDone(!agents_done));
                        }),
                        ..Default::default()
                    }
                    .into(),
                    CheckmarkItem {
                        label: "Allow on battery".into(),
                        checked: battery,
                        activate: Box::new(move |t: &mut Self| {
                            t.view.allow_on_battery = !battery;
                            t.send(Cmd::SetAllowOnBattery(!battery));
                        }),
                        ..Default::default()
                    }
                    .into(),
                    ksni::MenuItem::Separator,
                    item("End lid session", Cmd::LidEnd, v.lid_on),
                ],
                ..Default::default()
            }
            .into(),
        );
        let agents: Vec<ksni::MenuItem<Self>> = if v.agents.is_empty() {
            vec![info("No agents running")]
        } else {
            v.agents.iter().map(|a| info(a)).collect()
        };
        menu.push(
            SubMenu { label: format!("Agents ({})", v.agents.len()), submenu: agents, ..Default::default() }.into(),
        );
        menu.push(ksni::MenuItem::Separator);
        let login = v.open_at_login;
        menu.push(
            CheckmarkItem {
                label: "Open at login".into(),
                checked: login,
                activate: Box::new(move |t: &mut Self| {
                    t.view.open_at_login = !login;
                    t.send(Cmd::SetOpenAtLogin(!login));
                }),
                ..Default::default()
            }
            .into(),
        );
        menu.push(item("Quit", Cmd::Quit, true));
        menu
    }
}

/// The controller: owns the sessions this tray started.
struct Controller {
    awake: Option<AwakeSession>,
    lid: Option<LidSession>,
    end_when_agents_done: bool,
    allow_on_battery: bool,
    agent_names: std::collections::BTreeSet<String>,
    agent_rows: Vec<String>,
    notifier: Notifier,
}

const MAX_AGENT_ROWS: usize = 20;

impl Controller {
    fn sample_agents(&mut self) {
        let light = procs::snapshot_light();
        self.agent_names = agents::running_agents(&procs::own_running(&light)).into_keys().collect();
        let sessions = procs::sessions(&light);
        let pids: Vec<u32> = sessions.iter().take(MAX_AGENT_ROWS).map(|s| s.pid).collect();
        let detailed = procs::snapshot_of(&pids);
        let home = util::home_dir();
        self.agent_rows = sessions
            .iter()
            .take(MAX_AGENT_ROWS)
            .map(|s| {
                let folder = detailed
                    .iter()
                    .find(|p| p.pid == s.pid)
                    .and_then(|p| p.cwd.as_deref())
                    .map_or("?".to_string(), |f| util::abbreviate_home(f, home.as_deref()));
                util::clean_line(&format!("{} · {folder}", s.agent), 80)
            })
            .collect();
    }

    fn end_awake(&mut self, why: AwakeEnd) {
        let Some(s) = self.awake.take() else {
            return;
        };
        s.finish();
        match why {
            AwakeEnd::AgentsFinished => {
                self.notifier.send("Agents finished", "Your computer can sleep again.");
            }
            AwakeEnd::TimeUp => self.notifier.send("Keep awake ended", "Your computer can sleep again."),
            AwakeEnd::Lost => self.notifier.send("Keep awake stopped", "The keep-awake lock was lost."),
            AwakeEnd::StopRequested => {}
        }
    }

    fn end_lid(&mut self, why: EndReason) {
        let Some(s) = self.lid.take() else {
            return;
        };
        // Tell the user before a suspend can happen.
        if why != EndReason::Quit {
            self.notifier.send("Lid session ended", &format!("It ended because {}.", why.describe()));
        }
        let outcome = s.finish(why);
        eprintln!("keepwatch-tray: lid session ended: {}. {}", why.describe(), outcome.describe());
    }

    fn handle(&mut self, cmd: Cmd) -> bool {
        match cmd {
            Cmd::Awake(mode) => {
                self.end_awake(AwakeEnd::StopRequested);
                if let StopResult::Failed(l) = lock::stop(Kind::Awake) {
                    self.notifier
                        .send("Couldn't keep awake", &format!("Another keepwatch (pid {}) didn't stop.", l.pid));
                    return true;
                }
                match AwakeSession::start(mode, Owner::Tray) {
                    Ok((s, warning)) => {
                        if let Some(w) = warning {
                            eprintln!("keepwatch-tray: {w}");
                        }
                        self.awake = Some(s);
                    }
                    Err(e) => self.notifier.send("Couldn't keep awake", &e),
                }
            }
            Cmd::AwakeOff => {
                if self.awake.is_some() {
                    self.end_awake(AwakeEnd::StopRequested);
                } else {
                    let _ = lock::stop(Kind::Awake);
                }
            }
            Cmd::LidStart { half_hours } => {
                self.end_lid(EndReason::StopRequested);
                if let StopResult::Failed(l) = lock::stop(Kind::Lid) {
                    let msg = format!("Another lid session (pid {}) didn't stop.", l.pid);
                    self.notifier.send("Couldn't start a lid session", &msg);
                    return true;
                }
                let plan = LidPlan::new(half_hours, None, self.end_when_agents_done, self.allow_on_battery);
                match LidSession::start(plan, Owner::Tray) {
                    Ok(s) => self.lid = Some(s),
                    Err(e) => self.notifier.send("Couldn't start a lid session", &e),
                }
            }
            Cmd::LidEnd => {
                if self.lid.is_some() {
                    self.end_lid(EndReason::StopRequested);
                } else {
                    let _ = lock::stop(Kind::Lid);
                }
            }
            Cmd::SetEndWhenAgentsDone(on) => self.end_when_agents_done = on,
            Cmd::SetAllowOnBattery(on) => self.allow_on_battery = on,
            Cmd::SetOpenAtLogin(on) => {
                if let Err(e) = autostart::set(on) {
                    self.notifier.send("Couldn't change Open at login", &e);
                }
            }
            Cmd::Quit => return false,
        }
        true
    }

    /// The cheap checks, every second.
    fn check(&mut self) {
        if let Some(why) = self.awake.as_mut().and_then(AwakeSession::check) {
            self.end_awake(why);
        }
        if let Some(why) = self.lid.as_mut().and_then(LidSession::check) {
            self.end_lid(why);
        }
    }

    /// The rule tick, every 5 s: agents, the lid rules.
    fn rules(&mut self) {
        self.sample_agents();
        if let Some(s) = self.awake.as_mut() {
            let (_, end) = s.agents_tick(&self.agent_names);
            if let Some(why) = end {
                self.end_awake(why);
            }
        }
        if let Some(s) = self.lid.as_mut() {
            let mut sensors = lid::read_sensors(false);
            sensors.agents_running = Some(!self.agent_names.is_empty());
            let (_, end) = s.step(&sensors);
            if let Some(why) = end {
                self.end_lid(why);
            }
        }
    }

    fn view(&self) -> View {
        let me = std::process::id();
        let now = session::unix_now();
        let mut status = Vec::new();
        let lid = lid::current_json();
        if lid.active {
            status.push(lid_line(&lid, lid.pid == Some(me), now));
        }
        let awake = lock::live(Kind::Awake);
        if let Some(live) = awake {
            let state = lock::read_state(Kind::Awake)
                .and_then(|t| serde_json::from_str::<AwakeState>(&t).ok())
                .filter(|s| s.pid == live.pid);
            status.push(awake_line(state.as_ref(), live.pid == me, now));
        }
        View {
            status,
            icon: Some(if lid.active {
                IconKind::Lid
            } else if awake.is_some() {
                IconKind::Awake
            } else {
                IconKind::Idle
            }),
            awake_on: awake.is_some(),
            lid_on: lid.active,
            agents: self.agent_rows.clone(),
            end_when_agents_done: self.end_when_agents_done,
            allow_on_battery: self.allow_on_battery,
            open_at_login: autostart::enabled(),
        }
    }

    fn quit(&mut self) {
        self.end_awake(AwakeEnd::StopRequested);
        self.end_lid(EndReason::Quit);
    }
}

/// Another keepwatch-tray of ours already running?
fn other_tray() -> Option<u32> {
    let me = std::process::id();
    procs::snapshot_light()
        .into_iter()
        .find(|p| p.own && p.pid != me && p.name.eq_ignore_ascii_case(lock::TRAY_NAME))
        .map(|p| p.pid)
}

pub fn run() -> i32 {
    if let Some(pid) = other_tray() {
        eprintln!("keepwatch-tray is already running (pid {pid}).");
        return 1;
    }
    let (tx, rx) = mpsc::channel::<Cmd>();
    let quit_tx = tx.clone();
    // Ctrl-C quits cleanly; SIGTERM keeps its default action (the inhibitors go with the process).
    let _ = ctrlc::set_handler(move || {
        let _ = quit_tx.send(Cmd::Quit);
    });
    let mut c = Controller {
        awake: None,
        lid: None,
        end_when_agents_done: false,
        allow_on_battery: false,
        agent_names: Default::default(),
        agent_rows: Vec::new(),
        notifier: Notifier::new(),
    };
    c.sample_agents();
    let mut last_view = c.view();
    let tray = Tray {
        tx,
        view: last_view.clone(),
        icons: [icons(IconKind::Idle), icons(IconKind::Awake), icons(IconKind::Lid)],
        warned: AtomicBool::new(false),
    };
    let handle = match tray.assume_sni_available(true).spawn() {
        Ok(h) => h,
        Err(e) => {
            eprintln!("keepwatch-tray: couldn't put an icon on the session bus: {e}");
            return 2;
        }
    };
    eprintln!("keepwatch-tray {} running (pid {}).", keepwatch::VERSION, std::process::id());
    let tick = lid::rule_tick();
    let mut last_rules = Instant::now();
    loop {
        let mut changed = false;
        match rx.recv_timeout(Duration::from_secs(1)) {
            Ok(cmd) => {
                if !c.handle(cmd) {
                    break;
                }
                changed = true;
            }
            Err(RecvTimeoutError::Timeout) => {}
            Err(RecvTimeoutError::Disconnected) => break,
        }
        c.check();
        if last_rules.elapsed() >= tick {
            last_rules = Instant::now();
            c.rules();
            changed = true;
        }
        if changed {
            let view = c.view();
            if view != last_view {
                last_view = view.clone();
                handle.update(move |t: &mut Tray| t.view = view);
            }
        }
        if handle.is_closed() {
            break;
        }
    }
    c.quit();
    handle.shutdown().wait();
    0
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn status_lines() {
        let timed = AwakeState {
            owner: "tray".into(),
            pid: 5,
            mode: "timed".into(),
            started_at: None,
            ends_at: Some(1_000 + 2 * 3600 + 41 * 60),
        };
        assert_eq!(awake_line(Some(&timed), true, 1_000), "Awake · 2 h 41 min left");
        assert_eq!(awake_line(Some(&timed), true, 1_001), "Awake · 2 h 41 min left", "rounded up");
        assert_eq!(awake_line(Some(&timed), false, 1_000), "Awake · 2 h 41 min left (from a terminal)");
        let agents = AwakeState { mode: "agents".into(), ends_at: None, ..timed.clone() };
        assert_eq!(awake_line(Some(&agents), true, 0), "Awake while agents run");
        let forever = AwakeState { mode: "indefinitely".into(), ends_at: None, ..timed.clone() };
        assert_eq!(awake_line(Some(&forever), true, 0), "Awake until you turn it off");
        assert_eq!(awake_line(None, false, 0), "Awake (from a terminal)");
        let past = AwakeState { ends_at: Some(-5), ..timed };
        assert_eq!(awake_line(Some(&past), true, i64::MAX), "Awake · 1 min left", "no overflow");

        let mut j = LidSessionJson { active: true, after_lid_closed_minutes: Some(180), ..Default::default() };
        assert_eq!(lid_line(&j, true, 0), "Lid session · sleeps 3 h after closing");
        j.lid_closed_since = keepwatch::util::iso8601(1_792_170_000);
        assert_eq!(lid_line(&j, true, 1_792_170_000 + 50 * 60), "Lid session · sleeps in 2 h 10 min");
        assert_eq!(lid_line(&j, false, 1_792_170_000), "Lid session · sleeps in 3 h (from a terminal)");
        j.lid_closed_since = Some("junk".into());
        assert_eq!(lid_line(&j, true, 0), "Lid session · sleeps 3 h after closing");
        j.after_lid_closed_minutes = Some(i64::MAX);
        let _ = lid_line(&j, true, i64::MIN);
    }
}
