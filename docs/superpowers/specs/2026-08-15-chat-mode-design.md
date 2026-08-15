# clrc Chat Mode — Design Spec

**Date:** 2026-08-15
**Status:** Draft for review
**Topic:** A second session kind that runs `claude` headless (`stream-json`) and renders a native chat on iOS, instead of streaming a raw PTY of the Claude Code TUI.

---

## 1. Problem

Driving `claude` from the phone today means streaming its full-screen TUI over a PTY. Two independent problems follow from that, and only one of them is a performance bug.

**Rendering lag.** Every PTY read becomes its own WebSocket frame and its own screen repaint:

- `agent/pty_session.go:112-124` reads into a 4 KB buffer and calls `sendToRelay` per read; `agent/ws_client.go:359-372` does one `conn.Write` per call. A TUI with a spinner repaints dozens of times per second, so this emits hundreds of micro-frames per second. Nothing coalesces.
- `RelayWebSocket.swift:186-203` hops to `MainActor` for **every** frame, and does not read the next frame until the main thread is free.
- `TerminalView.swift:24-26` adds a *second* `DispatchQueue.main.async`, which guarantees each frame lands in its own runloop iteration — making batching structurally impossible.
- `TerminalSession.swift:74-77` calls `tv.feed()` per frame, so SwiftTerm marks `setNeedsDisplay` and CoreText redraws the whole screen each time.

**Illegibility.** `TerminalView.swift:18` sets a 15pt monospaced font, giving roughly 40 columns on an iPhone. The Claude Code TUI targets 80+. It does not gracefully shrink — its boxes and wrapping break. No amount of render optimisation fixes this.

The transport is not the bottleneck. The bottleneck is that we ship a terminal to a device that cannot display one.

## 2. Goal

Add a **chat** session kind alongside the existing **pty** kind. In chat mode the agent runs `claude` headless with a JSONL protocol, normalises its events, and the iPhone renders a native chat. No ANSI, no column constraints, no repaints — the thing that lagged stops existing.

Primary use case (stated by the owner): *give a task, put the phone away, check progress periodically, occasionally answer.* Not high-speed interactive typing.

## 3. Scope

This spec covers **the core only**. The work was decomposed into three independent sub-projects; the other two get their own specs once the core stands.

| # | Sub-project | Status |
|---|---|---|
| 1 | **Core: structured chat mode** — protocol, headless runner, relay routing, minimal chat UI | **this spec** |
| 2 | Persistence & feed quality — on-disk event log, `--resume` across reboot, Markdown/diffs/collapsible tool calls | later |
| 3 | Push notifications — APNs key, device tokens in relay, send on `result` | later |

Separately tracked and independent of all three: coalescing fixes for PTY mode (agent-side timer batching, iOS frame batching, removing the double main-thread hop). Not part of this spec.

### 3.1 Non-goals (YAGNI)

- **No token-level streaming.** `--include-partial-messages` is not used. Whole assistant messages are enough for the stated use case and cut event volume by orders of magnitude.
- **No permission prompts.** Sessions run `--permission-mode bypassPermissions`, matching how the owner already works (the `⚠ claude --dangerously-skip-permissions` quick command in `TerminalView.swift:122`). No MCP permission-prompt tool is built.
- **No thinking blocks in the UI.** They are parsed and dropped, not forwarded.
- **No Markdown rendering, syntax highlighting, or diff views** — sub-project 2.
- **No replacement of PTY mode.** It stays, for `bash` and anything genuinely interactive.
- **No Claude Agent SDK.** The agent is Go; pulling a Node or Python runtime into the daemon is a bad trade.

## 4. Verified assumptions

These were checked empirically against the real CLI on 2026-08-15, not taken from documentation. Raw capture: two turns through one process.

