#!/bin/bash
# Install claude-agent as a launchd service (auto-start on login, auto-restart on crash).
# Run once per Mac. Re-run to update the binary.
#
# Usage: ./scripts/install-agent.sh [path/to/config.yaml]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENT_DIR="$SCRIPT_DIR/../agent"
BINARY="/usr/local/bin/claude-agent"
CONFIG="${1:-$HOME/.config/claude-agent/config.yaml}"
PLIST="$HOME/Library/LaunchAgents/com.claude.agent.plist"
LABEL="com.claude.agent"
LOG_FILE="/tmp/claude-agent.log"

# ── 1. Build ────────────────────────────────────────────────────────────────
echo "🔄 Building claude-agent..."
cd "$AGENT_DIR"
go build -o claude-agent .
echo "✅ Build succeeded"

# ── 2. Install binary ───────────────────────────────────────────────────────
echo "📦 Installing binary → $BINARY"
sudo cp claude-agent "$BINARY"
sudo chmod +x "$BINARY"
rm -f claude-agent

# ── 3. First-time config setup ──────────────────────────────────────────────
if [ ! -f "$CONFIG" ]; then
    echo ""
    echo "⚙️  No config found — initializing at $CONFIG"
    "$BINARY" --init --config "$CONFIG"
    echo ""
    echo "⚠️  Edit $CONFIG before continuing:"
    echo "     relay_url: wss://your-relay.up.railway.app"
    echo "     secret:    <same as AGENT_SECRET in relay .env>"
    echo ""
    echo "Then re-run:  ./scripts/install-agent.sh"
    exit 1
fi

# ── 4. Write launchd plist ──────────────────────────────────────────────────
echo "📝 Writing launchd plist → $PLIST"
mkdir -p "$(dirname "$PLIST")"

cat > "$PLIST" << PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${LABEL}</string>

    <key>ProgramArguments</key>
    <array>
        <string>${BINARY}</string>
        <string>--config</string>
        <string>${CONFIG}</string>
    </array>

    <!-- Start on login and keep alive (restart on crash) -->
    <key>RunAtLoad</key>   <true/>
    <key>KeepAlive</key>   <true/>
    <key>ThrottleInterval</key> <integer>10</integer>

    <key>StandardOutPath</key>  <string>${LOG_FILE}</string>
    <key>StandardErrorPath</key><string>${LOG_FILE}</string>

    <key>EnvironmentVariables</key>
    <dict>
        <key>HOME</key>  <string>${HOME}</string>
        <key>TERM</key>  <string>xterm-256color</string>
        <key>LANG</key>  <string>en_US.UTF-8</string>
        <key>PATH</key>  <string>/usr/local/bin:/usr/bin:/bin:/opt/homebrew/bin:/opt/homebrew/sbin</string>
    </dict>
</dict>
</plist>
PLIST_EOF

# ── 5. Load / reload service ─────────────────────────────────────────────────
# Unload silently if already loaded
launchctl unload "$PLIST" 2>/dev/null || true
launchctl load "$PLIST"

echo ""
echo "✅ claude-agent installed and running as launchd service"
echo ""
echo "Useful commands:"
echo "  Logs:      tail -f $LOG_FILE"
echo "  Stop:      launchctl unload $PLIST"
echo "  Start:     launchctl load $PLIST"
echo "  Status:    launchctl list | grep claude"
echo "  Uninstall: ./scripts/uninstall-agent.sh"
