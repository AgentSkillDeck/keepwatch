# Keepwatch: design (v0.1)

Status: v0.1 built unattended on 2026-10-15 while the owner was away. Correct anything here before v0.2.

Revision history:
- 2026-10-15: first draft. Renamed from "Lidless" (name taken). Lid mode redesigned around a root watchdog, because nobody can type a password with the lid shut. Added lid sessions with a time limit and scheduled sleep (owner request), listening ports, and the `keepwatch://` URL scheme.

## What it is

Keepwatch is a native macOS menu-bar app (Swift, SwiftUI, Developer ID signed and notarized, not sandboxed). It brings together the controls a laptop developer reaches for every day:

1. **Stay awake for agents.** Keep the Mac awake for a set time, indefinitely, or *while Claude Code / Codex / other agent CLIs are running*, and notify when an agent run ends.
2. **Lid-closed mode.** Keep running with the lid shut. This needs an admin action and is built to fail safe (see Safety).
3. **Privacy watch.** Live indicators for the mic and camera, with the app using them where macOS exposes that; one-click links to the System Settings privacy panes; a hard mic mute; and automatic actions when the lid closes.
4. **Dashboard.** One window with power, battery health, privacy state, login item, and quick toggles for common settings (Dock autohide, hidden files, appearance).

## Who it is for

- Developers running long AI-agent sessions (Claude Code, Codex) who need the Mac to stay awake and want to know when a run finishes.
- Anyone who wants to see at a glance whether their mic or camera is live.

## v0.1 scope (built unattended)

| Feature | Privilege | Status |
|---|---|---|
| Keep awake: timer / indefinite (IOPMAssertion) | user | v0.1 |
| Keep awake while an agent CLI runs, notify on exit | user | v0.1 |
| Mic and camera in-use indicators | user (read-only) | v0.1 |
| Hard mic mute (CoreAudio input mute) | user | v0.1 |
| Deep links to System Settings privacy panes | user | v0.1 |
| Launch at login (SMAppService.mainApp) | user | v0.1 |
| Battery health, power source, thermal state | user | v0.1 |
| Quick toggles (Dock autohide, hidden files, appearance, display sleep now) | user | v0.1 |
| Lid-closed sessions: N h after lid close, sleep at a set time, end with agents, power-only by default, 12 h cap | one admin prompt per session; a root watchdog restores sleep | v0.1. Watchdog shell loop tested against stubs; never run for real unattended |
| Which app uses the mic | user (CoreAudio process list, 14+) | v0.1 |
| Which app uses the camera | no public API | later, best effort |
| Listening ports with confirmed Stop (macOS processes protected) | user | v0.1 |
| `keepwatch://` URL scheme (Shortcuts, Raycast) | user; cannot start lid sessions | v0.1 |
| Revoke a single app's camera/mic permission (`tccutil reset`) | user | later, needs owner review |
| Privileged helper (SMAppService.daemon) instead of admin prompt | root helper | v0.2 |

## Safety rules

- Lid-closed mode changes a **persistent system setting**. It survives an app crash. So:
  - Keepwatch records its intent in its own preferences before changing anything.
  - On every launch it reads the real state (`pmset -g`) and, if sleep is disabled but Keepwatch did not intend it (crash, reboot), it offers to restore it at once.
  - It turns lid-closed mode off on quit, when the timer ends, at low battery (default 15%), and on serious or critical thermal state.
- Nothing is changed without an explicit click. No background admin prompts.
- No reading of TCC.db and no Full Disk Access in v0.1.

## Architecture

- `KeepwatchCore` (library, unit-tested): pure logic and thin system wrappers. Covers power assertions, `pmset` parsing and command building, the agent process matcher, the session state machine, the mic/camera monitors, battery info, settings toggles and privacy pane URLs.
- `Keepwatch` (executable): the SwiftUI `MenuBarExtra` and the dashboard window.
- `scripts/`: `build-app.sh` assembles `Keepwatch.app`, `sign.sh` signs with Developer ID and hardened runtime, `notarize.sh` notarizes with `--keychain-profile`.

## Assumptions to confirm

- The name "Keepwatch" is a working title ("Lidless" was taken).
- The minimum OS is macOS 14 (Sonoma), so it runs on most current Macs.
- Keepwatch is a local repo with no remote until the owner decides where it lives.
