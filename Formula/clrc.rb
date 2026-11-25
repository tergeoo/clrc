class Clrc < Formula
  desc "Claude Remote Control — use Claude CLI on your Mac from your iPhone"
  homepage "https://github.com/tergeoo/clrc"
  version "2.2.0"
  license "MIT"

  on_macos do
    on_arm do
      url "https://github.com/tergeoo/clrc/releases/download/v#{version}/clrc-darwin-arm64"
      sha256 "0ef2a448aeb25d0abb80b64979fd42e73098d6e523ceb87ffe2cf28b96de51de"
    end
    on_intel do
      url "https://github.com/tergeoo/clrc/releases/download/v#{version}/clrc-darwin-amd64"
      sha256 "83d9c618a50966c5ec775c4849b12310b9804dce286095bdbc771dfe0edd6590"
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
