//! The `keepwatch` command line, parsed. A port of `CLICommand.swift`:
//! same commands, same usage errors, same exit codes. Parsing is pure.

use crate::duration;
use chrono::{DateTime, TimeZone};

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Command {
    Status { json: bool },
    Awake(AwakeRequest),
    Run { command: Vec<String>, display: bool },
    Mic { mute: bool },
    LidEnd,
    LidStart { half_hours: Option<u32> },
    Ports { json: bool },
    Agents { json: bool },
    AgentStop { pid: u32 },
    Privacy { json: bool },
    Apps { json: bool },
    Security { json: bool },
    Help,
    Version,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AwakeRequest {
    Minutes(u32),
    Indefinitely,
    WhileAgentsRun,
    Off,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ParseError {
    UnknownCommand(String),
    Bad(String),
}

impl std::fmt::Display for ParseError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            ParseError::UnknownCommand(c) => {
                write!(f, "unknown command '{c}'. Run 'keepwatch help'.")
            }
            ParseError::Bad(m) => f.write_str(m),
        }
    }
}

fn bad(m: &str) -> ParseError {
    ParseError::Bad(m.to_string())
}

pub const USAGE: &str = "\
keepwatch: keep your computer awake for AI agents, and check power, agents, ports, mic and camera.

USAGE
  keepwatch status [--json]          power, sleep blockers, agents, mic/camera
  keepwatch awake                    keep awake until 'awake --off' or Ctrl-C
  keepwatch awake --for 3h           keep awake for 45m, 3h, 1h30m, 2d, 1w... (max 30 days)
  keepwatch awake --until 18:30      keep awake until a time (today, or tomorrow if it has passed)
  keepwatch awake --minutes N        same as --for Nm
  keepwatch awake --agents           keep awake while agent CLIs (Claude Code, Codex...) run
  keepwatch awake --off              stop a running 'keepwatch awake'
  keepwatch run [--display] -- CMD...  keep awake while CMD runs; exits with CMD's status
  keepwatch agents [--json]          agent sessions: agent, pid, folder, working or idle
  keepwatch agents stop PID          quit one agent session
  keepwatch privacy [--json]         mic and camera now (best effort)
  keepwatch apps [--json]            your apps by memory use (read-only)
  keepwatch ports [--json]           your processes listening on TCP ports
  keepwatch version

  Not on Linux and Windows yet (macOS only): mic mute|unmute, lid start|end, security.

There is no Keepwatch app on Linux and Windows yet, so 'awake' holds the
computer awake itself and keeps running until the time is up, 'awake --off'
or Ctrl-C.

EXIT CODES  0 ok · 1 usage error · 2 system error · otherwise CMD's status for 'run'";

