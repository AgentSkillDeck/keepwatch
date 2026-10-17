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

/// `run` ignores Ctrl-C (the child gets it) but must still die on SIGTERM,
/// like the macOS CLI, so `kill` never leaves it holding the machine awake.
#[cfg(target_os = "linux")]
#[test]
fn run_stops_on_sigterm() {
    let dir = temp_dir("sigterm");
    let mut kw = keepwatch()
        .env("KEEPWATCH_TEST_SYSTEMD_INHIBIT", fake_inhibit(&dir))
        .args(["run", "--", "sleep", "30"])
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .unwrap();
    std::thread::sleep(Duration::from_millis(800));
    let killed = Command::new("kill").args(["-TERM", &kw.id().to_string()]).status().unwrap();
    assert!(killed.success());
    wait_for("run to exit on SIGTERM", Duration::from_secs(5), || matches!(kw.try_wait(), Ok(Some(_))));
    let _ = std::fs::remove_dir_all(&dir);
}

// MARK: - lid sessions (Linux)

/// A sandbox for lid tests: stand-in `systemd-inhibit` and `systemctl` that
/// record their arguments, a stand-in lid, battery and thermal zone, and
/// session time sped up. The real logind is never touched.
#[cfg(target_os = "linux")]
struct LidLab {
    dir: PathBuf,
}

#[cfg(target_os = "linux")]
impl LidLab {
    fn new(tag: &str) -> LidLab {
        use std::os::unix::fs::PermissionsExt;
        let dir = temp_dir(tag);
        std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o700)).unwrap();
        let exe = |name: &str, body: &str| {
            let p = dir.join(name);
            std::fs::write(&p, format!("#!/bin/sh\n{body}")).unwrap();
            std::fs::set_permissions(&p, std::fs::Permissions::from_mode(0o755)).unwrap();
        };
        exe(
            "systemd-inhibit",
            "case \"$1\" in --list) exit 1;; esac\n\
             echo \"$@\" >> \"$KW_TEST_DIR/inhibit-args\"\n\
             echo $$ > \"$KW_TEST_DIR/inhibit-pid\"\n\
             while [ $# -gt 0 ]; do case \"$1\" in --*) shift;; *) break;; esac; done\nexec \"$@\"\n",
        );
        exe("systemctl", "echo \"$@\" >> \"$KW_TEST_DIR/systemctl-args\"\n");
        exe("refusing-inhibit", "echo 'Failed to inhibit: Access denied' >&2\nexit 1\n");
        let lab = LidLab { dir };
        lab.set_lid(true);
        lab.set_power(false, 80);
        lab.set_temp(40_000);
        lab
    }

    fn set_lid(&self, closed: bool) {
        let state = if closed { "closed" } else { "open" };
        std::fs::write(self.dir.join("lid"), format!("state:      {state}\n")).unwrap();
    }

    fn set_power(&self, on_battery: bool, percent: u32) {
        let ps = self.dir.join("ps");
        for (name, files) in [
            ("AC", vec![("type", "Mains".to_string()), ("online", if on_battery { "0" } else { "1" }.into())]),
            (
                "BAT0",
                vec![
                    ("type", "Battery".to_string()),
                    ("status", if on_battery { "Discharging" } else { "Charging" }.into()),
                    ("capacity", percent.to_string()),
                ],
            ),
        ] {
            std::fs::create_dir_all(ps.join(name)).unwrap();
            for (k, v) in files {
                std::fs::write(ps.join(name).join(k), format!("{v}\n")).unwrap();
            }
        }
    }

    fn set_temp(&self, millic: i64) {
        let zone = self.dir.join("thermal").join("thermal_zone0");
        std::fs::create_dir_all(&zone).unwrap();
        std::fs::write(zone.join("temp"), format!("{millic}\n")).unwrap();
    }

    /// `keepwatch` with the sandbox; `scale` session seconds per real second.
    fn cmd(&self, scale: u32) -> Command {
        let mut c = keepwatch();
        let d = &self.dir;
        c.env("KW_TEST_DIR", d)
            .env("XDG_RUNTIME_DIR", d)
            .env("XDG_STATE_HOME", d.join("state"))
            .env("KEEPWATCH_TEST_SYSTEMD_INHIBIT", d.join("systemd-inhibit"))
            .env("KEEPWATCH_TEST_SYSTEMCTL", d.join("systemctl"))
            .env("KEEPWATCH_TEST_BUSCTL", d.join("no-busctl"))
            .env("KEEPWATCH_TEST_POWERPROFILESCTL", d.join("no-powerprofilesctl"))
            .env("KEEPWATCH_TEST_LID_STATE", d.join("lid"))
            .env("KEEPWATCH_TEST_POWER_SUPPLY", d.join("ps"))
            .env("KEEPWATCH_TEST_THERMAL", d.join("thermal"))
            .env("KEEPWATCH_TEST_TIME_SCALE", scale.to_string())
            .env("KEEPWATCH_TEST_LID_TICK_MS", "100")
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped());
        c
    }

    fn read(&self, name: &str) -> String {
        std::fs::read_to_string(self.dir.join(name)).unwrap_or_default()
    }

    fn log(&self) -> String {
        std::fs::read_to_string(self.dir.join("state/keepwatch/lid.log")).unwrap_or_default()
    }

    fn lock(&self) -> PathBuf {
        self.dir.join("keepwatch").join("lid.pid")
    }
}

