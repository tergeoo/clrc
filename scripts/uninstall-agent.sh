#!/bin/bash
# Remove clrc launchd service and binary.

set -euo pipefail

PLIST="$HOME/Library/LaunchAgents/com.clrc.plist"
BINARY="/usr/local/bin/clrc"

echo "🛑 Stopping and unloading launchd service..."
launchctl unload "$PLIST" 2>/dev/null && echo "  Service stopped" || echo "  (service was not loaded)"

echo "🗑  Removing files..."
rm -f "$PLIST"  && echo "  Removed $PLIST"
sudo rm -f "$BINARY" && echo "  Removed $BINARY"

echo ""
echo "✅ clrc uninstalled."
echo "   Config (~/.config/clrc/config.yaml) was kept — remove manually if needed."
