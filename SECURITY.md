# Security policy

## Reporting a vulnerability

Please report security issues privately through GitHub security advisories: on this repository, open the **Security** tab and choose **Report a vulnerability**. Do not open a public issue for a vulnerability.

Include what you found, how to reproduce it, and the impact you expect. We will acknowledge the report, keep you informed while we fix it, and credit you in the advisory unless you ask us not to.

## What runs with administrator rights

Only one thing, and only after you enter your password in the macOS prompt. The prompt appears when you click **Start lid session**, or when `keepwatch lid start` (run by you or an agent) asks the running app over a local distributed notification:

- `pmset -a disablesleep 1`, and
- a `/bin/sh` watchdog loop, built in `Sources/KeepwatchCore/LidSession.swift` and submitted as the launchd job `app.keepwatch.lid-watchdog`, that turns sleep back on (`pmset -a disablesleep 0`) and, if the lid is shut, `pmset sleepnow`, then removes its own job. It checks the stop file every 2 s (battery and lid every 30 s) and appends when it started and why it stopped to `/var/log/keepwatch-lid.log`, a root-owned folder; it writes nothing in your folders.

Every value interpolated into that command is a number or a vetted path: absolute, with no quote, backslash or newline. No user text reaches the root shell. Starting a lid session is not reachable from `keepwatch://` URLs.

The watchdog checks for a stop file in `~/Library/Caches/Keepwatch/`. Any local process that can write there can end a session early. That is by design: ending a session only turns sleep back on.

## What Keepwatch never does

- capture audio or video (it only asks the system whether the mic or camera is running);
- read or write the TCC privacy database, or ask for Full Disk Access;
- ask for Accessibility, unless you turn on **Stay active**. Then it uses it for one thing only: when you've been idle for the minutes you chose, it posts a 1-pixel mouse move and moves the pointer back. It never clicks, types or reads the screen, and never does it during a lid session;
- make network requests, except the opt-in update check: with **Check for updates** (or the daily switch, off by default) it sends one GET to `api.github.com/repos/AgentSkillDeck/keepwatch/releases/latest` with no cookies, reads the version number, the release page and the download links; only when you click **Install and relaunch** does it download `Keepwatch-VERSION.zip` and `SHA256SUMS.txt` from that release (redirects only to GitHub's download hosts), and it replaces the app only if the checksum matches, the new app is signed by team `S99G3X6RPM` with bundle id `app.keepwatch.Keepwatch`, Gatekeeper accepts it (notarized) and its version is newer;
- stop macOS's own processes. In the app, Stop always asks first. `keepwatch agents stop PID` stops only a process that is an agent session (Claude Code, Codex…) of your own user, and re-checks that just before signalling it.

## Other things it changes, only when you ask

- **Reset camera access** runs Apple's `tccutil reset Camera` after a confirmation, so every app must ask again. It never reads or edits the privacy database itself.
- **Session names** in the Agents tab come from the end of Claude Code's own transcript for that session (`~/.claude/projects/…/<session>.jsonl`, at most the last 512 KB). Keepwatch reads only the title, keeps it in memory for the current run, and shows a name only when it can tell which transcript belongs to which session. For Codex it reads the end of `~/.codex/session_index.jsonl` (thread names) and the first line (at most 64 KB) of rollout files from the last three days' folders under `~/.codex/sessions`, to match a running session to its folder; the same rules apply.
- The **activity log** is `~/Library/Application Support/Keepwatch/activity-log.json` (mode 0600, at most 1,000 entries, never sent anywhere). Each entry is also written to the unified system log (subsystem `app.keepwatch.Keepwatch`, category `activity`), with details marked private. Text that comes from other software, such as app and process names, is stripped of control characters and capped before it is logged.
- **Screen Sharing detection** only checks whether macOS's `screensharingd` is running. **Away summaries** are kept in memory and never written to disk.
- The mic and camera history is a small JSON file in `~/Library/Application Support/Keepwatch/`, capped at 500 entries, never sent anywhere. **Clear** in the Privacy tab deletes it.

- **Storage** reads only the volume's free space and the sizes of a fixed list of folders under your home (caches, Xcode and simulator data, `~/.cache`, `~/.npm`, `~/Library/Logs`). It never deletes anything and never reads Downloads, the Trash or other apps' containers.
- **Startup items** reads the property lists in `~/Library/LaunchAgents`, `/Library/LaunchAgents` and `/Library/LaunchDaemons` (at most 1,000 files, 256 KB each). **Remove** works only on your own items (`~/Library/LaunchAgents`): it runs `launchctl bootout` for that item and moves its file to the Trash, after two clicks, and logs it.
- The **agent time limit** stops a session only if you chose "Stop the session", with the same checks as Stop in the Agents tab.

## Linux (beta): lid-closed sessions and the tray

On Linux, nothing runs as root and there is no password prompt. `keepwatch lid start` (or **Laptop closed** in `keepwatch-tray`) takes a logind block inhibitor on the lid switch, sleep and idle through `systemd-inhibit`, which polkit allows for the active session on most desktops. That means any process running as you, an agent included, can start a lid session. What bounds one is the session itself: it ends after the hours you chose once the lid closes, at the `--at` time, at 20% battery (or when unplugged, with `--no-battery`), at 95 °C, and after 12 hours at most, and then asks to suspend if the lid is shut.

- It changes no setting and writes nothing outside your own folders. The inhibitor belongs to the keepwatch process: if keepwatch crashes or is killed, even with SIGKILL, logind drops it and closing the lid suspends as usual.
- `keepwatch lid end`, `keepwatch awake --off` and the tray stop a session by writing a stop file in your private runtime folder (`$XDG_RUNTIME_DIR/keepwatch`, mode 0700), after checking the pid is your own keepwatch with the recorded start time. Anything running as you can end a session early, by design.
- The session log (`~/.local/state/keepwatch/lid.log`), the lock and state files and the tray's autostart file are written as mode 0600, never through a symlink, and the log is capped at 1 MB.
- `keepwatch-tray` talks only to your session bus (the tray icon and desktop notifications). Like the CLI, it makes no network connections.
- Debug builds read `KEEPWATCH_TEST_*` environment variables for test stand-ins; release builds ignore them.

A report that any of these guarantees can be broken is in scope.
