# keepwatch for Linux and Windows (command line, beta)

A Rust port of the macOS `keepwatch` command. It has the same commands, JSON field names and exit codes, as far as each platform allows. There is no tray app on Linux or Windows yet, so `keepwatch awake` holds the computer awake itself, in the foreground.

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

Fields that can't be known on a platform are `null` in JSON, never guessed. On macOS, unknown fields are left out of the JSON instead. `status --json` has an extra `platform` field (`"linux"` or `"windows"`).

## Not yet

- `mic mute|unmute`, `lid start|end` and `security` print "not available" and exit with status 1.
- No tray app, no privacy history and no agent session titles (`title` is always `null`).
- `thermal` and `sleepDisabled` are always `null`. On Windows, `preventedBy` is `null` because reading other apps' requests (`powercfg /requests`) needs an administrator.
- Linux: `--display` doesn't stop the screen blanking (that is up to the desktop), and `awake` needs `systemd-inhibit`. Without it, `awake` and `run` exit with status 2.
- Windows: tested in CI (Windows Server), not yet on a laptop. The `.exe` isn't code-signed, so SmartScreen may warn.

## Exit codes

0 ok, 1 usage error, 2 system error. For `run`, the command's own status: 127 if it isn't found, and 128 + N if signal N killed it (Linux).

## Install

Download `keepwatch-VERSION-linux-x86_64.tar.gz` (static, any x86_64 distribution) or `keepwatch-VERSION-windows-x86_64.zip` from the [latest release](https://github.com/AgentSkillDeck/keepwatch/releases/latest), and check it against `SHA256SUMS.txt`.

## Build

```sh
cd cross
cargo build --release      # target/release/keepwatch(.exe)
cargo test
```

`awake --off` finds the running `awake` through a lock file in `$XDG_RUNTIME_DIR/keepwatch` (or a private `keepwatch-UID` folder in the temp dir) on Linux, and in `%TEMP%\keepwatch` on Windows. It checks that the pid is still your own `keepwatch awake` before it signals it. keepwatch makes no network connections and never asks for administrator rights.
