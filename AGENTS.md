# AGENTS.md: rules for agents working on Keepwatch

Keepwatch is a native macOS menu-bar app and CLI (Swift and SwiftUI, macOS 14+). It keeps a Mac awake for AI agents, runs lid-closed sessions through a root watchdog, and watches the mic and camera. It runs with the user's password and changes a persistent power setting. **A bug here can leave a laptop sleepless in a bag.** These rules are strict. When a rule and a feature request conflict, the rule wins; raise the conflict in the PR.

Read `README.md`, `docs/design.md` and `SECURITY.md` before changing anything.

## 1. Safety of the lid watchdog (highest priority)

- The only privileged code path is `LidWatchdog.startCommand` → `PMSet.adminAppleScript` → `osascript … with administrator privileges`. **Do not add another.** Any new root action needs an issue and the maintainer's approval first.
- Every value interpolated into the root shell must be a number or a vetted absolute path (no `'`, `\`, newline). **Never interpolate user, URL, CLI or file text.** Add a rejection test for every new input.
- Every way to start a lid session must also end it without a password: the watchdog deadline, the 12 h hard cap (`LidSessionPlan.hardCap`), the battery rules, the stop file and the launch-time check (boot time and watchdog alive). Never weaken or remove one of these. Never raise the hard cap.
- Lid sessions can **never** be started from `keepwatch://` URLs (any web page can open one). The CLI may only *ask* the running app (`keepwatch lid start`, a local distributed notification); the app then goes through the same macOS administrator prompt, so only the person at the Mac can grant it. Never add a path that starts a lid session without that prompt (no sudoers rule, no cached authorization). Tests `testAgentsCannotStartLidSessions` and `testRejectsBadInputAndCapsDuration` guard it.
- **Never run `pmset` with a setting, `sudo`, `osascript … administrator`, or the real watchdog in tests or while developing.** Test the shell loop the way `LidWatchdogTests` does: run it against stub `pmset` and `ioreg` binaries in a temp dir.

## 2. Never crash, never hang

- No `!` force-unwraps, `try!`, `as!`, `fatalError`, `precondition` or `unsafe` code outside tests. Read every system value (`IORegistry`, `pmset`, CoreAudio, `sysctl`, `lsof`, `proc_*`) as optional, and degrade to "unknown" rather than failing.
- Cap every buffer sized by system or input data (see `ProcessList.maxProcesses`, `maxArgumentBytes`, `PrivacyMonitor.maxObjects`).
- Every subprocess gets a timeout (`SystemState.run`) and absolute executable paths. Never block the main thread on a subprocess or an admin prompt.

## 3. Privacy and permissions

- Keepwatch captures no audio or video, makes **no network requests** except the opt-in update check in `UpdateCheck` (one GET to GitHub's latest-release API, off by default, [#4](https://github.com/AgentSkillDeck/keepwatch/issues/4)), reads no `TCC.db`, and asks for no Full Disk Access or Screen Recording permission. Accessibility is used only by the opt-in **Stay active** (`StayActive`, [#5](https://github.com/AgentSkillDeck/keepwatch/issues/5)): a 1-pixel pointer move when idle, never clicks or keys, never during a lid session. Adding any of these needs an issue first and a `SECURITY.md` update.
- Never stop a process without a user confirmation, and never stop macOS's own (`ListeningPorts.isSystemPath`).
- Never store anything about other apps beyond the current run.

## 4. Public contracts

- `keepwatch status --json` field names, `keepwatch://` URLs, CLI commands and exit codes (0 ok, 1 usage, 2 system, else the child's status for `run`) are used by agents and scripts. **Add, never rename or remove.** Update `skills/keepwatch/SKILL.md` and `README.md` in the same PR.
- The agent matcher must never count idle helpers. Claude Code's `--bg-spare` and `/spare/` pty host and `claude daemon` are excluded; a new agent CLI's daemons must be excluded the same way, with a test.

## 5. Code layout and tests

- Logic goes in `Sources/KeepwatchCore` with unit tests. `Sources/Keepwatch` (SwiftUI) and `Sources/KeepwatchCLI` are thin glue.
- **Prove each new test can fail:** break the code it guards, watch it fail, restore. A test you haven't seen fail proves nothing.
- Tests that read the live machine must be read-only and must pass on CI (no battery, no lid, no camera).
- Review UI changes by rendering them: `dist/Keepwatch.app/Contents/MacOS/Keepwatch --render-snapshots /tmp/kw`, then look at the light and dark PNGs. Don't use `screencapture`.

## 6. Provenance

- No third-party code or assets. Write your own code; art is original (`assets/`).
- Ideas from other projects are fine. Note them in `docs/research.md`. **Never read or copy code from GPL projects** (OverSight, Ice, vorssaint-utils and others).
- No secrets, personal data, signing identities beyond the public Team ID, or notarization credentials in the repo. Never read the keychain.

## 7. Gates before every commit

```sh
swift build && swift test                 # all green
scripts/build-app.sh --arm64-only         # the app bundle builds
```

- Commit only green states. Use one focused change per commit with an imperative subject.
- `main` is protected. Branch as `feat/…`, `fix/…`, `docs/…` or `chore/…`, and open a PR. CI must pass and CODEOWNERS must approve.
- Signing and notarization are done by the maintainer (`scripts/sign.sh`, `scripts/notarize.sh`), never by an agent.
