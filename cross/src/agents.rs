//! Recognises AI coding-agent CLIs. A faithful port of `AgentMatcher` in
//! `AgentProcesses.swift`, plus the platform normalisation Windows needs
//! (`.exe` names, backslash paths). Everything here is pure and tested.

use std::collections::{BTreeMap, BTreeSet};

/// A running process, as much as the matcher needs to know about it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RunningProcess {
    pub pid: u32,
    /// Executable name (Linux `comm`, Windows image name without `.exe`).
    pub name: String,
    /// Command-line arguments after argv[0].
    pub arguments: Vec<String>,
}

#[cfg(test)]
impl RunningProcess {
    pub fn new(pid: u32, name: &str, arguments: &[&str]) -> Self {
        RunningProcess { pid, name: name.to_string(), arguments: arguments.iter().map(|s| s.to_string()).collect() }
    }
}

/// Executable names of agent CLIs (matched exactly, case-insensitively).
const NAMES: &[(&str, &str)] = &[
    ("claude", "Claude Code"),
    ("codex", "Codex"),
    ("gemini", "Gemini CLI"),
    ("aider", "Aider"),
    ("opencode", "OpenCode"),
    ("goose", "Goose"),
    ("amp", "Amp"),
    ("cursor-agent", "Cursor Agent"),
    ("qwen", "Qwen Code"),
    ("crush", "Crush"),
];

/// Argument markers of helper processes that are not a session of their own
/// (Claude Code's pre-warmed spare and its background pty host).
const IDLE_HELPER_MARKERS: &[&str] = &["--bg-spare", "/spare/", "--bg-pty-host"];
/// First-argument subcommands of long-lived supervisors (`claude daemon run`).
const SUPERVISOR_SUBCOMMANDS: &[&str] = &["daemon"];
/// Script runtimes: for these the script path decides. Case-sensitive, as in Swift.
const INTERPRETERS: &[&str] = &["node", "bun", "deno", "python", "python3", "Python"];
/// Install paths that identify an agent run through an interpreter.
const PACKAGE_MARKERS: &[(&str, &str)] = &[
    ("@google/gemini-cli", "Gemini CLI"),
    ("@qwen-code/qwen-code", "Qwen Code"),
    ("@sourcegraph/amp", "Amp"),
    ("@anthropic-ai/claude-code", "Claude Code"),
    ("@openai/codex", "Codex"),
    ("opencode-ai", "OpenCode"),
    ("cursor-agent", "Cursor Agent"),
    ("/aider/", "Aider"),
    ("aider-chat", "Aider"),
];

fn agent_for_name(name: &str) -> Option<&'static str> {
    let lower = name.to_lowercase();
    NAMES.iter().find(|(n, _)| *n == lower).map(|(_, a)| *a)
}

/// The executable name without a Windows `.exe` suffix (any case).
pub fn normalize_name(name: &str) -> &str {
    let n = name.len();
    match (n.checked_sub(4), name.get(n.saturating_sub(4)..)) {
        (Some(cut), Some(ext)) if ext.eq_ignore_ascii_case(".exe") => name.get(..cut).unwrap_or(name),
        _ => name,
    }
}

/// `lastPathComponent` + `deletingPathExtension` + lowercased, for `/` and `\` paths.
fn script_base(arg: &str) -> String {
    let path = arg.replace('\\', "/");
    let trimmed = path.trim_end_matches('/');
    let last = trimmed.rsplit('/').next().unwrap_or(trimmed);
    let stem = match last.rfind('.') {
        Some(dot) if dot > 0 => last.get(..dot).unwrap_or(last),
        _ => last,
    };
    stem.to_lowercase()
}

/// Whether the executable name is an agent CLI or a script runtime (before argument checks).
pub fn is_candidate(name: &str) -> bool {
    let name = normalize_name(name);
    agent_for_name(name).is_some() || INTERPRETERS.contains(&name)
}

/// The agent a script runtime is running, from the script argument. Arguments
/// after the script belong to the script and never count.
fn interpreted_agent(arguments: &[String]) -> Option<&'static str> {
    let mut i = 0;
    while let Some(arg) = arguments.get(i) {
        if arg == "-m" {
            if let Some(module) = arguments.get(i + 1) {
                return agent_for_name(module);
            }
        }
        if arg.starts_with('-') {
            i += 1;
            continue;
        }
        if let Some(agent) = agent_for_name(&script_base(arg)) {
            return Some(agent);
        }
        let path = arg.replace('\\', "/");
        return PACKAGE_MARKERS.iter().find(|(m, _)| path.contains(m)).map(|(_, a)| *a);
    }
    None
}

