# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

**clrc** (Claude Remote Control) lets you drive the `claude` CLI (or `bash`) running on a Mac from an iPhone. Three components connected by WebSockets:

```
iPhone (SwiftUI) ──WS──▶ Relay (Go) ◀──WS── clrc agent (Go daemon on Mac)
                                                  │ PTY
                                                  ▼
                                            claude / bash
```

- **`relay/`** — Go HTTP/WebSocket server. Routes traffic between iOS clients and Mac agents. Stateless except for in-memory connection/session maps. Deployed once (Railway/fly.io/local) and shared.
- **`agent/`** — Go daemon that runs on each Mac. Connects *out* to the relay (so no inbound ports needed), spawns PTY sessions, and streams terminal I/O. Ships as the `clrc` CLI binary.
- **`Claude Orchestrator.iOS/`** — SwiftUI iPhone app (Xcode project, iOS 26). 2.0 shell:
  tab bar Входящие · Ревью · Проекты · Настройки (`Shell/`), sessions pushed full screen via
  `SessionRoute`; Inbox (`Inbox/`, `InboxModel` → `InboxContent` → pure `InboxScreen`), New Task
  sheet (`NewTask/`), shared look in `DesignSystem/` (palette, `StatusIcon`, `.cardStyle()`).
  Testable logic lives in the local SwiftPM package `Claude Orchestrator.iOS/ClrcCore`
  (`swift test`): session status, inbox sections, tool labels, answer undo queue, launch
  planning; the app persists sessions locally and auto-reattaches on launch. Debug builds
  accept `-designPreview <normal|answered|offline|macoffline|empty|loading|newtask>` to render
  screens over fixtures without a relay. Redesign spec/mockups: `docs/design/2.0.0/`.
- **`mac-installer/`** — one-click macOS menu-bar installer (Tailscale topology).
  `ClrcInstallerCore` is a standalone SwiftPM package holding all the tested logic
  behind a mockable `CommandRunner` boundary (join/pair `clrc://` deep links,
  CSPRNG secrets + Keychain, Tailscale/agent/relay orchestration, hub & satellite
  setup state machines, iCloud sync) — `swift test`. The SwiftUI app shell
  (`ClrcInstaller`, Xcode project) and distribution scripts live alongside; the
  app shell, iOS scan-to-pair, signing/notarization, and `clrc-app` cask are still
  to be built. Design/plan: `docs/superpowers/{specs,plans}/2026-07-08-mac-installer*`.

> Naming note: the product is **clrc**, but the repo dir, Go module paths (`github.com/claude-orchestrator/...`), and the iOS folder still use the older "claude-orchestrator" / "Claude Orchestrator" name. The CLI binary is `clrc`.

## Build / run / test

Two independent Go modules (`relay/`, `agent/`) — there is no workspace root, so `go` commands must run inside each module dir. Use the Makefile from the repo root:

```sh
make build            # build both → /tmp/claude-relay and /tmp/clrc
make build-relay      # relay only
make build-agent      # agent (clrc) only
make install          # build agent + copy to /usr/local/bin/clrc

# tests / vet (run inside a module dir; relay currently has no _test.go files)
cd relay && go test -race ./... && go vet ./...
cd agent && go test -race ./... && go vet ./...

# iOS logic tests
cd "Claude Orchestrator.iOS/ClrcCore" && swift test
```

Local dev (relay + agent on the same Mac):

```sh
make relay-init       # create relay/.env from .env.example
make agent-init       # create agent/.env from .env.example
make relay            # start relay on :8080 (scripts/start-relay.sh)
make agent            # start agent (scripts/start-agent.sh)
make dev              # both in foreground

make logs             # tail /tmp/clrc.log (agent)
make relay-logs       # tail /tmp/claude-relay.log
make status           # launchctl status + clrc status
```

The agent as an installed daemon is controlled via the CLI itself: `clrc start|stop|restart|status|logs|sessions|attach`. Config lives at `~/.config/clrc/.env` and is managed with `clrc config --relay-url ... --secret ... --name ... --command ...` (or `make set KEY=... VALUE=...`).

**iOS:** open `Claude Orchestrator.iOS/Claude Orchestrator.xcodeproj` in Xcode, build to a device. The default relay URL comes from the `RELAY_URL` key in `Info.plist`.

## Architecture details worth knowing before editing

### The message protocol (the contract between all three components)

Every text control message is a JSON envelope `{ "type": string, "payload": <raw json> }`. This `Message` struct is **defined separately in three places** and must be kept in sync:
- `relay/session.go`
- `agent/ws_client.go`
- the iOS `RelayWebSocket` service

There is no shared `proto` package (an older `proto/messages.go` was removed). When you add or change a message type, update all three.

**Two transport channels on the same socket:**
- **Text frames** = control messages (`register`, `auth`, `connect`, `resize`, `disconnect`, `detach`, `list_sessions`, `fs_*`, `agent_list`, `session_ready`, `error`, `*_result`).
- **Binary frames** = raw terminal bytes, wrapped in a custom framing: `[4-byte big-endian session_id length][session_id][payload]`. See `encodeBinaryFrame`/`decodeBinaryFrame`, duplicated in both `relay/hub.go` and `agent/ws_client.go`.
- `connect` carries an optional `name` (session display name). The agent persists it
  (`agent/session_store.go`) and returns `name`, `command`, `started` (RFC3339) per entry
  in `sessions_list`. All fields are optional — old clients/agents interoperate.

