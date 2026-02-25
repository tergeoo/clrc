#!/bin/sh
# Claude Agent — Universal Installer
# Usage: curl -fsSL https://raw.githubusercontent.com/vrtoursuz/claude-orchestrator/main/install.sh | sh
# Or with options:
#   curl -fsSL .../install.sh | sh -s -- --relay wss://my-relay.com --secret mysecret
set -e

REPO="vrtoursuz/claude-orchestrator"
BINARY="claude-agent"
INSTALL_DIR="/usr/local/bin"
CONFIG_DIR="$HOME/.config/claude-agent"
CONFIG_FILE="$CONFIG_DIR/config.yaml"

# ── Colours ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BOLD='\033[1m'; NC='\033[0m'
info()    { printf "${BOLD}[claude-agent]${NC} %s\n" "$*"; }
success() { printf "${GREEN}✓${NC} %s\n" "$*"; }
warn()    { printf "${YELLOW}⚠${NC} %s\n" "$*"; }
die()     { printf "${RED}✗${NC} %s\n" "$*" >&2; exit 1; }

# ── Detect OS & arch ─────────────────────────────────────────────────────────
OS="$(uname -s)"
ARCH="$(uname -m)"

case "$OS" in
  Darwin) GOOS="darwin" ;;
  Linux)  GOOS="linux"  ;;
  *)      die "Unsupported OS: $OS. Only macOS and Linux are supported." ;;
esac

case "$ARCH" in
  x86_64|amd64) GOARCH="amd64" ;;
  arm64|aarch64) GOARCH="arm64" ;;
  *) die "Unsupported architecture: $ARCH" ;;
esac

ASSET_NAME="claude-agent-${GOOS}-${GOARCH}"

info "Detected: $OS / $ARCH"

# ── Parse arguments ───────────────────────────────────────────────────────────
RELAY_URL=""
AGENT_SECRET=""
AGENT_NAME=""

while [ $# -gt 0 ]; do
  case "$1" in
    --relay)  RELAY_URL="$2";    shift 2 ;;
    --secret) AGENT_SECRET="$2"; shift 2 ;;
    --name)   AGENT_NAME="$2";   shift 2 ;;
    *) warn "Unknown option: $1"; shift ;;
  esac
done

# ── Find latest release ───────────────────────────────────────────────────────
info "Fetching latest release from GitHub..."
API_URL="https://api.github.com/repos/${REPO}/releases/latest"

if command -v curl >/dev/null 2>&1; then
  RELEASE_JSON="$(curl -fsSL "$API_URL")"
elif command -v wget >/dev/null 2>&1; then
  RELEASE_JSON="$(wget -qO- "$API_URL")"
else
  die "curl or wget is required"
fi

# Extract download URL for our asset
DOWNLOAD_URL="$(printf '%s' "$RELEASE_JSON" | grep -o "\"browser_download_url\": *\"[^\"]*${ASSET_NAME}[^\"]*\"" | head -1 | sed 's/.*": *"\(.*\)"/\1/')"

if [ -z "$DOWNLOAD_URL" ]; then
  die "No binary found for ${ASSET_NAME} in latest release.\nCheck: https://github.com/${REPO}/releases"
fi

