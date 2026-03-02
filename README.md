# clrc — Claude Remote Control

Use Claude CLI on your Mac from your iPhone.

```
iPhone ──WebSocket──▶ Relay ◀──WebSocket── clrc (Mac daemon)
                                                  │ PTY
                                                  ▼
                                             claude / bash
```

---

## Install agent

### Option 1 — one-liner (recommended)

```sh
curl -fsSL https://raw.githubusercontent.com/tergeoo/clrc/main/install.sh | sh
```

Prompts for relay URL and secret, downloads binary, sets up auto-start on login.

### Option 2 — Homebrew

```sh
brew install --cask tergeoo/clrc/clrc
```

Then configure and start:

```sh
mkdir -p ~/.config/clrc
cat > ~/.config/clrc/.env <<EOF
RELAY_URL="wss://your-relay.up.railway.app"
AGENT_SECRET="your-secret"
EOF

clrc start
```

### Option 3 — from source

```sh
git clone https://github.com/tergeoo/clrc
cd clrc
make install    # build + copy to /usr/local/bin
make config     # create ~/.config/clrc/.env interactively
clrc start
```

---

## Agent usage

```sh
clrc start      # start daemon in background
clrc stop       # stop
clrc restart    # restart
clrc status     # running / stopped
clrc logs       # tail -f /tmp/clrc.log
```

Config: `~/.config/clrc/.env`

Override per-run:
```sh
clrc --relay wss://my-relay.com --secret mysecret --name "My Mac"
```

---

## Relay

Routes traffic between iPhone and Macs. Deploy once, use from anywhere.

### Cloud — Railway / fly.io

Deploy `relay/` with Docker. Set three env vars:

| Variable | Description |
|---|---|
| `JWT_SECRET` | Random string, signs auth tokens |
| `ADMIN_PASSWORD` | Password for iOS app login |
| `AGENT_SECRET` | Shared secret for Mac agents |

### Local network

```sh
git clone https://github.com/tergeoo/clrc
cd clrc
make relay-init      # create relay/.env
$EDITOR relay/.env   # set JWT_SECRET, ADMIN_PASSWORD, AGENT_SECRET
make relay           # start on :8080
```

Then in the iOS app use `http://YOUR_MAC_IP:8080`.

---

## iOS App

Open `Claude Orchestrator.iOS/Claude Orchestrator.xcodeproj` in Xcode.
Build & run on device. Enter relay URL and password to connect.

---

## Config reference

`~/.config/clrc/.env`:

| Variable | Required | Default | Description |
|---|---|---|---|
| `RELAY_URL` | ✅ | — | `ws://` for LAN, `wss://` for cloud |
| `AGENT_SECRET` | ✅ | — | Must match relay's `AGENT_SECRET` |
| `AGENT_ID` | — | auto | Stable ID, auto-generated on first run |
| `AGENT_NAME` | — | hostname | Display name in iOS app |
| `DEFAULT_COMMAND` | — | `bash` | Command spawned in new sessions |

---

## Makefile

```sh
make install          # build agent + install to /usr/local/bin
make config           # create ~/.config/clrc/.env interactively
make show             # print current config
make edit             # open config in $EDITOR
make set KEY=RELAY_URL VALUE=wss://...  # set one value
make dev              # start relay + agent locally (foreground)
make build            # build both binaries to /tmp/
make relay            # start relay only
make agent            # start agent only
make logs             # tail /tmp/clrc.log
make relay-logs       # tail relay logs
make status           # service status
make uninstall        # remove launchd service
make release VERSION=v1.2.3
```

---

## Project structure

```
clrc/
├── install.sh              # one-liner installer
├── Makefile
├── agent/                  # clrc binary (Go)
│   ├── cmd/main.go         # start/stop/status/logs subcommands
│   ├── config.go           # config loading + stable agent ID
│   ├── ws_client.go        # relay connection + message routing
│   ├── pty_session.go      # PTY process management
│   └── fs_ops.go           # file system operations
├── relay/                  # relay server (Go)
│   ├── cmd/main.go
│   ├── hub.go              # connection registry + routing
│   ├── auth.go             # JWT auth + rate limiting
│   └── session.go          # message types
├── Formula/clrc.rb         # Homebrew formula
├── Casks/clrc.rb           # Homebrew cask (no CLT required)
└── Claude Orchestrator.iOS/ # SwiftUI iOS app
```
