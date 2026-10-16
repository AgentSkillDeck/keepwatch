# Homebrew formula for the CLI

`keepwatch-cli.rb` installs the `keepwatch` command on its own, without the app. It lives in the tap repo `AgentSkillDeck/homebrew-tap` as `Formula/keepwatch-cli.rb`. People install with:

```sh
brew install agentskilldeck/tap/keepwatch-cli
```

## Publishing a version (maintainer)

1. Set the version in `Resources/Info.plist` (and `version` in `Sources/KeepwatchCLI/main.swift`).
2. Run `scripts/make-cli-zip.sh`. It builds `dist/keepwatch-cli-VERSION-macos.zip` (universal) and prints the signing steps.
3. Sign the binary with Developer ID and the hardened runtime, zip it again, and notarize the zip with `xcrun notarytool submit … --wait`. A bare binary can't be stapled, so Gatekeeper checks it online on first run.
4. Upload the zip to the `vVERSION` GitHub release, next to the app, and list it in the release's `SHA256SUMS.txt` (`shasum -a 256 *.zip *.dmg > SHA256SUMS.txt`): `scripts/install-cli.sh` and the app's updater refuse files that aren't listed there.
5. In the tap, copy this file to `Formula/keepwatch-cli.rb`, set the version in both places in `url`, and replace the placeholder `sha256` with the output of `shasum -a 256` on the uploaded zip.
6. Check the style locally with `brew style Formula/keepwatch-cli.rb`, push the tap, then check the install:

   ```sh
   brew install agentskilldeck/tap/keepwatch-cli
   brew test keepwatch-cli
   brew audit --strict --online agentskilldeck/tap/keepwatch-cli
   ```

The `test do` block checks that `keepwatch version` prints the formula's version, so `version` in `Sources/KeepwatchCLI/main.swift` must match the release.

Keep this copy in step with the tap so the next release starts from it.