VERSION="$(printf '%s' "$RELEASE_JSON" | grep -o '"tag_name": *"[^"]*"' | head -1 | sed 's/.*": *"\(.*\)"/\1/')"
info "Installing version: $VERSION"

# ── Download binary ───────────────────────────────────────────────────────────
TMP_BIN="$(mktemp)"
info "Downloading $ASSET_NAME..."

if command -v curl >/dev/null 2>&1; then
  curl -fsSL --progress-bar -o "$TMP_BIN" "$DOWNLOAD_URL"
elif command -v wget >/dev/null 2>&1; then
  wget -q --show-progress -O "$TMP_BIN" "$DOWNLOAD_URL"
fi

chmod +x "$TMP_BIN"

# ── Install binary ────────────────────────────────────────────────────────────
# Try /usr/local/bin first, fall back to ~/bin
if [ -w "$INSTALL_DIR" ] || sudo -n true 2>/dev/null; then
  if [ ! -w "$INSTALL_DIR" ]; then
    info "Installing to $INSTALL_DIR (sudo required)..."
    sudo mv "$TMP_BIN" "$INSTALL_DIR/$BINARY"
    sudo chmod +x "$INSTALL_DIR/$BINARY"
  else
    mv "$TMP_BIN" "$INSTALL_DIR/$BINARY"
  fi
else
  INSTALL_DIR="$HOME/.local/bin"
  mkdir -p "$INSTALL_DIR"
  mv "$TMP_BIN" "$INSTALL_DIR/$BINARY"
  warn "Installed to $INSTALL_DIR (add to PATH if needed)"
fi

success "Binary installed: $(which $BINARY 2>/dev/null || echo "$INSTALL_DIR/$BINARY")"

# ── Configure ─────────────────────────────────────────────────────────────────
mkdir -p "$CONFIG_DIR"

if [ -f "$CONFIG_FILE" ]; then
  warn "Config already exists at $CONFIG_FILE — skipping."
else
  # Prompt for relay URL if not provided
  if [ -z "$RELAY_URL" ]; then
    printf "${BOLD}Relay URL${NC} (e.g. wss://my-relay.up.railway.app): "
    read -r RELAY_URL
  fi
  if [ -z "$RELAY_URL" ]; then
    RELAY_URL="wss://your-relay.up.railway.app"
    warn "No relay URL provided, using placeholder. Edit $CONFIG_FILE to set it."
  fi

  # Prompt for secret if not provided
  if [ -z "$AGENT_SECRET" ]; then
    printf "${BOLD}Agent secret${NC} (must match AGENT_SECRET on relay): "
    read -r AGENT_SECRET
  fi
  if [ -z "$AGENT_SECRET" ]; then
    die "Agent secret is required. Re-run with --secret <value>"
  fi

  # Auto-detect name
  if [ -z "$AGENT_NAME" ]; then
    AGENT_NAME="$(hostname 2>/dev/null || echo "my-machine")"
  fi

  # Generate a stable agent ID
  AGENT_ID="$(cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen 2>/dev/null || od -x /dev/urandom | head -1 | awk '{OFS="-"; print $2$3,$4,$5,$6,$7$8$9}')"

  cat > "$CONFIG_FILE" <<YAML
agent_id: "${AGENT_ID}"
name: "${AGENT_NAME}"
secret: "${AGENT_SECRET}"
relay_url: "${RELAY_URL}"
default_command: "bash"
YAML
  chmod 600 "$CONFIG_FILE"
  success "Config written: $CONFIG_FILE"
fi

# ── Install as service ────────────────────────────────────────────────────────
install_launchd() {
  PLIST="$HOME/Library/LaunchAgents/com.claude.agent.plist"
  BINARY_PATH="$(which $BINARY 2>/dev/null || echo "$INSTALL_DIR/$BINARY")"
  cat > "$PLIST" <<XML
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>             <string>com.claude.agent</string>
  <key>ProgramArguments</key>
  <array>
    <string>${BINARY_PATH}</string>
    <string>--config</string>
    <string>${CONFIG_FILE}</string>
  </array>
  <key>RunAtLoad</key>         <true/>
  <key>KeepAlive</key>         <true/>
  <key>StandardOutPath</key>   <string>/tmp/claude-agent.log</string>
  <key>StandardErrorPath</key> <string>/tmp/claude-agent.log</string>
</dict>
</plist>
XML
  launchctl unload "$PLIST" 2>/dev/null || true
  launchctl load -w "$PLIST"
  success "Installed as launchd service (auto-starts on login)"
  info "Logs: tail -f /tmp/claude-agent.log"
}

install_systemd() {
  BINARY_PATH="$(which $BINARY 2>/dev/null || echo "$INSTALL_DIR/$BINARY")"
  SERVICE_FILE="$HOME/.config/systemd/user/claude-agent.service"
  mkdir -p "$(dirname "$SERVICE_FILE")"
  cat > "$SERVICE_FILE" <<UNIT
[Unit]
Description=Claude Agent
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=${BINARY_PATH} --config ${CONFIG_FILE}
Restart=always
RestartSec=5
StandardOutput=append:/tmp/claude-agent.log
StandardError=append:/tmp/claude-agent.log

[Install]
WantedBy=default.target
UNIT
  systemctl --user daemon-reload
  systemctl --user enable --now claude-agent
  success "Installed as systemd user service (auto-starts on login)"
  info "Status: systemctl --user status claude-agent"
  info "Logs:   journalctl --user -u claude-agent -f"
}

install_system_systemd() {
  # For servers running as root / system service
  BINARY_PATH="$(which $BINARY 2>/dev/null || echo "$INSTALL_DIR/$BINARY")"
  SERVICE_FILE="/etc/systemd/system/claude-agent.service"
  sudo tee "$SERVICE_FILE" > /dev/null <<UNIT
[Unit]
Description=Claude Agent
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=${BINARY_PATH} --config ${CONFIG_FILE}
Restart=always
RestartSec=5
StandardOutput=append:/tmp/claude-agent.log
StandardError=append:/tmp/claude-agent.log

[Install]
WantedBy=multi-user.target
UNIT
  sudo systemctl daemon-reload
  sudo systemctl enable --now claude-agent
  success "Installed as system-wide systemd service"
  info "Status: sudo systemctl status claude-agent"
  info "Logs:   sudo journalctl -u claude-agent -f"
}

# Determine service manager
if [ "$GOOS" = "darwin" ]; then
  install_launchd
elif [ "$GOOS" = "linux" ]; then
  if command -v systemctl >/dev/null 2>&1; then
    # If running as root or on a server, install system-wide; otherwise user service
    if [ "$(id -u)" = "0" ]; then
      install_system_systemd
    else
      install_systemd
    fi
  else
    warn "systemd not found. Start agent manually:"
    info "  $BINARY --config $CONFIG_FILE"
  fi
fi

# ── Done ──────────────────────────────────────────────────────────────────────
printf "\n${GREEN}${BOLD}Installation complete!${NC}\n"
printf "\nThe agent will connect to your relay and appear as '${BOLD}$(grep 'name:' "$CONFIG_FILE" | awk '{print $2}')${NC}' in the iOS app.\n"
printf "\nTo check status:\n"
if [ "$GOOS" = "darwin" ]; then
  printf "  launchctl list | grep claude\n"
  printf "  tail -f /tmp/claude-agent.log\n"
else
  printf "  systemctl --user status claude-agent\n"
  printf "  tail -f /tmp/claude-agent.log\n"
fi
printf "\nTo uninstall:\n"
if [ "$GOOS" = "darwin" ]; then
  printf "  launchctl unload ~/Library/LaunchAgents/com.claude.agent.plist\n"
  printf "  rm ~/Library/LaunchAgents/com.claude.agent.plist\n"
else
  printf "  systemctl --user disable --now claude-agent\n"
fi
printf "  rm \$(which claude-agent)\n"
printf "\n"