/// Display name of the agent this process belongs to, or None.
pub fn agent_name(process: &RunningProcess) -> Option<&'static str> {
    let name = normalize_name(&process.name);
    let direct = agent_for_name(name);
    let interpreted =
        if direct.is_none() && INTERPRETERS.contains(&name) { interpreted_agent(&process.arguments) } else { None };
    let agent = direct.or(interpreted)?;
    // For interpreters, look at the script's own arguments only.
    let args: Vec<&String> = if interpreted.is_none() {
        process.arguments.iter().collect()
    } else {
        process.arguments.iter().skip_while(|a| a.starts_with('-')).skip(1).collect()
    };
    let idle_helper = args.iter().any(|a| IDLE_HELPER_MARKERS.iter().any(|m| a.contains(m)));
    let supervisor = args.first().is_some_and(|a| SUPERVISOR_SUBCOMMANDS.contains(&a.as_str()));
    if idle_helper || supervisor {
        None
    } else {
        Some(agent)
    }
}

/// Running agents by display name, with a process count each.
pub fn running_agents(processes: &[RunningProcess]) -> BTreeMap<String, usize> {
    let mut counts = BTreeMap::new();
    for p in processes {
        if let Some(a) = agent_name(p) {
            let c: &mut usize = counts.entry(a.to_string()).or_default();
            *c = c.saturating_add(1);
        }
    }
    counts
}

/// What `awake --agents` does each tick: hold while any agent runs, and for
/// `grace` seconds after the last one exits. Port of the `whileAgentsRun`
/// branch of `KeepAwakeEngine`.
#[derive(Debug, Clone)]
pub struct AgentsWatch {
    grace: f64,
    last_seen: Option<f64>,
    previous: BTreeSet<String>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct Tick {
    pub hold: bool,
    /// Agents that were running on the previous tick and no longer are.
    pub finished: Vec<String>,
    /// The grace period just ran out with no agents.
    pub idle: bool,
}

impl AgentsWatch {
    pub fn new(grace_seconds: f64) -> Self {
        let grace = if grace_seconds.is_finite() { grace_seconds.max(0.0) } else { 0.0 };
        AgentsWatch { grace, last_seen: None, previous: BTreeSet::new() }
    }

