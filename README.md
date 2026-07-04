# clrc — Claude Remote Control

Control Claude CLI on your Mac from your iPhone.

```
iPhone ──WebSocket──▶ Relay ◀──WebSocket── clrc (Mac daemon)
                                                  │ PTY
                                                  ▼
                                             claude / bash
```

---

## Install agent (Mac)

### Option 1 — one-liner

```sh
curl -fsSL https://raw.githubusercontent.com/tergeoo/clrc/main/install.sh | sh
```

Prompts for relay URL and secret, downloads the binary, sets up auto-start on login.

### Option 2 — Homebrew (no Xcode CLT required)

```sh
brew tap tergeoo/clrc https://github.com/tergeoo/clrc
brew install --cask clrc
```

Then configure and start:

```sh
clrc config --relay-url wss://your-relay.up.railway.app --secret your-secret
clrc start
```

### Option 3 — from source

```sh
git clone https://github.com/tergeoo/clrc
cd clrc
make install    # build + copy to /usr/local/bin
clrc config --relay-url wss://... --secret ...
clrc start
```

---

## Agent commands

```sh
clrc start                    # start daemon in background
clrc stop                     # stop daemon
clrc restart                  # restart daemon
clrc status                   # running / stopped
clrc logs                     # tail -f /tmp/clrc.log
clrc sessions                 # list active PTY sessions (from iPhone)
clrc attach                   # attach to session via reptyr + tmux
clrc attach e1d177b3          # attach by session ID prefix
```

### Config

```sh
clrc config                               # show current config
clrc config --relay-url wss://...         # set relay URL
clrc config --secret SECRET               # set agent secret
clrc config --name "My Mac"               # set display name
clrc config --command bash                # set default command
clrc config --edit                        # open config in $EDITOR
```

Config file: `~/.config/clrc/.env`

```sh
RELAY_URL="wss://your-relay.up.railway.app"
AGENT_SECRET="your-secret"
AGENT_ID="auto-generated-uuid"
AGENT_NAME="My Mac"
DEFAULT_COMMAND="bash"
```

---

## Relay

Routes traffic between iPhone and Macs. Deploy once, use from anywhere.

### Cloud — Railway / fly.io

Deploy `relay/` with Docker. Set three env vars:

| Variable | Description |
|---|---|
| `JWT_SECRET` | Random string — `openssl rand -hex 32` |
| `ADMIN_PASSWORD` | Password for iOS app login |
| `AGENT_SECRET` | Shared secret for Mac agents |

### Local network

```sh
cd clrc
make relay-init      # create relay/.env
$EDITOR relay/.env   # set JWT_SECRET, ADMIN_PASSWORD, AGENT_SECRET
make relay           # start on :8080
```

Then in the iOS app use `http://YOUR_MAC_IP:8080`.

---

## iOS App

Open `Claude Orchestrator.iOS/Claude Orchestrator.xcodeproj` in Xcode, build and run on device.
Enter relay URL and password to connect.

---

## Attach to a session from Mac terminal

When a session is open from the iPhone, attach to it locally:

```sh
# Requires: brew install reptyr tmux
clrc sessions        # list open sessions
clrc attach          # attach (if only one session)
clrc attach e1d177b3 # attach by ID prefix
```

Opens the session in a new tmux window via `reptyr`. Detach with `Ctrl-B D`.

---

## Config reference

`~/.config/clrc/.env`:

| Variable | Required | Default | Description |
|---|---|---|---|
| `RELAY_URL` | ✅ | — | `ws://` for LAN, `wss://` for cloud |
| `AGENT_SECRET` | ✅ | — | Must match relay's `AGENT_SECRET` |
| `AGENT_ID` | — | auto | Stable UUID — auto-generated on first run |
| `AGENT_NAME` | — | hostname | Display name in iOS app |
| `DEFAULT_COMMAND` | — | `bash` | Command spawned in new sessions |

---

## Project structure

```
clrc/
├── install.sh                  one-liner installer
├── Makefile
├── agent/                      clrc binary (Go)
│   ├── cmd/main.go             CLI: start/stop/sessions/attach/config subcommands
│   ├── config.go               config loading + stable agent ID
│   ├── ws_client.go            relay connection + message routing
│   ├── pty_session.go          PTY process management
│   ├── session_store.go        persists active session info for clrc sessions/attach
│   ├── fs_ops.go               file system operations
│   └── com.clrc.plist          launchd plist template
├── relay/                      relay server (Go)
│   ├── cmd/main.go
│   ├── hub.go                  connection registry + routing
│   ├── auth.go                 JWT auth + rate limiting
│   └── session.go              message types
├── Formula/clrc.rb             Homebrew formula (requires CLT)
├── Casks/clrc.rb               Homebrew cask (no CLT required)
└── Claude Orchestrator.iOS/    SwiftUI iOS app
```

---

## Makefile

```sh
make install          # build agent + install to /usr/local/bin
make build            # build both binaries to /tmp/
make relay            # start relay only
make agent            # start agent only
make dev              # start relay + agent in parallel (dev)
make logs             # tail /tmp/clrc.log
make relay-logs       # tail relay logs
make status           # service status
make release VERSION=v1.2.3
```