1. **The process is long-lived and multi-turn.** Writing two JSONL user messages to one process's stdin produced one shared `session_id` and correct cross-turn recall (asked to reply `FIRST`, then asked what it had been told to say — answered `FIRST`). This is a real conversation, not two independent `-p` invocations.
2. **`--verbose` is mandatory.** Without it the CLI refuses: `--output-format=stream-json requires --verbose`.
3. **`result` is a clean end-of-turn signal**, carrying `session_id`, `num_turns`, `total_cost_usd`, `duration_api_ms`, `stop_reason`, `is_error`, `usage`. Sub-project 3 will trigger push off this event; no parsing required.
4. **`assistant.content` is an array of typed blocks** — `thinking`, `text`, `tool_use`. A thinking block has no `text` key, so naive `content[].text` extraction yields nulls. The translator must switch on block `type`.
5. **The stream is noisy.** A single turn emitted twelve consecutive `system/thinking_tokens` events plus `system/hook_started` / `system/hook_response` pairs. This is the decisive argument for normalising in the agent rather than forwarding raw.

## 5. Approach (chosen)

**The agent normalises; the phone consumes a stable contract.**

Rejected: (b) *agent as a dumb pipe*, forwarding raw JSONL for iOS to parse — the Claude Code stream format is internal and will change, and the iOS client is the slowest component to update (App Store review), while `clrc` on a Mac updates with one command. Put the translation layer where updates are cheap. (c) *Claude Agent SDK* — see non-goals.

**Process lifecycle: lazy start, resume on death.** The agent does not hold a `claude` process open from session creation. It spawns on the first `chat_send` and keeps it while the session lives. If the process dies — crash, or the Mac rebooted and the agent restarted — the next message respawns it with `--resume`. Reboot stops being a special case; it is just a cold start.

## 6. Protocol

Extends the existing `{type, payload}` envelope. The `Message` struct is defined in three places (`relay/session.go`, `agent/ws_client.go`, iOS `RelayWebSocket`) and all three must be updated together.

### 6.1 Session creation

`connect` gains two optional fields:

```jsonc
{ "type": "connect", "payload": {
    "agent_id": "...", "session_id": "<uuid-v4-lowercase>",
    "kind": "chat",          // "pty" when absent — old clients and agents keep working
    "cwd": "/Users/me/proj", // chat only; resolved and confined to $HOME
    "name": "...",           // existing
    "model": "..."           // optional; omitted = CLI default
} }
```

Backward compatibility is by omission: an old client sends no `kind`, and the agent treats it as `pty`; an old agent ignores `kind` entirely and spawns a PTY, which is the current behaviour.

### 6.2 Client → agent

| Type | Payload | Notes |
|---|---|---|
| `chat_send` | `{session_id, text}` | user message |
| `chat_interrupt` | `{session_id}` | stop the current turn |
| `chat_history` | `{agent_id, session_id, request_id, after_seq}` | replay after reconnect |

`detach` and `disconnect` keep their existing asymmetric meaning: an unexpected client drop detaches and the session survives; an explicit `disconnect` ends it and kills the process.

### 6.3 Agent → client

`chat_event` carries one normalised event; `chat_history_result` carries `{request_id, events[], next_seq}`.

```jsonc
{"kind":"turn_start",  "seq":1, "ts":"..."}
{"kind":"text",        "seq":2, "ts":"...", "text":"..."}
{"kind":"tool_use",    "seq":3, "ts":"...", "tool_id":"...", "name":"Bash", "input":"...", "truncated":false}
{"kind":"tool_result", "seq":4, "ts":"...", "tool_id":"...", "ok":true, "output":"...", "truncated":true}
{"kind":"turn_end",    "seq":5, "ts":"...", "num_turns":1, "cost_usd":0.049, "duration_ms":4877, "stop_reason":"end_turn"}
{"kind":"error",       "seq":6, "ts":"...", "message":"..."}
```

`seq` is a monotonic per-session counter. It is what makes reconnection correct: the client reports the highest `seq` it holds, the agent sends only the tail. No duplicates, no gaps, no races.

