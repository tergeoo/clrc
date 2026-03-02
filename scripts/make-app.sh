#!/bin/sh
# Creates "Claude Agent.app" — a double-clickable macOS app that launches the agent.
# Usage: sh scripts/make-app.sh [/path/to/claude-agent-binary]
set -e

BINARY="${1:-/usr/local/bin/claude-agent}"
APP="Claude Agent.app"

if [ ! -f "$BINARY" ]; then
  # Try ~/.local/bin fallback
  BINARY="$HOME/.local/bin/claude-agent"
fi
if [ ! -f "$BINARY" ]; then
  echo "claude-agent binary not found. Build it first: make build-agent" >&2
  exit 1
fi

echo "Building $APP from $BINARY..."

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

# ── Info.plist ────────────────────────────────────────────────────────────────
cat > "$APP/Contents/Info.plist" <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>    <string>launcher</string>
  <key>CFBundleIdentifier</key>   <string>com.claude.agent</string>
  <key>CFBundleName</key>         <string>Claude Agent</string>
  <key>CFBundleDisplayName</key>  <string>Claude Agent</string>
  <key>CFBundleVersion</key>      <string>1</string>
  <key>CFBundleShortVersionString</key> <string>1.0</string>
  <key>LSUIElement</key>          <true/>
</dict>
</plist>
XML

# ── Embed the binary ──────────────────────────────────────────────────────────
cp "$BINARY" "$APP/Contents/MacOS/claude-agent"
chmod +x "$APP/Contents/MacOS/claude-agent"

# ── Launcher shell script ─────────────────────────────────────────────────────
cat > "$APP/Contents/MacOS/launcher" <<'LAUNCHER'
#!/bin/bash
DIR="$(cd "$(dirname "$0")" && pwd)"
BINARY="$DIR/claude-agent"
CONFIG="$HOME/.config/claude-agent/.env"

notify() { osascript -e "display notification \"$1\" with title \"Claude Agent\"" 2>/dev/null || true; }
ask()    { osascript -e "text returned of (display dialog \"$1\" default answer \"$2\")" 2>/dev/null; }
ask_pw() { osascript -e "text returned of (display dialog \"$1\" default answer \"\" with hidden answer)" 2>/dev/null; }

# Already running?
if pgrep -x claude-agent >/dev/null 2>&1; then
  notify "Already running — check /tmp/claude-agent.log"
  exit 0
fi

# First-run: prompt for config
if [ ! -f "$CONFIG" ]; then
  RELAY=$(ask "Relay URL:" "wss://")
  [ -z "$RELAY" ] && exit 0

  SECRET=$(ask_pw "Agent Secret (must match relay):")
  [ -z "$SECRET" ] && exit 0

  NAME=$(ask "Agent name (shown in iOS app):" "$(hostname -s 2>/dev/null || echo my-mac)")

  mkdir -p "$(dirname "$CONFIG")"
  AGENT_ID="$(uuidgen 2>/dev/null | tr A-Z a-z || od -x /dev/urandom | head -1 | awk '{OFS="-"; print $2$3,$4,$5,$6,$7$8$9}')"
  printf 'AGENT_ID="%s"\nAGENT_NAME="%s"\nAGENT_SECRET="%s"\nRELAY_URL="%s"\nDEFAULT_COMMAND="bash"\n' \
    "$AGENT_ID" "$NAME" "$SECRET" "$RELAY" > "$CONFIG"
  chmod 600 "$CONFIG"
fi

# Load config
. "$CONFIG"
export AGENT_ID AGENT_NAME AGENT_SECRET RELAY_URL DEFAULT_COMMAND

# Launch in background
nohup "$BINARY" >> /tmp/claude-agent.log 2>&1 &
notify "Connecting to relay as \"$AGENT_NAME\"…"
LAUNCHER

chmod +x "$APP/Contents/MacOS/launcher"

echo ""
echo "✅ $APP created"
echo ""
echo "  • Double-click to start the agent"
echo "  • First launch: prompts for relay URL and secret"
echo "  • Runs silently in background (no Dock icon)"
echo "  • Logs: tail -f /tmp/claude-agent.log"
echo ""
echo "Drag to /Applications to keep it permanently."
