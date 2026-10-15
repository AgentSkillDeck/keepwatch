# Keepwatch

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/logo-dark.svg">
    <img src="assets/logo.svg" alt="Keepwatch" width="420">
  </picture>
</p>

[![ci](https://github.com/AgentSkillDeck/keepwatch/actions/workflows/ci.yml/badge.svg)](https://github.com/AgentSkillDeck/keepwatch/actions/workflows/ci.yml)

A native macOS menu-bar app that keeps your Mac awake for AI coding agents, even with the lid closed, and keeps watch on your mic and camera.

Built with Swift and SwiftUI for macOS 14 and later. It runs on Apple Silicon and Intel, is signed with a Developer ID, and is not sandboxed.

## What it does

**Stay awake**
- One click for 1 h, 3 h, or until you turn it off.
- **While AI agents run** keeps the Mac awake only while Claude Code, Codex, Gemini CLI, Aider, OpenCode, Goose, Amp, Cursor Agent, Qwen Code or Crush is running. After the last one exits, it waits a 2-minute grace period, then lets the Mac sleep.
  - Claude Code's idle helpers (the pre-warmed `--bg-spare` process and `claude daemon`) don't count, so they can't keep the Mac awake forever.
- A notification tells you when an agent finishes.
- It shows which other apps are also holding the Mac awake (Amphetamine, caffeinate, and so on).

**Lid-closed sessions (beta)**

> Beta: the watchdog is tested by running its real shell loop against stub tools, but lid sessions have had little real-world use. Try one plugged in first: start a session, check that `pmset -g | grep SleepDisabled` shows `1`, click **End lid session**, and check that the line disappears within about 30 s.

- Keeps agents running with the lid shut, then puts the Mac to sleep by itself. Choose:
  - sleep **N hours after the lid closes** (opening the lid resets the timer), and/or
  - sleep **at a set time** (for example, tonight at 1:00),
  - end **when all agents finish**,
  - **never on battery** unless you allow it, and then it stops at 20%,
  - a **12-hour hard cap** in every case.
- It asks for your password **once**, when you start a session. That one admin command turns sleep off and starts a small root watchdog. The watchdog alone turns sleep back on and sleeps the Mac, so it works with the lid shut and even if Keepwatch crashes or quits.
- Keepwatch ends a session early without a password (agents done, Mac running hot, you click End) by dropping a stop file that the watchdog checks every 30 s.
- On launch, Keepwatch checks the real `pmset` state:
  - If sleep is still off from an earlier session whose watchdog is gone (after a restart, say), it offers to turn sleep back on.
  - If something else turned sleep off, it says so.

**Privacy**
- Live mic and camera indicators in the menu bar.
- **Which app is using the mic**, from CoreAudio's process list (macOS 14+).
- One-click **mic mute**.
- **Mute the mic when the lid closes**, and unmute it when the lid opens.
- One-click links to the System Settings privacy lists: Camera, Microphone, Screen Recording, Accessibility, Full Disk Access, Automation, Location.
- Keepwatch needs **no** mic, camera, Full Disk Access or Accessibility permission. It never captures anything; it only asks the system whether a device is running.

**Dashboard**
- Battery charge, source, time left, **health** (% of original capacity), cycle count, Low Power Mode, thermal state and lid state.
- **Listening ports**: your processes listening on TCP ports, with a confirmed Stop. Stop is hidden for macOS's own processes.
- Quick settings: Dock autohide, show hidden files, show all file extensions.
- Open at login, plus a link to manage all login items.

**Command line, for you and your AI agents**

Install it from the dashboard (**Install the keepwatch command**), then:

```sh
keepwatch run -- npm test          # stay awake exactly while a command runs (exit status passes through)
keepwatch awake --agents           # stay awake while Claude Code, Codex, … run
keepwatch awake --minutes 90       # or --off
keepwatch status --json            # power, sleep blockers, agents, mic/camera, lid
keepwatch ports                    # what's listening on which port
keepwatch lid end                  # end a lid session (starting one needs the app and your password)
```

**Agent skill:** [`skills/keepwatch/SKILL.md`](skills/keepwatch/SKILL.md) teaches Claude Code, Codex and other agents to use it safely: `npx skills add AgentSkillDeck/keepwatch`.

**Automation (Shortcuts, Raycast, scripts)**

```sh
open "keepwatch://awake?minutes=90"   # keep awake 90 min (max 24 h)
open "keepwatch://awake"              # until turned off
open "keepwatch://awake/agents"       # while AI agents run
open "keepwatch://awake/off"
open "keepwatch://mic/mute"           # or mic/unmute
open "keepwatch://lid/end"            # end a lid session (restores sleep)
open "keepwatch://dashboard"
```

Starting a lid session is deliberately **not** available by URL, so a web page can never put a password prompt in front of you.

## Safety

- Lid-closed mode changes a persistent system setting (`pmset disablesleep`). While the Mac is running, the watchdog's deadline, the 12 h cap, the battery rules and the thermal cut-out all end it.
- **Known gap: a restart during a session.** `SleepDisabled` survives a reboot and the watchdog doesn't. Keepwatch spots this on its next launch (it compares boot time with the session start) and offers to turn sleep back on. Until Keepwatch is opened, though, the Mac won't sleep, so turn on **Open Keepwatch at login** if you use lid sessions. A privileged helper (roadmap) will close this gap.
- No background admin prompts. The password is asked only when you click **Start lid session**.
- Nothing reads TCC.db and no permission is granted silently.

## Build, sign, notarize

```sh
swift test                      # 47 unit, shell-watchdog and live read-only tests
scripts/build-app.sh            # dist/Keepwatch.app (universal)
scripts/sign.sh                 # Developer ID + hardened runtime + timestamp
# one-time: store notarization credentials in your keychain
xcrun notarytool store-credentials keepwatch-notary --apple-id YOU@EXAMPLE.COM --team-id S99G3X6RPM
scripts/notarize.sh [profile]   # notarize, staple, zip -> dist/Keepwatch-0.1.0.zip
shasum -a 256 dist/Keepwatch-0.1.0.zip > dist/SHA256SUMS.txt
```

To review the UI without a screen capture: `dist/Keepwatch.app/Contents/MacOS/Keepwatch --render-snapshots /tmp/kw` writes light and dark PNGs of the menu and dashboard.

## Layout

- `Sources/KeepwatchCore`: logic and thin system wrappers, unit-tested. Covers power assertions, `pmset` parsing, agent detection, the keep-awake engine, the lid-mode policy, the lid watchdog builder, the privacy monitor, power state, quick toggles, listening ports and URL commands.
- `Sources/Keepwatch`: the SwiftUI app (menu-bar extra, dashboard, app model).
- `Tests/KeepwatchCoreTests`: includes a test that runs the real watchdog shell loop against stub `pmset` and `ioreg` binaries.
- `Sources/KeepwatchCLI`: the `keepwatch` command.
- `skills/keepwatch`: the agent skill.
- `docs/`: the design doc and research notes.
- `AGENTS.md`: strict rules for agents developing Keepwatch.

## Licence

Apache-2.0. See [LICENSE](LICENSE) and [NOTICE](NOTICE). Report security issues as described in [SECURITY.md](SECURITY.md).
