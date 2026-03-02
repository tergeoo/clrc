# clrc

Mac daemon. Connects to the relay, spawns PTY sessions, handles file system operations.

```
relay  ──WebSocket──▶  agent  ──PTY──▶  claude / bash
```

## Configuration

All config via environment variables.

| Variable | Required | Description |
|---|---|---|
| `RELAY_URL` | yes | WebSocket URL of the relay. `ws://` for LAN, `wss://` for cloud |
| `AGENT_SECRET` | yes | Must match `AGENT_SECRET` on the relay |
| `AGENT_ID` | no | Stable UUID for this machine. Auto-generated if empty — set it to keep sessions persistent across restarts. `uuidgen \| tr A-Z a-z` |
| `AGENT_NAME` | no | Display name in the iOS app (default: hostname) |
| `DEFAULT_COMMAND` | no | Command launched in new terminal sessions (default: `bash`) |

## Local development

```bash
cp .env.example .env
$EDITOR .env          # set RELAY_URL and AGENT_SECRET at minimum
make agent            # builds and runs in foreground
```

## Production (launchd)

Copy `com.clrc.plist` to `~/Library/LaunchAgents/`, fill in the `EnvironmentVariables` section, then:

```bash
launchctl load -w ~/Library/LaunchAgents/com.clrc.plist
```

Logs: `tail -f /tmp/clrc.log`

## One-liner install (from GitHub Releases)

```bash
curl -fsSL https://raw.githubusercontent.com/vrtoursuz/claude-orchestrator/main/install.sh | sh
```

Prompts for relay URL and secret, downloads the binary, sets up launchd.

## Flags

Flags override env vars — useful for quick testing without an `.env` file.

```bash
clrc --relay wss://your-relay.up.railway.app --secret mysecret --name "My Mac"
```

## Build

```bash
go build -o /tmp/clrc ./cmd/
```

## Package structure

```
agent/
├── cmd/main.go       Reads env vars, validates config, starts WSClient
├── config.go         Config struct and Validate()
├── ws_client.go      WSClient — relay connection, reconnect loop, message dispatch
├── pty_session.go    PTYSession — PTY process lifecycle, resize, detach/reattach
├── fs_ops.go         File system operations (list, read, mkdir, delete)
└── docker/
    ├── Dockerfile
    ├── docker-compose.agent.yml
    └── docker-entrypoint.sh
```

## Detach vs disconnect

- **Detach** — iOS app closed unexpectedly. PTY stays alive; output is suppressed. Reconnecting with the same `session_id` reattaches to the running process.
- **Disconnect** — explicit tab close. PTY is killed.
