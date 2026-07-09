cask "clrc-app" do
  version "1.0.0"
  sha256 :no_check

  url "https://github.com/tergeoo/clrc/releases/download/v#{version}/Clrc.dmg"
  name "clrc Installer"
  desc "Menu-bar app to install and auto-configure clrc on any Mac"
  homepage "https://github.com/tergeoo/clrc"

  depends_on macos: ">= :sonoma"

  app "Clrc.app"

  caveats <<~EOS
    The clrc installer sets up clrc over Tailscale:
      • First Mac  → "Set up the hub" (installs relay + agent, generates a
        pairing QR for your iPhone and a join token for other Macs).
      • Other Macs → "Add this Mac" and paste the join token.

    Requires Tailscale on every device, signed into the same account.
  EOS
end