All chat traffic uses **text** frames. The binary channel stays exclusively for PTY. Event volume is orders of magnitude below screen repaints, so binary framing would buy nothing.

### 6.4 Size limits

The relay caps messages at 4 MB (`maxMessageBytes`). A `Write` tool call carrying a whole file would breach that, so the agent truncates `input` and `output` to **4 KB** each and sets `truncated: true`. This follows the existing deliberate-limits convention rather than working around it.

## 7. Agent

Three new files, one responsibility each, per the repo's many-small-files rule.

### 7.1 `agent/chat_events.go` — translation (the testable core)

Pure functions: raw Claude Code JSONL line → zero or more normalised events. No processes, no IO, no network. Responsibilities:

- Drop noise: `system/thinking_tokens`, `system/hook_started`, `system/hook_response`, `rate_limit_event`.
- Walk `assistant.message.content[]` by block `type`: `text` → `text` event; `tool_use` → `tool_use` event; `thinking` → dropped.
- Map `user.message.content[]` blocks of type `tool_result` → `tool_result` events, matched to their `tool_use` by `tool_use_id`.
- Map `result` → `turn_end`, carrying `num_turns`, `total_cost_usd`, `duration_api_ms`, `stop_reason`; `is_error: true` additionally yields an `error` event.
- Map `system/init` → `turn_start`. The capture shows `init` is emitted at the start of **every** turn, not only the first, so it is a per-turn marker rather than a session-open marker.
- Truncate per §6.4.

`seq` is **not** assigned here. Translation stays a pure function of its input line, so the counter lives in the buffer (§7.3) and is stamped on `Append`. This keeps the translator trivially table-testable with no shared state between cases.

### 7.2 `agent/chat_session.go` — process lifecycle

`exec.Command` with pipes (**not** a PTY), a stdin writer, a stdout scanner, a separate stderr scanner, and interrupt handling. Launch:

```
claude -p --input-format stream-json --output-format stream-json --verbose \
       --permission-mode bypassPermissions --session-id <session_id> [--model M]
```

with `Dir: cwd` and `Env: cleanEnv()`. Our `session_id` is already a lowercase UUID v4 (the relay validates this), so it feeds `--session-id` directly — one identity instead of two, which also makes `--resume` trivial.

On respawn after death, `--session-id` is **replaced by** `--resume <session_id>` — the two are not passed together, since one asks to create a session with a given id and the other asks to continue an existing one. The first task of the implementation is a throwaway check that `--resume` on an id originally created via `--session-id` restores context; if it does not, the fallback is to keep the transcript ourselves and replay it as context on respawn.

**Interrupt:** SIGINT to the process, then `--resume` on the next message. Crude but deterministic and testable. A native control-message interrupt, if one is found during implementation, is a drop-in replacement.

Scanner buffers must be raised above `bufio.Scanner`'s default 64 KB — a single JSONL line carrying a large tool result will exceed it. Use a 1 MB buffer and treat over-long lines as a skipped-line error rather than a session kill.

### 7.3 `agent/chat_buffer.go` — event buffer

A small interface (`Append(events...) []event`, `Since(seq) []event`, `NextSeq() uint64`) backed by an in-memory ring buffer holding the last N events (N = 2000). `Append` stamps the monotonic `seq` and returns the stamped events, which is the single place the counter advances. Sub-project 2 substitutes a disk-backed log at this same seam without touching callers.

### 7.4 Security

`cwd` is resolved through the existing `fsResolve` in `agent/fs_ops.go` and rejected if it escapes `$HOME` — identical confinement to every other filesystem operation. A chat session must not become a way around it.

## 8. Relay

The smallest change of the three components, which is a good sign for the design.

- `chat_send`, `chat_interrupt`: client→agent, over the existing per-session routing.
- `chat_event`: agent→client, existing path.
- `chat_history`: reuses the existing `request_id` correlation machinery (`pendingRequests` sync.Map, `agent_id` stripped before forwarding) exactly as `fs_list` and `list_sessions` do.

