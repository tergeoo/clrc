#!/bin/bash
# Remove claude-agent launchd service and binary.

set -euo pipefail

PLIST="$HOME/Library/LaunchAgents/com.claude.agent.plist"
BINARY="/usr/local/bin/claude-agent"

echo "🛑 Stopping and unloading launchd service..."
launchctl unload "$PLIST" 2>/dev/null && echo "  Service stopped" || echo "  (service was not loaded)"

echo "🗑  Removing files..."
rm -f "$PLIST"  && echo "  Removed $PLIST"
sudo rm -f "$BINARY" && echo "  Removed $BINARY"

echo ""
echo "✅ claude-agent uninstalled."
echo "   Config (~/.config/claude-agent/config.yaml) was kept — remove manually if needed."
