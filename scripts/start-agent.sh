#!/bin/bash
# Start the agent locally for development.
# Reads config from agent/.env (copy from agent/.env.example).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENT_DIR="$SCRIPT_DIR/../agent"
ENV_FILE="$AGENT_DIR/.env"

# Load .env if it exists
if [ -f "$ENV_FILE" ]; then
    set -a
    # shellcheck disable=SC1090
    source "$ENV_FILE"
    set +a
else
    echo "⚠️  agent/.env not found."
    echo "   Copy agent/.env.example → agent/.env and fill in the values."
    echo ""
    echo "   Quick start:"
    echo "     cp agent/.env.example agent/.env"
    echo "     \$EDITOR agent/.env"
    echo "     make agent"
    exit 1
fi

: "${RELAY_URL:?RELAY_URL is required in agent/.env}"
: "${AGENT_SECRET:?AGENT_SECRET is required in agent/.env}"

echo "🔄 Building agent..."
cd "$AGENT_DIR"
go build -o /tmp/clrc ./cmd/ 2>&1

echo "🚀 Agent starting (relay: ${RELAY_URL}, name: ${AGENT_NAME:-$(hostname)})"
echo ""
exec /tmp/clrc
