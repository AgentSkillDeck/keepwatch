//! "What's on :3000?": TCP ports the user's own processes listen on.
//! Linux: `/proc/net/tcp{,6}` LISTEN sockets mapped to pids through
//! `/proc/<pid>/fd` socket links. Windows: `netstat -ano`.
// The pure Linux parsers are compiled (and tested) everywhere, used live on Linux only.
#![cfg_attr(not(target_os = "linux"), allow(dead_code))]

use serde::Serialize;
use std::collections::{BTreeSet, HashMap};

/// One row of `keepwatch ports --json` (same fields as the Swift CLI).
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct PortRow {
    pub port: u16,
    pub address: String,
    pub pid: u32,
    pub process: String,
    /// Unknown executable, or part of the OS: agents must not stop these.
    pub system: bool,
}

/// A listening socket from `/proc/net/tcp`: (address, port, inode).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Listener {
    pub address: String,
    pub port: u16,
    pub inode: u64,
}

const TCP_LISTEN: &str = "0A";
/// Lines of /proc/net/tcp we look at, and fds per process we follow.
const MAX_LINES: usize = 65_536;
#[cfg_attr(not(target_os = "linux"), allow(dead_code))]
const MAX_FDS_PER_PROCESS: usize = 4_096;

/// Parse `/proc/net/tcp` or `/proc/net/tcp6` text; LISTEN rows only.
pub fn parse_proc_net_tcp(text: &str) -> Vec<Listener> {
    let mut out = Vec::new();
    for line in text.lines().skip(1).take(MAX_LINES) {
        let cols: Vec<&str> = line.split_whitespace().collect();
        let (Some(local), Some(state), Some(inode)) = (cols.get(1), cols.get(3), cols.get(9)) else {
            continue;
        };
        if *state != TCP_LISTEN {
            continue;
        }
        let Some((addr_hex, port_hex)) = local.split_once(':') else {
            continue;
        };
        let (Ok(port), Ok(inode)) = (u16::from_str_radix(port_hex, 16), inode.parse::<u64>()) else {
            continue;
        };
        if port == 0 || inode == 0 {
            continue;
        }
        let Some(address) = decode_address(addr_hex) else {
            continue;
        };
        out.push(Listener { address, port, inode });
    }
    out
}

/// Kernel hex address -> lsof-style text: "*" for any, "127.0.0.1", "[::1]".
/// Each 32-bit word is in host byte order (little-endian on every Linux we ship for).
fn decode_address(hex: &str) -> Option<String> {
    let words: Vec<u32> = (0..hex.len() / 8)
        .map(|i| hex.get(i * 8..i * 8 + 8).and_then(|w| u32::from_str_radix(w, 16).ok()))
        .collect::<Option<_>>()?;
    match (hex.len(), words.as_slice()) {
        (8, [w]) => {
            let ip = std::net::Ipv4Addr::from(w.to_le_bytes());
            Some(if ip.is_unspecified() { "*".into() } else { ip.to_string() })
        }
        (32, [a, b, c, d]) => {
            let mut bytes = [0u8; 16];
            for (chunk, w) in bytes.as_chunks_mut::<4>().0.iter_mut().zip([a, b, c, d]) {
                chunk.copy_from_slice(&w.to_le_bytes());
            }
            let ip = std::net::Ipv6Addr::from(bytes);
            Some(if ip.is_unspecified() { "*".into() } else { format!("[{ip}]") })
        }
        _ => None,
    }
}

/// `socket:[12345]` -> 12345.
pub fn socket_inode(link: &str) -> Option<u64> {
    link.strip_prefix("socket:[")?.strip_suffix(']')?.parse().ok()
}

/// Parse `netstat -ano` output: TCP rows whose foreign address is the
/// wildcard (`0.0.0.0:0`, `[::]:0`) are listeners. The state column is
/// localized, so it isn't used. Returns (address, port, pid).
#[cfg_attr(not(windows), allow(dead_code))]
pub fn parse_netstat(text: &str) -> Vec<(String, u16, u32)> {
    let mut out = Vec::new();
    for line in text.lines().take(MAX_LINES) {
        let cols: Vec<&str> = line.split_whitespace().collect();
        let (Some(proto), Some(local), Some(foreign), Some(pid)) =
            (cols.first(), cols.get(1), cols.get(2), cols.last())
        else {
            continue;
        };
        if !proto.eq_ignore_ascii_case("TCP") || !matches!(*foreign, "0.0.0.0:0" | "[::]:0" | "*:*") {
            continue;
        }
        let Some((addr, port)) = local.rsplit_once(':') else {
            continue;
        };
        let (Ok(port), Ok(pid)) = (port.parse::<u16>(), pid.parse::<u32>()) else {
            continue;
        };
        if port == 0 || pid == 0 {
            continue;
        }
        let address = match addr {
            "0.0.0.0" | "[::]" => "*".to_string(),
            other => other.to_string(),
        };
        out.push((address, port, pid));
    }
    out
}