/// Parse argv[1..]. `now` is the current local time, for `--until`.
pub fn parse<Tz: TimeZone>(args: &[String], now: &DateTime<Tz>) -> Result<Command, ParseError> {
    let Some(first) = args.first() else {
        return Ok(Command::Help);
    };
    let rest: Vec<&str> = args.iter().skip(1).map(String::as_str).collect();
    let json = || -> Result<bool, ParseError> {
        if let Some(a) = rest.iter().find(|a| **a != "--json") {
            return Err(ParseError::Bad(format!("unexpected argument '{a}'")));
        }
        Ok(rest.contains(&"--json"))
    };
    match first.as_str() {
        "help" | "-h" | "--help" => Ok(Command::Help),
        "version" | "--version" => Ok(Command::Version),
        "status" => Ok(Command::Status { json: json()? }),
        "ports" => Ok(Command::Ports { json: json()? }),
        "privacy" => Ok(Command::Privacy { json: json()? }),
        "apps" => Ok(Command::Apps { json: json()? }),
        "security" => Ok(Command::Security { json: json()? }),
        "agents" => {
            if rest.first() == Some(&"stop") {
                let pid = match rest.as_slice() {
                    [_, p] => parse_pid(p),
                    _ => None,
                };
                return pid
                    .map(|pid| Command::AgentStop { pid })
                    .ok_or_else(|| bad("usage: keepwatch agents stop PID"));
            }
            Ok(Command::Agents { json: json()? })
        }
        "awake" => parse_awake(&rest, now).map(Command::Awake),
        "run" => {
            let usage = || bad("usage: keepwatch run [--display] -- CMD [ARGS…]");
            let mut display = false;
            let mut i = 0;
            while let Some(a) = rest.get(i) {
                if *a == "--" {
                    break;
                }
                if *a != "--display" {
                    return Err(usage());
                }
                display = true;
                i += 1;
            }
            if i >= rest.len() {
                return Err(usage());
            }
            let command: Vec<String> = rest.iter().skip(i + 1).map(|s| s.to_string()).collect();
            if command.is_empty() {
                return Err(usage());
            }
            Ok(Command::Run { command, display })
        }
        "mic" => match rest.as_slice() {
            ["mute"] => Ok(Command::Mic { mute: true }),
            ["unmute"] => Ok(Command::Mic { mute: false }),
            _ => Err(bad("usage: keepwatch mic mute|unmute")),
        },
        "lid" => match rest.as_slice() {
            ["end"] => Ok(Command::LidEnd),
            ["start"] => Ok(Command::LidStart { half_hours: None }),
            ["start", "--hours", h] => {
                let hours: f64 = h.parse().map_err(|_| bad("--hours needs a number from 0.5 to 12"))?;
                if !(hours.is_finite() && hours > 0.0 && hours <= 12.0) {
                    return Err(bad("--hours needs a number from 0.5 to 12"));
                }
                // Rounded to the nearest half hour, like the Swift CLI; 0..=24 so the cast is exact.
                let half = (hours * 2.0).round().clamp(0.0, 24.0) as u32;
                Ok(Command::LidStart { half_hours: Some(half) })
            }
            _ => Err(bad("usage: keepwatch lid start [--hours N] | keepwatch lid end")),
        },
        other => Err(ParseError::UnknownCommand(other.to_string())),
    }
}

/// A pid as the Swift CLI accepts it: a positive Int32 above 1.
fn parse_pid(s: &str) -> Option<u32> {
    let pid: i32 = s.parse().ok()?;
    if pid > 1 {
        u32::try_from(pid).ok()
    } else {
        None
    }
}

