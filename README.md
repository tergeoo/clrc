# Claude Orchestrator

Control multiple Macs from your iPhone — interactive Claude Code CLI over WebSocket.

```
iPhone (SwiftUI)
    │  WebSocket / TLS
    ▼
Relay Server  ←── each Mac agent registers here
    │  WebSocket / TLS
    ▼
Mac Agent (Go daemon)
    │  PTY
    ▼
claude CLI process
```

---

## Requirements

| Component | Requirement |
|-----------|-------------|
| Mac agent | Go 1.21+, `claude` CLI installed |
| Relay server | Any Linux host, Docker, or Railway |
| iOS app | Xcode 15+, iOS 17+, SwiftTerm (added via SPM) |

---

## Step 1 — Deploy the relay

The relay is a small Go server that routes traffic between your iPhone and Mac agents.
Deploy it once to the cloud; it stays running permanently.

### Option A: Railway (recommended, free tier works)

1. Fork this repo or push it to GitHub
2. In [Railway](https://railway.app) → **New Project → Deploy from GitHub** → select `relay/`
3. Set environment variables:

| Variable | Value |
|----------|-------|
| `JWT_SECRET` | `openssl rand -hex 32` |
| `ADMIN_PASSWORD` | Password you'll type in the iOS app |
| `AGENT_SECRET` | Secret shared with all Mac agents |

Railway auto-detects the `Dockerfile` and exposes a public URL like `https://your-relay.up.railway.app`.

### Option B: Local development

```bash
# 1. Copy and edit the env file
cp relay/.env.example relay/.env
$EDITOR relay/.env          # fill in JWT_SECRET, ADMIN_PASSWORD, AGENT_SECRET

# 2. Start
make relay
#  → builds relay binary and starts on :8080
```

---

## Step 2 — Install the agent on each Mac

Run this on **every Mac** you want to control.

### Quick install (launchd — auto-start on login)

```bash
# Clone or copy the repo, then:
make install
```

What `make install` does:
1. Builds `claude-agent` and installs it to `/usr/local/bin/`
2. Creates `~/.config/claude-agent/config.yaml` on first run
3. Installs and loads a launchd service (`com.claude.agent`) that starts on login and restarts on crash

**First run** will print the config path and exit — edit it:

```yaml
# ~/.config/claude-agent/config.yaml
agent_id: macbook-pro-home        # unique ID for this Mac (no spaces)
name: MacBook Pro Home            # display name in the iOS app
secret: your-agent-secret        # must match AGENT_SECRET in relay .env
relay_url: wss://your-relay.up.railway.app
default_command: claude           # or "bash" for a plain shell
```

Then re-run `make install` to install with the updated config.

### Development (no launchd, runs in foreground)

```bash
make agent
# builds and starts, auto-inits config on first run
```

### Useful commands

```bash
make logs       # tail -f /tmp/claude-agent.log
make status     # launchctl list | grep claude
make uninstall  # remove service and binary
```

---

## Step 3 — iOS App

1. Open `Claude Orchestrator/Claude Orchestrator.xcodeproj` in Xcode
2. **Add SwiftTerm** via SPM:
   `File → Add Package Dependencies → https://github.com/migueldeicaza/SwiftTerm`
3. Build & run on your device or simulator

**First launch:**
- Enter your relay URL (e.g. `https://your-relay.up.railway.app`)
- Enter `ADMIN_PASSWORD`
- Tap an online Mac → terminal opens

---

## App UX

```
┌─────────────────────────────────────────┐
│  ● MacBook Pro  ○ Mac Mini  +   [⌨][📁] │  ← machines + Terminal/Files toggle
├─────────────────────────────────────────┤
│                                         │
│   Terminal  or  File Browser            │
│                                         │
├─────────────────────────────────────────┤
│  ↑  ↓  Tab  Ctrl+C  ✦ claude  ⚠ claude │  ← quick commands
└─────────────────────────────────────────┘
```

- **Switch machines** — tap the machine pill
- **Switch view** — tap `⌨` (terminal) or `📁` (file browser)
- **Browse files** — navigate directories, create folders, read files, delete
- **Launch Claude** — "Claude here" button in file browser → opens a terminal in that directory
- **Dangerous mode** — sends `claude --dangerously-skip-permissions`

---

## Protocol

### Control messages (JSON)

| Direction | Type | Payload |
|-----------|------|---------|
| agent → relay | `register` | `{agent_id, name, secret}` |
| client → relay | `auth` | `{token}` |
| client → relay | `list` | `{}` |
| client → relay | `connect` | `{agent_id, session_id, cols, rows}` |
| client → relay | `resize` | `{session_id, cols, rows}` |
| client → relay | `disconnect` | `{session_id}` |
| client → relay | `fs_list` | `{agent_id, request_id, path}` |
| client → relay | `fs_mkdir` | `{agent_id, request_id, path}` |
| client → relay | `fs_delete` | `{agent_id, request_id, path}` |
| client → relay | `fs_read` | `{agent_id, request_id, path}` |
| relay → client | `agent_list` | `{agents: [{id, name, connected}]}` |
| relay → client | `session_ready` | `{session_id}` |

### Terminal data (binary frames)

```
[4B uint32 BE: session_id length] [session_id bytes] [terminal bytes]
```

---

## Repository structure

```
claude-orchestrator/
├── Makefile                    # make relay / agent / install / logs
├── scripts/
│   ├── start-relay.sh          # dev: start relay (reads relay/.env)
│   ├── start-agent.sh          # dev: start agent (reads ~/.config/claude-agent/config.yaml)
│   ├── install-agent.sh        # install as launchd service
│   └── uninstall-agent.sh      # remove service
│
├── relay/
│   ├── .env.example            # ← copy to .env for local dev
│   ├── Dockerfile              # for Railway / Docker
│   ├── main.go                 # HTTP server, env config
│   ├── hub.go                  # connection registry + routing
│   ├── session.go              # message types
│   └── auth.go                 # JWT login/refresh
│
├── agent/
│   ├── main.go                 # config, startup, --init flag
│   ├── ws_client.go            # relay connection, message routing
│   ├── pty_session.go          # PTY process management
│   └── fs_ops.go               # file system operations
│
└── Claude Orchestrator/        # Xcode project (SwiftUI iOS app)
    ├── App/
    │   └── ClaudeTerminalApp.swift     # app entry, SessionManager, LoginView
    ├── Views/
    │   ├── SessionTabsView.swift       # machine pills + Terminal/Files switcher
    │   ├── AgentListView.swift         # connect to Mac / session picker
    │   ├── FileBrowserView.swift       # file browser (inline + sheet modes)
    │   └── TerminalView.swift          # SwiftTerm integration + quick commands
    ├── Models/
    │   └── TerminalSession.swift
    └── Services/
        ├── RelayWebSocket.swift        # WS connection + binary mux + fs ops
        └── AuthService.swift           # JWT + Keychain
```

---

## Security

| Threat | Mitigation |
|--------|------------|
| MITM | TLS (`wss://`) with certificate validation |
| Unauthorized access | JWT (15 min access + 30 day refresh) for clients; pre-shared secret for agents |
| Session hijacking | `session_id` is UUID v4 |
| Token leakage | Tokens stored in iOS Keychain |
