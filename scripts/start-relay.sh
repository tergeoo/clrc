#!/bin/bash
# Start the relay server locally for development.
# Reads config from relay/.env (copy from relay/.env.example).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RELAY_DIR="$SCRIPT_DIR/../relay"
ENV_FILE="$RELAY_DIR/.env"

# Load .env if it exists
if [ -f "$ENV_FILE" ]; then
    set -a
    # shellcheck disable=SC1090
    source "$ENV_FILE"
    set +a
else
    echo "⚠️  relay/.env not found."
    echo "   Copy relay/.env.example → relay/.env and fill in the values."
    echo ""
    echo "   Quick start:"
    echo "     cp relay/.env.example relay/.env"
    echo "     \$EDITOR relay/.env"
    echo "     make relay"
    exit 1
fi

: "${JWT_SECRET:?JWT_SECRET is required in relay/.env}"
: "${ADMIN_PASSWORD:?ADMIN_PASSWORD is required in relay/.env}"
: "${AGENT_SECRET:?AGENT_SECRET is required in relay/.env}"
PORT="${PORT:-8080}"

echo "🔄 Building relay..."
cd "$RELAY_DIR"
go build -o /tmp/claude-relay . 2>&1

echo "🚀 Relay starting on :${PORT}"
echo "   Login password: ${ADMIN_PASSWORD}"
echo "   Agent secret:   ${AGENT_SECRET}"
echo ""
exec /tmp/claude-relay
