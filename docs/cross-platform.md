# Linux and Windows: plan (phase 2 in progress)

Status: phase 1 (the command line) and the Linux half of phase 2 (lid-closed sessions and the `keepwatch-tray` app) are built in [`cross/`](../cross/README.md), beta, 2026-10-17. Linux is tested in containers with stand-in systemd tools, not yet on a real laptop; Windows is compile-checked and runs its tests in CI only. Still to do: mic mute, security checks, and lid sessions and a tray on Windows.

Keepwatch v0.1 was macOS-only. Every system feature in it uses Mac APIs (IOKit power assertions, `pmset`, `AppleClamshellState`, CoreAudio, CoreMediaIO, `SMAppService`, SwiftUI `MenuBarExtra`), so other platforms need a separate implementation, not a recompile.

## What maps, and how

| Feature | Linux | Windows |
|---|---|---|
| Keep awake (idle) | `systemd-inhibit --what=idle:sleep` or logind D-Bus `Inhibit` (user-level) | `SetThreadExecutionState(ES_CONTINUOUS \| ES_SYSTEM_REQUIRED)` (user-level) |
| Keep running with the lid closed | logind `Inhibit` with `handle-lid-switch` through `systemd-inhibit` (user-level with polkit): built, no watchdog needed because the lock dies with the process | Lid close action: `powercfg /setacvalueindex … LIDACTION 0` (admin; persistent, so it needs the same watchdog design) |
| Lid state | `/proc/acpi/button/lid/*/state` or logind `LidClosed` | `GUID_LIDSWITCH_STATE_CHANGE` power notification |
| Agent detection | `/proc/*/comm` and `cmdline` (same matcher rules) | `CreateToolhelp32Snapshot` + command line via WMI |
| Mic in use | PipeWire/PulseAudio source-outputs (`pactl list source-outputs`) | `CapabilityAccessManager` registry "LastUsedTimeStop == 0" per app (user-level) |
| Camera in use | `fuser /dev/video*` (own processes only) or PipeWire nodes | same CapabilityAccessManager keys (`webcam`) |
| Battery | `/sys/class/power_supply/BAT*` (health = `energy_full`/`energy_full_design`) | `GetSystemPowerStatus` + WMI `BatteryFullChargedCapacity` |
| Tray UI | StatusNotifierItem through `ksni` (KDE, XFCE, Cinnamon, GNOME with the AppIndicator extension): built | Notification-area icon |
| Signing | none needed; ship `.deb`/`.rpm`/AppImage + checksums | Authenticode certificate (paid) or the Microsoft Store |

## Recommended approach

1. Write the cross-platform **CLI first** in Rust (`keepwatch` with the same commands, JSON fields and exit codes as the macOS CLI). Agents then get one interface on every OS. The `StatusReport` field names are the contract.
2. Add a small tray app per platform later, reusing the Rust core (for example the `tray-icon` crate).
3. Port the lid watchdog design as-is: one elevated start, a self-ending watchdog, a hard cap, battery and thermal rules, and a launch-time check.
4. Release with CI per platform. On Windows, budget for a code-signing certificate, or SmartScreen will warn every user.

## Effort

About 1–2 weeks for a solid CLI on both platforms, plus about 1 week per tray app. The lid-closed mode on Windows (persistent `powercfg` change) needs the most care.

## Revisions

- 2026-10-17: phase 2 on Linux. `keepwatch lid start|end|status` (logind lid-switch inhibitor; the macOS rules: N hours after closing, `--at`, agents done, 20% battery floor, unplugged, 95 °C, 12 h cap; suspend when it ends with the lid shut) and `keepwatch-tray` (ksni, own icons, same sessions and lock files as the CLI). `status --json` gains `lidSession`. The core moved to a library shared by both binaries.

- 2026-10-17: phase 1. A Rust `keepwatch` CLI for Linux and Windows in `cross/` (status, awake, run, agents, ports, privacy, apps), with CI on Ubuntu and Windows. Process listing uses the `sysinfo` crate on both platforms.
- 2026-10-15: proposal.