/// Whether an executable counts as part of the OS. Unknown counts as system:
/// when in doubt, don't offer Stop. On Linux the user's own processes in
/// `/usr/bin` (node, python) are ordinary tools, so only the path being unknown counts.
pub fn is_system_path(path: Option<&str>, windows: bool) -> bool {
    let Some(path) = path.filter(|p| !p.is_empty()) else {
        return true;
    };
    if windows {
        let lower = path.to_lowercase().replace('/', "\\");
        lower.starts_with("c:\\windows\\") || lower.starts_with("\\\\?\\c:\\windows\\")
    } else {
        false
    }
}

/// One row per (port, pid), sorted by port, pid, address: IPv4 and IPv6 collapse.
pub fn finish(mut rows: Vec<PortRow>) -> Vec<PortRow> {
    rows.sort_by(|a, b| (a.port, a.pid, &a.address).cmp(&(b.port, b.pid, &b.address)));
    let mut seen = BTreeSet::new();
    rows.retain(|r| seen.insert((r.port, r.pid)));
    rows
}

/// The current user's listening ports.
pub fn current() -> Vec<PortRow> {
    let procs: HashMap<u32, crate::procs::Proc> =
        crate::procs::snapshot().into_iter().filter(|p| p.own).map(|p| (p.pid, p)).collect();
    finish(live(&procs))
}

#[cfg(target_os = "linux")]
fn live(procs: &HashMap<u32, crate::procs::Proc>) -> Vec<PortRow> {
    use std::path::Path;
    let mut by_inode: HashMap<u64, Listener> = HashMap::new();
    for file in ["/proc/net/tcp", "/proc/net/tcp6"] {
        if let Some(text) = crate::util::read_capped(Path::new(file)) {
            for l in parse_proc_net_tcp(&text) {
                by_inode.insert(l.inode, l);
            }
        }
    }
    if by_inode.is_empty() {
        return Vec::new();
    }
    let mut rows = Vec::new();
    for (pid, p) in procs {
        let Ok(dir) = std::fs::read_dir(format!("/proc/{pid}/fd")) else {
            continue;
        };
        for entry in dir.flatten().take(MAX_FDS_PER_PROCESS) {
            let Ok(link) = std::fs::read_link(entry.path()) else {
                continue;
            };
            let Some(inode) = socket_inode(&link.to_string_lossy()) else {
                continue;
            };
            if let Some(l) = by_inode.get(&inode) {
                rows.push(PortRow {
                    port: l.port,
                    address: l.address.clone(),
                    pid: *pid,
                    process: p.name.clone(),
                    system: is_system_path(p.exe.as_deref(), false),
                });
            }
        }
    }
    rows
}

#[cfg(windows)]
fn live(procs: &HashMap<u32, crate::procs::Proc>) -> Vec<PortRow> {
    let Some(netstat) = crate::util::system_program("netstat") else { return Vec::new() };
    let Some(text) = crate::util::run_capture(&netstat, &["-ano", "-p", "TCP"], std::time::Duration::from_secs(5))
    else {
        return Vec::new();
    };
    let mut rows = Vec::new();
    // `-p TCP` lists IPv4 only; run again for IPv6.
    let v6 = crate::util::run_capture(&netstat, &["-ano", "-p", "TCPv6"], std::time::Duration::from_secs(5))
        .unwrap_or_default();
    for (address, port, pid) in parse_netstat(&text).into_iter().chain(parse_netstat(&v6)) {
        let Some(p) = procs.get(&pid) else { continue };
        rows.push(PortRow {
            port,
            address,
            pid,
            process: p.name.clone(),
            system: is_system_path(p.exe.as_deref(), true),
        });
    }
    rows
}

#[cfg(not(any(target_os = "linux", windows)))]
fn live(_procs: &HashMap<u32, crate::procs::Proc>) -> Vec<PortRow> {
    Vec::new()
}

#[cfg(test)]
mod tests {
    use super::*;

