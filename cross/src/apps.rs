//! Your own apps by memory use, read-only. Processes are grouped by
//! executable name; memory is resident memory (RSS / working set).

use crate::procs::Proc;
use serde::Serialize;
use std::collections::BTreeMap;

/// One row of `keepwatch apps --json` (same fields as the Swift CLI).
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct AppRow {
    pub name: String,
    pub path: String,
    pub bytes: u64,
    pub processes: usize,
    pub system: bool,
}

/// Group `procs` (own processes, excluding keepwatch itself) by name,
/// biggest first, at most `limit` rows.
pub fn group(procs: &[Proc], me: u32, limit: usize, windows: bool) -> Vec<AppRow> {
    let mut by_name: BTreeMap<String, (AppRow, u64)> = BTreeMap::new();
    for p in procs.iter().filter(|p| p.own && p.pid != me && p.memory > 0 && !p.name.is_empty()) {
        let entry = by_name.entry(p.name.clone()).or_insert_with(|| {
            (AppRow { name: p.name.clone(), path: String::new(), bytes: 0, processes: 0, system: true }, 0)
        });
        let (row, biggest) = entry;
        row.bytes = row.bytes.saturating_add(p.memory);
        row.processes = row.processes.saturating_add(1);
        // The path (and system flag) of the biggest process stands for the app.
        if p.memory > *biggest {
            *biggest = p.memory;
            row.path = p.exe.clone().unwrap_or_default();
            row.system = crate::ports::is_system_path(p.exe.as_deref(), windows);
        }
    }
    let mut rows: Vec<AppRow> = by_name.into_values().map(|(r, _)| r).collect();
    rows.sort_by(|a, b| b.bytes.cmp(&a.bytes).then_with(|| a.name.cmp(&b.name)));
    rows.truncate(limit);
    rows
}

#[cfg(test)]
mod tests {
    use super::*;

    fn p(pid: u32, name: &str, exe: Option<&str>, memory: u64, own: bool) -> Proc {
        Proc {
            pid,
            name: name.into(),
            arguments: vec![],
            exe: exe.map(String::from),
            cwd: None,
            started: None,
            own,
            memory,
            cpu_ms: 0,
        }
    }

    #[test]
    fn groups_and_sorts() {
        let procs = vec![
            p(10, "chrome", Some("/opt/google/chrome/chrome"), 300, true),
            p(11, "chrome", Some("/opt/google/chrome/chrome"), 500, true),
            p(12, "node", Some("/usr/bin/node"), 900, true),
            p(13, "sshd", Some("/usr/sbin/sshd"), 5_000, false),
            p(14, "keepwatch", Some("/x/keepwatch"), 50, true),
            p(15, "zombie", None, 0, true),
            p(16, "mystery", None, 1, true),
        ];
        let rows = group(&procs, 14, 15, false);
        assert_eq!(
            rows,
            vec![
                AppRow { name: "node".into(), path: "/usr/bin/node".into(), bytes: 900, processes: 1, system: false },
                AppRow {
                    name: "chrome".into(),
                    path: "/opt/google/chrome/chrome".into(),
                    bytes: 800,
                    processes: 2,
                    system: false
                },
                AppRow { name: "mystery".into(), path: String::new(), bytes: 1, processes: 1, system: true },
            ]
        );
        assert_eq!(group(&procs, 14, 1, false).len(), 1);
        assert_eq!(group(&[], 1, 15, false), vec![]);
    }
}
