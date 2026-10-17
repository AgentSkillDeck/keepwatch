# keepwatch for Linux and Windows (beta)

A Rust port of the macOS `keepwatch` command. It has the same commands, JSON field names and exit codes, as far as each platform allows. `keepwatch awake` and `keepwatch lid start` hold the computer themselves, in the foreground. On Linux there is also a tray app, `keepwatch-tray`.

## What works

| Command | Linux | Windows |
|---|---|---|
| `run [--display] -- CMD…` | yes, through `systemd-inhibit` (idle and sleep) | yes, `SetThreadExecutionState` (`--display` keeps the screen on) |
| `awake --for/--until/--minutes/--agents`, bare `awake` | yes, in the foreground until the time is up, agents finish (+2 min) or Ctrl-C | yes, same |
| `awake --off` | stops a running `awake` of yours | same |
| `status [--json]` | battery, charge, health, cycles, lid, other apps' sleep blocks (`systemd-inhibit --list`), agents, mic and camera | battery and charge, power saver, agents, mic and camera |
| `agents [--json]`, `agents stop PID` | yes (SIGTERM) | yes (ends the process) |
| `ports [--json]` | yes (`/proc/net/tcp`, your processes) | yes (`netstat -ano`, your processes) |
| `privacy [--json]` | mic from `pactl` (PulseAudio or PipeWire), camera from open `/dev/video*` | mic and camera from the Windows privacy settings store |
| `apps [--json]` | yes (resident memory) | yes (working set) |
| `lid start`, `lid end`, `lid status [--json]` | yes (see below) | not yet |
| tray app | `keepwatch-tray` (see below) | not yet |

Fields that can't be known on a platform are `null` in JSON, never guessed. On macOS, unknown fields are left out of the JSON instead. `status --json` has an extra `platform` field (`"linux"` or `"windows"`), and on Linux a `lidSession` object (below; `null` on Windows). On Linux, `appRunning` is true while `keepwatch-tray` runs, and `sleep.sleepDisabled` is true while any app (a lid session, for one) blocks the lid switch.

## Lid-closed sessions (Linux)

```sh
keepwatch lid start [--hours N] [--at HH:MM] [--until-agents-done] [--no-battery]
keepwatch lid end
keepwatch lid status [--json]
```

`lid start` runs in the foreground, like `awake`. It holds a logind block inhibitor on `handle-lid-switch:sleep:idle` (`systemd-inhibit`, the same child process as `awake`), so closing the lid doesn't suspend the computer. Every 5 seconds it checks these rules, and the session ends when any of them is true:

- the lid has been closed for N hours (default 3, 0.5 to 12). Opening the lid resets the timer;
- it's the `--at` time;
- with `--until-agents-done`: no agent session has run for 2 minutes (counted from the start if none ran);
- on battery at or below 20%, or on battery at all with `--no-battery`. It won't start on battery at or below 20%;
- a thermal zone reaches 95 °C;
- 12 hours have passed since the start (the hard cap).

When it ends, keepwatch releases the inhibitor and, if the lid is still closed and the machine isn't docked, runs `systemctl suspend`. If that fails, logind acts on the closed lid itself once nothing blocks it. It won't start if it can't read the lid state (`/proc/acpi/button/lid`, else logind's `LidClosed`), if the battery is at or below 20%, or if it's too hot. If polkit refuses the inhibitor, it exits with status 2.

Safety: no root, no `sudo`, no setting that outlives the process. If keepwatch crashes or is killed, even with SIGKILL, the inhibitor goes with it and the lid works normally again. `lid end` (and the tray) ask the session to stop through a file in the private lock folder; the session logs why it ended. The log is `$XDG_STATE_HOME/keepwatch/lid.log` (default `~/.local/state/keepwatch/lid.log`): one line per start and end, mode 0600, cut to its newest half past 1 MB.