#[cfg(target_os = "linux")]
impl Drop for LidLab {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.dir);
    }
}

#[cfg(target_os = "linux")]
fn finish(mut child: std::process::Child, timeout: Duration) -> Output {
    wait_for("the lid session to end", timeout, || matches!(child.try_wait(), Ok(Some(_))));
    child.wait_with_output().unwrap()
}

#[cfg(target_os = "linux")]
fn text(b: &[u8]) -> String {
    String::from_utf8_lossy(b).into_owned()
}

/// Closed lid, plugged in: after --hours (0.5 h, sped up 3600x) the session
/// releases the inhibitor, logs why, and asks to suspend.
#[cfg(target_os = "linux")]
#[test]
fn lid_session_sleeps_after_the_lid_closes() {
    use std::os::unix::fs::PermissionsExt;
    let lab = LidLab::new("lid-timer");
    let child = lab.cmd(3600).args(["lid", "start", "--hours", "0.5"]).spawn().unwrap();
    let out = finish(child, Duration::from_secs(20));
    let stdout = text(&out.stdout);
    assert_eq!(out.status.code(), Some(0), "{stdout}{}", text(&out.stderr));
    assert!(stdout.contains("Lid session ended: the lid was closed for the time you chose"), "{stdout}");
    assert!(stdout.contains("asked it to suspend"), "{stdout}");
    assert!(lab.read("inhibit-args").contains("--what=handle-lid-switch:sleep:idle --who=keepwatch"));
    assert!(lab.read("inhibit-args").contains("--mode=block"));
    assert_eq!(lab.read("systemctl-args").trim(), "suspend");
    let log = lab.log();
    assert!(log.contains(" started pid ") && log.contains(" ended lid-closed-limit: "), "{log}");
    let mode = std::fs::metadata(lab.dir.join("state/keepwatch/lid.log")).unwrap().permissions().mode();
    assert_eq!(mode & 0o777, 0o600);
    assert!(!lab.lock().exists(), "lock removed");
}

/// Lid open: the timer never runs. `lid status`, `status --json` see the
/// session; `lid end` ends it, and with the lid open nothing is suspended.
#[cfg(target_os = "linux")]
#[test]
fn lid_end_stops_a_running_session_and_status_shows_it() {
    let lab = LidLab::new("lid-end");
    lab.set_lid(false);
    let child = lab.cmd(60).args(["lid", "start", "--hours", "0.5", "--until-agents-done"]).spawn().unwrap();
    wait_for("the lid lock", Duration::from_secs(10), || lab.lock().exists());
    let status = lab.cmd(1).args(["lid", "status", "--json"]).output().unwrap();
    let v: serde_json::Value = serde_json::from_slice(&status.stdout).unwrap();
    assert_eq!(v["active"], true, "{v}");
    assert_eq!(v["owner"], "cli");
    assert_eq!(v["afterLidClosedMinutes"], 30);
    assert_eq!(v["untilAgentsDone"], true);
    assert_eq!(v["minBatteryPercent"], 20);
    let all = lab.cmd(1).args(["status", "--json"]).output().unwrap();
    let all: serde_json::Value = serde_json::from_slice(&all.stdout).unwrap();
    assert_eq!(all["lidSession"]["active"], true);
    assert_eq!(all["sleep"]["sleepDisabled"], true);
    assert_eq!(all["sleep"]["keepwatchHolding"], true);
    assert_eq!(all["power"]["lidClosed"], false);

    let end = lab.cmd(1).args(["lid", "end"]).output().unwrap();
    assert_eq!(end.status.code(), Some(0), "{}", text(&end.stderr));
    assert!(text(&end.stdout).contains("Ended the lid session"));
    let out = finish(child, Duration::from_secs(10));
    let stdout = text(&out.stdout);
    assert!(stdout.contains("Lid session ended: you ended it. The lid is open"), "{stdout}");
    assert_eq!(lab.read("systemctl-args"), "", "lid open: no suspend");
    assert!(lab.log().contains(" ended stop-requested: "));
    let after = lab.cmd(1).args(["lid", "status", "--json"]).output().unwrap();
    let after: serde_json::Value = serde_json::from_slice(&after.stdout).unwrap();
    assert_eq!(after["active"], false);
    assert_eq!(after["lastEndReason"], "stop-requested");
    let again = lab.cmd(1).args(["lid", "end"]).output().unwrap();
    assert!(text(&again.stdout).contains("No lid session is running"));
}

