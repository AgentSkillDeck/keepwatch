# Security policy

## Reporting a vulnerability

Please report security issues privately through GitHub security advisories: on this repository, open the **Security** tab and choose **Report a vulnerability**. Do not open a public issue for a vulnerability.

Include what you found, how to reproduce it, and the impact you expect. We will acknowledge the report, keep you informed while we fix it, and credit you in the advisory unless you ask us not to.

## What runs with administrator rights

Only one thing, and only when you click **Start lid session** and enter your password:

- `pmset -a disablesleep 1`, and
- a detached `/bin/sh` watchdog loop, built in `Sources/KeepwatchCore/LidSession.swift`, that turns sleep back on (`pmset -a disablesleep 0`) and, if the lid is shut, `pmset sleepnow`.

Every value interpolated into that command is a number or a vetted path: absolute, with no quote, backslash or newline. No user text reaches the root shell. Starting a lid session is not reachable from `keepwatch://` URLs.

The watchdog checks for a stop file in `~/Library/Caches/Keepwatch/`. Any local process that can write there can end a session early. That is by design: ending a session only turns sleep back on.

## What Keepwatch never does

- capture audio or video (it only asks the system whether the mic or camera is running);
- read or write the TCC privacy database, or ask for Full Disk Access or Accessibility;
- make network requests;
- stop processes without your confirmation, or stop macOS's own processes.

A report that any of these guarantees can be broken is in scope.
