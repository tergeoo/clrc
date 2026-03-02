#!/bin/sh
# Entrypoint: build config from env vars if no config file is mounted.
set -e

CONFIG_FILE="${CONFIG_FILE:-/agent/config.yaml}"

if [ ! -f "$CONFIG_FILE" ]; then
  # Generate agent_id if not provided
  AGENT_ID="${AGENT_ID:-$(cat /proc/sys/kernel/random/uuid 2>/dev/null || head -c16 /dev/urandom | od -A n -t x | tr -d ' \n')}"
  AGENT_NAME="${AGENT_NAME:-$(hostname)}"
  RELAY_URL="${RELAY_URL:-wss://your-relay.up.railway.app}"
  AGENT_SECRET="${AGENT_SECRET:-}"
  DEFAULT_CMD="${DEFAULT_CMD:-bash}"

  if [ -z "$AGENT_SECRET" ]; then
    echo "ERROR: AGENT_SECRET environment variable is required." >&2
    exit 1
  fi
  if [ -z "$RELAY_URL" ] || [ "$RELAY_URL" = "wss://your-relay.up.railway.app" ]; then
    echo "WARNING: RELAY_URL is not set. Agent will fail to connect." >&2
  fi

  mkdir -p "$(dirname "$CONFIG_FILE")"
  cat > "$CONFIG_FILE" <<YAML
agent_id: "${AGENT_ID}"
name: "${AGENT_NAME}"
secret: "${AGENT_SECRET}"
relay_url: "${RELAY_URL}"
default_command: "${DEFAULT_CMD}"
YAML
  echo "Config written to $CONFIG_FILE"
fi

exec clrc --config "$CONFIG_FILE" "$@"