    /// `now` is seconds on any monotonic clock.
    pub fn tick(&mut self, now: f64, agents: &BTreeSet<String>) -> Tick {
        let finished: Vec<String> = self.previous.difference(agents).cloned().collect();
        self.previous = agents.clone();
        if !agents.is_empty() {
            self.last_seen = Some(now);
            return Tick { hold: true, finished, idle: false };
        }
        match self.last_seen {
            Some(seen) if now - seen < self.grace => Tick { hold: true, finished, idle: false },
            Some(_) => {
                self.last_seen = None;
                Tick { hold: false, finished, idle: true }
            }
            None => Tick { hold: false, finished, idle: false },
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn agent(name: &str, args: &[&str]) -> Option<&'static str> {
        agent_name(&RunningProcess::new(5, name, args))
    }

    fn counts(pairs: &[(&str, usize)]) -> BTreeMap<String, usize> {
        pairs.iter().map(|(k, v)| (k.to_string(), *v)).collect()
    }

    #[test]
    fn ignores_claude_spare_helpers() {
        let procs = vec![
            RunningProcess::new(1, "claude", &["bg-spare", "--bg-spare", "/tmp/cc-daemon-502/x/spare/a.claim.sock"]),
            RunningProcess::new(
                2,
                "claude",
                &["bg-pty-host", "--bg-pty-host", "/tmp/cc-daemon-502/x/spare/a.pty.sock"],
            ),
        ];
        assert_eq!(running_agents(&procs), counts(&[]));
        assert_eq!(agent("claude", &["daemon", "run", "--origin", "transient"]), None);
        assert!(agent("claude", &["--session-id", "x"]).is_some());
        let mut more = procs.clone();
        more.push(RunningProcess::new(3, "claude", &[]));
        assert_eq!(running_agents(&more), counts(&[("Claude Code", 1)]));
    }

    #[test]
    fn background_session_pty_host_counts_once() {
        let procs = vec![
            RunningProcess::new(
                10,
                "claude",
                &["--bg-pty-host", "/tmp/cc-daemon-502/x/pty/s.sock", "--", "/opt/claude"],
            ),
            RunningProcess::new(11, "claude", &["--session-id", "s", "--agent", "claude"]),
            RunningProcess::new(12, "claude", &[]),
            RunningProcess::new(13, "codex", &[]),
        ];
        assert_eq!(running_agents(&procs), counts(&[("Claude Code", 2), ("Codex", 1)]));
    }

    #[test]
    fn agents_run_through_node_or_python() {
        assert_eq!(agent("node", &["/opt/homebrew/bin/gemini"]), Some("Gemini CLI"));
        assert_eq!(
            agent("node", &["--no-warnings", "/usr/local/lib/node_modules/@google/gemini-cli/dist/index.js"]),
            Some("Gemini CLI")
        );
        assert_eq!(
            agent("node", &["/Users/me/.npm-global/lib/node_modules/@qwen-code/qwen-code/cli.js"]),
            Some("Qwen Code")
        );
        assert_eq!(agent("node", &["/opt/homebrew/lib/node_modules/@sourcegraph/amp/dist/main.js"]), Some("Amp"));
        assert_eq!(agent("node", &["/Users/me/.local/bin/cursor-agent"]), Some("Cursor Agent"));
        assert_eq!(
            agent("node", &["/usr/local/lib/node_modules/@anthropic-ai/claude-code/cli.js"]),
            Some("Claude Code")
        );
        assert_eq!(agent("python3", &["/Users/me/.local/bin/aider", "--model", "x"]), Some("Aider"));
        assert_eq!(agent("Python", &["-m", "aider"]), Some("Aider"));
        assert_eq!(agent("bun", &["/Users/me/.bun/bin/opencode"]), Some("OpenCode"));
    }

    #[test]
    fn other_scripts_are_not_agents() {
        assert_eq!(agent("node", &["server.js", "--name", "gemini"]), None, "only the script decides");
        assert_eq!(agent("node", &["/app/node_modules/.bin/vite"]), None);
        assert_eq!(agent("python3", &["-m", "http.server"]), None);
        assert_eq!(agent("node", &[]), None);
        assert_eq!(agent("python3", &["-m"]), None);
        assert_eq!(agent("Cursor", &[]), None, "the Cursor editor is not an agent session");
        assert_eq!(agent("cursor", &[]), None);
        assert_eq!(
            agent("node", &["/usr/local/lib/node_modules/@anthropic-ai/claude-code/cli.js", "--bg-spare"]),
            None
        );
        assert_eq!(agent("bash", &["-c", "claude"]), None, "a shell mentioning claude isn't claude");
    }

    #[test]
    fn candidate_includes_runtimes() {
        assert!(is_candidate("node"));
        assert!(is_candidate("claude"));
        assert!(is_candidate("node.exe"));
        assert!(!is_candidate("Finder"));
    }

    #[test]
    fn windows_names_and_paths() {
        assert_eq!(agent("claude.exe", &[]), Some("Claude Code"));
        assert_eq!(agent("CODEX.EXE", &[]), Some("Codex"));
        assert_eq!(
            agent(
                "node.exe",
                &["C:\\Users\\me\\AppData\\Roaming\\npm\\node_modules\\@google\\gemini-cli\\dist\\index.js"]
            ),
            Some("Gemini CLI")
        );
        assert_eq!(
            agent(
                "node.exe",
                &["C:\\Users\\me\\AppData\\Roaming\\npm\\node_modules\\@anthropic-ai\\claude-code\\cli.js"]
            ),
            Some("Claude Code")
        );
        assert_eq!(agent("python.exe", &["C:\\Users\\me\\.local\\bin\\aider.exe"]), Some("Aider"));
        assert_eq!(agent("Cursor.exe", &[]), None);
        assert_eq!(normalize_name(".exe"), "");
        assert_eq!(normalize_name("exe"), "exe");
        assert_eq!(normalize_name("é.EXE"), "é");
    }

    #[test]
    fn while_agents_run_with_grace_and_finish_events() {
        let set = |v: &[&str]| v.iter().map(|s| s.to_string()).collect::<BTreeSet<_>>();
        let mut w = AgentsWatch::new(120.0);
        assert!(!w.tick(0.0, &set(&[])).hold, "no agent yet: don't hold");
        assert!(w.tick(1.0, &set(&["Claude Code"])).hold);
        let finished = w.tick(2.0, &set(&[]));
        assert!(finished.hold, "inside grace");
        assert_eq!(finished.finished, vec!["Claude Code".to_string()]);
        let idle = w.tick(200.0, &set(&[]));
        assert!(!idle.hold);
        assert!(idle.idle);
        assert!(w.tick(300.0, &set(&["Codex"])).hold, "stays armed for the next agent");

        let mut neg = AgentsWatch::new(-5.0);
        neg.tick(0.0, &set(&["Codex"]));
        assert!(!neg.tick(1.0, &set(&[])).hold, "negative grace is zero");
        let mut nan = AgentsWatch::new(f64::NAN);
        nan.tick(0.0, &set(&["Codex"]));
        assert!(!nan.tick(1.0, &set(&[])).hold);
    }
}
