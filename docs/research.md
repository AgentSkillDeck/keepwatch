# Research notes (2026-10-15)

These notes come from two research passes (similar apps and trending projects, then macOS API feasibility) done while v0.1 was built. Everything is treated as public information. No code from any of these projects was read or copied.

## The landscape

- **Keep-awake:** Amphetamine (closed source, needs the separate "Enhancer" helper for closed-lid use) and KeepingYouAwake (MIT, no closed-lid mode).
- **Closed-lid keep-awake for agents is a new category in 2026:**
  - Adrafinil (MIT): agent hooks plus a thermal cut-out. HN 124 points.
  - Insomnia (MIT): a sudoers rule for `pmset`.
  - MacMiniMode (MIT): only works on power.
  - Recurring HN objections: heat in a bag, "it's just `sudo pmset disablesleep 1`", and distrust of unsigned apps that ask for sudo. Keepwatch answers these with the watchdog, the power-only default, the thermal cut-out, signing and notarization, and one password per session.
- **Agent status, notifications and usage meters:** coucou (5.3k★), muster, claude-status-bar, CodexBar (22.5k★), Pulse, headroom.
- **All-in-one toolkits:** vorssaint-utils (GPL-3.0, 27k★, #1 on Swift monthly trending, ideas only), hop (MIT), Ghostmoon (HN 147 points; commenters asked for notarization).
- **Privacy:** OverSight (GPL-3.0, ideas only) and Micro Snitch (paid).
- **Gap:** nobody combines agent-aware closed-lid wake, privacy and settings in one signed app that is open about what it can and can't do.

## API facts that shaped v0.1

| Need | How | Privilege |
|---|---|---|
| Idle keep-awake | `IOPMAssertionCreateWithName(PreventUserIdleSystemSleep / …DisplaySleep)` | user |
| Survive lid close | `pmset -a disablesleep 1`: undocumented, persists across reboots | root |
| Lid state | `AppleClamshellState` on IOPMrootDomain (`ioreg -r -k AppleClamshellState`) | user |
| Mic in use | `kAudioDevicePropertyDeviceIsRunningSomewhere` | user, no TCC |
| Who uses the mic | `kAudioHardwarePropertyProcessObjectList` + `kAudioProcessPropertyIsRunningInput/PID/BundleID` (14+) | user |
| Camera in use | `kCMIODevicePropertyDeviceIsRunningSomewhere` | user, no TCC |
| Who uses the camera | no public API (only fragile unified-log parsing) | not done |
| Revoke a permission | `tccutil reset Camera <bundle>` forces a re-prompt; it is not a deny | not done in v0.1 |
| Disable the camera system-wide | impossible without MDM | n/a |
| Own login item | `SMAppService.mainApp` | user |
| Other apps' login items | `sfltool dumpbtm` needs root; deep-link instead | n/a |

## Roadmap ideas, ranked

1. **Claude Code / Codex hook integration.** Use `Stop`/`Notification` hooks and Codex `notify` for exact "turn finished / needs approval" events instead of process polling. Needs an opt-in edit of the user's agent settings.
2. **Privileged helper (SMAppService.daemon + XPC).** No password per lid session; the user approves it once in Login Items.
3. **Local usage and cost meter** from `~/.claude` and `~/.codex` logs. No network needed.
4. **Phone push when an agent finishes** (ntfy or Pushover). Opt-in, because it means outbound network.
5. **Remote-access health check** for closed-lid use (SSH, Screen Sharing, Tailscale reachable?).
6. **Security nudges:** for example, "Chrome remote debugging port 9222 is open: any local program can control your browser". The listening-ports view already makes this visible.
7. Per-app camera attribution (best effort), a `tccutil reset` button with confirmation, and LaunchAgents viewer and cleaner.
8. Battery charge limit (needs root and SMC writes), external display brightness (DDC), and a lid-angle readout.

## Tested and dropped (2026-10-16)

- **"Stay active" for Slack and Teams.** `IOPMAssertionDeclareUserActivity` (what `caffeinate -u` uses) wakes the display but does **not** reset the HID idle time that chat apps read: measured 95 s idle before the call, 96 s after. Resetting it means posting synthetic input events, which needs the Accessibility permission Keepwatch promises never to ask for. Not shipped.
