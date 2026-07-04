# Session Persistence & Reconnect UX Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** iOS tabs survive app restarts (auto-reattach to live PTYs), reattach lists show human-readable names, and a New Session sheet with recent projects makes session creation two taps.

**Architecture:** The agent stores an optional session `name` (sent in `connect`) and returns `name`/`command`/`started` in `sessions_list`. The relay forwards payloads verbatim — **no relay changes**. On iOS, a new local SwiftPM package `ClrcCore` holds all testable logic (persisted-session store, restore planner, naming, protocol parsing); the app's `SessionManager` persists sessions and reconciles them against live agent sessions on every agent arrival.

**Tech Stack:** Go 1.x (agent, table-driven tests, `-race`), Swift / SwiftUI, SwiftPM local package with Swift Testing (`swift test`), Xcode 16+ synchronized-folder project (new files auto-included).

**Spec:** `docs/superpowers/specs/2026-07-03-session-persistence-design.md`

## Global Constraints

- Protocol change is backward compatible: absent/unknown JSON fields are ignored by all parties; no version bump.
- The relay is NOT modified (verified: `relay/hub.go:507` forwards `connect` payload verbatim; `sessions_list` replies relay untouched).
- The `Message` envelope `{type, payload}` definitions stay as they are in all three components.
- Session IDs remain lowercase UUID v4 (relay validates).
- Go: gofmt, wrap errors with `%w`, table-driven tests run with `-race`.
- Swift: new app files go under `Claude Orchestrator.iOS/Claude Orchestrator/` (synchronized group — no pbxproj edit needed for source files). Keep `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` app setting in mind: app types are implicitly MainActor.
- iOS deployment target 26.0 / Xcode 26 (`xcodebuild` available on this Mac).
- All shell commands below run from the repo root `/Users/georgijter-grigoranc/startups/claude-orchestrator` unless a `cd` is shown.
- Commit after every task (conventional commits, no attribution footer — disabled globally).

## File Structure

**Agent (Go, module `agent/`):**
- Modify `agent/session_store.go` — `SessionInfo.Name`, `WriteSess` gains `name`, new `RenameSess`.
- Create `agent/session_store_test.go`.
- Modify `agent/ws_client.go` — `connectReq` type with `name`, reattach-rename, `buildSessionsList` helper, richer `sessions_list`.
- Create `agent/ws_client_test.go`.
- Modify `agent/cmd/main.go` — `clrc sessions` NAME column.

**iOS local package (new, `Claude Orchestrator.iOS/ClrcCore/`):**
- `Package.swift`
- `Sources/ClrcCore/PersistedSession.swift` — Codable model.
- `Sources/ClrcCore/SessionsStore.swift` — file-backed store (sessions + recent projects).
- `Sources/ClrcCore/SessionNaming.swift` — auto-name / project-path parsing (moved from SessionManager).
- `Sources/ClrcCore/RestorePlanner.swift` — alive-vs-tombstone diff.
- `Sources/ClrcCore/RemoteSessionInfo.swift` — typed `sessions_list` entry parsing.
- `Tests/ClrcCoreTests/*` — Swift Testing tests for each of the above.

**iOS app:**
- Modify `Claude Orchestrator.iOS/Claude Orchestrator.xcodeproj/project.pbxproj` — reference local package `ClrcCore` (the ONLY pbxproj edit).
- Modify `Services/RelayWebSocket.swift` — `sendConnect(name:)`, typed per-request `sessions_list` API.
- Create `Services/SessionManager.swift` — SessionManager moved out of `ClaudeTerminalApp.swift`, extended with store/restore/tombstones.
- Modify `App/ClaudeTerminalApp.swift` — remove SessionManager class, inject store.
- Create `Views/NewSessionSheet.swift` — creation sheet with recents.
- Modify `Views/SessionTabsView.swift` — “+” button, tombstone section, rename/close via manager.
- Modify `Views/AgentListView.swift` — new typed session-list API, readable reattach rows.

---

### Task 1: Agent — session name in the session store

**Files:**
- Modify: `agent/session_store.go`
- Create: `agent/session_store_test.go`

**Interfaces:**
- Produces: `SessionInfo{ID, PID, Command, Name string, Started}`; `WriteSess(id string, pid int, command, name string)`; `RenameSess(id, name string)`. Task 2 depends on these exact signatures.

- [ ] **Step 1: Write the failing tests**

Create `agent/session_store_test.go`:

```go
package agent

import (
	"os"
	"path/filepath"
	"testing"
)

// pointSessDirAt redirects os.UserConfigDir into a temp dir for the test.
func pointSessDirAt(t *testing.T) string {
	t.Helper()
	tmp := t.TempDir()
	t.Setenv("HOME", tmp)                                        // macOS: $HOME/Library/Application Support
	t.Setenv("XDG_CONFIG_HOME", filepath.Join(tmp, ".config"))   // Linux/CI
	return tmp
}

func TestWriteListRemoveSess(t *testing.T) {
	pointSessDirAt(t)

	WriteSess("11111111-1111-4111-8111-111111111111", 4242, "claude", "drops.iOS")

	got := ListSess()
	if len(got) != 1 {
		t.Fatalf("ListSess() returned %d sessions, want 1", len(got))
	}
	s := got[0]
	if s.ID != "11111111-1111-4111-8111-111111111111" ||
		s.PID != 4242 || s.Command != "claude" || s.Name != "drops.iOS" {
		t.Errorf("unexpected session: %+v", s)
	}
	if s.Started.IsZero() {
		t.Error("Started should be set")
	}

	RemoveSess(s.ID)
	if got := ListSess(); len(got) != 0 {
		t.Errorf("after RemoveSess, ListSess() = %d sessions, want 0", len(got))
	}
}

func TestWriteSessEmptyNameOmitted(t *testing.T) {
	pointSessDirAt(t)

	WriteSess("22222222-2222-4222-8222-222222222222", 1, "bash", "")

	got := ListSess()
	if len(got) != 1 {
		t.Fatalf("ListSess() returned %d sessions, want 1", len(got))
	}
	if got[0].Name != "" {
		t.Errorf("Name = %q, want empty", got[0].Name)
	}
}

func TestRenameSess(t *testing.T) {
	pointSessDirAt(t)

	id := "33333333-3333-4333-8333-333333333333"
	WriteSess(id, 7, "claude", "old-name")
	RenameSess(id, "new-name")

	got := ListSess()
	if len(got) != 1 {
		t.Fatalf("ListSess() returned %d sessions, want 1", len(got))
	}
	if got[0].Name != "new-name" {
		t.Errorf("Name = %q, want %q", got[0].Name, "new-name")
	}
	// Other fields survive the rename
	if got[0].PID != 7 || got[0].Command != "claude" {
		t.Errorf("rename clobbered fields: %+v", got[0])
	}
}

func TestRenameSessMissingFileIsNoop(t *testing.T) {
	pointSessDirAt(t)
	RenameSess("44444444-4444-4444-8444-444444444444", "x") // must not panic or create a file
	if got := ListSess(); len(got) != 0 {
		t.Errorf("RenameSess on missing id created %d entries, want 0", len(got))
	}
}

func TestListSessSkipsCorruptFiles(t *testing.T) {
	pointSessDirAt(t)
	WriteSess("55555555-5555-4555-8555-555555555555", 1, "claude", "ok")
	if err := os.WriteFile(filepath.Join(sessDir(), "garbage.json"), []byte("{not json"), 0600); err != nil {
		t.Fatal(err)
	}
	got := ListSess()
	if len(got) != 1 {
		t.Errorf("ListSess() = %d sessions, want 1 (corrupt file skipped)", len(got))
	}
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd agent && go test -race -run 'TestWriteListRemoveSess|TestWriteSessEmptyNameOmitted|TestRenameSess|TestRenameSessMissingFileIsNoop|TestListSessSkipsCorruptFiles' ./...`
Expected: compile FAIL — `WriteSess` called with 4 args (has 3), `SessionInfo` has no field `Name`, `RenameSess` undefined.

- [ ] **Step 3: Implement**

In `agent/session_store.go`:

Add `Name` to the struct (after `Command`):

```go
// SessionInfo describes a live PTY session.
type SessionInfo struct {
	ID      string    `json:"id"`
	PID     int       `json:"pid"`
	Command string    `json:"command"`
	Name    string    `json:"name,omitempty"`
	Started time.Time `json:"started"`
}
```