#[cfg(target_os = "linux")]
#[test]
fn lid_start_refuses_unsafe_starts() {
    let lab = LidLab::new("lid-refuse");
    let start = |args: &[&str]| -> Output { lab.cmd(1).args(["lid", "start"]).args(args).output().unwrap() };
    lab.set_power(true, 20);
    let low = start(&[]);
    assert_eq!(low.status.code(), Some(2));
    assert!(text(&low.stderr).contains("20%"), "{}", text(&low.stderr));
    lab.set_power(true, 90);
    let no_battery = start(&["--no-battery"]);
    assert_eq!(no_battery.status.code(), Some(2));
    assert!(text(&no_battery.stderr).contains("plug it in"));
    lab.set_power(false, 90);
    lab.set_temp(96_000);
    let hot = start(&[]);
    assert_eq!(hot.status.code(), Some(2));
    assert!(text(&hot.stderr).contains("hot"));
    lab.set_temp(40_000);
    std::fs::write(lab.dir.join("lid"), "state: ajar\n").unwrap();
    let unknown = start(&[]);
    assert_eq!(unknown.status.code(), Some(2));
    assert!(text(&unknown.stderr).contains("can't read whether the lid"));
    assert_eq!(lab.read("inhibit-args"), "", "nothing was held");
    lab.set_lid(true);
    let refused = lab
        .cmd(1)
        .env("KEEPWATCH_TEST_SYSTEMD_INHIBIT", lab.dir.join("refusing-inhibit"))
        .args(["lid", "start"])
        .output()
        .unwrap();
    assert_eq!(refused.status.code(), Some(2));
    assert!(text(&refused.stderr).contains("polkit"), "{}", text(&refused.stderr));
    for bad in [&["--hours", "0.1"][..], &["--hours", "13"], &["--at", "25:00"], &["--bogus"]] {
        assert_eq!(start(bad).status.code(), Some(1), "{bad:?}");
    }
    assert_eq!(lab.read("systemctl-args"), "");
}

/// Rules that end a running session: too hot, unplugged with --no-battery,
/// battery at the floor. Each releases and logs its reason.
#[cfg(target_os = "linux")]
#[test]
fn lid_rules_end_a_running_session() {
    let lab = LidLab::new("lid-rules");
    lab.set_lid(false);
    // (lid start arguments, what changes while it runs, what it says, the log code)
    type Case<'a> = (&'a [&'a str], &'a dyn Fn(&LidLab), &'a str, &'a str);
    let cases: [Case; 3] = [
        (&[], &|l| l.set_temp(97_000), "running hot (97 °C)", "thermal"),
        (&["--no-battery"], &|l| l.set_power(true, 90), "the power adapter was unplugged", "on-battery"),
        (&[], &|l| l.set_power(true, 20), "the battery is at 20%", "low-battery"),
    ];
    for (args, change, said, code) in cases {
        lab.set_temp(40_000);
        lab.set_power(false, 90);
        let child = lab.cmd(1).args(["lid", "start"]).args(args).spawn().unwrap();
        wait_for("the lid lock", Duration::from_secs(10), || lab.lock().exists());
        change(&lab);
        let out = finish(child, Duration::from_secs(10));
        assert_eq!(out.status.code(), Some(0));
        assert!(text(&out.stdout).contains(said), "{}", text(&out.stdout));
        assert!(lab.log().contains(&format!(" ended {code}: ")), "{}", lab.log());
        assert!(!lab.lock().exists());
    }
}

/// The 12-hour cap holds even with no other rule (sped up 7200x: 6 s).
#[cfg(target_os = "linux")]
#[test]
fn lid_hard_cap_ends_the_session() {
    let lab = LidLab::new("lid-cap");
    lab.set_lid(false);
    let child = lab.cmd(7200).args(["lid", "start", "--hours", "12"]).spawn().unwrap();
    let out = finish(child, Duration::from_secs(30));
    assert!(text(&out.stdout).contains("the 12-hour limit was reached"), "{}", text(&out.stdout));
    assert!(lab.log().contains(" ended hard-cap: "));
}

