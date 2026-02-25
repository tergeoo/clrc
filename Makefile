.PHONY: relay agent install uninstall logs build-relay build-agent help

# ── Development ──────────────────────────────────────────────────────────────

## Start relay server locally (reads relay/.env)
relay:
	@./scripts/start-relay.sh

## Start Mac agent locally (reads ~/.config/claude-agent/config.yaml)
agent:
	@./scripts/start-agent.sh

## Start relay + agent in parallel (dev only)
dev:
	@./scripts/start-relay.sh &
	@sleep 2
	@./scripts/start-agent.sh

# ── Installation ─────────────────────────────────────────────────────────────

## Install agent as a launchd service (auto-start on login)
install:
	@./scripts/install-agent.sh

## Remove launchd service and binary
uninstall:
	@./scripts/uninstall-agent.sh

# ── Logs & status ────────────────────────────────────────────────────────────

## Tail agent logs
logs:
	@tail -f /tmp/claude-agent.log

## Show launchd service status
status:
	@launchctl list | grep claude || echo "(not running)"

# ── Build ────────────────────────────────────────────────────────────────────

## Build relay binary → /tmp/claude-relay
build-relay:
	@cd relay && go build -o /tmp/claude-relay . && echo "✅ relay → /tmp/claude-relay"

## Build agent binary → /tmp/claude-agent
build-agent:
	@cd agent && go build -o /tmp/claude-agent . && echo "✅ agent → /tmp/claude-agent"

## Build both
build: build-relay build-agent

## Build distributable ClaudeAgent.app → dist/ClaudeAgent.zip
dist:
	@./scripts/build-dist.sh

# ── Help ─────────────────────────────────────────────────────────────────────

help:
	@echo ""
	@echo "Claude Orchestrator"
	@echo "────────────────────────────────────────────"
	@echo "  make relay      Start relay locally"
	@echo "  make agent      Start agent locally"
	@echo "  make install    Install agent as launchd service"
	@echo "  make uninstall  Remove launchd service"
	@echo "  make logs       Tail agent logs"
	@echo "  make status     Show service status"
	@echo "  make build      Build both binaries"
	@echo "  make dist       Build ClaudeAgent.app → dist/ClaudeAgent.zip"
	@echo ""
