cask "clrc" do
  arch arm: "arm64", intel: "amd64"

  version "2.2.0"
  sha256 arm:   "0ef2a448aeb25d0abb80b64979fd42e73098d6e523ceb87ffe2cf28b96de51de",
         intel: "83d9c618a50966c5ec775c4849b12310b9804dce286095bdbc771dfe0edd6590"

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
