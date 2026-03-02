.PHONY: relay agent relay-init agent-init app uninstall logs relay-logs build-relay build-agent build release help

# ── Development ──────────────────────────────────────────────────────────────

## Copy relay/.env.example → relay/.env (first-time setup)
relay-init:
	@test -f relay/.env && echo "relay/.env already exists" || (cp relay/.env.example relay/.env && echo "Created relay/.env — edit it before running make relay")

## Copy agent/.env.example → agent/.env (first-time setup)
agent-init:
	@test -f agent/.env && echo "agent/.env already exists" || (cp agent/.env.example agent/.env && echo "Created agent/.env — edit it before running make agent")

## Start relay server locally (reads relay/.env)
relay:
	@./scripts/start-relay.sh

## Start Mac agent locally (reads agent/.env)
agent:
	@./scripts/start-agent.sh

## Start relay + agent in parallel (dev only)
dev:
	@./scripts/start-relay.sh &
	@sleep 2
	@./scripts/start-agent.sh

# ── App bundle ───────────────────────────────────────────────────────────────

## Build "Claude Agent.app" — double-clickable macOS app
app: build-agent
	@sh scripts/make-app.sh /tmp/claude-agent

# ── Installation ─────────────────────────────────────────────────────────────

## Remove launchd service and binary
uninstall:
	@./scripts/uninstall-agent.sh

# ── Logs & status ────────────────────────────────────────────────────────────

## Tail agent logs
logs:
	@tail -f /tmp/claude-agent.log

## Tail relay logs
relay-logs:
	@tail -f /tmp/claude-relay.log

## Show launchd service status
status:
	@launchctl list | grep claude || echo "(not running)"

# ── Build ────────────────────────────────────────────────────────────────────

## Build relay binary → /tmp/claude-relay
build-relay:
	@cd relay && go build -o /tmp/claude-relay ./cmd/ && echo "✅ relay → /tmp/claude-relay"

## Build agent binary → /tmp/claude-agent
build-agent:
	@cd agent && go build -o /tmp/claude-agent ./cmd/ && echo "✅ agent → /tmp/claude-agent"

## Build both
build: build-relay build-agent

## Tag and push a release (triggers GitHub Actions to build binaries)
## Usage: make release VERSION=v1.2.3
release:
	@test -n "$(VERSION)" || (echo "Usage: make release VERSION=v1.2.3" && exit 1)
	@git tag "$(VERSION)"
	@git push origin "$(VERSION)"
	@echo "✅ Tag $(VERSION) pushed — GitHub Actions will build binaries"

# ── Help ─────────────────────────────────────────────────────────────────────

help:
	@echo ""
	@echo "Claude Orchestrator"
	@echo "────────────────────────────────────────────"
	@echo "  make relay-init  Create relay/.env from example"
	@echo "  make agent-init  Create agent/.env from example"
	@echo "  make relay       Start relay locally"
	@echo "  make agent       Start agent locally"
	@echo "  make uninstall   Remove launchd service"
	@echo "  make logs        Tail agent logs"
	@echo "  make relay-logs  Tail relay logs"
	@echo "  make status      Show service status"
	@echo "  make build       Build both binaries"
	@echo "  make app             Build Claude Agent.app (double-clickable)"
	@echo "  make release VERSION=v1.0.0  Tag + push → triggers CI build"
	@echo ""