/// SIGKILL: keepwatch can't clean up, but the inhibitor child still goes
/// (its stdin closes), so the laptop sleeps normally. The main safety guarantee.
#[cfg(target_os = "linux")]
#[test]
fn sigkill_releases_the_lid_inhibitor() {
    let lab = LidLab::new("lid-kill");
    let mut child = lab.cmd(1).args(["lid", "start"]).spawn().unwrap();
    wait_for("the lid lock", Duration::from_secs(10), || lab.lock().exists());
    let holder: u32 = lab.read("inhibit-pid").trim().parse().unwrap();
    let running = |pid: u32| {
        std::fs::read_to_string(format!("/proc/{pid}/stat"))
            .ok()
            .and_then(|s| s.rsplit_once(") ").map(|(_, rest)| !rest.starts_with('Z')))
            .unwrap_or(false)
    };
    assert!(running(holder), "the inhibitor is held");
    child.kill().unwrap();
    let _ = child.wait();
    wait_for("the inhibitor to go", Duration::from_secs(5), || !running(holder));
    // The stale lock is ignored and cleaned up.
    let status = lab.cmd(1).args(["lid", "status", "--json"]).output().unwrap();
    let v: serde_json::Value = serde_json::from_slice(&status.stdout).unwrap();
    assert_eq!(v["active"], false);
    assert!(!lab.lock().exists());
}

/// The log never writes through a symlink, and is cut to its newer half past 1 MB.
#[cfg(target_os = "linux")]
#[test]
fn lid_log_is_capped_and_never_follows_links() {
    let lab = LidLab::new("lid-log");
    let logdir = lab.dir.join("state/keepwatch");
    std::fs::create_dir_all(&logdir).unwrap();
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&logdir, std::fs::Permissions::from_mode(0o700)).unwrap();
    }
    let victim = lab.dir.join("victim");
    std::fs::write(&victim, "precious\n").unwrap();
    std::os::unix::fs::symlink(&victim, logdir.join("lid.log")).unwrap();
    let out = finish(lab.cmd(3600).args(["lid", "start", "--hours", "0.5"]).spawn().unwrap(), Duration::from_secs(20));
    assert_eq!(out.status.code(), Some(0), "a log failure doesn't stop the session");
    assert_eq!(std::fs::read_to_string(&victim).unwrap(), "precious\n");

    std::fs::remove_file(logdir.join("lid.log")).unwrap();
    let old_line = "2026-01-01T00:00:00+00:00 old entry ".to_string() + &"x".repeat(80) + "\n";
    std::fs::write(logdir.join("lid.log"), old_line.repeat(1_048_576 / old_line.len() + 100)).unwrap();
    let out = finish(lab.cmd(3600).args(["lid", "start", "--hours", "0.5"]).spawn().unwrap(), Duration::from_secs(20));
    assert_eq!(out.status.code(), Some(0));
    let log = lab.log();
    assert!(log.len() < 700_000, "rotated: {}", log.len());
    assert!(log.starts_with("2026-01-01T00:00:00+00:00 old entry"), "cut at a line");
    assert!(log.contains(" ended lid-closed-limit: "));
}

/// Release builds ignore every KEEPWATCH_TEST_* stand-in. Run with
/// `cargo test --release --test cli release_`.
#[cfg(all(target_os = "linux", not(debug_assertions)))]
#[test]
fn release_builds_ignore_test_overrides() {
    let lab = LidLab::new("lid-release");
    let mut child = lab.cmd(3600).args(["lid", "start", "--hours", "0.5"]).spawn().unwrap();
    // Without a real lid (containers) it can't start. On a machine with logind
    // (a CI runner, a laptop) it may hold for real, unscaled: end it.
    let start = Instant::now();
    while start.elapsed() < Duration::from_secs(5) && matches!(child.try_wait(), Ok(None)) {
        std::thread::sleep(Duration::from_millis(100));
    }
    if matches!(child.try_wait(), Ok(None)) {
        let end = lab.cmd(1).args(["lid", "end"]).output().unwrap();
        assert_eq!(end.status.code(), Some(0));
        let _ = finish(child, Duration::from_secs(15));
    }
    assert_eq!(lab.read("inhibit-args"), "", "the stand-in systemd-inhibit was not used");
    assert_eq!(lab.read("systemctl-args"), "", "the stand-in systemctl was not used");
    // The stand-in lid says "closed"; release builds report the real lid instead.
    let lid = |cmd: &mut Command| -> serde_json::Value {
        let out = cmd.args(["status", "--json"]).output().unwrap();
        serde_json::from_slice::<serde_json::Value>(&out.stdout).unwrap()["power"]["lidClosed"].clone()
    };
    lab.set_lid(true);
    assert_eq!(lid(&mut lab.cmd(1)), lid(&mut keepwatch()), "the stand-in lid was not read");
    lab.set_lid(false);
    assert_eq!(lid(&mut lab.cmd(1)), lid(&mut keepwatch()));
}

#[cfg(windows)]
#[test]
fn lid_is_not_available_on_windows() {
    for args in [&["lid", "start"][..], &["lid", "end"], &["lid", "status"]] {
        let out = keepwatch().args(args).output().unwrap();
        assert_eq!(out.status.code(), Some(1));
        assert!(String::from_utf8_lossy(&out.stderr).contains("not available on Windows yet"));
    }
}