Replace `WriteSess` and add `RenameSess`:

```go
// WriteSess persists a session entry to disk.
func WriteSess(id string, pid int, command, name string) {
	_ = os.MkdirAll(sessDir(), 0700)
	info := SessionInfo{ID: id, PID: pid, Command: command, Name: name, Started: time.Now()}
	data, _ := json.Marshal(info)
	_ = os.WriteFile(filepath.Join(sessDir(), id+".json"), data, 0600)
}

// RenameSess updates the stored display name of a session, keeping other fields.
// Missing or unreadable entries are ignored.
func RenameSess(id, name string) {
	path := filepath.Join(sessDir(), id+".json")
	data, err := os.ReadFile(path)
	if err != nil {
		return
	}
	var info SessionInfo
	if err := json.Unmarshal(data, &info); err != nil {
		return
	}
	info.Name = name
	out, _ := json.Marshal(info)
	_ = os.WriteFile(path, out, 0600)
}
```

Fix the (now broken) caller so the package compiles — in `agent/ws_client.go` change:

```go
	WriteSess(req.SessionID, sess.Pid(), command)
```
to:
```go
	WriteSess(req.SessionID, sess.Pid(), command, "")
```
(Task 2 replaces `""` with the real name.)

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd agent && go test -race ./... && go vet ./...`
Expected: PASS, no vet issues.

- [ ] **Step 5: Commit**

```bash
git add agent/session_store.go agent/session_store_test.go agent/ws_client.go
git commit -m "feat(agent): store session display name in session store"
```

---

### Task 2: Agent — name in `connect`, rich `sessions_list`, CLI column

**Files:**
- Modify: `agent/ws_client.go` (handleConnect ~line 167, handleListSessions ~line 274)
- Create: `agent/ws_client_test.go`
- Modify: `agent/cmd/main.go` (`cmdSessions`, ~line 114)

**Interfaces:**
- Consumes: `WriteSess(id, pid, command, name)`, `RenameSess(id, name)`, `SessionInfo` from Task 1.
- Produces: wire format consumed by Task 4/6 — `sessions_list` entries `{id, cols, rows, name?, command?, started?}` where `started` is RFC3339 UTC; `connect` accepts optional `"name"`.

- [ ] **Step 1: Write the failing tests**

Create `agent/ws_client_test.go`:

```go
package agent

import (
	"encoding/json"
	"testing"
	"time"
)

func TestConnectReqParsesOptionalName(t *testing.T) {
	tests := []struct {
		name    string
		payload string
		want    connectReq
	}{
		{
			name:    "with name",
			payload: `{"session_id":"abc","cols":100,"rows":30,"name":"drops.iOS"}`,
			want:    connectReq{SessionID: "abc", Cols: 100, Rows: 30, Name: "drops.iOS"},
		},
		{
			name:    "without name (old client)",
			payload: `{"session_id":"abc","cols":80,"rows":24}`,
			want:    connectReq{SessionID: "abc", Cols: 80, Rows: 24, Name: ""},
		},
		{
			name:    "extra unknown fields ignored",
			payload: `{"agent_id":"x","session_id":"abc","cols":80,"rows":24,"future":"y"}`,
			want:    connectReq{SessionID: "abc", Cols: 80, Rows: 24},
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			var got connectReq
			if err := json.Unmarshal([]byte(tt.payload), &got); err != nil {
				t.Fatalf("unmarshal: %v", err)
			}
			if got != tt.want {
				t.Errorf("got %+v, want %+v", got, tt.want)
			}
		})
	}
}