    const TCP: &str = "  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode
   0: 0100007F:0BB8 00000000:0000 0A 00000000:00000000 00:00000000 00000000  1000        0 41234 1 0000000000000000 100 0 0 10 0
   1: 00000000:1F90 00000000:0000 0A 00000000:00000000 00:00000000 00000000  1000        0 41235 1 0000000000000000 100 0 0 10 0
   2: 0100007F:0BB8 0100007F:D431 01 00000000:00000000 00:00000000 00000000  1000        0 41236 1 0000000000000000 100 0 0 10 0
   3: garbage
   4: 0100007F:ZZZZ 00000000:0000 0A 00000000:00000000 00:00000000 00000000  1000        0 41237 1
   5: 0100007F:0050 00000000:0000 0A 00000000:00000000 00:00000000 00000000  1000        0 0 1
";

    const TCP6: &str = "  sl  local_address                         remote_address                        st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode
   0: 00000000000000000000000001000000:1538 00000000000000000000000000000000:0000 0A 00000000:00000000 00:00000000 00000000  1000        0 5001 1 0000000000000000 100 0 0 10 0
   1: 00000000000000000000000000000000:0BB8 00000000000000000000000000000000:0000 0A 00000000:00000000 00:00000000 00000000  1000        0 5002 1 0000000000000000 100 0 0 10 0
   2: 0000000000000000FFFF00000100007F:0016 00000000000000000000000000000000:0000 0A 00000000:00000000 00:00000000 00000000  1000        0 5003 1 0000000000000000 100 0 0 10 0
";

    #[test]
    fn parses_proc_net_tcp() {
        assert_eq!(
            parse_proc_net_tcp(TCP),
            vec![
                Listener { address: "127.0.0.1".into(), port: 3000, inode: 41234 },
                Listener { address: "*".into(), port: 8080, inode: 41235 },
            ]
        );
        assert_eq!(parse_proc_net_tcp(""), vec![]);
        assert_eq!(parse_proc_net_tcp("header only\n"), vec![]);
    }

    #[test]
    fn parses_proc_net_tcp6() {
        let l = parse_proc_net_tcp(TCP6);
        assert_eq!(l.len(), 3);
        assert_eq!(l[0], Listener { address: "[::1]".into(), port: 5432, inode: 5001 });
        assert_eq!(l[1].address, "*");
        assert_eq!(l[2].address, "[::ffff:127.0.0.1]");
        assert_eq!(decode_address("0100007"), None);
        assert_eq!(decode_address("é1234567"), None);
    }

    #[test]
    fn socket_links() {
        assert_eq!(socket_inode("socket:[41234]"), Some(41234));
        assert_eq!(socket_inode("pipe:[41234]"), None);
        assert_eq!(socket_inode("socket:[x]"), None);
        assert_eq!(socket_inode("/dev/null"), None);
    }

    #[test]
    fn parses_netstat_regardless_of_language() {
        let out = "
Active Connections

  Proto  Local Address          Foreign Address        State           PID
  TCP    0.0.0.0:135            0.0.0.0:0              LISTENING       1184
  TCP    127.0.0.1:3000         0.0.0.0:0              ABHÖREN         4242
  TCP    127.0.0.1:3000         127.0.0.1:52000        ESTABLISHED     4242
  TCP    [::]:445               [::]:0                 LISTENING       4
  TCP    [::1]:5432             [::]:0                 LISTENING       777
  UDP    0.0.0.0:5353           *:*                                    999
  TCP    0.0.0.0:99999          0.0.0.0:0              LISTENING       1
  TCP    junk
";
        assert_eq!(
            parse_netstat(out),
            vec![
                ("*".into(), 135, 1184),
                ("127.0.0.1".into(), 3000, 4242),
                ("*".into(), 445, 4),
                ("[::1]".into(), 5432, 777)
            ]
        );
    }

    #[test]
    fn dedupes_by_port_and_pid() {
        let row = |port, address: &str, pid| PortRow {
            port,
            address: address.into(),
            pid,
            process: "node".into(),
            system: false,
        };
        assert_eq!(
            finish(vec![row(3000, "[::1]", 9), row(3000, "127.0.0.1", 9), row(80, "*", 9), row(3000, "*", 8)]),
            vec![row(80, "*", 9), row(3000, "*", 8), row(3000, "127.0.0.1", 9)]
        );
    }

    #[test]
    fn system_paths() {
        assert!(is_system_path(None, false));
        assert!(is_system_path(Some(""), true));
        assert!(!is_system_path(Some("/usr/bin/node"), false));
        assert!(is_system_path(Some("C:\\Windows\\System32\\svchost.exe"), true));
        assert!(is_system_path(Some("c:/windows/system32/svchost.exe"), true));
        assert!(!is_system_path(Some("C:\\Program Files\\nodejs\\node.exe"), true));
    }
}
