FROM golang:1.23-alpine AS builder

WORKDIR /app
COPY go.mod go.sum ./
RUN go mod download

COPY . .
RUN CGO_ENABLED=0 go build -ldflags="-s -w" -o claude-agent ./cmd/

# ── Runtime image ─────────────────────────────────────────────────────────────
FROM alpine:3.21

RUN apk add --no-cache \
    bash \
    ca-certificates \
    tini

WORKDIR /agent
COPY --from=builder /app/claude-agent /usr/local/bin/claude-agent

# Configuration via environment variables (alternative to config file)
# AGENT_ID      - unique identifier for this machine (auto-generated if empty)
# AGENT_NAME    - display name in iOS app (defaults to hostname)
# AGENT_SECRET  - must match AGENT_SECRET on relay server
# RELAY_URL     - wss://your-relay.example.com
# DEFAULT_CMD   - command to run in PTY (default: bash)

COPY docker/docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

ENTRYPOINT ["tini", "--", "docker-entrypoint.sh"]
