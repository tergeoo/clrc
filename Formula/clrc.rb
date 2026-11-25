class Clrc < Formula
  desc "Claude Remote Control — use Claude CLI on your Mac from your iPhone"
  homepage "https://github.com/tergeoo/clrc"
  version "2.1.0"
  license "MIT"

  on_macos do
    on_arm do
      url "https://github.com/tergeoo/clrc/releases/download/v#{version}/clrc-darwin-arm64"
      sha256 "75259f0f0267aa06834736118ea21c5f73b64b4fb36ce595ae7302ca18ca0770"
    end
    on_intel do
      url "https://github.com/tergeoo/clrc/releases/download/v#{version}/clrc-darwin-amd64"
      sha256 "36f0b19364003956aa1fdcef9ffe1954b3077b9a609f6c4de94a261df55d5bf0"
    end
  end

  def install
    if Hardware::CPU.arm?
      bin.install "clrc-darwin-arm64" => "clrc"
    else
      bin.install "clrc-darwin-amd64" => "clrc"
    end
  end

  service do
    run opt_bin/"clrc"
    keep_alive true
    log_path "/tmp/clrc.log"
    error_log_path "/tmp/clrc.log"
    environment_variables PATH: std_service_path_env
  end

  def caveats
    <<~EOS
      Configure clrc before starting:
        $EDITOR #{Dir.home}/.config/clrc/.env

      Required fields: RELAY_URL and AGENT_SECRET.

      Start the daemon:
        brew services start clrc   # auto-start on login
        clrc start                 # start once in background
    EOS
  end

  test do
    assert_match "Usage", shell_output("#{bin}/clrc --help 2>&1", 1)
  end
end
