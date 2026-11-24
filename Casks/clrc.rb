cask "clrc" do
  arch arm: "arm64", intel: "amd64"

  version "2.0.0"
  sha256 arm:   "5db621bdd566f5d6a4e819d8e82003f2df99e20464112a3a32b5dc5020db854c",
         intel: "36c153b25bbe91863a46aef5bcd712f51d99ff4d5de405ebb0dc57e0d0f640b1"

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