These are new switch branches, not new machinery. Session-id validation, connection caps, and the message-size cap apply unchanged.

The relay currently has **no tests at all**, which `CLAUDE.md` names the highest-value remaining gap. Chat routing is where that gap starts closing (§10).

## 9. iOS

### 9.1 `ClrcCore` — testable logic

- `ChatEvent` — model plus decoding, tolerant of unknown `kind` values (forward compatibility: a newer agent must not break an older app).
- `ChatTranscript` — applies events, discards duplicates by `seq`, detects gaps and requests replay, groups events into turns.

Pure logic covered by `swift test`, following the existing `RestorePlanner` / `SessionsStore` pattern.

### 9.2 App layer

- `ChatSessionView` — list of turns.
- `ChatComposer` — text input and send.
- `ToolCallRow` — one collapsed tool call.

`SessionManager` starts holding sessions of two kinds. `TerminalSession` already carries too much (rendering plus activity parsing); chat does not go on it. `ChatSession` is a separate type and `SessionTabsView` picks the view.

Session creation reuses `NewSessionSheet` as-is — recent projects, the folder browser, the name field. Today it composes the string `cd "path" && claude` and *types it into the PTY* (`NewSessionSheet.swift:145-147`); in chat mode the same choice becomes an honest `cwd` field on `connect`.

### 9.3 Targeted cleanup

The `toolPattern` regex and `stripANSI` in `TerminalSession.swift` exist only because structure had to be guessed from ANSI output. Chat mode delivers real structure. This code stays for PTY sessions and is marked as a removal candidate — chasing TUI layout with regexes has no future once a typed feed exists. Removing it is out of scope here.

## 10. Testing

TDD, tests first, per the repo rules; 80% coverage target on new code.

| Suite | Covers |
|---|---|
| `agent/chat_events_test.go` | Table-driven over a **real** captured JSONL fixture, not an invented one: text extraction, thinking blocks with no `text` key, noise filtering, `tool_use`↔`tool_result` pairing by id, truncation, `seq` assignment |
| `agent/chat_session_test.go` | Lifecycle against a **fake `claude`** — a small script emitting canned JSONL. No API calls, runs under `-race`: spawn, send, respawn after death, SIGINT, over-long line handling |
| `agent/chat_buffer_test.go` | `Since(seq)` semantics, ring eviction |
| `relay/chat_routing_test.go` | First tests in the relay: chat message routing both ways, `request_id` correlation, `agent_id` stripping |
| `ClrcCore/Tests/ChatTranscriptTests` | Duplicate `seq`, out-of-order arrival, gap detection, turn grouping, unknown-kind tolerance |

The fake-`claude` script is the mockable boundary that keeps the whole agent side testable without network or credentials.

## 11. Error handling

| Condition | Behaviour |
|---|---|
| `claude` not on `PATH` | `error` event with an actionable message; session stays alive |
| Process exits non-zero | `error` event + server-side log; next `chat_send` respawns with `--resume` |
| Malformed JSONL line | Skip and count; do not kill the session — the CLI may write non-JSON to stdout |
| Line exceeds scanner buffer | Skip with an `error` event; session survives |
| stderr output | Read on its own goroutine, surfaced as `error` events |
| `cwd` outside `$HOME` | `connect` rejected with `error`, no process spawned |
| Tool payload over 4 KB | Truncated with `truncated: true` |

## 12. Open decisions deliberately made

- **Thinking blocks are dropped, not surfaced.** They are large and, for the "give a task and watch" use case, noise. Revisit only if asked.
- **Interrupt is SIGINT + resume**, not a protocol-level control message, because the former is verified to work and the latter is not.
- **The event buffer is in memory in this sub-project.** History surviving an agent restart is sub-project 2, and the buffer interface is the seam it plugs into.
