# Session Persistence & Reconnect UX — Design

**Date:** 2026-07-03
**Status:** DRAFT — pending user approval
**Scope:** clrc iOS app + agent (Go) + protocol extension

## Problem

Today the iOS app holds sessions only in memory:

- Kill/relaunch the app → all tabs are gone, even though the PTYs on the Mac are still alive.
- Reattaching is manual: Agents list → tap agent → picker that shows only truncated UUIDs and terminal dimensions — impossible to tell sessions apart.
- Custom session names live only in the running app instance; they are lost on restart and never reach the Mac.
- The agent persists only `id / pid / command / started` per session — no name, no working directory.
- Creating a session in a specific project folder requires navigating the Files tab every time; there are no recents.

Goal: opening the app should feel like opening a terminal that never closed. Creating a new session in a known project should take two taps.

## Decisions (assumptions made while user was away — confirm/adjust)

1. **Reconnect model: automatic tab restore.** The app persists its session list locally and transparently reattaches to all still-alive PTYs on launch/reconnect. (Alternative "show a picker on launch" rejected as extra friction; tmux-based survival of agent restarts rejected as out of scope — it was deliberately removed in v2.)
2. **Session metadata (name, project path) is written to the agent too**, via a small protocol extension, so the reattach picker is human-readable even after app reinstall.
3. **Recent projects** are stored client-side per agent and offered in a New Session sheet.

## Approaches considered

| | Approach | Verdict |
|---|---|---|
| A | Client-side persistence only (no protocol changes) | Simplest, but reattach list stays cryptic when local metadata is missing (reinstall, second device) |
| B | **Client persistence + minimal protocol extension (`name` in `connect`, richer `sessions_list`)** | **Chosen.** Small, touches all three components but in a contained way |
| C | Relay-side session registry and/or tmux-backed PTY survival | YAGNI for a single-user tool; large complexity, deliberately removed in v2 |

## Design

### 1. Protocol extension (three `Message` definitions must stay in sync)

`connect` payload (client → relay → agent) gains one optional field:

```json
{ "session_id": "…", "cols": 80, "rows": 24, "name": "drops.iOS" }
```

`sessions_list` response (agent → relay → client) entries gain fields:

```json
{ "id": "…", "cols": 80, "rows": 24, "name": "drops.iOS", "command": "claude", "started": "2026-07-03T12:00:00Z" }
```

Unknown/absent fields are ignored by all parties → fully backward compatible; no version bump needed.

Files: `agent/ws_client.go` (`handleConnect`, `handleListSessions`) and iOS `RelayWebSocket`. **The relay needs no changes**: `handleClientConnect` (relay/hub.go:507) forwards `msg.Payload` verbatim, so `name` passes through; `sessions_list` replies are likewise relayed untouched via the `request_id` correlation path.

### 2. Agent (Go)

- `SessionInfo` gains `Name string \`json:"name"\``.
- `handleConnect` parses optional `name`; passes it to `WriteSess`; on **reattach** with a non-empty name, updates the stored name (rename-on-reconnect gives us rename sync for free).
- `handleListSessions` reads names from the in-memory sessions map (add `Name` to `PTYSession`) and includes `name`, `command`, `started` in each entry.
- `clrc sessions` CLI output shows the name column.

### 3. iOS: local session store

New `SessionsStore` service (file-backed JSON in Application Support; UserDefaults is fine too but a file keeps it testable):

```swift
struct PersistedSession: Codable {
    let id: String
    let agentID: String
    let agentName: String
    var customName: String
    var projectPath: String?   // parsed from initialCommand ("cd X && claude")
    let createdAt: Date
}
```

- `SessionManager.createSession/attachSession` writes an entry; `remove/closeAll` deletes; rename updates.
- Store also keeps `recentProjects: [agentID: [path]]` (max 8 per agent, most-recent-first).

### 4. iOS: restore flow (on relay connect)

Current behavior to change: `SessionManager` auto-creates one session per newly-seen agent, and `onConnect` re-sends `connect` for in-memory sessions only.

New flow when relay connects and agents arrive:

1. For each online agent that has persisted sessions → send `list_sessions`.
2. Alive persisted sessions → `attachSession` with restored `customName` (tabs reappear silently).
3. Persisted sessions not in the list → PTY is dead: keep a tombstone row in the machine-selector sheet marked "Ended", with actions **Restart here** (new session with `cd <projectPath> && claude`) and **Remove**. Tombstones are not auto-deleted; terminal tab area is not occupied by dead sessions.
4. Auto-create-a-tab-per-agent (commit 93a786f) now fires **only if** the agent has no persisted and no live sessions — first-run convenience preserved, no duplicates after restore.

Reconnect after transient drops (already working via `onConnect` re-`connect`) is unchanged, but now also re-sends `name`.

### 5. iOS: New Session sheet

Replace the current "tap agent → bare picker" with a proper creation sheet, reachable from a **+ button in the top bar** (one tap from anywhere):

- Agent picker (segmented/menu; preselected to the current session's agent; hidden if only one agent online).
- **Recent projects** list (from `SessionsStore`) — tap = create session with `cd <path> && claude`.
- "Browse…" row → existing `FileBrowserView` in picker mode.
- Toggle: "Skip permissions (`--dangerously-skip-permissions`)" — persisted as a default.
- Optional name field (defaults to folder name, as today's auto-naming).
- "Plain shell" row for a bash session without claude.

The existing `MachineSelectorSheet` keeps session switching/rename/close and the reattach list, but reattach entries now show **name + project + started time** instead of UUIDs (data from extended `sessions_list`).

### 6. Error handling

- `list_sessions` timeout (existing 3 s fallback) → treat as "no info": keep tabs in a "reconnecting" state, retry on next relay connect; never silently drop persisted sessions.
- Store read failure (corrupt JSON) → log, start with empty store; never crash on launch.
- `connect` for a dead session id spawns a fresh PTY on the agent (current agent behavior) — prevented by restoring only ids confirmed via `list_sessions`.

### 7. Testing

First tests in the repo (currently none):

- **Go (agent):** table-driven tests for `session_store` (write/list/remove/clean with name), `handleConnect` name parsing + reattach rename, `handleListSessions` payload shape. Run with `-race`.
- **Swift:** unit tests for `SessionsStore` (persist/load/corrupt file), restore matching logic (alive vs tombstone), auto-name/project-path parsing (already-existing regex logic extracted to a testable helper), recents ordering/cap.
- Manual E2E checklist in the PR: kill app → relaunch → tabs restored; kill agent → tombstones + restart-here; reinstall app → reattach picker shows names.

## Out of scope

- PTY survival across agent daemon restarts (tmux) — revisit later if needed.
- Multi-device name sync conflicts (last-writer-wins via reattach rename is acceptable).
- Push notifications when Claude finishes — idea for a separate, later spec.