`lid status --json` and `status --json` (`lidSession`) report: `active`, `owner` (`"cli"` or `"tray"`), `pid`, `startedAt`, `afterLidClosedMinutes`, `sleepAt`, `untilAgentsDone`, `allowOnBattery`, `minBatteryPercent`, `hardCapAt`, `lidClosedSince` (set while the lid is closed), and `lastEndedAt` / `lastEndReason` from the log (`lid-closed-limit`, `sleep-at`, `agents-done`, `low-battery`, `on-battery`, `thermal`, `hard-cap`, `stop-requested`, `interrupted`, `tray-quit`, `inhibitor-lost`). Times are ISO 8601; unknowns are `null`.

Desktop power managers (GNOME's gsd-power, KDE's PowerDevil) also watch the lid. They normally respect logind's lid inhibitors, but this hasn't been checked on every desktop yet.

## Tray app (Linux)

`keepwatch-tray` puts an eye icon in the system tray (StatusNotifierItem over D-Bus; no GTK). It shows in KDE, XFCE, Cinnamon and Ubuntu's GNOME, where the AppIndicator extension is on by default. **Stock GNOME needs the AppIndicator extension** (for example `gnome-shell-extension-appindicator`); without one, the tray keeps running but shows nothing.

The menu has a status line, **Keep awake** (1 h, 3 h, 8 h, until you turn it off, while agents run, turn off), **Laptop closed** (start for 1, 3, 6 or 12 hours, with *End when agents finish* and *Allow on battery*, off by default, and *End lid session*), a read-only **Agents** list, **Open at login** (writes `~/.config/autostart/keepwatch-tray.desktop`) and **Quit**. Quit ends the sessions the tray started.

The tray runs the same code as the CLI, in-process, and uses the same lock files, so `keepwatch awake --off` and `keepwatch lid end` stop the tray's sessions, and sessions started in a terminal show up in the tray. It shows a desktop notification when a session ends. It checks for stop requests every second and reads the system every 5 seconds, and only redraws when something changed. SIGTERM ends it at once and releases its inhibitors; Ctrl-C and Quit end its sessions first.

## Not yet

- `mic mute|unmute` and `security` print "not available" and exit with status 1, and so does `lid` on Windows (a lid-closed mode there needs an administrator `powercfg` change).
- No tray app on Windows, no privacy history and no agent session titles (`title` is always `null`).
- `thermal` is always `null`, and so is `sleepDisabled` on Windows. On Windows, `preventedBy` is `null` because reading other apps' requests (`powercfg /requests`) needs an administrator.
- Lid sessions and the tray are tested in containers with stand-in `systemd-inhibit`, `systemctl`, lid, battery and thermal files, not yet on a real laptop.
- Linux: `--display` doesn't stop the screen blanking (that is up to the desktop), and `awake` needs `systemd-inhibit`. Without it, `awake` and `run` exit with status 2.
- Windows: tested in CI (Windows Server), not yet on a laptop. The `.exe` isn't code-signed, so SmartScreen may warn.

## Exit codes

0 ok, 1 usage error, 2 system error. For `run`, the command's own status: 127 if it isn't found, and 128 + N if signal N killed it (Linux).

## Install

Download `keepwatch-VERSION-linux-x86_64.tar.gz` (static `keepwatch` and `keepwatch-tray`, any x86_64 distribution) or `keepwatch-VERSION-windows-x86_64.zip` from the [latest release](https://github.com/AgentSkillDeck/keepwatch/releases/latest), and check it against `SHA256SUMS.txt`.

## Build

```sh
cd cross
cargo build --release      # target/release/keepwatch(.exe), and keepwatch-tray on Linux
cargo test
dbus-run-session -- sh scripts/tray-smoke.sh target/debug   # Linux: tray smoke test
```

Debug builds read `KEEPWATCH_TEST_*` stand-ins (tools, lid, battery and thermal files, a faster clock) so tests never touch the real logind. Release builds ignore them; `cargo test --release --test cli release_` checks that.

`awake --off` and `lid end` find the running session through a lock file in `$XDG_RUNTIME_DIR/keepwatch` (or a private `keepwatch-UID` folder in the temp dir) on Linux, and in `%TEMP%\keepwatch` on Windows. They check that the pid is still your own `keepwatch awake`, `keepwatch lid start` or `keepwatch-tray`, with the recorded start time, before they signal it or ask it to stop. The tray is never signalled. keepwatch makes no network connections and never asks for administrator rights.
