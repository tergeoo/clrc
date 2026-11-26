cask "clrc" do
  arch arm: "arm64", intel: "amd64"

  version "2.2.1"
  sha256 arm:   "c55936e3fcef3197a5c8e8b4b9ea6a2a12fa7a931903aefa52140180adfe06ce",
         intel: "65829669bc7c51dd34d3223130e509b8be90388dc0a6210156b4e2bb58733350"

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
