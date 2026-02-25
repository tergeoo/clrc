#!/bin/bash
# Build a distributable Claude Agent macOS app.
# Output: dist/ClaudeAgent.zip  (contains ClaudeAgent.app)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$SCRIPT_DIR/.."
AGENT_DIR="$ROOT/agent"
APP_TEMPLATE="$SCRIPT_DIR/ClaudeAgent.app"
DIST_DIR="$ROOT/dist"
APP_OUT="$DIST_DIR/ClaudeAgent.app"
ZIP_OUT="$DIST_DIR/ClaudeAgent.zip"

# ── Build universal binary ────────────────────────────────────────────────────

echo "🔄 Building claude-agent (arm64)..."
cd "$AGENT_DIR"
GOOS=darwin GOARCH=arm64 go build -ldflags="-s -w" -o /tmp/claude-agent-arm64 .

echo "🔄 Building claude-agent (amd64)..."
GOOS=darwin GOARCH=amd64 go build -ldflags="-s -w" -o /tmp/claude-agent-amd64 .

echo "🔗 Creating universal binary..."
lipo -create \
    -output /tmp/claude-agent-universal \
    /tmp/claude-agent-arm64 \
    /tmp/claude-agent-amd64

rm -f /tmp/claude-agent-arm64 /tmp/claude-agent-amd64

# ── Assemble app bundle ───────────────────────────────────────────────────────

echo "📦 Assembling app bundle..."
mkdir -p "$DIST_DIR"
rm -rf "$APP_OUT"
cp -r "$APP_TEMPLATE" "$APP_OUT"

# Place the binary in Resources
cp /tmp/claude-agent-universal "$APP_OUT/Contents/Resources/claude-agent"
chmod +x "$APP_OUT/Contents/Resources/claude-agent"
chmod +x "$APP_OUT/Contents/MacOS/ClaudeAgent"
rm -f /tmp/claude-agent-universal

# ── Code sign (ad-hoc) ────────────────────────────────────────────────────────
# Ad-hoc signing lets the app run on other Macs without a paid Apple developer account.
# Users will need to right-click → Open on first launch (Gatekeeper bypass).
if command -v codesign &>/dev/null; then
    echo "🔏 Ad-hoc signing..."
    codesign --force --deep --sign - "$APP_OUT" 2>/dev/null && echo "   Signed OK" || echo "   (signing skipped)"
fi

# ── Package ───────────────────────────────────────────────────────────────────

mkdir -p "$DIST_DIR"
rm -f "$ZIP_OUT"
cd "$DIST_DIR"
zip -r --quiet "ClaudeAgent.zip" "ClaudeAgent.app"
rm -rf "$APP_OUT"

SIZE=$(du -sh "$ZIP_OUT" | cut -f1)
echo ""
echo "✅ Done: dist/ClaudeAgent.zip ($SIZE)"
echo ""
echo "Send to another Mac, then:"
echo "  1. Unzip"
echo "  2. Right-click ClaudeAgent.app → Open  (first time only, to bypass Gatekeeper)"
echo "  3. Follow the setup dialog"
