#!/bin/sh
# CLRC — Universal Installer
# Usage: curl -fsSL https://raw.githubusercontent.com/vrtoursuz/claude-orchestrator/main/install.sh | sh
# Or with options:
#   curl -fsSL .../install.sh | sh -s -- --relay wss://my-relay.com --secret mysecret
set -e

REPO="tergeoo/clrc"
BINARY="clrc"
INSTALL_DIR="/usr/local/bin"
CONFIG_DIR="$HOME/.config/clrc"
CONFIG_FILE="$CONFIG_DIR/.env"

# ── Colours ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BOLD='\033[1m'; NC='\033[0m'
info()    { printf "${BOLD}[clrc]${NC} %s\n" "$*"; }
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

ASSET_NAME="clrc-${GOOS}-${GOARCH}"

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

  cat > "$CONFIG_FILE" <<ENV
AGENT_ID="${AGENT_ID}"
AGENT_NAME="${AGENT_NAME}"
AGENT_SECRET="${AGENT_SECRET}"
RELAY_URL="${RELAY_URL}"
DEFAULT_COMMAND="bash"
ENV
  chmod 600 "$CONFIG_FILE"
  success "Config written: $CONFIG_FILE"
fi

# ── Install as service ────────────────────────────────────────────────────────
install_launchd() {
  PLIST="$HOME/Library/LaunchAgents/com.clrc.plist"
  BINARY_PATH="$(which $BINARY 2>/dev/null || echo "$INSTALL_DIR/$BINARY")"
  # Read values from config file
  . "$CONFIG_FILE"
  cat > "$PLIST" <<XML
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>             <string>com.clrc</string>
  <key>ProgramArguments</key>
  <array>
    <string>${BINARY_PATH}</string>
  </array>
  <key>RunAtLoad</key>         <true/>
  <key>KeepAlive</key>         <true/>
  <key>ThrottleInterval</key>  <integer>10</integer>
  <key>StandardOutPath</key>   <string>/tmp/clrc.log</string>
  <key>StandardErrorPath</key> <string>/tmp/clrc.log</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>HOME</key>            <string>${HOME}</string>
    <key>PATH</key>            <string>/usr/local/bin:/usr/bin:/bin:/opt/homebrew/bin:/opt/homebrew/sbin</string>
    <key>TERM</key>            <string>xterm-256color</string>
    <key>LANG</key>            <string>en_US.UTF-8</string>
    <key>AGENT_ID</key>        <string>${AGENT_ID}</string>
    <key>AGENT_NAME</key>      <string>${AGENT_NAME}</string>
    <key>AGENT_SECRET</key>    <string>${AGENT_SECRET}</string>
    <key>RELAY_URL</key>       <string>${RELAY_URL}</string>
    <key>DEFAULT_COMMAND</key> <string>${DEFAULT_COMMAND}</string>
  </dict>
</dict>
</plist>
XML
  chmod 600 "$PLIST"
  launchctl unload "$PLIST" 2>/dev/null || true
  launchctl load -w "$PLIST"
  success "Installed as launchd service (auto-starts on login)"
  info "Logs: tail -f /tmp/clrc.log"
}

install_systemd() {
  BINARY_PATH="$(which $BINARY 2>/dev/null || echo "$INSTALL_DIR/$BINARY")"
  SERVICE_FILE="$HOME/.config/systemd/user/clrc.service"
  mkdir -p "$(dirname "$SERVICE_FILE")"
  cat > "$SERVICE_FILE" <<UNIT
[Unit]
Description=CLRC
After=network-online.target
Wants=network-online.target

[Service]
EnvironmentFile=${CONFIG_FILE}
ExecStart=${BINARY_PATH}
Restart=always
RestartSec=5
StandardOutput=append:/tmp/clrc.log
StandardError=append:/tmp/clrc.log

[Install]
WantedBy=default.target
UNIT
  systemctl --user daemon-reload
  systemctl --user enable --now clrc
  success "Installed as systemd user service (auto-starts on login)"
  info "Status: systemctl --user status clrc"
  info "Logs:   journalctl --user -u clrc -f"
}

install_system_systemd() {
  # For servers running as root / system service
  BINARY_PATH="$(which $BINARY 2>/dev/null || echo "$INSTALL_DIR/$BINARY")"
  SERVICE_FILE="/etc/systemd/system/clrc.service"
  sudo tee "$SERVICE_FILE" > /dev/null <<UNIT
[Unit]
Description=CLRC
After=network-online.target
Wants=network-online.target

[Service]
EnvironmentFile=${CONFIG_FILE}
ExecStart=${BINARY_PATH}
Restart=always
RestartSec=5
StandardOutput=append:/tmp/clrc.log
StandardError=append:/tmp/clrc.log

[Install]
WantedBy=multi-user.target
UNIT
  sudo systemctl daemon-reload
  sudo systemctl enable --now clrc
  success "Installed as system-wide systemd service"
  info "Status: sudo systemctl status clrc"
  info "Logs:   sudo journalctl -u clrc -f"
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
    info "  . $CONFIG_FILE && $BINARY"
  fi
fi

# ── Done ──────────────────────────────────────────────────────────────────────
printf "\n${GREEN}${BOLD}Installation complete!${NC}\n"
printf "\nThe agent will connect to your relay and appear as '${BOLD}${AGENT_NAME}${NC}' in the iOS app.\n"
printf "\nTo check status:\n"
if [ "$GOOS" = "darwin" ]; then
  printf "  launchctl list | grep claude\n"
  printf "  tail -f /tmp/clrc.log\n"
else
  printf "  systemctl --user status clrc\n"
  printf "  tail -f /tmp/clrc.log\n"
fi
printf "\nTo uninstall:\n"
if [ "$GOOS" = "darwin" ]; then
  printf "  launchctl unload ~/Library/LaunchAgents/com.clrc.plist\n"
  printf "  rm ~/Library/LaunchAgents/com.clrc.plist\n"
else
  printf "  systemctl --user disable --now clrc\n"
fi
printf "  rm \$(which clrc)\n"
printf "\n"
