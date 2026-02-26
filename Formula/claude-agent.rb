class ClaudeAgent < Formula
  desc "Mac agent daemon for Claude Orchestrator — connects your Mac to the relay"
  homepage "https://github.com/tergeoo/Claude-Orchestrator"
  version "1.0.0"
  license "MIT"

  on_macos do
    on_arm do
      url "https://github.com/tergeoo/Claude-Orchestrator/raw/main/bin/claude-agent-darwin-arm64"
      sha256 "f9a25d227b958a56e7b7165df1ffd7449652bd893f71cb899e31f1e27968fcb2"
    end
    on_intel do
      url "https://github.com/tergeoo/Claude-Orchestrator/raw/main/bin/claude-agent-darwin-amd64"
      sha256 "0f44d0a9856d3bfc0d4eddae60e311df663689a113c8852ce4e113e43113b260"
    end
  end

  def install
    bin.install stable.url.split("/").last => "claude-agent"
  end

  def caveats
    <<~EOS
      Run the agent (no config file needed):
        claude-agent --relay wss://YOUR_RELAY --secret YOUR_SECRET --name "#{`hostname`.strip}"

      Or start as a background service with launchd:
        brew services start claude-agent
        # Edit plist to add --relay / --secret flags first:
        open ~/Library/LaunchAgents/homebrew.mxcl.claude-agent.plist
    EOS
  end

  service do
    run [opt_bin/"claude-agent", "--config", "#{Dir.home}/.config/claude-agent/config.yaml"]
    keep_alive true
    log_path "/tmp/claude-agent.log"
    error_log_path "/tmp/claude-agent.log"
  end

  test do
    assert_match "Usage", shell_output("#{bin}/claude-agent --help 2>&1", 2)
  end
end