### Structured output (chat mode)

- Chat replies use a Claude Code output style (`clrc-chat` / `clrc-brief`, kept in the user's Claude config) and end with a ```` ```clrc-report ```` JSON block. `agent/turn_tracker.go` + `agent/turn_report.go` strip the `**header**` line and the block from the text and emit a `report` event (`v, status, title, summary, questions, next_steps, changed_files, header, context_ok, source`) right before `turn_end`, with a fallback report when the block is missing.
- Agent env: `CLRC_PROFILE` (→ `CLAUDE_CONFIG_DIR=~/.claude-<profile>`), `CLRC_CLAUDE_CONFIG_DIR` (explicit dir, wins), `CLRC_OUTPUT_STYLE` (default `clrc-chat`, empty = none), `CLRC_EXPECTED_HEADER_PREFIX` (gates `context_ok`). Every spawned process gets `CLRC_SESSION=1`.
- Chat `connect` takes optional `profile` and `style` overriding those defaults per session. Full contract: section 13 of `docs/superpowers/specs/2026-08-15-chat-mode-design.md`.

### Relay routing (`relay/hub.go`)

- The `Hub` runs a single goroutine (`Run()`) that owns register/unregister via channels; all map access is guarded by `Hub.mu`. Connection writes go through per-conn mutexes (`AgentConn.Send`, `ClientConn.Send`).
- A `Session` ties one `session_id` to one (agent, client) pair. Binary frames are routed by looking up the session and forwarding to the other side.
- **Async request/response** (`list_sessions`, `fs_list`, `fs_mkdir`, `fs_delete`, `fs_read`) uses a `request_id` correlation: the relay stores `request_id → ClientConn` in `pendingRequests` (a `sync.Map`), forwards to the agent, and matches the agent's `*_result` reply back to the waiting client. The relay strips `agent_id` before forwarding to the agent.
- **Connection lifecycle is asymmetric on purpose:** when a *client* drops unexpectedly, the relay sends `detach` to the agent — the PTY stays alive so the session survives reconnect. An explicit `disconnect` from the client *kills* the PTY. Preserve this distinction.

### Agent / PTY lifecycle (`agent/ws_client.go`, `agent/pty_session.go`, `agent/session_store.go`)

- The agent dials *out* to `RELAY_URL + "/ws/agent"` and maintains the connection with exponential backoff (1s→60s, reset after a >10s healthy connection — handles laptop sleep/wake). A 30s ping drives reconnect on failure.
- On `connect`, if the `session_id` already exists the agent **reattaches** (re-points the send fn, resizes) instead of spawning a new PTY. This is what makes sessions survive client reconnects.
- `session_store.go` persists live-session metadata (PID, command, dims) to disk so `clrc sessions` / `clrc attach` can find them from a separate process. `CleanStaleSessions()` runs on startup. `clrc attach` uses `reptyr` (+ `tmux` if present) to grab a running PTY into your terminal.
- Agent identity: `AGENT_ID` is auto-generated as a UUID and persisted to `~/.config/clrc/id` on first run (`loadOrCreateAgentID`). The relay validates a lowercase UUID — keep IDs lowercase.

### Auth (`relay/auth.go`)

- iOS clients log in via `POST /auth/login` (password = `ADMIN_PASSWORD`) → JWT access + refresh tokens; `/auth/refresh` rotates. The client WS handshake's first message must be `auth` carrying the access token.
- Mac agents authenticate with a shared `AGENT_SECRET` in their first `register` message. Login is rate-limited per IP.

### Required relay env vars (`relay/cmd/main.go` fails fast if missing)

`JWT_SECRET`, `ADMIN_PASSWORD`, `AGENT_SECRET`. Optional `PORT` (default `8080`). Optional `TLS_CERT_FILE` + `TLS_KEY_FILE` (set both) → relay serves https/wss directly via `ListenAndServeTLS`; leave unset when TLS is terminated upstream (Railway/Cloudflare) or the relay is only on a private network (Tailscale). Remote-access topologies: `docs/REMOTE-ACCESS.md`.

## Conventions / constraints

- **Security limits live in the relay and agent and are deliberate** — don't remove them: 4 MB max WS message, agent/client connection caps, UUID-v4 session-id validation, agent-id/name length caps, login rate limiting. Filesystem ops (`agent/fs_ops.go`) resolve `~`/relative paths and **reject anything outside the user's home dir**; file reads are capped at 100 KB.
- WebSocket library: `nhooyr.io/websocket` on both Go sides. All network calls use `context.Context` with timeouts.
- The relay deploys via Docker (`relay/docker/Dockerfile`); release binaries are built by `.github/workflows/release.yml` on a `vX.Y.Z` tag (`make release VERSION=v1.2.3`). Homebrew formula/cask live in `Formula/` and `Casks/`.

## Project rules

This repo ships rule files under `.claude/rules/` (common + Go specifics). Key points: gofmt/goimports mandatory, wrap errors with `%w` and context, table-driven tests run with `-race`, small interfaces, secrets only from env. The `agent/` module and the iOS `ClrcCore` package now have automated tests (`go test -race ./...` and `swift test`, respectively); `relay/` still has none — adding relay tests (and keeping the three `Message` definitions in sync via tests) is the highest-value remaining testing gap.
