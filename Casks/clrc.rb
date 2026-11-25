cask "clrc" do
  arch arm: "arm64", intel: "amd64"

  version "2.1.0"
  sha256 arm:   "75259f0f0267aa06834736118ea21c5f73b64b4fb36ce595ae7302ca18ca0770",
         intel: "36f0b19364003956aa1fdcef9ffe1954b3077b9a609f6c4de94a261df55d5bf0"

  url "https://github.com/tergeoo/clrc/releases/download/v#{version}/clrc-darwin-#{arch}"
  name "clrc"
  desc "Claude Remote Control — use Claude CLI on your Mac from your iPhone"
  homepage "https://github.com/tergeoo/clrc"

  binary "clrc-darwin-#{arch}", target: "clrc"

  caveats <<~EOS
    Configure clrc before starting:
      $EDITOR #{Dir.home}/.config/clrc/.env

    Required fields: RELAY_URL and AGENT_SECRET.

    Start the daemon:
      clrc start        # start once in background
      clrc stop         # stop
      clrc status       # check status
      clrc logs         # tail logs
  EOS
end