func TestBuildSessionsList(t *testing.T) {
	started := time.Date(2026, 7, 4, 10, 30, 0, 0, time.UTC)
	live := map[string]*PTYSession{
		"id-with-meta": {ID: "id-with-meta", Cols: 100, Rows: 30},
		"id-no-meta":   {ID: "id-no-meta", Cols: 80, Rows: 24},
	}
	disk := []SessionInfo{
		{ID: "id-with-meta", PID: 1, Command: "claude", Name: "drops.iOS", Started: started},
		{ID: "stale-on-disk", PID: 2, Command: "bash", Name: "gone", Started: started},
	}

	entries := buildSessionsList(live, disk)

	if len(entries) != 2 {
		t.Fatalf("got %d entries, want 2 (only live sessions listed)", len(entries))
	}
	byID := map[string]map[string]any{}
	for _, e := range entries {
		byID[e["id"].(string)] = e
	}

	withMeta, ok := byID["id-with-meta"]
	if !ok {
		t.Fatal("id-with-meta missing")
	}
	if withMeta["name"] != "drops.iOS" || withMeta["command"] != "claude" {
		t.Errorf("metadata not joined: %+v", withMeta)
	}
	if withMeta["started"] != "2026-07-04T10:30:00Z" {
		t.Errorf("started = %v, want RFC3339 UTC", withMeta["started"])
	}
	if withMeta["cols"] != uint16(100) || withMeta["rows"] != uint16(30) {
		t.Errorf("dims wrong: %+v", withMeta)
	}

	noMeta, ok := byID["id-no-meta"]
	if !ok {
		t.Fatal("id-no-meta missing")
	}
	if _, has := noMeta["name"]; has {
		t.Errorf("entry without disk metadata must omit name, got %+v", noMeta)
	}
	if _, has := byID["stale-on-disk"]; has {
		t.Error("disk-only (dead) session must not be listed")
	}
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd agent && go test -race -run 'TestConnectReqParsesOptionalName|TestBuildSessionsList' ./...`
Expected: compile FAIL — `connectReq` and `buildSessionsList` undefined.

- [ ] **Step 3: Implement in `agent/ws_client.go`**

Add near the top of the file (after the `Message` type):

```go
// connectReq is the payload of a "connect" control message.
// Name is optional — older clients don't send it.
type connectReq struct {
	SessionID string `json:"session_id"`
	Cols      uint16 `json:"cols"`
	Rows      uint16 `json:"rows"`
	Name      string `json:"name"`
}

// buildSessionsList joins live PTY sessions with their on-disk metadata.
// Only live sessions are returned; disk-only entries are stale.
func buildSessionsList(live map[string]*PTYSession, disk []SessionInfo) []map[string]any {
	byID := make(map[string]SessionInfo, len(disk))
	for _, d := range disk {
		byID[d.ID] = d
	}
	out := make([]map[string]any, 0, len(live))
	for id, sess := range live {
		entry := map[string]any{"id": id, "cols": sess.Cols, "rows": sess.Rows}
		if d, ok := byID[id]; ok {
			if d.Name != "" {
				entry["name"] = d.Name
			}
			entry["command"] = d.Command
			entry["started"] = d.Started.UTC().Format(time.RFC3339)
		}
		out = append(out, entry)
	}
	return out
}
```

In `handleConnect`, replace the inline anonymous req struct with `connectReq`, propagate the name on both paths:

```go
func (c *WSClient) handleConnect(ctx context.Context, payload json.RawMessage) {
	var req connectReq
	if err := json.Unmarshal(payload, &req); err != nil {
		log.Printf("Invalid connect payload: %v", err)
		return
	}

	// Check if session already exists — reattach instead of creating new PTY
	c.mu.RLock()
	existing := c.sessions[req.SessionID]
	c.mu.RUnlock()

	if existing != nil {
		existing.SetSendFn(c.sendToRelay)
		existing.Resize(req.Cols, req.Rows)
		if req.Name != "" {
			RenameSess(req.SessionID, req.Name) // rename-on-reconnect keeps names in sync
		}
		log.Printf("PTY session reattached: %s (%dx%d)", req.SessionID, req.Cols, req.Rows)
		return
	}
	// ... unchanged spawn logic ...
```

and in the spawn path change the Task 1 stopgap to:

```go
	WriteSess(req.SessionID, sess.Pid(), command, req.Name)
```

In `handleListSessions`, replace the inline loop with the helper:

```go
	c.mu.RLock()
	live := make(map[string]*PTYSession, len(c.sessions))
	for id, sess := range c.sessions {
		live[id] = sess
	}
	c.mu.RUnlock()

	sessions := buildSessionsList(live, ListSess())
```
(keep the rest of the function — request_id echo and conn write — as is; delete the old `sessions := make(...)` loop).

- [ ] **Step 4: Add NAME column to `clrc sessions` in `agent/cmd/main.go`**

Replace the body of `cmdSessions` printing:

```go
func cmdSessions() {
	sessions := agent.ListSess()
	if len(sessions) == 0 {
		fmt.Println("No active sessions")
		return
	}
	fmt.Printf("%-10s  %-18s  %-6s  %-10s  %s\n", "SESSION", "NAME", "PID", "COMMAND", "STARTED")
	fmt.Println(strings.Repeat("─", 70))
	for _, s := range sessions {
		short := s.ID
		if len(short) > 8 {
			short = short[:8]
		}
		name := s.Name
		if name == "" {
			name = "—"
		}
		if len(name) > 18 {
			name = name[:17] + "…"
		}
		fmt.Printf("%-10s  %-18s  %-6d  %-10s  %s\n",
			short, name, s.PID, s.Command, s.Started.Format("15:04:05"))
	}
}
```

- [ ] **Step 5: Run tests and build**

Run: `cd agent && go test -race ./... && go vet ./... && go build ./...`
Expected: all PASS, builds clean.

- [ ] **Step 6: Commit**

```bash
git add agent/ws_client.go agent/ws_client_test.go agent/cmd/main.go
git commit -m "feat(agent): accept session name in connect, return name/command/started in sessions_list"
```

---

### Task 3: ClrcCore package — scaffold, SessionNaming, RestorePlanner

**Files:**
- Create: `Claude Orchestrator.iOS/ClrcCore/Package.swift`
- Create: `Claude Orchestrator.iOS/ClrcCore/Sources/ClrcCore/SessionNaming.swift`
- Create: `Claude Orchestrator.iOS/ClrcCore/Sources/ClrcCore/PersistedSession.swift`
- Create: `Claude Orchestrator.iOS/ClrcCore/Sources/ClrcCore/RestorePlanner.swift`
- Create: `Claude Orchestrator.iOS/ClrcCore/Tests/ClrcCoreTests/SessionNamingTests.swift`
- Create: `Claude Orchestrator.iOS/ClrcCore/Tests/ClrcCoreTests/RestorePlannerTests.swift`
- Modify: `.gitignore` (add `.build/`)

**Interfaces:**
- Produces (used by Tasks 4, 7, 8):
  - `PersistedSession(id:agentID:agentName:customName:projectPath:createdAt:)` — `Codable, Equatable, Identifiable, Sendable`; `customName` and `projectPath` are `var`.
  - `SessionNaming.autoName(for command: String?, index: Int) -> String`
  - `SessionNaming.projectPath(from command: String?) -> String?`
  - `RestorePlan { toAttach: [PersistedSession]; tombstones: [PersistedSession] }`
  - `RestorePlanner.plan(persisted: [PersistedSession], liveSessionIDs: Set<String>) -> RestorePlan`

- [ ] **Step 1: Create the package manifest**

`Claude Orchestrator.iOS/ClrcCore/Package.swift`:

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ClrcCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "ClrcCore", targets: ["ClrcCore"])
    ],
    targets: [
        .target(name: "ClrcCore"),
        .testTarget(name: "ClrcCoreTests", dependencies: ["ClrcCore"]),
    ]
)
```

Append to `.gitignore` (repo root):

```
# SwiftPM build artifacts
.build/
```

- [ ] **Step 2: Write the failing tests**

`Claude Orchestrator.iOS/ClrcCore/Tests/ClrcCoreTests/SessionNamingTests.swift`:

```swift
import Testing
@testable import ClrcCore

@Suite("SessionNaming")
struct SessionNamingTests {

    @Test("extracts project path from cd && claude command")
    func projectPathFromCommand() {
        #expect(SessionNaming.projectPath(from: #"cd "/Users/me/dev/drops" && claude"#) == "/Users/me/dev/drops")
        #expect(SessionNaming.projectPath(from: "cd ~/dev/drops && claude") == "~/dev/drops")
        #expect(SessionNaming.projectPath(from: "claude") == nil)
        #expect(SessionNaming.projectPath(from: nil) == nil)
        #expect(SessionNaming.projectPath(from: "") == nil)
    }

    @Test("names session after project folder")
    func autoNameFromProject() {
        #expect(SessionNaming.autoName(for: #"cd "/Users/me/dev/drops" && claude"#, index: 3) == "drops")
    }

    @Test("marks dangerous sessions")
    func autoNameDangerous() {
        let name = SessionNaming.autoName(
            for: #"cd "/Users/me/dev/drops" && claude --dangerously-skip-permissions"#, index: 1)
        #expect(name == "drops ⚠")
        #expect(SessionNaming.autoName(for: "claude --dangerously-skip-permissions", index: 1) == "Claude ⚠")
    }

    @Test("falls back to generic names")
    func autoNameFallbacks() {
        #expect(SessionNaming.autoName(for: nil, index: 2) == "Session 2")
        #expect(SessionNaming.autoName(for: "  ", index: 2) == "Session 2")
        #expect(SessionNaming.autoName(for: "claude", index: 4) == "Claude 4")
        #expect(SessionNaming.autoName(for: "htop", index: 5) == "Session 5")
    }
}
```

`Claude Orchestrator.iOS/ClrcCore/Tests/ClrcCoreTests/RestorePlannerTests.swift`:

```swift
import Foundation
import Testing
@testable import ClrcCore

@Suite("RestorePlanner")
struct RestorePlannerTests {

    private func session(_ id: String) -> PersistedSession {
        PersistedSession(id: id, agentID: "agent-1", agentName: "mac",
                         customName: "s-\(id)", projectPath: nil, createdAt: Date(timeIntervalSince1970: 0))
    }

    @Test("splits persisted sessions into alive and tombstones")
    func splitAliveDead() {
        let persisted = [session("a"), session("b"), session("c")]
        let plan = RestorePlanner.plan(persisted: persisted, liveSessionIDs: ["a", "c", "unrelated"])
        #expect(plan.toAttach.map(\.id) == ["a", "c"])
        #expect(plan.tombstones.map(\.id) == ["b"])
    }

    @Test("no live sessions → everything tombstoned")
    func allDead() {
        let plan = RestorePlanner.plan(persisted: [session("a")], liveSessionIDs: [])
        #expect(plan.toAttach.isEmpty)
        #expect(plan.tombstones.map(\.id) == ["a"])
    }

    @Test("nothing persisted → empty plan")
    func emptyInput() {
        let plan = RestorePlanner.plan(persisted: [], liveSessionIDs: ["x"])
        #expect(plan.toAttach.isEmpty && plan.tombstones.isEmpty)
    }
}
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `cd "Claude Orchestrator.iOS/ClrcCore" && swift test`
Expected: compile FAIL — `SessionNaming`, `PersistedSession`, `RestorePlanner` not found.

- [ ] **Step 4: Implement the three source files**

`Sources/ClrcCore/PersistedSession.swift`:

```swift
import Foundation

/// A terminal session as remembered by the iOS app between launches.
public struct PersistedSession: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let agentID: String
    public let agentName: String
    public var customName: String
    public var projectPath: String?
    public let createdAt: Date

    public init(id: String, agentID: String, agentName: String,
                customName: String, projectPath: String? = nil, createdAt: Date = Date()) {
        self.id = id
        self.agentID = agentID
        self.agentName = agentName
        self.customName = customName
        self.projectPath = projectPath
        self.createdAt = createdAt
    }
}
```

`Sources/ClrcCore/SessionNaming.swift` (logic moved verbatim from `SessionManager.autoName`/`extractLastDir`; Task 7 deletes the originals):

```swift
import Foundation

/// Derives display names and project paths from the shell command a session was started with.
public enum SessionNaming {

    /// Extracts the directory from a "cd <path> && …" prefix, if present.
    public static func projectPath(from command: String?) -> String? {
        guard let cmd = command else { return nil }
        let pattern = #"cd\s+["']?([^"'&\r\n]+?)["']?\s*&&"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: cmd, range: NSRange(cmd.startIndex..., in: cmd)),
              let range = Range(match.range(at: 1), in: cmd) else { return nil }
        let path = String(cmd[range]).trimmingCharacters(in: .whitespaces)
        return path.isEmpty ? nil : path
    }

    public static func autoName(for command: String?, index: Int) -> String {
        guard let cmd = command?.trimmingCharacters(in: .whitespacesAndNewlines),
              !cmd.isEmpty else {
            return "Session \(index)"
        }
        let dangerous = cmd.contains("--dangerously-skip-permissions")
        let warning = dangerous ? " ⚠" : ""

        if let path = projectPath(from: cmd) {
            let last = (path as NSString).lastPathComponent
            if !last.isEmpty { return last + warning }
        }
        if cmd.contains("claude") {
            return dangerous ? "Claude ⚠" : "Claude \(index)"
        }
        return "Session \(index)"
    }
}
```

`Sources/ClrcCore/RestorePlanner.swift`:

```swift
/// Splits persisted sessions into those still alive on the agent (reattach)
/// and those whose PTY is gone (tombstones).
public struct RestorePlan: Equatable, Sendable {
    public let toAttach: [PersistedSession]
    public let tombstones: [PersistedSession]

    public init(toAttach: [PersistedSession], tombstones: [PersistedSession]) {
        self.toAttach = toAttach
        self.tombstones = tombstones
    }
}

public enum RestorePlanner {
    public static func plan(persisted: [PersistedSession],
                            liveSessionIDs: Set<String>) -> RestorePlan {
        RestorePlan(
            toAttach: persisted.filter { liveSessionIDs.contains($0.id) },
            tombstones: persisted.filter { !liveSessionIDs.contains($0.id) }
        )
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `cd "Claude Orchestrator.iOS/ClrcCore" && swift test`
Expected: PASS (8 tests).

- [ ] **Step 6: Commit**

```bash
git add "Claude Orchestrator.iOS/ClrcCore" .gitignore
git commit -m "feat(ios): add ClrcCore package with session naming and restore planner"
```

---

### Task 4: ClrcCore — SessionsStore and RemoteSessionInfo

**Files:**
- Create: `Claude Orchestrator.iOS/ClrcCore/Sources/ClrcCore/SessionsStore.swift`
- Create: `Claude Orchestrator.iOS/ClrcCore/Sources/ClrcCore/RemoteSessionInfo.swift`
- Create: `Claude Orchestrator.iOS/ClrcCore/Tests/ClrcCoreTests/SessionsStoreTests.swift`
- Create: `Claude Orchestrator.iOS/ClrcCore/Tests/ClrcCoreTests/RemoteSessionInfoTests.swift`

**Interfaces:**
- Consumes: `PersistedSession` from Task 3.
- Produces (used by Tasks 6, 7, 8):
  - `SessionsStore(directory: URL)` — synchronous file-backed store. Methods: `upsert(_:)`, `remove(id:)`, `rename(id:to:)`, `sessions(forAgent:) -> [PersistedSession]`, `addRecentProject(_:agentID:)`, `recentProjects(forAgent:) -> [String]`; property `sessions: [PersistedSession]`.
  - `RemoteSessionInfo(dict: [String: Any])` failable init; fields `id: String`, `cols: Int`, `rows: Int`, `name: String?`, `command: String?`, `started: Date?`.

- [ ] **Step 1: Write the failing tests**

`Tests/ClrcCoreTests/SessionsStoreTests.swift`:

```swift
import Foundation
import Testing
@testable import ClrcCore

@Suite("SessionsStore")
struct SessionsStoreTests {

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("clrc-store-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func session(_ id: String, agentID: String = "agent-1") -> PersistedSession {
        PersistedSession(id: id, agentID: agentID, agentName: "mac",
                         customName: "name-\(id)", projectPath: "/tmp/\(id)",
                         createdAt: Date(timeIntervalSince1970: 100))
    }

    @Test("round-trips sessions across store instances")
    func persistence() throws {
        let dir = try makeTempDir()
        let store = SessionsStore(directory: dir)
        store.upsert(session("a"))
        store.upsert(session("b", agentID: "agent-2"))

        let reloaded = SessionsStore(directory: dir)
        #expect(reloaded.sessions.count == 2)
        #expect(reloaded.sessions(forAgent: "agent-1").map(\.id) == ["a"])
        #expect(reloaded.sessions(forAgent: "agent-2").map(\.id) == ["b"])
    }

    @Test("upsert replaces an existing entry")
    func upsertReplaces() throws {
        let dir = try makeTempDir()
        let store = SessionsStore(directory: dir)
        store.upsert(session("a"))
        var updated = session("a")
        updated.customName = "renamed"
        store.upsert(updated)
        #expect(store.sessions.count == 1)
        #expect(store.sessions[0].customName == "renamed")
    }

    @Test("remove and rename persist")
    func removeAndRename() throws {
        let dir = try makeTempDir()
        let store = SessionsStore(directory: dir)
        store.upsert(session("a"))
        store.upsert(session("b"))
        store.remove(id: "a")
        store.rename(id: "b", to: "fancy")

        let reloaded = SessionsStore(directory: dir)
        #expect(reloaded.sessions.map(\.id) == ["b"])
        #expect(reloaded.sessions[0].customName == "fancy")
    }

    @Test("recent projects: MRU order, dedupe, cap of 8")
    func recents() throws {
        let dir = try makeTempDir()
        let store = SessionsStore(directory: dir)
        for i in 1...10 {
            store.addRecentProject("/p/\(i)", agentID: "agent-1")
        }
        store.addRecentProject("/p/5", agentID: "agent-1") // re-use bumps to front

        let recents = store.recentProjects(forAgent: "agent-1")
        #expect(recents.count == 8)
        #expect(recents.first == "/p/5")
        #expect(!recents.contains("/p/1")) // evicted
        #expect(store.recentProjects(forAgent: "other").isEmpty)
    }

    @Test("corrupt store file starts empty instead of crashing")
    func corruptFile() throws {
        let dir = try makeTempDir()
        try Data("{broken json".utf8)
            .write(to: dir.appendingPathComponent("sessions-store.json"))
        let store = SessionsStore(directory: dir)
        #expect(store.sessions.isEmpty)
        store.upsert(session("a")) // and recovers by writing fresh state
        #expect(SessionsStore(directory: dir).sessions.count == 1)
    }
}
```

`Tests/ClrcCoreTests/RemoteSessionInfoTests.swift`:

```swift
import Foundation
import Testing
@testable import ClrcCore

@Suite("RemoteSessionInfo")
struct RemoteSessionInfoTests {

    @Test("parses a full agent entry")
    func fullEntry() {
        let dict: [String: Any] = [
            "id": "abc", "cols": 100, "rows": 30,
            "name": "drops.iOS", "command": "claude",
            "started": "2026-07-04T10:30:00Z",
        ]
        let info = RemoteSessionInfo(dict: dict)
        #expect(info?.id == "abc")
        #expect(info?.cols == 100)
        #expect(info?.rows == 30)
        #expect(info?.name == "drops.iOS")
        #expect(info?.command == "claude")
        #expect(info?.started == ISO8601DateFormatter().date(from: "2026-07-04T10:30:00Z"))
    }

    @Test("parses a legacy entry without metadata")
    func legacyEntry() {
        let info = RemoteSessionInfo(dict: ["id": "abc", "cols": 80, "rows": 24])
        #expect(info?.name == nil)
        #expect(info?.command == nil)
        #expect(info?.started == nil)
    }

    @Test("empty name is normalized to nil")
    func emptyName() {
        let info = RemoteSessionInfo(dict: ["id": "abc", "cols": 80, "rows": 24, "name": ""])
        #expect(info?.name == nil)
    }

    @Test("missing id → nil")
    func missingID() {
        #expect(RemoteSessionInfo(dict: ["cols": 80]) == nil)
        #expect(RemoteSessionInfo(dict: ["id": "", "cols": 80]) == nil)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd "Claude Orchestrator.iOS/ClrcCore" && swift test`
Expected: compile FAIL — `SessionsStore`, `RemoteSessionInfo` not found.

- [ ] **Step 3: Implement**

`Sources/ClrcCore/SessionsStore.swift`:

```swift
import Foundation
import os

/// File-backed store for persisted sessions and recent project paths.
/// Synchronous; intended to be called from the main actor only.
public final class SessionsStore {

    public private(set) var sessions: [PersistedSession] = []
    private var recentsByAgent: [String: [String]] = [:]

    private let fileURL: URL
    private static let maxRecents = 8
    private static let log = Logger(subsystem: "clrc", category: "SessionsStore")

    private struct StoreFile: Codable {
        var sessions: [PersistedSession] = []
        var recentsByAgent: [String: [String]] = [:]
    }

    public init(directory: URL) {
        self.fileURL = directory.appendingPathComponent("sessions-store.json")
        load()
    }

    // MARK: - Sessions

    public func upsert(_ session: PersistedSession) {
        sessions = sessions.filter { $0.id != session.id } + [session]
        save()
    }

    public func remove(id: String) {
        sessions = sessions.filter { $0.id != id }
        save()
    }

    public func rename(id: String, to name: String) {
        sessions = sessions.map { s in
            guard s.id == id else { return s }
            var copy = s
            copy.customName = name
            return copy
        }
        save()
    }

    public func sessions(forAgent agentID: String) -> [PersistedSession] {
        sessions.filter { $0.agentID == agentID }
    }

    // MARK: - Recent projects

    public func addRecentProject(_ path: String, agentID: String) {
        var list = recentsByAgent[agentID] ?? []
        list.removeAll { $0 == path }
        list.insert(path, at: 0)
        recentsByAgent[agentID] = Array(list.prefix(Self.maxRecents))
        save()
    }

    public func recentProjects(forAgent agentID: String) -> [String] {
        recentsByAgent[agentID] ?? []
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return } // first launch
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let file = try? decoder.decode(StoreFile.self, from: data) else {
            Self.log.error("corrupt store at \(self.fileURL.path) — starting empty")
            return
        }
        sessions = file.sessions
        recentsByAgent = file.recentsByAgent
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try encoder.encode(StoreFile(sessions: sessions, recentsByAgent: recentsByAgent))
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // Persistence failure must never break the live session UI.
            Self.log.error("save failed: \(error.localizedDescription)")
        }
    }
}
```

`Sources/ClrcCore/RemoteSessionInfo.swift`:

```swift
import Foundation

/// One entry of the agent's `sessions_list` reply.
public struct RemoteSessionInfo: Equatable, Sendable, Identifiable {
    public let id: String
    public let cols: Int
    public let rows: Int
    public let name: String?
    public let command: String?
    public let started: Date?

    private static let iso = ISO8601DateFormatter()

    public init?(dict: [String: Any]) {
        guard let id = dict["id"] as? String, !id.isEmpty else { return nil }
        self.id = id
        self.cols = dict["cols"] as? Int ?? 80
        self.rows = dict["rows"] as? Int ?? 24
        let name = dict["name"] as? String
        self.name = (name?.isEmpty == false) ? name : nil
        let command = dict["command"] as? String
        self.command = (command?.isEmpty == false) ? command : nil
        self.started = (dict["started"] as? String).flatMap { Self.iso.date(from: $0) }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd "Claude Orchestrator.iOS/ClrcCore" && swift test`
Expected: PASS (17 tests total).

- [ ] **Step 5: Commit**

```bash
git add "Claude Orchestrator.iOS/ClrcCore"
git commit -m "feat(ios): add SessionsStore and RemoteSessionInfo to ClrcCore"
```

---

### Task 5: Wire ClrcCore into the Xcode project

**Files:**
- Modify: `Claude Orchestrator.iOS/Claude Orchestrator.xcodeproj/project.pbxproj`

**Interfaces:**
- Produces: app target can `import ClrcCore`. Tasks 6–8 depend on this.

The project is small (358 lines) and uses Xcode 16 format. Four precise edits add a local package reference. New object IDs are 24-char hex, chosen to not collide with existing IDs.

- [ ] **Step 1: Add the build file** — in the `PBXBuildFile` section, after the SwiftTerm line:

```
		11AA00012F5000010000AA01 /* ClrcCore in Frameworks */ = {isa = PBXBuildFile; productRef = 11AA00022F5000020000AA02 /* ClrcCore */; };
```

- [ ] **Step 2: Add to Frameworks phase** — in `PBXFrameworksBuildPhase`, `files = (` list, after the SwiftTerm entry:

```
				11AA00012F5000010000AA01 /* ClrcCore in Frameworks */,
```

- [ ] **Step 3: Add to target dependencies** — in `PBXNativeTarget`, `packageProductDependencies = (` list, after the SwiftTerm entry:

```
				11AA00022F5000020000AA02 /* ClrcCore */,
```

- [ ] **Step 4: Add to project package references** — in `PBXProject`, `packageReferences = (` list, after the SwiftTerm entry:

```
				11AA00032F5000030000AA03 /* XCLocalSwiftPackageReference "ClrcCore" */,
```

- [ ] **Step 5: Add the two new sections** — before the `XCRemoteSwiftPackageReference` section:

```
/* Begin XCLocalSwiftPackageReference section */
		11AA00032F5000030000AA03 /* XCLocalSwiftPackageReference "ClrcCore" */ = {
			isa = XCLocalSwiftPackageReference;
			relativePath = ClrcCore;
		};
/* End XCLocalSwiftPackageReference section */
```

and inside the existing `XCSwiftPackageProductDependency` section, after the SwiftTerm entry:

```
		11AA00022F5000020000AA02 /* ClrcCore */ = {
			isa = XCSwiftPackageProductDependency;
			productName = ClrcCore;
		};
```

(Note: local package product dependencies have no `package =` line — that is correct for `XCLocalSwiftPackageReference`.)

- [ ] **Step 6: Verify the project resolves and builds**

```bash
cd "Claude Orchestrator.iOS"
xcodebuild -project "Claude Orchestrator.xcodeproj" -list
xcodebuild -project "Claude Orchestrator.xcodeproj" -scheme "Claude Orchestrator" \
  -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' build 2>&1 | tail -5
```
Expected: `-list` still shows the target (pbxproj parses); build ends with `** BUILD SUCCEEDED **`.
If the build fails on package resolution, re-check the five edits — every ID must appear exactly twice (definition + reference), except the build-file ID which appears twice as shown.

- [ ] **Step 7: Smoke-test the import** — add `import ClrcCore` at the top of `Claude Orchestrator/App/ClaudeTerminalApp.swift` (leave the rest unchanged; Task 7 uses it), rebuild with the same command.
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 8: Commit**

```bash
git add "Claude Orchestrator.iOS/Claude Orchestrator.xcodeproj/project.pbxproj" \
        "Claude Orchestrator.iOS/Claude Orchestrator/App/ClaudeTerminalApp.swift"
git commit -m "build(ios): link local ClrcCore package into app target"
```

---

### Task 6: RelayWebSocket — named connect + typed session-list API

**Files:**
- Modify: `Claude Orchestrator.iOS/Claude Orchestrator/Services/RelayWebSocket.swift`
- Modify: `Claude Orchestrator.iOS/Claude Orchestrator/Views/AgentListView.swift`

**Interfaces:**
- Consumes: `RemoteSessionInfo` (Task 4).
- Produces (Task 7/8 rely on these):
  - `sendConnect(agentID:sessionID:cols:rows:name:)` — `name: String? = nil`.
  - `requestSessionList(agentID:completion:)` — `completion: ([RemoteSessionInfo]?) -> Void`; `nil` = timeout (3 s), `[]` = agent reports none. The old `onSessionsList` callback and `requestSessionList(agentID:requestID:)` are REMOVED.

- [ ] **Step 1: Update RelayWebSocket**

Add `import ClrcCore` at the top.

Replace the `onSessionsList` property (line ~35):

```swift
    // Pending sessions_list callbacks — keyed by request_id, consumed once (nil = timeout)
    private var pendingSessionListRequests: [String: ([RemoteSessionInfo]?) -> Void] = [:]
```

Replace `sendConnect` :

```swift
    func sendConnect(agentID: String, sessionID: String, cols: Int, rows: Int, name: String? = nil) {
        var payload: [String: Any] = [
            "agent_id": agentID,
            "session_id": sessionID,
            "cols": cols,
            "rows": rows
        ]
        if let name, !name.isEmpty {
            payload["name"] = name
        }
        sendJSON(["type": "connect", "payload": payload])
    }
```

Replace `requestSessionList(agentID:requestID:)`:

```swift
    /// Requests live sessions from an agent. Completion runs exactly once:
    /// with the parsed list, or nil after a 3-second timeout.
    func requestSessionList(agentID: String, completion: @escaping ([RemoteSessionInfo]?) -> Void) {
        let requestID = UUID().uuidString
        pendingSessionListRequests[requestID] = completion
        sendJSON([
            "type": "list_sessions",
            "payload": ["agent_id": agentID, "request_id": requestID] as [String: Any]
        ])
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self else { return }
            self.pendingSessionListRequests.removeValue(forKey: requestID)?(nil)
        }
    }
```

Replace the `case "sessions_list":` handler:

```swift
        case "sessions_list":
            if let requestID = payload["request_id"] as? String {
                let raw = payload["sessions"] as? [[String: Any]] ?? []
                let infos = raw.compactMap(RemoteSessionInfo.init(dict:))
                pendingSessionListRequests.removeValue(forKey: requestID)?(infos)
            }
```

- [ ] **Step 2: Update AgentListView to the new API**

Add `import ClrcCore`. Replace the picker state and `connectTapped`:

```swift
    // Session picker state
    @State private var selectedAgent: Agent?
    @State private var existingSessions: [RemoteSessionInfo] = []
    @State private var isLoadingSessions = false
```

```swift
    private func connectTapped(agent: Agent) {
        existingSessions = []
        isLoadingSessions = true
        relay.requestSessionList(agentID: agent.id) { sessions in
            existingSessions = sessions ?? []
            isLoadingSessions = false
        }
        selectedAgent = agent
    }
```
(Delete the old requestID plumbing and the manual 3 s timeout `Task` — the relay API owns the timeout now.)

Update `SessionPickerView` to typed, readable rows (replace `existing: [[String: Any]]` and the row body; delete the `Dictionary` helpers extension at the bottom of the file):

```swift
struct SessionPickerView: View {
    let agent: Agent
    let existing: [RemoteSessionInfo]
    let isLoading: Bool
    let onPick: (String?) -> Void  // nil = new session

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            List {
                Section {
                    Button {
                        onPick(nil)
                    } label: {
                        Label("New Session", systemImage: "plus.circle.fill")
                            .foregroundStyle(Color.accentColor)
                    }
                }

                if isLoading {
                    Section("Existing Sessions") {
                        HStack {
                            ProgressView().padding(.trailing, 8)
                            Text("Loading sessions…").foregroundStyle(.secondary)
                        }
                    }
                } else if !existing.isEmpty {
                    Section("Existing Sessions") {
                        ForEach(existing) { session in
                            Button {
                                onPick(session.id)
                            } label: {
                                HStack {
                                    Image(systemName: "terminal")
                                        .foregroundStyle(.secondary)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(session.name ?? String(session.id.prefix(8)) + "…")
                                            .font(.body)
                                        Text(sessionSubtitle(session))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: "arrow.right.circle")
                                        .foregroundStyle(Color.accentColor)
                                }
                            }
                            .foregroundStyle(.primary)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(agent.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private func sessionSubtitle(_ session: RemoteSessionInfo) -> String {
        var parts: [String] = []
        if let command = session.command { parts.append(command) }
        if let started = session.started {
            parts.append("since " + started.formatted(date: .omitted, time: .shortened))
        }
        parts.append("\(session.cols)×\(session.rows)")
        return parts.joined(separator: " · ")
    }
}
```

In the `.sheet(item: $selectedAgent)` callback, the reattach branch gains the name (SessionManager signature updated in Task 7 — for now keep the existing call compiling):

```swift
                if let sid = sessionID {
                    sessionManager.attachSession(agentID: agent.id, sessionID: sid, agentName: agent.name)
                } else {
                    sessionManager.createSession(for: agent)
                }
```
(unchanged in this task).

- [ ] **Step 3: Build**

```bash
cd "Claude Orchestrator.iOS"
xcodebuild -project "Claude Orchestrator.xcodeproj" -scheme "Claude Orchestrator" \
  -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' build 2>&1 | tail -5
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
git add "Claude Orchestrator.iOS/Claude Orchestrator/Services/RelayWebSocket.swift" \
        "Claude Orchestrator.iOS/Claude Orchestrator/Views/AgentListView.swift"
git commit -m "feat(ios): named connect + typed sessions_list API with readable reattach picker"
```

---

### Task 7: SessionManager — persistence, restore, tombstones

**Files:**
- Create: `Claude Orchestrator.iOS/Claude Orchestrator/Services/SessionManager.swift`
- Modify: `Claude Orchestrator.iOS/Claude Orchestrator/App/ClaudeTerminalApp.swift` (delete the SessionManager class from it)

**Interfaces:**
- Consumes: `SessionsStore`, `RestorePlanner`, `SessionNaming`, `PersistedSession`, `RemoteSessionInfo` (Tasks 3–4); `relay.sendConnect(name:)`, `relay.requestSessionList(agentID:completion:)` (Task 6).
- Produces (Task 8 relies on):
  - `@Published var tombstones: [PersistedSession]`
  - `func createSession(for agent: Agent, initialCommand: String? = nil)` (same as today)
  - `func attachSession(agentID:sessionID:agentName:customName:)` — `customName: String? = nil`
  - `func rename(_ session: TerminalSession, to name: String)`
  - `func close(_ session: TerminalSession)` (replaces `remove(session:)`)
  - `func closeAll()`
  - `func restartTombstone(_ tombstone: PersistedSession)`
  - `func removeTombstone(id: String)`

- [ ] **Step 1: Create `Services/SessionManager.swift`**

Move the class out of `ClaudeTerminalApp.swift` and extend it. Full new file:

```swift
import Foundation
import Combine
import ClrcCore

/// Manages creation, persistence, restore and lifecycle of terminal sessions.
@MainActor
final class SessionManager: ObservableObject {
    @Published var sessions: [TerminalSession] = []
    /// Persisted sessions whose PTY is gone — shown as "Ended" with a restart option.
    @Published var tombstones: [PersistedSession] = []

    private let relay: RelayWebSocket
    private let store: SessionsStore
    private var sessionCounter = 0
    private var cancellables = Set<AnyCancellable>()
    /// IDs of agents currently known to be online — detects new arrivals vs list refreshes.
    private var knownAgentIDs = Set<String>()

    static func defaultStore() -> SessionsStore {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("clrc", isDirectory: true)
        return SessionsStore(directory: dir)
    }

    init(relay: RelayWebSocket, store: SessionsStore) {
        self.relay = relay
        self.store = store

        // Reconcile persisted sessions whenever an agent (re)appears.
        relay.$agents
            .receive(on: RunLoop.main)
            .sink { [weak self] agents in
                guard let self else { return }
                let connectedIDs = Set(agents.filter { $0.connected }.map { $0.id })
                let newIDs = connectedIDs.subtracting(self.knownAgentIDs)
                self.knownAgentIDs = connectedIDs
                for agent in agents where newIDs.contains(agent.id) {
                    self.reconcile(agent)
                }
            }
            .store(in: &cancellables)

        relay.onSessionReady = { [weak self] sessionID in
            guard let self else { return }
            if let session = self.sessions.first(where: { $0.id == sessionID }) {
                guard !session.isReady else { return } // already sent initialCommand, skip on reconnect
                session.isReady = true
                if let cmd = session.initialCommand {
                    self.relay.sendInput(sessionID: sessionID, data: Data((cmd + "\n").utf8))
                }
            }
        }

        // After every reconnect, re-register all live sessions with the relay.
        relay.onConnect = { [weak self] in
            guard let self else { return }
            for session in self.sessions {
                self.relay.sendConnect(
                    agentID: session.agent.id,
                    sessionID: session.id,
                    cols: session.lastCols,
                    rows: session.lastRows,
                    name: session.customName
                )
            }
        }
    }

    // MARK: - Restore

    /// Match persisted sessions against the agent's live PTYs:
    /// reattach the alive ones, tombstone the dead ones,
    /// auto-create a first tab only when there is nothing to restore.
    private func reconcile(_ agent: Agent) {
        let alreadyLive = Set(sessions.map(\.id))
        let persisted = store.sessions(forAgent: agent.id).filter { !alreadyLive.contains($0.id) }

        guard !persisted.isEmpty else {
            autoCreateIfEmpty(for: agent)
            return
        }

        relay.requestSessionList(agentID: agent.id) { [weak self] remote in
            guard let self else { return }
            guard let remote else {
                // Timeout — unknown state. Keep persisted entries, retry on next arrival.
                return
            }
            let plan = RestorePlanner.plan(
                persisted: persisted,
                liveSessionIDs: Set(remote.map(\.id))
            )
            for entry in plan.toAttach {
                self.attachSession(
                    agentID: entry.agentID,
                    sessionID: entry.id,
                    agentName: entry.agentName,
                    customName: entry.customName
                )
            }
            let known = Set(self.tombstones.map(\.id))
            self.tombstones += plan.tombstones.filter { !known.contains($0.id) }
            self.autoCreateIfEmpty(for: agent)
        }
    }

    private func autoCreateIfEmpty(for agent: Agent) {
        let hasAny = sessions.contains { $0.agent.id == agent.id }
            || !tombstones.filter { $0.agentID == agent.id }.isEmpty
        if !hasAny {
            createSession(for: agent)
        }
    }

    // MARK: - Create / attach

    func createSession(for agent: Agent, initialCommand: String? = nil) {
        sessionCounter += 1
        let name = SessionNaming.autoName(for: initialCommand, index: sessionCounter)
        let session = TerminalSession(agent: agent, customName: name, initialCommand: initialCommand)
        sessions.append(session)

        let projectPath = SessionNaming.projectPath(from: initialCommand)
        store.upsert(PersistedSession(
            id: session.id,
            agentID: agent.id,
            agentName: agent.name,
            customName: name,
            projectPath: projectPath
        ))
        if let projectPath {
            store.addRecentProject(projectPath, agentID: agent.id)
        }
        relay.sendConnect(agentID: agent.id, sessionID: session.id, cols: 80, rows: 24, name: name)
    }

    /// Attach to an existing PTY session on the agent (session_id already known).
    func attachSession(agentID: String, sessionID: String, agentName: String, customName: String? = nil) {
        guard !sessions.contains(where: { $0.id == sessionID }) else { return }
        sessionCounter += 1
        let name = customName ?? "Session \(sessionCounter)"
        let session = TerminalSession(
            agentID: agentID,
            agentName: agentName,
            sessionID: sessionID,
            customName: name
        )
        sessions.append(session)
        tombstones.removeAll { $0.id == sessionID }

        // Preserve an existing store entry's projectPath if we have one.
        let existing = store.sessions.first { $0.id == sessionID }
        store.upsert(PersistedSession(
            id: sessionID,
            agentID: agentID,
            agentName: agentName,
            customName: name,
            projectPath: existing?.projectPath,
            createdAt: existing?.createdAt ?? Date()
        ))
        relay.sendConnect(agentID: agentID, sessionID: sessionID, cols: 80, rows: 24, name: name)
    }

    // MARK: - Rename / close

    func rename(_ session: TerminalSession, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        session.customName = trimmed
        store.rename(id: session.id, to: trimmed)
        // Re-connect is a reattach on the agent side: it re-points output and stores the new name.
        relay.sendConnect(
            agentID: session.agent.id,
            sessionID: session.id,
            cols: session.lastCols,
            rows: session.lastRows,
            name: trimmed
        )
    }

    /// Explicitly close a session: kills the PTY on the Mac and forgets it.
    func close(_ session: TerminalSession) {
        relay.sendDisconnect(sessionID: session.id)
        relay.unregisterSessionHandler(sessionID: session.id)
        store.remove(id: session.id)
        sessions.removeAll { $0.id == session.id }
    }

    func closeAll() {
        for session in sessions {
            close(session)
        }
    }

    // MARK: - Tombstones

    /// Start a fresh session in the dead session's project folder.
    func restartTombstone(_ tombstone: PersistedSession) {
        removeTombstone(id: tombstone.id)
        guard let agent = agentFor(id: tombstone.agentID) else { return }
        if let path = tombstone.projectPath {
            createSession(for: agent, initialCommand: "cd \"\(path)\" && claude")
        } else {
            createSession(for: agent)
        }
    }

    func removeTombstone(id: String) {
        tombstones.removeAll { $0.id == id }
        store.remove(id: id)
    }

    private func agentFor(id: String) -> Agent? {
        relay.agents.first { $0.id == id && $0.connected }
    }
}
```

- [ ] **Step 2: Update `App/ClaudeTerminalApp.swift`**

Delete the whole `// MARK: - SessionManager` section (the class moved). In `init()`, change the manager construction:

```swift
        let mgr = SessionManager(relay: ws, store: SessionManager.defaultStore())
```
Keep `import ClrcCore` (added in Task 5).

- [ ] **Step 3: Fix the two remaining callers of removed APIs**

In `Views/SessionTabsView.swift` (`MachineSelectorSheet`):

- Rename alert `Save` button action becomes:

```swift
            Button("Save") {
                if let session = sessionToRename {
                    sessionManager.rename(session, to: renameDraft)
                }
                sessionToRename = nil
            }
```

- `closeSession(_:)` becomes:

```swift
    private func closeSession(_ session: TerminalSession) {
        sessionManager.close(session)
        if selectedSessionID == session.id {
            selectedSessionID = sessionManager.sessions.first?.id
        }
    }
```

(`closeAll` call sites stay valid.)

- [ ] **Step 4: Build**

```bash
cd "Claude Orchestrator.iOS"
xcodebuild -project "Claude Orchestrator.xcodeproj" -scheme "Claude Orchestrator" \
  -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' build 2>&1 | tail -5
```
Expected: `** BUILD SUCCEEDED **`. Common failure: leftover references to `sessionManager.remove(session:)` — they were all replaced in Step 3.

- [ ] **Step 5: Run package tests once more (regression)**

Run: `cd "Claude Orchestrator.iOS/ClrcCore" && swift test`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add "Claude Orchestrator.iOS/Claude Orchestrator/Services/SessionManager.swift" \
        "Claude Orchestrator.iOS/Claude Orchestrator/App/ClaudeTerminalApp.swift" \
        "Claude Orchestrator.iOS/Claude Orchestrator/Views/SessionTabsView.swift"
git commit -m "feat(ios): persist sessions, auto-restore tabs on launch, tombstones for dead sessions"
```

---

### Task 8: New Session sheet + tombstone UI

**Files:**
- Create: `Claude Orchestrator.iOS/Claude Orchestrator/Views/NewSessionSheet.swift`
- Modify: `Claude Orchestrator.iOS/Claude Orchestrator/Views/SessionTabsView.swift`

**Interfaces:**
- Consumes: `sessionManager.createSession(for:initialCommand:)`, `store` recents via a small accessor added below, `sessionManager.restartTombstone(_:)`, `sessionManager.removeTombstone(id:)`, `@Published tombstones`.

- [ ] **Step 1: Expose recents through SessionManager**

Add to `Services/SessionManager.swift` (below the tombstone helpers):

```swift
    // MARK: - Recents

    func recentProjects(for agent: Agent) -> [String] {
        store.recentProjects(forAgent: agent.id)
    }
```

- [ ] **Step 2: Create `Views/NewSessionSheet.swift`**

```swift
import SwiftUI
import ClrcCore

/// Two-tap session creation: pick a Mac, tap a recent project (or browse).
struct NewSessionSheet: View {
    @EnvironmentObject var relay: RelayWebSocket
    @EnvironmentObject var sessionManager: SessionManager
    @Environment(\.dismiss) private var dismiss

    /// Preselected agent (current session's agent), if still online.
    let preferredAgentID: String?

    @State private var selectedAgentID: String?
    @State private var customName = ""
    @State private var showBrowser = false
    @AppStorage("default_skip_permissions") private var skipPermissions = false

    private var onlineAgents: [Agent] {
        relay.agents.filter(\.connected)
    }

    private var selectedAgent: Agent? {
        onlineAgents.first { $0.id == selectedAgentID } ?? onlineAgents.first
    }

    var body: some View {
        NavigationView {
            List {
                if onlineAgents.isEmpty {
                    Section {
                        Label("No agents online", systemImage: "desktopcomputer.trianglebadge.exclamationmark")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    if onlineAgents.count > 1 {
                        Section("Mac") {
                            Picker("Mac", selection: agentSelection) {
                                ForEach(onlineAgents) { agent in
                                    Text(shortName(agent.name)).tag(agent.id)
                                }
                            }
                            .pickerStyle(.menu)
                        }
                    }

                    if let agent = selectedAgent {
                        projectSection(agent: agent)
                        optionsSection
                        startSection(agent: agent)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("New Session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .sheet(isPresented: $showBrowser) {
                if let agent = selectedAgent {
                    FileBrowserView(agentID: agent.id, agentName: agent.name, embedded: false) { path, dangerous in
                        showBrowser = false
                        start(in: path, agent: agent, dangerous: dangerous)
                    }
                    .environmentObject(relay)
                }
            }
        }
        .onAppear {
            selectedAgentID = preferredAgentID ?? onlineAgents.first?.id
        }
    }

    private var agentSelection: Binding<String> {
        Binding(
            get: { selectedAgent?.id ?? "" },
            set: { selectedAgentID = $0 }
        )
    }

    // MARK: - Sections

    @ViewBuilder
    private func projectSection(agent: Agent) -> some View {
        Section("Project") {
            ForEach(sessionManager.recentProjects(for: agent), id: \.self) { path in
                Button {
                    start(in: path, agent: agent, dangerous: skipPermissions)
                } label: {
                    HStack {
                        Image(systemName: "clock.arrow.circlepath")
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text((path as NSString).lastPathComponent)
                                .foregroundStyle(.primary)
                            Text(path)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }
            }
            Button {
                showBrowser = true
            } label: {
                Label("Browse folders…", systemImage: "folder")
            }
        }
    }

    private var optionsSection: some View {
        Section("Options") {
            Toggle("Skip permissions (⚠ dangerous)", isOn: $skipPermissions)
            TextField("Name (optional)", text: $customName)
                .autocorrectionDisabled()
        }
    }

    private func startSection(agent: Agent) -> some View {
        Section {
            Button {
                start(in: nil, agent: agent, dangerous: skipPermissions)
            } label: {
                Label("Start Claude in home folder", systemImage: "sparkles")
            }
            Button {
                sessionManager.createSession(for: agent)
                dismiss()
            } label: {
                Label("Plain shell", systemImage: "terminal")
            }
        }
    }

    // MARK: - Actions

    private func start(in path: String?, agent: Agent, dangerous: Bool) {
        let claude = dangerous ? "claude --dangerously-skip-permissions" : "claude"
        let command = path.map { "cd \"\($0)\" && \(claude)" } ?? claude
        sessionManager.createSession(for: agent, initialCommand: command)
        renameIfNeeded()
        dismiss()
    }

    private func renameIfNeeded() {
        let trimmed = customName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let created = sessionManager.sessions.last else { return }
        sessionManager.rename(created, to: trimmed)
    }

    private func shortName(_ name: String) -> String {
        name.components(separatedBy: ".").first ?? name
    }
}
```

Note: `FileBrowserView(agentID:agentName:embedded:)` and its `(path, dangerous)` callback already exist (used in `SessionTabsView.filesTab`). If its `embedded: false` initializer presents its own navigation, keep the sheet as is; verify visually.

- [ ] **Step 3: Wire the “+” button and tombstones into `SessionTabsView.swift`**

Add state (next to `showAddAgent`):

```swift
    @State private var showNewSession = false
```

In `topBar`, insert a “+” button before the Settings button:

```swift
            // New session
            Button {
                showNewSession = true
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.plain)
```

Add the sheet (after the existing `.sheet(isPresented: $showAddAgent)`):

```swift
        .sheet(isPresented: $showNewSession) {
            NewSessionSheet(preferredAgentID: activeSession?.agent.id)
                .environmentObject(relay)
                .environmentObject(sessionManager)
        }
```

In `MachineSelectorSheet`'s `List`, add an “Ended sessions” section between the Mac Agents section and the footer actions:

```swift
                // ── Ended sessions (PTY gone) ────────────────────────────
                if !sessionManager.tombstones.isEmpty {
                    Section {
                        ForEach(sessionManager.tombstones) { tombstone in
                            HStack(spacing: 12) {
                                Image(systemName: "moon.zzz")
                                    .foregroundStyle(.tertiary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(tombstone.customName)
                                        .foregroundStyle(.secondary)
                                    if let path = tombstone.projectPath {
                                        Text(path)
                                            .font(.caption)
                                            .foregroundStyle(.tertiary)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                    }
                                }
                                Spacer()
                                Button {
                                    sessionManager.restartTombstone(tombstone)
                                    onDismiss()
                                } label: {
                                    Image(systemName: "arrow.clockwise.circle.fill")
                                        .font(.system(size: 22))
                                        .foregroundStyle(Color.accentColor)
                                }
                                .buttonStyle(.plain)
                            }
                            .swipeActions(edge: .trailing) {
                                Button("Remove", role: .destructive) {
                                    sessionManager.removeTombstone(id: tombstone.id)
                                }
                            }
                        }
                    } header: {
                        Label("Ended sessions", systemImage: "moon.zzz")
                    }
                }
```

- [ ] **Step 4: Build**

```bash
cd "Claude Orchestrator.iOS"
xcodebuild -project "Claude Orchestrator.xcodeproj" -scheme "Claude Orchestrator" \
  -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' build 2>&1 | tail -5
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add "Claude Orchestrator.iOS/Claude Orchestrator/Views/NewSessionSheet.swift" \
        "Claude Orchestrator.iOS/Claude Orchestrator/Views/SessionTabsView.swift" \
        "Claude Orchestrator.iOS/Claude Orchestrator/Services/SessionManager.swift"
git commit -m "feat(ios): New Session sheet with recent projects + ended-session restart"
```

---

### Task 9: Docs + full verification

**Files:**
- Modify: `CLAUDE.md` (protocol section)
- Modify: `README.md` (feature blurb, if it lists features)

- [ ] **Step 1: Update CLAUDE.md protocol notes**

In the “message protocol” section, add after the two-transport-channels paragraph:

```markdown
- `connect` carries an optional `name` (session display name). The agent persists it
  (`agent/session_store.go`) and returns `name`, `command`, `started` (RFC3339) per entry
  in `sessions_list`. All fields are optional — old clients/agents interoperate.
```

In the iOS bullet of the architecture overview, mention persistence:

```markdown
- **`Claude Orchestrator.iOS/`** — SwiftUI iPhone app (Xcode project). Terminal UI, agent list,
  file browser. Testable session logic lives in the local SwiftPM package
  `Claude Orchestrator.iOS/ClrcCore` (`swift test`); the app persists sessions locally and
  auto-reattaches to live PTYs on launch.
```

Update the build/test section:

```markdown
# iOS logic tests
cd "Claude Orchestrator.iOS/ClrcCore" && swift test
```

And update the “no automated tests” closing note to reflect that agent + ClrcCore now have tests.

- [ ] **Step 2: Full verification suite**

```bash
cd relay && go test -race ./... && go vet ./... && go build ./... && cd ..
cd agent && go test -race ./... && go vet ./... && go build ./... && cd ..
cd "Claude Orchestrator.iOS/ClrcCore" && swift test && cd ../..
cd "Claude Orchestrator.iOS" && xcodebuild -project "Claude Orchestrator.xcodeproj" \
  -scheme "Claude Orchestrator" -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' build 2>&1 | tail -3
```
Expected: everything PASS / BUILD SUCCEEDED.

- [ ] **Step 3: Manual E2E checklist (requires a device + running relay/agent)**

Report these as a checklist for the user to run — do not fake results:

1. Build to iPhone. Create two sessions in different folders via “+ → recent/browse”.
2. Kill the app. Relaunch → both tabs reappear with their names, terminal output resumes.
3. `clrc sessions` on the Mac shows the NAME column with the custom names.
4. Rename a session on iPhone; `clrc sessions` shows the new name after the rename.
5. `clrc restart` (kills PTYs) → app shows both sessions under “Ended sessions”; “Restart here” starts claude in the same folder.
6. Delete and reinstall the app → Agents list → agent → reattach picker shows session names, not UUIDs.

- [ ] **Step 4: Commit**

```bash
git add CLAUDE.md README.md
git commit -m "docs: document session name protocol extension and ClrcCore tests"
```

---

## Self-Review Notes (already applied)

- Spec §1 protocol → Tasks 1–2; §2 agent → Tasks 1–2; §3 store → Task 4; §4 restore → Task 7; §5 New Session sheet → Task 8; §6 error handling → timeout-nil path (Task 6/7), corrupt-store test (Task 4), tombstone-only-after-confirmed-list (Task 7); §7 testing → Tasks 1–4 + E2E checklist (Task 9).
- Type check: `attachSession(agentID:sessionID:agentName:customName:)` consistent between Tasks 6 (call site unchanged, default param) and 7 (definition); `RemoteSessionInfo` field names consistent across Tasks 4/6/7; `WriteSess`/`RenameSess` signatures consistent across Tasks 1/2.
- Known simplification: rename-sync re-sends `connect` (agent treats as reattach and renames) — deliberate, documented in Task 7 code comment.
