#!/bin/bash
# Build and run the Mac agent locally.
# Usage: ./scripts/start-agent.sh [path/to/config.yaml]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENT_DIR="$SCRIPT_DIR/../agent"
CONFIG="${1:-$HOME/.config/claude-agent/config.yaml}"

echo "🔄 Building agent..."
cd "$AGENT_DIR"
go build -o /tmp/claude-agent . 2>&1

# First-time setup: init config if missing
if [ ! -f "$CONFIG" ]; then
    echo ""
    echo "⚙️  No config found at: $CONFIG"
    echo "   Initializing with defaults..."
    echo ""
    /tmp/claude-agent --init --config "$CONFIG"
    echo ""
    echo "✅ Config created at: $CONFIG"
    echo ""
    echo "Next steps:"
    echo "  1. Edit the config:  \$EDITOR $CONFIG"
    echo "     - Set relay_url to your relay server (e.g. wss://your-relay.up.railway.app)"
    echo "     - Set secret to match AGENT_SECRET in your relay .env"
    echo "  2. Re-run:  ./scripts/start-agent.sh"
    exit 0
fi

echo "🚀 Starting agent (config: $CONFIG)"
echo ""
exec /tmp/claude-agent --config "$CONFIG"
