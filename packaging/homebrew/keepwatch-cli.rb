# frozen_string_literal: true

# Homebrew formula for the keepwatch command on its own, without the app.
# It lives in the tap repo AgentSkillDeck/homebrew-tap as Formula/keepwatch-cli.rb.
# See packaging/homebrew/README.md for how to publish a new version.
class KeepwatchCli < Formula
  desc "Keep your Mac awake for AI agents, and check mic, camera and power"
  homepage "https://github.com/AgentSkillDeck/keepwatch"
  # Homebrew reads the version from the URL. Set both numbers at release time:
  # .../releases/download/vVERSION/keepwatch-cli-VERSION-macos.zip
  url "https://github.com/AgentSkillDeck/keepwatch/releases/download/v0.3.0/keepwatch-cli-0.3.0-macos.zip"
  # FILL IN AT RELEASE TIME: shasum -a 256 dist/keepwatch-cli-<version>-macos.zip
  sha256 "d9e3753e6745141f01637dc210085c049d2b483012cc00214549e32d1b309ea3"
  license "Apache-2.0"

  depends_on macos: :sonoma

  def install
    bin.install "keepwatch"
  end

  def caveats
    <<~EOS
      Lid-closed sessions (keepwatch lid start) need the Keepwatch app:
        https://github.com/AgentSkillDeck/keepwatch/releases/latest
      Everything else works without it.
    EOS
  end

  test do
    assert_match "keepwatch #{version}", shell_output("#{bin}/keepwatch version")
  end
end
