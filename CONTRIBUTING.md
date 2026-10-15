# Contributing

Thanks for helping. You need macOS 14 or later and Xcode 16 or later (Swift 6 toolchain). There are no other dependencies.

```sh
swift build && swift test
scripts/build-app.sh --arm64-only   # dist/Keepwatch.app
dist/Keepwatch.app/Contents/MacOS/Keepwatch --render-snapshots /tmp/kw   # light/dark PNGs of the UI
```

## Rules

- **Logic goes in `KeepwatchCore`**, with a unit test. The app target (`Sources/Keepwatch`) is SwiftUI and glue only.
- **Never run privileged commands in tests.** The lid watchdog is tested by running its real shell loop against stub `pmset` and `ioreg` binaries (`LidWatchdogTests`). Follow that pattern.
- **Prove a new test can fail**: break the code it guards, watch the test fail, then restore.
- **No new privileges without discussion.** Anything that needs root, a TCC permission or network access needs an issue first.
- **No third-party code or assets.** Write your own. If you add an idea from another project, note it in `docs/research.md`. Never copy code from GPL projects.
- System facts that macOS doesn't document (`AppleClamshellState`, `SleepDisabled`, AppleSmartBattery keys) must be read defensively: every read optional, nothing force-unwrapped.

## Licence

By contributing you agree that your contribution is licensed under [Apache-2.0](LICENSE).