fn parse_awake<Tz: TimeZone>(rest: &[&str], now: &DateTime<Tz>) -> Result<AwakeRequest, ParseError> {
    match rest {
        [] => Ok(AwakeRequest::Indefinitely),
        ["--agents"] => Ok(AwakeRequest::WhileAgentsRun),
        ["--off"] => Ok(AwakeRequest::Off),
        ["--minutes", m] => {
            // Swift parses into Int: big numbers are capped, not rejected.
            let m: i64 = m.parse().map_err(|_| bad("--minutes needs a positive whole number"))?;
            if m <= 0 {
                return Err(bad("--minutes needs a positive whole number"));
            }
            let capped = m.min(i64::from(duration::MAX_MINUTES));
            Ok(AwakeRequest::Minutes(u32::try_from(capped).unwrap_or(duration::MAX_MINUTES)))
        }
        ["--for", length @ ..] if !length.is_empty() => {
            let s = duration::parse(&length.join(" "))
                .ok_or_else(|| bad("--for needs a length like 45m, 3h, 1h30m, 2d or 1w"))?;
            Ok(AwakeRequest::Minutes(duration::minutes(s)))
        }
        ["--until", time] => {
            let end = duration::next_occurrence(time, now).ok_or_else(|| bad("--until needs a time like 18:30"))?;
            let secs = (end - now.clone()).num_seconds();
            // num_seconds fits f64 exactly enough for a 1-day span.
            Ok(AwakeRequest::Minutes(duration::minutes(secs as f64)))
        }
        _ => Err(bad("usage: keepwatch awake [--for 3h | --until 18:30 | --minutes N | --agents | --off]")),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::Utc;

    fn p(s: &str) -> Result<Command, ParseError> {
        let args: Vec<String> = s.split(' ').filter(|a| !a.is_empty()).map(String::from).collect();
        parse(&args, &Utc::now())
    }

    #[test]
    fn parses_commands() {
        assert_eq!(parse::<Utc>(&[], &Utc::now()), Ok(Command::Help));
        assert_eq!(p("status --json"), Ok(Command::Status { json: true }));
        assert_eq!(p("awake"), Ok(Command::Awake(AwakeRequest::Indefinitely)));
        assert_eq!(p("awake --minutes 90"), Ok(Command::Awake(AwakeRequest::Minutes(90))));
        assert_eq!(p("awake --minutes 99999"), Ok(Command::Awake(AwakeRequest::Minutes(duration::MAX_MINUTES))));
        assert_eq!(
            p("awake --minutes 99999999999999"),
            Ok(Command::Awake(AwakeRequest::Minutes(duration::MAX_MINUTES)))
        );
        assert_eq!(p("awake --agents"), Ok(Command::Awake(AwakeRequest::WhileAgentsRun)));
        assert_eq!(p("awake --off"), Ok(Command::Awake(AwakeRequest::Off)));
        assert_eq!(
            p("run -- npm test --watch"),
            Ok(Command::Run { command: vec!["npm".into(), "test".into(), "--watch".into()], display: false })
        );
        assert_eq!(p("run --display -- make"), Ok(Command::Run { command: vec!["make".into()], display: true }));
        assert_eq!(p("mic mute"), Ok(Command::Mic { mute: true }));
        assert_eq!(p("lid end"), Ok(Command::LidEnd));
        assert_eq!(p("ports"), Ok(Command::Ports { json: false }));
        assert_eq!(p("awake --for 3h"), Ok(Command::Awake(AwakeRequest::Minutes(180))));
        assert_eq!(p("awake --for 1h 30m"), Ok(Command::Awake(AwakeRequest::Minutes(90))));
        assert_eq!(p("awake --for 2w"), Ok(Command::Awake(AwakeRequest::Minutes(20_160))));
        assert_eq!(p("awake --for 9w"), Ok(Command::Awake(AwakeRequest::Minutes(duration::MAX_MINUTES))));
        assert_eq!(p("agents --json"), Ok(Command::Agents { json: true }));
        assert_eq!(p("agents stop 4242"), Ok(Command::AgentStop { pid: 4242 }));
        assert_eq!(p("privacy"), Ok(Command::Privacy { json: false }));
        assert_eq!(p("security --json"), Ok(Command::Security { json: true }));
        assert_eq!(p("apps"), Ok(Command::Apps { json: false }));
        assert_eq!(p("apps --json"), Ok(Command::Apps { json: true }));
        assert_eq!(p("lid start"), Ok(Command::LidStart { half_hours: None }));
        assert_eq!(p("lid start --hours 2.7"), Ok(Command::LidStart { half_hours: Some(5) }));
        assert_eq!(p("version"), Ok(Command::Version));
        assert_eq!(p("--help"), Ok(Command::Help));
    }

    #[test]
    fn until_uses_the_next_occurrence() {
        let now = Utc.with_ymd_and_hms(2026, 10, 16, 17, 0, 0).single().unwrap();
        let until = |t: &str| parse(&["awake".to_string(), "--until".to_string(), t.to_string()], &now);
        assert_eq!(until("18:30"), Ok(Command::Awake(AwakeRequest::Minutes(90))));
        assert_eq!(until("16:00"), Ok(Command::Awake(AwakeRequest::Minutes(23 * 60))));
        for b in ["24:00", "9", "18:3x", "-1:00", "18:60", "١٨:٣٠"] {
            assert!(until(b).is_err(), "{b}");
        }
    }

    #[test]
    fn rejects_bad_input() {
        for b in [
            "awake --minutes 0",
            "awake --minutes x",
            "awake --bogus",
            "run",
            "run --",
            "run npm",
            "mic",
            "lid",
            "status --yaml",
            "frobnicate",
            "awake --for",
            "awake --for 3",
            "awake --for 0h",
            "awake --for 3x",
            "awake --for -2h",
            "agents stop",
            "agents stop 1",
            "agents stop abc",
            "agents stop -5",
            "agents stop 99999999999",
            "lid start --hours 0",
            "lid start --hours 13",
            "lid start --hours nan",
            "lid start now",
        ] {
            assert!(p(b).is_err(), "{b}");
        }
        assert_eq!(p("frobnicate").unwrap_err().to_string(), "unknown command 'frobnicate'. Run 'keepwatch help'.");
    }
}
