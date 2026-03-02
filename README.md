# clrc — Claude Remote Control

Use Claude CLI on your Mac from your iPhone, over WebSocket.

```
iPhone (SwiftUI)
    │  WebSocket
    ▼
Relay Server  ←── each Mac registers here
    │  WebSocket
    ▼
Mac Daemon (clrc)
    │  PTY
    ▼
claude / bash
```

---

## Quick start

### 1. Start the relay

```bash
make relay-init             # creates relay/.env from example
$EDITOR relay/.env          # set JWT_SECRET, ADMIN_PASSWORD, AGENT_SECRET
make relay                  # starts on :8080
```

### 2. Install clrc on each Mac

```bash
curl -fsSL https://raw.githubusercontent.com/tergeoo/clrc/main/install.sh | sh
```

Prompts for relay URL and secret, installs the binary, registers a launchd service.

Or from source:

```bash
make agent-init             # creates agent/.env from example
$EDITOR agent/.env          # set RELAY_URL, AGENT_SECRET
make agent                  # builds and runs
```

### 3. iOS App

Open `Claude Orchestrator.iOS/Claude Orchestrator.xcodeproj` in Xcode, build & run on your device (same Wi-Fi as the relay).

---

## clrc commands

```bash
clrc start     # start daemon in background
clrc stop      # stop daemon
clrc restart   # restart
clrc status    # running or not
clrc logs      # tail -f /tmp/clrc.log

# flags override config:
clrc --relay wss://my-relay.com --secret mysecret --name "My Mac"
```

Config file: `~/.config/clrc/.env`

---

## Makefile

```bash
make relay          # start relay locally
make agent          # start clrc locally (foreground)
make app            # build Claude Remote Control.app (double-clickable)
make logs           # tail clrc logs
make relay-logs     # tail relay logs
make status         # launchctl list | grep clrc
make uninstall      # remove launchd service and binary
make release VERSION=v1.2.3
```

---

## Repository structure

```
clrc/
├── install.sh                  # one-liner installer (curl | sh)
├── Makefile
├── scripts/
│   ├── start-relay.sh
│   ├── start-agent.sh
│   └── make-app.sh             # builds .app bundle
│
├── relay/                      # Go relay server
│   ├── hub.go                  # connection registry + routing
│   ├── auth.go                 # JWT + rate limiting
│   ├── session.go              # message types
│   └── cmd/main.go
│
├── agent/                      # Go Mac daemon (clrc binary)
│   ├── ws_client.go            # relay connection, message routing
│   ├── pty_session.go          # PTY process management
│   ├── fs_ops.go               # file system operations
│   ├── config.go               # config + stable agent ID
│   └── cmd/main.go             # start/stop/status/logs subcommands
│
└── Claude Orchestrator.iOS/    # Xcode project (SwiftUI)
```

---

## Protocol

### Control messages (JSON)

| Direction | Type | Payload |
|-----------|------|---------|
| agent → relay | `register` | `{agent_id, name, secret}` |
| client → relay | `auth` | `{token}` |
| client → relay | `connect` | `{agent_id, session_id, cols, rows}` |
| client → relay | `resize` | `{session_id, cols, rows}` |
| client → relay | `disconnect` | `{session_id}` |
| client → relay | `fs_list` | `{agent_id, request_id, path}` |
| client → relay | `fs_read` | `{agent_id, request_id, path}` |

### Terminal data (binary frames)

```
[4B uint32 BE: session_id length] [session_id bytes] [terminal bytes]
```

---

## Security

| Threat | Mitigation |
|--------|------------|
| Unauthorized access | JWT (15 min access + 30 day refresh); pre-shared secret for agents |
| Brute force | Max 10 login attempts / min / IP |
| Session hijacking | `session_id` validated as UUID v4 |
| Oversized messages | 4 MB limit on all WebSocket frames |
| Connection flooding | Max 50 agents / 20 clients |
| Path traversal | fs_ops rejects paths outside home directory |
| Token leakage | Tokens stored in iOS Keychain |
