.PHONY: relay agent relay-init agent-init install uninstall app logs relay-logs status build-relay build-agent build release help

INSTALL_DIR ?= /usr/local/bin

# ── Quick start ───────────────────────────────────────────────────────────────

## Build agent and install to /usr/local/bin/clrc
install: build-agent
	@if [ -w "$(INSTALL_DIR)" ]; then \
		cp /tmp/clrc $(INSTALL_DIR)/clrc; \
	else \
		sudo cp /tmp/clrc $(INSTALL_DIR)/clrc; \
	fi
	@echo "✅ clrc installed → $(INSTALL_DIR)/clrc"
	@echo ""
	@echo "Next: configure and start"
	@echo "  make config   # create ~/.config/clrc/.env"
	@echo "  clrc start"

## Open ~/.config/clrc/.env in $EDITOR
edit:
	@test -f ~/.config/clrc/.env || (echo "No config found. Run: make config" && exit 1)
	@$${EDITOR:-nano} ~/.config/clrc/.env

## Set a single config value: make set KEY=RELAY_URL VALUE=wss://...
set:
	@test -n "$(KEY)" || (echo "Usage: make set KEY=RELAY_URL VALUE=wss://..." && exit 1)
	@test -n "$(VALUE)" || (echo "Usage: make set KEY=RELAY_URL VALUE=wss://..." && exit 1)
	@test -f ~/.config/clrc/.env || (mkdir -p ~/.config/clrc && touch ~/.config/clrc/.env && chmod 600 ~/.config/clrc/.env)
	@if grep -q '^$(KEY)=' ~/.config/clrc/.env 2>/dev/null; then \
		sed -i '' 's|^$(KEY)=.*|$(KEY)="$(VALUE)"|' ~/.config/clrc/.env; \
	else \
		echo '$(KEY)="$(VALUE)"' >> ~/.config/clrc/.env; \
	fi
	@echo "✅ $(KEY) updated"
	@grep '^$(KEY)=' ~/.config/clrc/.env

## Show current config
show:
	@test -f ~/.config/clrc/.env && cat ~/.config/clrc/.env || echo "No config at ~/.config/clrc/.env"

## Create ~/.config/clrc/.env interactively
config:
	@mkdir -p ~/.config/clrc
	@if [ -f ~/.config/clrc/.env ]; then \
		echo "Config already exists: ~/.config/clrc/.env"; \
		cat ~/.config/clrc/.env; \
	else \
		printf "Relay URL (e.g. wss://my-relay.up.railway.app): "; \
		read relay; \
		printf "Agent secret: "; \
		read secret; \
		printf "Agent name [%s]: " "$$(hostname)"; \
		read name; \
		[ -z "$$name" ] && name=$$(hostname); \
		printf 'RELAY_URL="%s"\nAGENT_SECRET="%s"\nAGENT_NAME="%s"\nDEFAULT_COMMAND="bash"\n' \
			"$$relay" "$$secret" "$$name" > ~/.config/clrc/.env; \
		chmod 600 ~/.config/clrc/.env; \
		echo "✅ Config written: ~/.config/clrc/.env"; \
	fi

# ── Development ───────────────────────────────────────────────────────────────

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
dev: relay-init agent-init
	@./scripts/start-relay.sh &
	@sleep 2
	@./scripts/start-agent.sh

# ── App bundle ────────────────────────────────────────────────────────────────

## Build "CLRC.app" — double-clickable macOS app
app: build-agent
	@sh scripts/make-app.sh /tmp/clrc

# ── Installation ──────────────────────────────────────────────────────────────

## Remove launchd service and binary
uninstall:
	@./scripts/uninstall-agent.sh

# ── Logs & status ─────────────────────────────────────────────────────────────

## Tail agent logs
logs:
	@tail -f /tmp/clrc.log

## Tail relay logs
relay-logs:
	@tail -f /tmp/claude-relay.log

## Show launchd service status
status:
	@launchctl list | grep com.clrc || echo "(not running)"
	@echo ""
	@clrc status 2>/dev/null || true

# ── Build ─────────────────────────────────────────────────────────────────────

## Build relay binary → /tmp/claude-relay
build-relay:
	@cd relay && go build -o /tmp/claude-relay ./cmd/ && echo "✅ relay → /tmp/claude-relay"

## Build agent binary → /tmp/clrc
build-agent:
	@cd agent && go build -o /tmp/clrc ./cmd/ && echo "✅ agent → /tmp/clrc"

## Build both
build: build-relay build-agent

## Tag and push a release (triggers GitHub Actions to build binaries)
## Usage: make release VERSION=v1.2.3
release:
	@test -n "$(VERSION)" || (echo "Usage: make release VERSION=v1.2.3" && exit 1)
	@git tag "$(VERSION)"
	@git push origin "$(VERSION)"
	@echo "✅ Tag $(VERSION) pushed — GitHub Actions will build binaries"

# ── Help ──────────────────────────────────────────────────────────────────────

help:
	@echo ""
	@echo "clrc — Claude Remote Control"
	@echo "════════════════════════════════════════════"
	@echo ""
	@echo "Install from source:"
	@echo "  make install          Build + install to /usr/local/bin"
	@echo "  make config           Create ~/.config/clrc/.env interactively"
	@echo "  clrc start            Start daemon"
	@echo ""
	@echo "Config:"
	@echo "  make show             Print current config"
	@echo "  make edit             Open config in \$$EDITOR"
	@echo "  make set KEY=RELAY_URL VALUE=wss://...  Set one value"
	@echo ""
	@echo "Install binary (no build required):"
	@echo "  curl -fsSL https://raw.githubusercontent.com/tergeoo/clrc/main/install.sh | sh"
	@echo ""
	@echo "Install via Homebrew:"
	@echo "  brew install --cask tergeoo/clrc/clrc"
	@echo ""
	@echo "Dev commands:"
	@echo "  make relay-init       Create relay/.env"
	@echo "  make agent-init       Create agent/.env"
	@echo "  make dev              Start relay + agent (foreground)"
	@echo "  make relay            Start relay only"
	@echo "  make agent            Start agent only"
	@echo "  make build            Build both binaries to /tmp/"
	@echo "  make app              Build CLRC.app (double-clickable)"
	@echo "  make logs             Tail /tmp/clrc.log"
	@echo "  make relay-logs       Tail relay logs"
	@echo "  make status           Show service status"
	@echo "  make uninstall        Remove launchd service"
	@echo "  make release VERSION=v1.2.3"
	@echo ""
