//! End-to-end checks of the built `keepwatch` binary.

use std::path::PathBuf;
use std::process::{Command, Output, Stdio};
use std::time::{Duration, Instant};

fn keepwatch() -> Command {
    Command::new(env!("CARGO_BIN_EXE_keepwatch"))
}

fn temp_dir(tag: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("kw-test-{tag}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

#[test]
fn version_and_usage_errors() {
    let out = keepwatch().arg("version").output().unwrap();
    assert_eq!(String::from_utf8_lossy(&out.stdout).trim(), "keepwatch 0.3.0");
    assert_eq!(out.status.code(), Some(0));
    let bad = keepwatch().args(["frobnicate"]).output().unwrap();
    assert_eq!(bad.status.code(), Some(1));
    assert!(String::from_utf8_lossy(&bad.stderr).contains("unknown command 'frobnicate'"));
    for args in [&["run"][..], &["run", "--"], &["awake", "--for", "3x"], &["status", "--yaml"]] {
        assert_eq!(keepwatch().args(args).output().unwrap().status.code(), Some(1), "{args:?}");
    }
    let mic = keepwatch().args(["mic", "mute"]).output().unwrap();
    assert_eq!(mic.status.code(), Some(1));
    assert!(String::from_utf8_lossy(&mic.stderr).contains("not available"));
}

#[test]
fn status_and_lists_are_json() {
    let out = keepwatch().args(["status", "--json"]).output().unwrap();
    assert_eq!(out.status.code(), Some(0));
    let v: serde_json::Value = serde_json::from_slice(&out.stdout).unwrap();
    assert_eq!(v["platform"], if cfg!(windows) { "windows" } else { "linux" });
    assert_eq!(v["appRunning"], false);
    assert!(v["power"].as_object().unwrap().contains_key("batteryPercent"));
    assert!(v["sleep"]["keepwatchHolding"].is_boolean());
    for cmd in ["agents", "ports", "apps"] {
        let out = keepwatch().args([cmd, "--json"]).output().unwrap();
        assert_eq!(out.status.code(), Some(0), "{cmd}");
        let v: serde_json::Value = serde_json::from_slice(&out.stdout).unwrap();
        assert!(v.is_array(), "{cmd}");
    }
    let out = keepwatch().args(["privacy", "--json"]).output().unwrap();
    let v: serde_json::Value = serde_json::from_slice(&out.stdout).unwrap();
    assert!(v["history"].is_array());
}

/// On Linux, a stand-in `systemd-inhibit` (Docker and CI may have no usable
/// logind): it takes the options and runs the command it is given, like the
/// real one. Debug builds take it from `KEEPWATCH_TEST_SYSTEMD_INHIBIT`.
#[cfg(target_os = "linux")]
fn fake_inhibit(dir: &std::path::Path) -> PathBuf {
    use std::os::unix::fs::PermissionsExt;
    let script = dir.join("systemd-inhibit");
    std::fs::write(
        &script,
        "#!/bin/sh\ncase \"$1\" in --list) exit 1;; esac\n\
         while [ $# -gt 0 ]; do case \"$1\" in --*) shift;; *) break;; esac; done\nexec \"$@\"\n",
    )
    .unwrap();
    std::fs::set_permissions(&script, std::fs::Permissions::from_mode(0o755)).unwrap();
    script
}

#[cfg(target_os = "linux")]
#[test]
fn run_passes_the_exit_status_through() {
    let dir = temp_dir("run");
    let fake = fake_inhibit(&dir);
    let run = |args: &[&str]| -> Output {
        keepwatch().env("KEEPWATCH_TEST_SYSTEMD_INHIBIT", &fake).arg("run").args(args).output().unwrap()
    };
    assert_eq!(run(&["--", "sh", "-c", "exit 3"]).status.code(), Some(3));
    assert_eq!(run(&["--", "true"]).status.code(), Some(0));
    assert_eq!(run(&["--", "false"]).status.code(), Some(1));
    assert_eq!(run(&["--display", "--", "sh", "-c", "kill -TERM $$"]).status.code(), Some(143));
    let echoed = run(&["--", "sh", "-c", "echo out; echo err >&2"]);
    assert_eq!(String::from_utf8_lossy(&echoed.stdout), "out\n");
    assert_eq!(String::from_utf8_lossy(&echoed.stderr), "err\n");
    assert_eq!(run(&["--", "keepwatch-no-such-command"]).status.code(), Some(127));
    let _ = std::fs::remove_dir_all(&dir);
}

/// Without the stand-in: on a real desktop this holds through logind; where
/// there is no systemd-inhibit or logind (containers), it must fail with 2
/// and say why, never run the command unprotected.
#[cfg(target_os = "linux")]
#[test]
fn run_with_the_real_systemd_inhibit_or_a_clear_error() {
    let out = keepwatch()
        .env_remove("KEEPWATCH_TEST_SYSTEMD_INHIBIT")
        .args(["run", "--", "sh", "-c", "exit 3"])
        .output()
        .unwrap();
    let stderr = String::from_utf8_lossy(&out.stderr);
    if out.status.code() == Some(2) {
        assert!(
            stderr.contains("systemd-inhibit isn't installed") || stderr.contains("couldn't keep this computer awake"),
            "{stderr}"
        );
        eprintln!("skipped: no working systemd-inhibit here ({})", stderr.trim());
    } else {
        assert_eq!(out.status.code(), Some(3), "{stderr}");
    }
}

#[cfg(windows)]
#[test]
fn run_passes_the_exit_status_through() {
    let run = |args: &[&str]| -> Output { keepwatch().arg("run").args(args).output().unwrap() };
    assert_eq!(run(&["--", "cmd", "/c", "exit 3"]).status.code(), Some(3));
    assert_eq!(run(&["--", "cmd", "/c", "exit 0"]).status.code(), Some(0));
    assert_eq!(run(&["--", "keepwatch-no-such-command"]).status.code(), Some(127));
}

fn wait_for(what: &str, timeout: Duration, mut done: impl FnMut() -> bool) {
    let start = Instant::now();
    while !done() {
        assert!(start.elapsed() < timeout, "timed out waiting for {what}");
        std::thread::sleep(Duration::from_millis(100));
    }
}

#[test]
fn awake_off_stops_a_running_awake() {
    let dir = temp_dir("awake");
    let mut cmd = keepwatch();
    #[cfg(target_os = "linux")]
    cmd.env("KEEPWATCH_TEST_SYSTEMD_INHIBIT", fake_inhibit(&dir)).env("XDG_RUNTIME_DIR", &dir);
    #[cfg(windows)]
    cmd.env("TEMP", &dir).env("TMP", &dir);
    let env: Vec<(std::ffi::OsString, std::ffi::OsString)> =
        cmd.get_envs().filter_map(|(k, v)| Some((k.to_os_string(), v?.to_os_string()))).collect();
    let mut awake = cmd.args(["awake", "--for", "1m"]).stdout(Stdio::piped()).stderr(Stdio::piped()).spawn().unwrap();
    let lock = dir.join("keepwatch").join("awake.pid");
    wait_for("the lock file", Duration::from_secs(10), || lock.exists());

    let off = keepwatch().envs(env.clone()).args(["awake", "--off"]).output().unwrap();
    assert_eq!(off.status.code(), Some(0), "{}", String::from_utf8_lossy(&off.stderr));
    assert!(String::from_utf8_lossy(&off.stdout).contains("Stopped 'keepwatch awake'"));
    wait_for("awake to exit", Duration::from_secs(10), || matches!(awake.try_wait(), Ok(Some(_))));
    assert!(!lock.exists(), "lock removed");

    let again = keepwatch().envs(env).args(["awake", "--off"]).output().unwrap();
    assert_eq!(again.status.code(), Some(0));
    assert!(String::from_utf8_lossy(&again.stdout).contains("Nothing to turn off"));
    let _ = std::fs::remove_dir_all(&dir);
}
