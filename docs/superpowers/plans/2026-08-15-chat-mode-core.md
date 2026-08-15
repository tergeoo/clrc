# Chat Mode Core — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a `chat` session kind where the Mac agent runs `claude` headless over `stream-json`, normalises its events, and the iPhone renders a native chat instead of a raw PTY of the Claude Code TUI.

**Architecture:** The agent owns translation. It spawns `claude -p --input-format stream-json --output-format stream-json --verbose`, converts the noisy internal JSONL into a small stable event set (`turn_start`, `text`, `tool_use`, `tool_result`, `turn_end`, `error`), stamps each with a monotonic `seq`, and streams them as text frames. The relay gains routing branches only — no new machinery. iOS gets a `ChatSession` type alongside the existing `TerminalSession`, with all replay/dedup logic in the testable `ClrcCore` package.

**Tech Stack:** Go 1.x (two modules: `agent/`, `relay/`), `nhooyr.io/websocket`, SwiftUI + SwiftPM (`ClrcCore`), Swift Testing.

**Spec:** `docs/superpowers/specs/2026-08-15-chat-mode-design.md`

## Global Constraints

- `gofmt` and `goimports` are mandatory on all Go files.
- Go tests run with `-race`: `go test -race ./...` inside each module dir. There is **no workspace root** — `cd agent` or `cd relay` first.
- Wrap errors with `%w` and context: `fmt.Errorf("start chat session %s: %w", id, err)`.
- 80% coverage target on new code.
- Swift: `let` over `var`, value types, Swift Testing (`import Testing`, `@Test`, `#expect`). iOS logic tests run via `cd "Claude Orchestrator.iOS/ClrcCore" && swift test`.
- The `Message` envelope struct exists in **three** places and must stay in sync: `relay/session.go`, `agent/ws_client.go`, iOS `RelayWebSocket.swift`.
- Tool `input`/`output` truncate at **4096 bytes**, setting `truncated: true`. The relay caps whole messages at 4 MB.
- Session IDs are lowercase UUID v4; the relay validates this (`relay/validation.go`).
- `cwd` must pass through `fsResolve` in `agent/fs_ops.go` and be rejected outside `$HOME`.
- Chat traffic uses **text** WebSocket frames only. The binary channel stays exclusively for PTY.
- Never log secrets, tokens, or full tool payloads.

## File Structure

**Create:**
- `agent/chat_events.go` — pure JSONL → `ChatEvent` translation
- `agent/chat_events_test.go`
- `agent/chat_buffer.go` — ring buffer, stamps `seq`
- `agent/chat_buffer_test.go`
- `agent/chat_session.go` — `claude` process lifecycle
- `agent/chat_session_test.go`
- `agent/testdata/chat_stream_basic.jsonl` — real captured stream
- `agent/testdata/fake_claude.sh` — canned-output stand-in for `claude`
- `relay/chat_routing_test.go` — first relay integration test
- `Claude Orchestrator.iOS/ClrcCore/Sources/ClrcCore/ChatEvent.swift`
- `Claude Orchestrator.iOS/ClrcCore/Sources/ClrcCore/ChatTranscript.swift`
- `Claude Orchestrator.iOS/ClrcCore/Tests/ClrcCoreTests/ChatEventTests.swift`
- `Claude Orchestrator.iOS/ClrcCore/Tests/ClrcCoreTests/ChatTranscriptTests.swift`
- `Claude Orchestrator.iOS/Claude Orchestrator/Models/ChatSession.swift`
- `Claude Orchestrator.iOS/Claude Orchestrator/Views/ChatSessionView.swift`

**Modify:**
- `agent/ws_client.go` — `connectReq` gains `Kind`/`Cwd`/`Model`; new `chat_*` cases
- `relay/hub.go` — text-routing helpers + `chat_*` switch branches
- `Claude Orchestrator.iOS/Claude Orchestrator/Services/RelayWebSocket.swift` — chat send/receive API
- `Claude Orchestrator.iOS/Claude Orchestrator/Services/SessionManager.swift` — hold two session kinds
- `Claude Orchestrator.iOS/Claude Orchestrator/Views/NewSessionSheet.swift` — start chat sessions
- `Claude Orchestrator.iOS/Claude Orchestrator/Views/SessionTabsView.swift` — render either kind

---

### Task 1: Verify `--resume` and capture real fixtures

The spec's one unverified assumption. Everything about surviving a reboot depends on it, so it is checked before anything is built on it. Output is an answer plus two committed fixtures.

**Files:**
- Create: `agent/testdata/chat_stream_basic.jsonl`
- Create: `agent/testdata/fake_claude.sh`

**Interfaces:**
- Consumes: nothing
- Produces: `agent/testdata/chat_stream_basic.jsonl` (real captured stream, used by Task 2/3 tests); `agent/testdata/fake_claude.sh` (used by Task 5)

- [ ] **Step 1: Capture a real two-turn stream**

Run from a scratch dir (not the repo). Substitute your own `claude` invocation if it is wrapped by an alias — an alias will not resolve inside a script.

```bash
SID=$(uuidgen | tr 'A-Z' 'a-z')
{
  printf '%s\n' '{"type":"user","message":{"role":"user","content":"Run: echo hello. Then reply DONE."}}'
  sleep 25
} | claude -p --input-format stream-json --output-format stream-json --verbose \
      --permission-mode bypassPermissions --session-id "$SID" \
      --model claude-haiku-4-5-20251001 > turn1.jsonl 2>&1
echo "session: $SID"
```

This must contain at least one `tool_use` (the `Bash` call) so the translator tests have real tool data.

- [ ] **Step 2: Verify `--resume` restores context**

```bash
printf '%s\n' '{"type":"user","message":{"role":"user","content":"What command did I ask you to run? Answer in one word."}}' \
  | claude -p --input-format stream-json --output-format stream-json --verbose \
      --permission-mode bypassPermissions --resume "$SID" \
      --model claude-haiku-4-5-20251001 > turn2.jsonl 2>&1
grep -o '"text":"[^"]*"' turn2.jsonl | tail -3
```

Expected: the reply references `echo`, proving context survived a **new process**. Note that `--session-id` is NOT passed here — only `--resume`.

**If this fails:** stop and report. The fallback in spec §7.2 (keep our own transcript and replay it as context) changes Task 5 and must be agreed before continuing.

- [ ] **Step 3: Commit the captured stream as a fixture**

```bash
cp turn1.jsonl "<repo>/agent/testdata/chat_stream_basic.jsonl"
```

- [ ] **Step 4: Write the fake `claude` stand-in**

This is what makes Task 5 testable without network or credentials. It reads JSONL user messages on stdin and emits a canned turn per message.

```bash
#!/bin/bash
# agent/testdata/fake_claude.sh — stand-in for `claude` in tests.
# Emits one canned turn per stdin line. Honours FAKE_CLAUDE_MODE:
#   normal (default) | badline | exit1 | hang
set -u
if [ "${FAKE_CLAUDE_MODE:-normal}" = "exit1" ]; then
  echo '{"type":"system","subtype":"init","session_id":"s"}'
  exit 1
fi
while IFS= read -r _line; do
  echo '{"type":"system","subtype":"init","session_id":"s","model":"m"}'
  echo '{"type":"system","subtype":"thinking_tokens","estimated_tokens":3}'
  if [ "${FAKE_CLAUDE_MODE:-normal}" = "badline" ]; then
    echo 'this is not json'
  fi
  echo '{"type":"assistant","message":{"role":"assistant","content":[{"type":"thinking","thinking":"hmm"},{"type":"text","text":"hello"}]}}'
  echo '{"type":"result","subtype":"success","is_error":false,"num_turns":1,"total_cost_usd":0.01,"duration_api_ms":42,"stop_reason":"end_turn","session_id":"s"}'
  if [ "${FAKE_CLAUDE_MODE:-normal}" = "hang" ]; then sleep 300; fi
done
```

- [ ] **Step 5: Make it executable and commit**

```bash
chmod +x agent/testdata/fake_claude.sh
git add agent/testdata/
git commit -m "test: real claude stream fixture and fake claude stand-in"
```

- [ ] **Step 6: Report the `--resume` result**

State plainly whether context survived. This gates Task 5.

---

### Task 2: Event model and translator — text, noise, turn markers

**Files:**
- Create: `agent/chat_events.go`
- Test: `agent/chat_events_test.go`

**Interfaces:**
- Consumes: `agent/testdata/chat_stream_basic.jsonl` (Task 1)
- Produces: `type ChatEvent struct`, `type ChatEventKind string`, constants `EventTurnStart/EventText/EventToolUse/EventToolResult/EventTurnEnd/EventError`, `func TranslateLine(line []byte, ts string) []ChatEvent`, `const maxPayloadBytes = 4096`

- [ ] **Step 1: Write the failing test**

```go
package agent

import (
	"testing"
)

func TestTranslateLine(t *testing.T) {
	tests := []struct {
		name  string
		line  string
		want  []ChatEventKind
		check func(t *testing.T, got []ChatEvent)
	}{
		{
			name: "init becomes turn_start",
			line: `{"type":"system","subtype":"init","session_id":"s","model":"m"}`,
			want: []ChatEventKind{EventTurnStart},
		},
		{
			name: "thinking_tokens is noise",
			line: `{"type":"system","subtype":"thinking_tokens","estimated_tokens":3}`,
			want: nil,
		},
		{
			name: "hook events are noise",
			line: `{"type":"system","subtype":"hook_started","session_id":"s"}`,
			want: nil,
		},
		{
			name: "rate_limit_event is noise",
			line: `{"type":"rate_limit_event","status":"ok"}`,
			want: nil,
		},
		{
			name: "assistant text block becomes text",
			line: `{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"hello"}]}}`,
			want: []ChatEventKind{EventText},
			check: func(t *testing.T, got []ChatEvent) {
				if got[0].Text != "hello" {
					t.Fatalf("text = %q, want %q", got[0].Text, "hello")
				}
			},
		},
		{
			name: "thinking block is dropped but sibling text survives",
			line: `{"type":"assistant","message":{"role":"assistant","content":[{"type":"thinking","thinking":"secret"},{"type":"text","text":"visible"}]}}`,
			want: []ChatEventKind{EventText},
			check: func(t *testing.T, got []ChatEvent) {
				if got[0].Text != "visible" {
					t.Fatalf("text = %q, want %q", got[0].Text, "visible")
				}
			},
		},
		{
			name: "result becomes turn_end with metrics",
			line: `{"type":"result","subtype":"success","is_error":false,"num_turns":2,"total_cost_usd":0.05,"duration_api_ms":4877,"stop_reason":"end_turn"}`,
			want: []ChatEventKind{EventTurnEnd},
			check: func(t *testing.T, got []ChatEvent) {
				e := got[0]
				if e.NumTurns != 2 || e.CostUSD != 0.05 || e.DurationMS != 4877 || e.StopReason != "end_turn" {
					t.Fatalf("metrics not carried: %+v", e)
				}
			},
		},
		{
			name: "result with is_error yields turn_end and error",
			line: `{"type":"result","subtype":"error","is_error":true,"num_turns":1}`,
			want: []ChatEventKind{EventTurnEnd, EventError},
		},
		{
			name: "malformed json yields nothing, never panics",
			line: `not json at all`,
			want: nil,
		},
		{
			name: "unknown type is ignored",
			line: `{"type":"something_new_in_a_future_cli"}`,
			want: nil,
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			got := TranslateLine([]byte(tc.line), "2026-08-15T00:00:00Z")
			if len(got) != len(tc.want) {
				t.Fatalf("got %d events %+v, want %d", len(got), got, len(tc.want))
			}
			for i := range tc.want {
				if got[i].Kind != tc.want[i] {
					t.Fatalf("event %d kind = %q, want %q", i, got[i].Kind, tc.want[i])
				}
			}
			if tc.check != nil {
				tc.check(t, got)
			}
		})
	}
}

func TestTranslateLineNeverAssignsSeq(t *testing.T) {
	got := TranslateLine([]byte(`{"type":"assistant","message":{"content":[{"type":"text","text":"x"}]}}`), "t")
	if len(got) != 1 {
		t.Fatalf("expected 1 event, got %d", len(got))
	}
	if got[0].Seq != 0 {
		t.Fatalf("translator must not assign seq, got %d", got[0].Seq)
	}
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd agent && go test -race -run TestTranslateLine ./...`
Expected: FAIL — `undefined: ChatEvent`, `undefined: TranslateLine`.

- [ ] **Step 3: Write minimal implementation**

```go
package agent

import "encoding/json"

// maxPayloadBytes caps tool input/output so a single event cannot approach
// the relay's 4 MB message limit (see spec §6.4).
const maxPayloadBytes = 4096

// ChatEventKind enumerates the normalised event types sent to clients.
// This is our contract — deliberately narrower and more stable than the
// Claude Code stream format it is derived from.
type ChatEventKind string

const (
	EventTurnStart  ChatEventKind = "turn_start"
	EventText       ChatEventKind = "text"
	EventToolUse    ChatEventKind = "tool_use"
	EventToolResult ChatEventKind = "tool_result"
	EventTurnEnd    ChatEventKind = "turn_end"
	EventError      ChatEventKind = "error"
)

// ChatEvent is one normalised event. Seq is stamped by ChatBuffer.Append,
// never by the translator — translation stays a pure function of its input.
type ChatEvent struct {
	Kind ChatEventKind `json:"kind"`
	Seq  uint64        `json:"seq"`
	TS   string        `json:"ts"`

	Text string `json:"text,omitempty"`

	ToolID    string `json:"tool_id,omitempty"`
	Name      string `json:"name,omitempty"`
	Input     string `json:"input,omitempty"`
	Output    string `json:"output,omitempty"`
	OK        *bool  `json:"ok,omitempty"`
	Truncated bool   `json:"truncated,omitempty"`

	NumTurns   int     `json:"num_turns,omitempty"`
	CostUSD    float64 `json:"cost_usd,omitempty"`
	DurationMS int     `json:"duration_ms,omitempty"`
	StopReason string  `json:"stop_reason,omitempty"`

	Message string `json:"message,omitempty"`
}

// rawLine is the subset of the Claude Code stream-json envelope we read.
type rawLine struct {
	Type    string `json:"type"`
	Subtype string `json:"subtype"`
	Message struct {
		Content []rawBlock `json:"content"`
	} `json:"message"`
	IsError       bool    `json:"is_error"`
	NumTurns      int     `json:"num_turns"`
	TotalCostUSD  float64 `json:"total_cost_usd"`
	DurationAPIMS int     `json:"duration_api_ms"`
	StopReason    string  `json:"stop_reason"`
}

type rawBlock struct {
	Type string `json:"type"`
	Text string `json:"text"`
}

// TranslateLine converts one raw JSONL line into zero or more normalised
// events. It is pure: no IO, no clock, no shared state. Unparseable input
// yields no events rather than an error — the CLI may write non-JSON to
// stdout and that must not kill a session.
func TranslateLine(line []byte, ts string) []ChatEvent {
	var raw rawLine
	if err := json.Unmarshal(line, &raw); err != nil {
		return nil
	}

	switch raw.Type {
	case "system":
		if raw.Subtype == "init" {
			return []ChatEvent{{Kind: EventTurnStart, TS: ts}}
		}
		return nil

	case "assistant":
		var out []ChatEvent
		for _, b := range raw.Message.Content {
			if b.Type == "text" && b.Text != "" {
				out = append(out, ChatEvent{Kind: EventText, TS: ts, Text: b.Text})
			}
		}
		return out

	case "result":
		out := []ChatEvent{{
			Kind:       EventTurnEnd,
			TS:         ts,
			NumTurns:   raw.NumTurns,
			CostUSD:    raw.TotalCostUSD,
			DurationMS: raw.DurationAPIMS,
			StopReason: raw.StopReason,
		}}
		if raw.IsError {
			out = append(out, ChatEvent{Kind: EventError, TS: ts, Message: "turn ended with an error"})
		}
		return out
	}

	return nil
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd agent && go test -race -run TestTranslateLine ./...`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
gofmt -w agent/chat_events.go agent/chat_events_test.go
git add agent/chat_events.go agent/chat_events_test.go
git commit -m "feat(agent): normalised chat event model and translator"
```

---

### Task 3: Translator — tool calls, results, truncation, real fixture

**Files:**
- Modify: `agent/chat_events.go`
- Test: `agent/chat_events_test.go`

**Interfaces:**
- Consumes: `TranslateLine`, `ChatEvent`, `maxPayloadBytes` (Task 2); `agent/testdata/chat_stream_basic.jsonl` (Task 1)
- Produces: `func truncatePayload(s string) (string, bool)`

- [ ] **Step 1: Write the failing tests**

Append to `agent/chat_events_test.go`:

```go
import (
	"bytes"
	"os"
	"strings"
	"testing"
)

func TestTranslateToolUse(t *testing.T) {
	line := `{"type":"assistant","message":{"content":[{"type":"tool_use","id":"toolu_01","name":"Bash","input":{"command":"echo hello"}}]}}`
	got := TranslateLine([]byte(line), "t")
	if len(got) != 1 || got[0].Kind != EventToolUse {
		t.Fatalf("got %+v, want one tool_use", got)
	}
	if got[0].ToolID != "toolu_01" || got[0].Name != "Bash" {
		t.Fatalf("tool identity lost: %+v", got[0])
	}
	if !strings.Contains(got[0].Input, "echo hello") {
		t.Fatalf("input not serialised: %q", got[0].Input)
	}
}

func TestTranslateToolResult(t *testing.T) {
	line := `{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"toolu_01","is_error":false,"content":"hello\n"}]}}`
	got := TranslateLine([]byte(line), "t")
	if len(got) != 1 || got[0].Kind != EventToolResult {
		t.Fatalf("got %+v, want one tool_result", got)
	}
	if got[0].ToolID != "toolu_01" {
		t.Fatalf("tool_use_id not carried: %+v", got[0])
	}
	if got[0].OK == nil || !*got[0].OK {
		t.Fatalf("ok should be true: %+v", got[0])
	}
	if got[0].Output != "hello\n" {
		t.Fatalf("output = %q", got[0].Output)
	}
}

func TestTranslateToolResultError(t *testing.T) {
	line := `{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","is_error":true,"content":"boom"}]}}`
	got := TranslateLine([]byte(line), "t")
	if len(got) != 1 || got[0].OK == nil || *got[0].OK {
		t.Fatalf("expected ok=false, got %+v", got)
	}
}

func TestTruncatePayload(t *testing.T) {
	short := "abc"
	if s, tr := truncatePayload(short); s != short || tr {
		t.Fatalf("short payload changed: %q %v", s, tr)
	}
	long := strings.Repeat("x", maxPayloadBytes+100)
	s, tr := truncatePayload(long)
	if !tr {
		t.Fatal("long payload should report truncated")
	}
	if len(s) > maxPayloadBytes {
		t.Fatalf("payload not capped: %d bytes", len(s))
	}
}

func TestToolResultIsTruncated(t *testing.T) {
	big := strings.Repeat("y", maxPayloadBytes+50)
	line := `{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"` + big + `"}]}}`
	got := TranslateLine([]byte(line), "t")
	if len(got) != 1 || !got[0].Truncated {
		t.Fatalf("expected truncated tool_result, got %+v", got)
	}
	if len(got[0].Output) > maxPayloadBytes {
		t.Fatalf("output not capped: %d", len(got[0].Output))
	}
}

// TestTranslateRealStream runs the translator over a real captured session.
// It guards against the noise ratio regressing and against panics on real data.
func TestTranslateRealStream(t *testing.T) {
	data, err := os.ReadFile("testdata/chat_stream_basic.jsonl")
	if err != nil {
		t.Fatalf("read fixture: %v", err)
	}
	var events []ChatEvent
	var lines int
	for _, line := range bytes.Split(data, []byte("\n")) {
		if len(bytes.TrimSpace(line)) == 0 {
			continue
		}
		lines++
		events = append(events, TranslateLine(line, "t")...)
	}
	if lines == 0 {
		t.Fatal("fixture is empty")
	}
	var haveTurnEnd, haveText bool
	for _, e := range events {
		switch e.Kind {
		case EventTurnEnd:
			haveTurnEnd = true
		case EventText:
			haveText = true
		}
	}
	if !haveTurnEnd {
		t.Error("real stream produced no turn_end")
	}
	if !haveText {
		t.Error("real stream produced no assistant text")
	}
	if len(events) >= lines {
		t.Errorf("translator filtered nothing: %d events from %d lines", len(events), lines)
	}
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd agent && go test -race -run 'TestTranslateTool|TestTruncate|TestToolResult|TestTranslateRealStream' ./...`
Expected: FAIL — `undefined: truncatePayload`, and tool cases returning zero events.

- [ ] **Step 3: Extend the implementation**

Replace `rawBlock` and add tool handling in `agent/chat_events.go`:

```go
type rawBlock struct {
	Type string `json:"type"`
	Text string `json:"text"`

	// tool_use
	ID    string          `json:"id"`
	Name  string          `json:"name"`
	Input json.RawMessage `json:"input"`

	// tool_result
	ToolUseID string          `json:"tool_use_id"`
	IsError   bool            `json:"is_error"`
	Content   json.RawMessage `json:"content"`
}

// truncatePayload caps a payload at maxPayloadBytes, reporting whether it cut.
func truncatePayload(s string) (string, bool) {
	if len(s) <= maxPayloadBytes {
		return s, false
	}
	return s[:maxPayloadBytes], true
}

// decodeContent renders a tool_result content field, which the CLI emits
// either as a plain string or as an array of blocks.
func decodeContent(raw json.RawMessage) string {
	if len(raw) == 0 {
		return ""
	}
	var s string
	if err := json.Unmarshal(raw, &s); err == nil {
		return s
	}
	return string(raw)
}
```

In the `case "assistant":` branch, add tool_use handling alongside text:

```go
	case "assistant":
		var out []ChatEvent
		for _, b := range raw.Message.Content {
			switch b.Type {
			case "text":
				if b.Text != "" {
					out = append(out, ChatEvent{Kind: EventText, TS: ts, Text: b.Text})
				}
			case "tool_use":
				input, cut := truncatePayload(string(b.Input))
				out = append(out, ChatEvent{
					Kind: EventToolUse, TS: ts,
					ToolID: b.ID, Name: b.Name,
					Input: input, Truncated: cut,
				})
			}
			// "thinking" and any future block type are deliberately dropped.
		}
		return out
```

Add a new top-level case for tool results, which arrive as user-role messages:

```go
	case "user":
		var out []ChatEvent
		for _, b := range raw.Message.Content {
			if b.Type != "tool_result" {
				continue
			}
			output, cut := truncatePayload(decodeContent(b.Content))
			ok := !b.IsError
			out = append(out, ChatEvent{
				Kind: EventToolResult, TS: ts,
				ToolID: b.ToolUseID, OK: &ok,
				Output: output, Truncated: cut,
			})
		}
		return out
```

- [ ] **Step 4: Run the full agent suite**

Run: `cd agent && go test -race ./...`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
gofmt -w agent/chat_events.go agent/chat_events_test.go
git add agent/chat_events.go agent/chat_events_test.go
git commit -m "feat(agent): translate tool calls and results, cap payloads at 4KB"
```

---

### Task 4: Event buffer

**Files:**
- Create: `agent/chat_buffer.go`
- Test: `agent/chat_buffer_test.go`

**Interfaces:**
- Consumes: `ChatEvent` (Task 2)
- Produces: `func NewChatBuffer(capacity int) *ChatBuffer`, `func (b *ChatBuffer) Append(events ...ChatEvent) []ChatEvent`, `func (b *ChatBuffer) Since(seq uint64) []ChatEvent`, `func (b *ChatBuffer) NextSeq() uint64`

- [ ] **Step 1: Write the failing test**

```go
package agent

import (
	"sync"
	"testing"
)

func TestChatBufferStampsSequentialSeq(t *testing.T) {
	b := NewChatBuffer(10)
	got := b.Append(ChatEvent{Kind: EventText}, ChatEvent{Kind: EventText})
	if len(got) != 2 || got[0].Seq != 1 || got[1].Seq != 2 {
		t.Fatalf("seq not stamped from 1: %+v", got)
	}
	next := b.Append(ChatEvent{Kind: EventTurnEnd})
	if next[0].Seq != 3 {
		t.Fatalf("seq = %d, want 3", next[0].Seq)
	}
}

func TestChatBufferSinceReturnsTail(t *testing.T) {
	b := NewChatBuffer(10)
	b.Append(ChatEvent{Kind: EventText}, ChatEvent{Kind: EventText}, ChatEvent{Kind: EventText})
	tail := b.Since(1)
	if len(tail) != 2 || tail[0].Seq != 2 || tail[1].Seq != 3 {
		t.Fatalf("Since(1) = %+v, want seq 2 and 3", tail)
	}
	if len(b.Since(3)) != 0 {
		t.Fatal("Since(latest) must be empty")
	}
	if len(b.Since(0)) != 3 {
		t.Fatal("Since(0) must return everything held")
	}
}

func TestChatBufferEvictsOldest(t *testing.T) {
	b := NewChatBuffer(2)
	b.Append(ChatEvent{Kind: EventText}, ChatEvent{Kind: EventText}, ChatEvent{Kind: EventText})
	all := b.Since(0)
	if len(all) != 2 {
		t.Fatalf("held %d events, want cap of 2", len(all))
	}
	if all[0].Seq != 2 || all[1].Seq != 3 {
		t.Fatalf("wrong events retained: %+v", all)
	}
	if b.NextSeq() != 4 {
		t.Fatalf("NextSeq = %d, want 4 — eviction must not rewind the counter", b.NextSeq())
	}
}

func TestChatBufferIsConcurrencySafe(t *testing.T) {
	b := NewChatBuffer(1000)
	var wg sync.WaitGroup
	for i := 0; i < 50; i++ {
		wg.Add(2)
		go func() { defer wg.Done(); b.Append(ChatEvent{Kind: EventText}) }()
		go func() { defer wg.Done(); _ = b.Since(0) }()
	}
	wg.Wait()
	if got := len(b.Since(0)); got != 50 {
		t.Fatalf("held %d events, want 50", got)
	}
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd agent && go test -race -run TestChatBuffer ./...`
Expected: FAIL — `undefined: NewChatBuffer`.

- [ ] **Step 3: Write minimal implementation**

```go
package agent

import "sync"

// defaultChatBufferSize is how many recent events a chat session retains for
// replay after a client reconnects.
const defaultChatBufferSize = 2000

// ChatBuffer holds the recent tail of a session's events and is the single
// place the monotonic seq counter advances. Sub-project 2 replaces the
// in-memory ring with a disk-backed log behind this same surface.
type ChatBuffer struct {
	mu   sync.Mutex
	ring []ChatEvent
	cap  int
	next uint64
}

func NewChatBuffer(capacity int) *ChatBuffer {
	if capacity <= 0 {
		capacity = defaultChatBufferSize
	}
	return &ChatBuffer{ring: make([]ChatEvent, 0, capacity), cap: capacity, next: 1}
}

// Append stamps each event with the next seq and returns the stamped copies.
// Eviction never rewinds the counter, so seq stays monotonic for the life of
// the session even after the oldest events are dropped.
func (b *ChatBuffer) Append(events ...ChatEvent) []ChatEvent {
	b.mu.Lock()
	defer b.mu.Unlock()

	stamped := make([]ChatEvent, 0, len(events))
	for _, e := range events {
		e.Seq = b.next
		b.next++
		stamped = append(stamped, e)
		b.ring = append(b.ring, e)
	}
	if overflow := len(b.ring) - b.cap; overflow > 0 {
		b.ring = append(b.ring[:0], b.ring[overflow:]...)
	}
	return stamped
}

// Since returns every retained event with Seq greater than seq.
func (b *ChatBuffer) Since(seq uint64) []ChatEvent {
	b.mu.Lock()
	defer b.mu.Unlock()

	out := make([]ChatEvent, 0, len(b.ring))
	for _, e := range b.ring {
		if e.Seq > seq {
			out = append(out, e)
		}
	}
	return out
}

// NextSeq reports the seq the next appended event will receive.
func (b *ChatBuffer) NextSeq() uint64 {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.next
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd agent && go test -race -run TestChatBuffer ./...`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
gofmt -w agent/chat_buffer.go agent/chat_buffer_test.go
git add agent/chat_buffer.go agent/chat_buffer_test.go
git commit -m "feat(agent): seq-stamping ring buffer for chat replay"
```

---

### Task 5: Chat session process lifecycle

**Files:**
- Create: `agent/chat_session.go`
- Test: `agent/chat_session_test.go`

**Interfaces:**
- Consumes: `TranslateLine`, `ChatEvent` (Task 2/3); `NewChatBuffer` (Task 4); `agent/testdata/fake_claude.sh` (Task 1); `cleanEnv()` from `agent/pty_session.go`
- Produces: `func NewChatSession(id, cwd, model string, emit func(string, []ChatEvent)) *ChatSession`, `func (s *ChatSession) Send(text string) error`, `func (s *ChatSession) Interrupt()`, `func (s *ChatSession) History(afterSeq uint64) []ChatEvent`, `func (s *ChatSession) Close()`, `func (s *ChatSession) Done() <-chan struct{}`, field `Bin string`

- [ ] **Step 1: Write the failing test**

```go
package agent

import (
	"os"
	"path/filepath"
	"sync"
	"testing"
	"time"
)

// collectEvents returns an emit fn plus a getter, for asserting on what a
// session produced without racing the reader goroutine.
func collectEvents() (func(string, []ChatEvent), func() []ChatEvent) {
	var mu sync.Mutex
	var got []ChatEvent
	emit := func(_ string, evs []ChatEvent) {
		mu.Lock()
		defer mu.Unlock()
		got = append(got, evs...)
	}
	read := func() []ChatEvent {
		mu.Lock()
		defer mu.Unlock()
		out := make([]ChatEvent, len(got))
		copy(out, got)
		return out
	}
	return emit, read
}

func fakeClaude(t *testing.T) string {
	t.Helper()
	abs, err := filepath.Abs("testdata/fake_claude.sh")
	if err != nil {
		t.Fatalf("resolve fake claude: %v", err)
	}
	if _, err := os.Stat(abs); err != nil {
		t.Fatalf("fake claude missing: %v", err)
	}
	return abs
}

func waitFor(t *testing.T, read func() []ChatEvent, kind ChatEventKind) []ChatEvent {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		evs := read()
		for _, e := range evs {
			if e.Kind == kind {
				return evs
			}
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatalf("timed out waiting for %q; got %+v", kind, read())
	return nil
}

func TestChatSessionSendProducesNormalisedTurn(t *testing.T) {
	emit, read := collectEvents()
	s := NewChatSession("sid", t.TempDir(), "", emit)
	s.Bin = fakeClaude(t)
	defer s.Close()

	if err := s.Send("hello"); err != nil {
		t.Fatalf("send: %v", err)
	}

	evs := waitFor(t, read, EventTurnEnd)

	var kinds []ChatEventKind
	for _, e := range evs {
		kinds = append(kinds, e.Kind)
	}
	want := []ChatEventKind{EventTurnStart, EventText, EventTurnEnd}
	if len(kinds) != len(want) {
		t.Fatalf("kinds = %v, want %v (noise must be filtered)", kinds, want)
	}
	for i := range want {
		if kinds[i] != want[i] {
			t.Fatalf("kinds = %v, want %v", kinds, want)
		}
	}
	for i, e := range evs {
		if e.Seq != uint64(i+1) {
			t.Fatalf("event %d has seq %d, want %d", i, e.Seq, i+1)
		}
	}
}

func TestChatSessionHistoryReplaysTail(t *testing.T) {
	emit, read := collectEvents()
	s := NewChatSession("sid", t.TempDir(), "", emit)
	s.Bin = fakeClaude(t)
	defer s.Close()

	if err := s.Send("hello"); err != nil {
		t.Fatalf("send: %v", err)
	}
	waitFor(t, read, EventTurnEnd)

	tail := s.History(1)
	if len(tail) == 0 {
		t.Fatal("History(1) returned nothing")
	}
	for _, e := range tail {
		if e.Seq <= 1 {
			t.Fatalf("History(1) leaked seq %d", e.Seq)
		}
	}
}

func TestChatSessionSurvivesMalformedLine(t *testing.T) {
	t.Setenv("FAKE_CLAUDE_MODE", "badline")
	emit, read := collectEvents()
	s := NewChatSession("sid", t.TempDir(), "", emit)
	s.Bin = fakeClaude(t)
	defer s.Close()

	if err := s.Send("hello"); err != nil {
		t.Fatalf("send: %v", err)
	}
	waitFor(t, read, EventTurnEnd) // a junk line must not abort the turn
}

func TestChatSessionRejectsMissingBinary(t *testing.T) {
	emit, read := collectEvents()
	s := NewChatSession("sid", t.TempDir(), "", emit)
	s.Bin = "/nonexistent/claude-binary"
	defer s.Close()

	_ = s.Send("hello")

	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		for _, e := range read() {
			if e.Kind == EventError {
				return
			}
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatal("expected an error event when the binary is missing")
}

func TestChatSessionRespawnsAfterProcessExit(t *testing.T) {
	emit, read := collectEvents()
	s := NewChatSession("sid", t.TempDir(), "", emit)
	s.Bin = fakeClaude(t)
	defer s.Close()

	if err := s.Send("first"); err != nil {
		t.Fatalf("send: %v", err)
	}
	waitFor(t, read, EventTurnEnd)

	s.Interrupt() // kills the process
	time.Sleep(100 * time.Millisecond)

	if err := s.Send("second"); err != nil {
		t.Fatalf("second send after interrupt: %v", err)
	}

	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		var ends int
		for _, e := range read() {
			if e.Kind == EventTurnEnd {
				ends++
			}
		}
		if ends >= 2 {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatalf("expected a second turn after respawn; got %+v", read())
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd agent && go test -race -run TestChatSession ./...`
Expected: FAIL — `undefined: NewChatSession`.

- [ ] **Step 3: Write minimal implementation**

```go
package agent

import (
	"bufio"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"os/exec"
	"sync"
	"time"
)

// maxScanLine is the stdout line cap. bufio.Scanner defaults to 64 KB, which
// a single tool-result line easily exceeds.
const maxScanLine = 1 << 20 // 1 MB

// ChatSession owns one headless `claude` process and turns its JSONL stream
// into normalised events. The process starts lazily on the first Send and is
// respawned with --resume if it dies, so a Mac reboot is just a cold start.
type ChatSession struct {
	ID    string
	Cwd   string
	Model string
	Bin   string // overridden in tests

	emit func(sessionID string, events []ChatEvent)
	buf  *ChatBuffer

	mu       sync.Mutex
	cmd      *exec.Cmd
	stdin    io.WriteCloser
	started  bool // a process has run before, so the next spawn resumes
	closed   bool
	doneCh   chan struct{}
	doneOnce sync.Once
}

func NewChatSession(id, cwd, model string, emit func(string, []ChatEvent)) *ChatSession {
	return &ChatSession{
		ID:     id,
		Cwd:    cwd,
		Model:  model,
		Bin:    "claude",
		emit:   emit,
		buf:    NewChatBuffer(defaultChatBufferSize),
		doneCh: make(chan struct{}),
	}
}

// publish stamps events with seq and forwards them to the client.
func (s *ChatSession) publish(events ...ChatEvent) {
	if len(events) == 0 {
		return
	}
	stamped := s.buf.Append(events...)
	if s.emit != nil {
		s.emit(s.ID, stamped)
	}
}

func (s *ChatSession) publishError(format string, args ...any) {
	s.publish(ChatEvent{
		Kind:    EventError,
		TS:      time.Now().UTC().Format(time.RFC3339),
		Message: fmt.Sprintf(format, args...),
	})
}

// args builds the CLI invocation. The first spawn creates the session with
// our own session id; later spawns resume it. The two flags are mutually
// exclusive — one creates, the other continues.
func (s *ChatSession) args() []string {
	a := []string{
		"-p",
		"--input-format", "stream-json",
		"--output-format", "stream-json",
		"--verbose",
		"--permission-mode", "bypassPermissions",
	}
	if s.started {
		a = append(a, "--resume", s.ID)
	} else {
		a = append(a, "--session-id", s.ID)
	}
	if s.Model != "" {
		a = append(a, "--model", s.Model)
	}
	return a
}

// ensureProcess starts the process if it is not running. Caller holds s.mu.
func (s *ChatSession) ensureProcess() error {
	if s.cmd != nil {
		return nil
	}
	cmd := exec.Command(s.Bin, s.args()...)
	cmd.Dir = s.Cwd
	cmd.Env = cleanEnv()

	stdin, err := cmd.StdinPipe()
	if err != nil {
		return fmt.Errorf("chat session %s stdin: %w", s.ID, err)
	}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return fmt.Errorf("chat session %s stdout: %w", s.ID, err)
	}
	stderr, err := cmd.StderrPipe()
	if err != nil {
		return fmt.Errorf("chat session %s stderr: %w", s.ID, err)
	}
	if err := cmd.Start(); err != nil {
		return fmt.Errorf("start chat session %s: %w", s.ID, err)
	}

	s.cmd = cmd
	s.stdin = stdin
	s.started = true

	go s.readStdout(cmd, stdout)
	go s.readStderr(stderr)
	return nil
}

func (s *ChatSession) readStdout(cmd *exec.Cmd, stdout io.ReadCloser) {
	scanner := bufio.NewScanner(stdout)
	scanner.Buffer(make([]byte, 0, 64*1024), maxScanLine)
	for scanner.Scan() {
		ts := time.Now().UTC().Format(time.RFC3339)
		s.publish(TranslateLine(scanner.Bytes(), ts)...)
	}
	if err := scanner.Err(); err != nil {
		s.publishError("output stream error: %v", err)
	}
	_ = cmd.Wait()

	// Clear the handle so the next Send respawns with --resume.
	s.mu.Lock()
	if s.cmd == cmd {
		s.cmd = nil
		s.stdin = nil
	}
	closed := s.closed
	s.mu.Unlock()

	if closed {
		s.doneOnce.Do(func() { close(s.doneCh) })
	}
}

func (s *ChatSession) readStderr(stderr io.ReadCloser) {
	scanner := bufio.NewScanner(stderr)
	scanner.Buffer(make([]byte, 0, 64*1024), maxScanLine)
	for scanner.Scan() {
		line := scanner.Text()
		if line == "" {
			continue
		}
		log.Printf("chat session %s stderr: %s", s.ID, line)
		s.publishError("%s", line)
	}
}

// Send delivers one user message, starting or restarting the process as needed.
func (s *ChatSession) Send(text string) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	if s.closed {
		return fmt.Errorf("chat session %s is closed", s.ID)
	}
	if err := s.ensureProcess(); err != nil {
		s.publishError("could not start claude: %v", err)
		return err
	}

	msg := map[string]any{
		"type":    "user",
		"message": map[string]any{"role": "user", "content": text},
	}
	line, err := json.Marshal(msg)
	if err != nil {
		return fmt.Errorf("encode user message for %s: %w", s.ID, err)
	}
	if _, err := s.stdin.Write(append(line, '\n')); err != nil {
		s.publishError("could not deliver message: %v", err)
		return fmt.Errorf("write to chat session %s: %w", s.ID, err)
	}
	return nil
}

// Interrupt stops the current turn by killing the process. The next Send
// respawns it with --resume, which restores the conversation.
func (s *ChatSession) Interrupt() {
	s.mu.Lock()
	cmd := s.cmd
	s.mu.Unlock()
	if cmd != nil && cmd.Process != nil {
		_ = cmd.Process.Kill()
	}
}

// History returns retained events newer than afterSeq, for client replay.
func (s *ChatSession) History(afterSeq uint64) []ChatEvent {
	return s.buf.Since(afterSeq)
}

func (s *ChatSession) Close() {
	s.mu.Lock()
	if s.closed {
		s.mu.Unlock()
		return
	}
	s.closed = true
	cmd := s.cmd
	stdin := s.stdin
	s.mu.Unlock()

	if stdin != nil {
		_ = stdin.Close()
	}
	if cmd != nil && cmd.Process != nil {
		_ = cmd.Process.Kill()
	} else {
		s.doneOnce.Do(func() { close(s.doneCh) })
	}
}

func (s *ChatSession) Done() <-chan struct{} { return s.doneCh }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd agent && go test -race -run TestChatSession ./...`
Expected: PASS

- [ ] **Step 5: Run the whole agent suite and vet**

Run: `cd agent && go test -race ./... && go vet ./...`
Expected: PASS, no vet findings.

- [ ] **Step 6: Commit**

```bash
gofmt -w agent/chat_session.go agent/chat_session_test.go
git add agent/chat_session.go agent/chat_session_test.go
git commit -m "feat(agent): headless claude process lifecycle with lazy start and resume"
```

---

### Task 6: Wire chat into the agent's WebSocket client

**Files:**
- Modify: `agent/ws_client.go:21-26` (connectReq), `agent/ws_client.go:68-72` (WSClient), `agent/ws_client.go:187-213` (handleText), `agent/ws_client.go:215-269` (handleConnect)
- Test: `agent/ws_client_chat_test.go` (create)

**Interfaces:**
- Consumes: `NewChatSession`, `ChatSession` (Task 5); `fsResolve` from `agent/fs_ops.go`
- Produces: `connectReq.Kind`, `connectReq.Cwd`, `connectReq.Model`; `WSClient.chats map[string]*ChatSession`; handlers `handleChatSend`, `handleChatInterrupt`, `handleChatHistory`

- [ ] **Step 1: Write the failing test**

```go
package agent

import (
	"encoding/json"
	"testing"
)

func TestConnectReqDefaultsToPTYKind(t *testing.T) {
	var req connectReq
	if err := json.Unmarshal([]byte(`{"session_id":"s","cols":80,"rows":24}`), &req); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if req.Kind != "" {
		t.Fatalf("Kind = %q, want empty so it can default to pty", req.Kind)
	}
	if !req.isPTY() {
		t.Fatal("a connect with no kind must be treated as pty for backward compatibility")
	}
}

func TestConnectReqChatKind(t *testing.T) {
	var req connectReq
	body := `{"session_id":"s","kind":"chat","cwd":"~/proj","model":"m"}`
	if err := json.Unmarshal([]byte(body), &req); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if req.isPTY() {
		t.Fatal("kind=chat must not be treated as pty")
	}
	if req.Cwd != "~/proj" || req.Model != "m" {
		t.Fatalf("fields lost: %+v", req)
	}
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd agent && go test -race -run TestConnectReq ./...`
Expected: FAIL — `req.Kind undefined`.

- [ ] **Step 3: Extend `connectReq`**

Replace the struct at `agent/ws_client.go:21-26`:

```go
// connectReq is the payload of a "connect" control message.
// Name is optional — older clients don't send it. Kind is likewise optional
// and absent means "pty", which is what every pre-chat client sends.
type connectReq struct {
	SessionID string `json:"session_id"`
	Cols      uint16 `json:"cols"`
	Rows      uint16 `json:"rows"`
	Name      string `json:"name"`
	Kind      string `json:"kind"`
	Cwd       string `json:"cwd"`
	Model     string `json:"model"`
}

// isPTY reports whether this connect asks for a terminal session. Anything
// that is not explicitly "chat" is a PTY, so unknown kinds from a newer
// client degrade to current behaviour rather than failing.
func (r connectReq) isPTY() bool { return r.Kind != "chat" }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd agent && go test -race -run TestConnectReq ./...`
Expected: PASS

- [ ] **Step 5: Add the chat session map to `WSClient`**

In the `WSClient` struct (around `agent/ws_client.go:68`), alongside `sessions`:

```go
	chats map[string]*ChatSession
```

Initialise it wherever `sessions` is initialised, in the same statement group:

```go
	chats: make(map[string]*ChatSession),
```

- [ ] **Step 6: Branch `handleConnect` on kind**

At the top of `handleConnect`, immediately after `req.Name = sanitizeSessionName(req.Name)` (currently `agent/ws_client.go:225`), insert:

```go
	if !req.isPTY() {
		c.handleChatConnect(req)
		return
	}
```

Then add the chat connect handler in the same file:

```go
// handleChatConnect creates or reattaches a chat session. cwd goes through
// the same home-directory confinement as every other filesystem operation —
// a chat session must not become a way around it.
func (c *WSClient) handleChatConnect(req connectReq) {
	c.mu.RLock()
	existing := c.chats[req.SessionID]
	c.mu.RUnlock()
	if existing != nil {
		log.Printf("Chat session reattached: %s", req.SessionID)
		return
	}

	cwd, err := fsResolve(req.Cwd)
	if err != nil {
		log.Printf("Rejecting chat session %s: %v", req.SessionID, err)
		c.sendChatError(req.SessionID, "working directory is not allowed")
		return
	}

	sess := NewChatSession(req.SessionID, cwd, req.Model, c.sendChatEvents)

	c.mu.Lock()
	c.chats[req.SessionID] = sess
	c.mu.Unlock()

	log.Printf("Chat session started: %s (cwd: %s)", req.SessionID, cwd)

	go func() {
		<-sess.Done()
		c.mu.Lock()
		delete(c.chats, req.SessionID)
		c.mu.Unlock()
		log.Printf("Chat session ended: %s", req.SessionID)
	}()
}

// sendChatEvents forwards normalised events to the relay as text frames.
func (c *WSClient) sendChatEvents(sessionID string, events []ChatEvent) {
	for _, e := range events {
		c.sendTextMsg(context.Background(), "chat_event", map[string]any{
			"session_id": sessionID,
			"event":      e,
		})
	}
}

func (c *WSClient) sendChatError(sessionID, message string) {
	c.sendTextMsg(context.Background(), "chat_event", map[string]any{
		"session_id": sessionID,
		"event": ChatEvent{
			Kind:    EventError,
			TS:      time.Now().UTC().Format(time.RFC3339),
			Message: message,
		},
	})
}

func (c *WSClient) chatSession(sessionID string) *ChatSession {
	c.mu.RLock()
	defer c.mu.RUnlock()
	return c.chats[sessionID]
}

func (c *WSClient) handleChatSend(payload json.RawMessage) {
	var req struct {
		SessionID string `json:"session_id"`
		Text      string `json:"text"`
	}
	if err := json.Unmarshal(payload, &req); err != nil {
		return
	}
	sess := c.chatSession(req.SessionID)
	if sess == nil {
		return
	}
	if err := sess.Send(req.Text); err != nil {
		log.Printf("chat_send failed for %s: %v", req.SessionID, err)
	}
}

func (c *WSClient) handleChatInterrupt(payload json.RawMessage) {
	var req struct {
		SessionID string `json:"session_id"`
	}
	if err := json.Unmarshal(payload, &req); err != nil {
		return
	}
	if sess := c.chatSession(req.SessionID); sess != nil {
		sess.Interrupt()
	}
}

func (c *WSClient) handleChatHistory(ctx context.Context, payload json.RawMessage) {
	var req struct {
		SessionID string `json:"session_id"`
		RequestID string `json:"request_id"`
		AfterSeq  uint64 `json:"after_seq"`
	}
	if err := json.Unmarshal(payload, &req); err != nil {
		return
	}
	events := []ChatEvent{}
	var nextSeq uint64 = 1
	if sess := c.chatSession(req.SessionID); sess != nil {
		events = sess.History(req.AfterSeq)
		nextSeq = sess.buf.NextSeq()
	}
	c.sendTextMsg(ctx, "chat_history_result", map[string]any{
		"request_id": req.RequestID,
		"events":     events,
		"next_seq":   nextSeq,
	})
}
```

- [ ] **Step 7: Register the new message types**

In `handleText` (`agent/ws_client.go:187-213`), add to the switch:

```go
	case "chat_send":
		c.handleChatSend(msg.Payload)
	case "chat_interrupt":
		c.handleChatInterrupt(msg.Payload)
	case "chat_history":
		c.handleChatHistory(ctx, msg.Payload)
```

- [ ] **Step 8: Also destroy chat sessions on disconnect**

In `handleDisconnect` (`agent/ws_client.go:306`), after the existing PTY teardown, add:

```go
	c.mu.Lock()
	chat := c.chats[req.SessionID]
	delete(c.chats, req.SessionID)
	c.mu.Unlock()
	if chat != nil {
		chat.Close()
	}
```

- [ ] **Step 9: Build, vet and run the full suite**

Run: `cd agent && go build ./... && go vet ./... && go test -race ./...`
Expected: PASS

- [ ] **Step 10: Commit**

```bash
gofmt -w agent/ws_client.go agent/ws_client_chat_test.go
git add agent/ws_client.go agent/ws_client_chat_test.go
git commit -m "feat(agent): route chat_send/interrupt/history to chat sessions"
```

---

### Task 7: Relay routing

`connect` needs **no** relay change — `relay/hub.go:554` already forwards `msg.Payload` verbatim, so `kind`, `cwd` and `model` pass through untouched. Only the new message types need branches.

**Files:**
- Modify: `relay/hub.go:212-238` (routing helpers), `relay/hub.go:354-369` (agent→client switch), `relay/hub.go:477-515` (client→agent switch)
- Test: `relay/chat_routing_test.go` (create)

**Interfaces:**
- Consumes: `Hub`, `Session`, `AgentConn`, `ClientConn`
- Produces: `func (h *Hub) RouteTextToAgent(sessionID string, data []byte) bool`, `func (h *Hub) RouteTextToClient(sessionID string, data []byte) bool`

- [ ] **Step 1: Write the failing test**

This is the relay's first integration test. It runs a real hub behind `httptest`, dials a fake agent and a fake client over real WebSockets, and asserts messages cross correctly.

```go
package relay

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"nhooyr.io/websocket"
)

const (
	testAgentSecret = "test-agent-secret"
	testAgentID     = "11111111-2222-4333-8444-555555555555"
	testSessionID   = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
)

// newTestRelay starts a hub behind an httptest server and returns its ws://
// base URL plus the Auth used to sign client tokens.
func newTestRelay(t *testing.T) (*Hub, *Auth, string) {
	t.Helper()
	hub := NewHub()
	go hub.Run()

	auth := NewAuth("test-jwt-secret", "test-admin-password")
	mux := http.NewServeMux()
	mux.HandleFunc("/ws/agent", func(w http.ResponseWriter, r *http.Request) {
		HandleAgentWS(w, r, hub, testAgentSecret)
	})
	mux.HandleFunc("/ws/client", func(w http.ResponseWriter, r *http.Request) {
		HandleClientWS(w, r, hub, auth)
	})
	srv := httptest.NewServer(mux)
	t.Cleanup(srv.Close)
	return hub, auth, "ws" + strings.TrimPrefix(srv.URL, "http")
}

func dial(t *testing.T, url string) *websocket.Conn {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	conn, _, err := websocket.Dial(ctx, url, nil)
	if err != nil {
		t.Fatalf("dial %s: %v", url, err)
	}
	t.Cleanup(func() { conn.Close(websocket.StatusNormalClosure, "") })
	return conn
}

func writeMsg(t *testing.T, conn *websocket.Conn, msgType string, payload any) {
	t.Helper()
	body, err := json.Marshal(Message{Type: msgType, Payload: mustMarshal(payload)})
	if err != nil {
		t.Fatalf("marshal %s: %v", msgType, err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if err := conn.Write(ctx, websocket.MessageText, body); err != nil {
		t.Fatalf("write %s: %v", msgType, err)
	}
}

// readUntil reads text frames until one has the wanted type, or times out.
func readUntil(t *testing.T, conn *websocket.Conn, want string) Message {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		ctx, cancel := context.WithDeadline(context.Background(), deadline)
		typ, data, err := conn.Read(ctx)
		cancel()
		if err != nil {
			t.Fatalf("read waiting for %q: %v", want, err)
		}
		if typ != websocket.MessageText {
			continue
		}
		var msg Message
		if err := json.Unmarshal(data, &msg); err != nil {
			continue
		}
		if msg.Type == want {
			return msg
		}
	}
	t.Fatalf("timed out waiting for %q", want)
	return Message{}
}

// connectPair wires up an agent and a client sharing one session.
func connectPair(t *testing.T) (agent, client *websocket.Conn) {
	t.Helper()
	_, auth, base := newTestRelay(t)

	agent = dial(t, base+"/ws/agent")
	writeMsg(t, agent, "register", map[string]any{
		"agent_id": testAgentID, "name": "test-mac", "secret": testAgentSecret,
	})

	token, err := auth.GenerateAccessToken()
	if err != nil {
		t.Fatalf("mint token: %v", err)
	}
	client = dial(t, base+"/ws/client")
	writeMsg(t, client, "auth", map[string]any{"token": token})

	time.Sleep(100 * time.Millisecond) // let registration settle

	writeMsg(t, client, "connect", map[string]any{
		"agent_id": testAgentID, "session_id": testSessionID,
		"kind": "chat", "cwd": "~/proj",
	})
	readUntil(t, client, "session_ready")
	return agent, client
}

func TestConnectForwardsChatFieldsVerbatim(t *testing.T) {
	agent, _ := connectPair(t)

	msg := readUntil(t, agent, "connect")
	var payload map[string]any
	if err := json.Unmarshal(msg.Payload, &payload); err != nil {
		t.Fatalf("unmarshal forwarded connect: %v", err)
	}
	if payload["kind"] != "chat" {
		t.Fatalf("kind lost in relay: %+v", payload)
	}
	if payload["cwd"] != "~/proj" {
		t.Fatalf("cwd lost in relay: %+v", payload)
	}
}

func TestChatSendRoutesClientToAgent(t *testing.T) {
	agent, client := connectPair(t)
	readUntil(t, agent, "connect")

	writeMsg(t, client, "chat_send", map[string]any{
		"session_id": testSessionID, "text": "hello there",
	})

	msg := readUntil(t, agent, "chat_send")
	var payload map[string]any
	json.Unmarshal(msg.Payload, &payload)
	if payload["text"] != "hello there" {
		t.Fatalf("text lost: %+v", payload)
	}
}

func TestChatEventRoutesAgentToClient(t *testing.T) {
	agent, client := connectPair(t)
	readUntil(t, agent, "connect")

	writeMsg(t, agent, "chat_event", map[string]any{
		"session_id": testSessionID,
		"event":      map[string]any{"kind": "text", "seq": 1, "text": "hi"},
	})

	msg := readUntil(t, client, "chat_event")
	var payload map[string]any
	json.Unmarshal(msg.Payload, &payload)
	if payload["session_id"] != testSessionID {
		t.Fatalf("session_id lost: %+v", payload)
	}
}

func TestChatHistoryUsesRequestCorrelation(t *testing.T) {
	agent, client := connectPair(t)
	readUntil(t, agent, "connect")

	writeMsg(t, client, "chat_history", map[string]any{
		"agent_id": testAgentID, "session_id": testSessionID,
		"request_id": "req-1", "after_seq": 0,
	})

	fwd := readUntil(t, agent, "chat_history")
	var fwdPayload map[string]any
	json.Unmarshal(fwd.Payload, &fwdPayload)
	if _, leaked := fwdPayload["agent_id"]; leaked {
		t.Error("agent_id must be stripped before forwarding to the agent")
	}

	writeMsg(t, agent, "chat_history_result", map[string]any{
		"request_id": "req-1", "events": []any{}, "next_seq": 1,
	})

	got := readUntil(t, client, "chat_history_result")
	var gotPayload map[string]any
	json.Unmarshal(got.Payload, &gotPayload)
	if gotPayload["request_id"] != "req-1" {
		t.Fatalf("request_id not correlated: %+v", gotPayload)
	}
}
```

**API note (verified):** `relay/auth.go:26` exposes `NewAuth(jwtSecret, adminPassword string) *Auth` and `relay/auth.go:52` exposes `(a *Auth) GenerateAccessToken() (string, error)`. The test above uses both correctly — no adjustment needed, and no production code changes to accommodate the test.

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd relay && go test -race -run 'TestChat|TestConnectForwards' ./...`
Expected: FAIL — chat messages are not routed, so the reads time out.

- [ ] **Step 3: Add the text-routing helpers**

After `RouteToAgent` in `relay/hub.go`:

```go
// RouteTextToClient forwards a raw text control message to the client that
// owns sessionID. Unlike RouteToClient it does not wrap in a binary frame —
// chat traffic is JSON on the text channel.
func (h *Hub) RouteTextToClient(sessionID string, data []byte) bool {
	h.mu.RLock()
	sess, ok := h.sessions[sessionID]
	h.mu.RUnlock()
	if !ok {
		return false
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	return sess.Client.Send(ctx, websocket.MessageText, data) == nil
}

// RouteTextToAgent forwards a raw text control message to the agent that
// owns sessionID.
func (h *Hub) RouteTextToAgent(sessionID string, data []byte) bool {
	h.mu.RLock()
	sess, ok := h.sessions[sessionID]
	h.mu.RUnlock()
	if !ok {
		return false
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	return sess.Agent.Send(ctx, websocket.MessageText, data) == nil
}
```

- [ ] **Step 4: Route client → agent**

In the client switch (`relay/hub.go:477`), add:

```go
		case "chat_send", "chat_interrupt":
			var pl struct {
				SessionID string `json:"session_id"`
			}
			if err := json.Unmarshal(incoming.Payload, &pl); err != nil {
				break
			}
			hub.RouteTextToAgent(pl.SessionID, data)

		case "chat_history":
			var pl struct {
				AgentID   string `json:"agent_id"`
				SessionID string `json:"session_id"`
				RequestID string `json:"request_id"`
				AfterSeq  uint64 `json:"after_seq"`
			}
			if err := json.Unmarshal(incoming.Payload, &pl); err != nil || pl.AgentID == "" {
				break
			}
			agent, ok := hub.GetAgent(pl.AgentID)
			if !ok {
				break
			}
			hub.pendingRequests.Store(pl.RequestID, client)
			fwd := Message{Type: "chat_history", Payload: mustMarshal(map[string]any{
				"session_id": pl.SessionID,
				"request_id": pl.RequestID,
				"after_seq":  pl.AfterSeq,
			})}
			fwdData, _ := json.Marshal(fwd)
			agent.Send(ctx, websocket.MessageText, fwdData)
```

- [ ] **Step 5: Route agent → client**

In the agent switch (`relay/hub.go:354`), extend the correlated-response list and add a session-routed case:

```go
			case "sessions_list", "fs_list_result", "fs_mkdir_result", "fs_delete_result", "fs_read_result", "chat_history_result":
				// ... existing request_id correlation body, unchanged ...

			case "chat_event":
				var pl struct {
					SessionID string `json:"session_id"`
				}
				json.Unmarshal(textMsg.Payload, &pl)
				hub.RouteTextToClient(pl.SessionID, data)
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `cd relay && go test -race ./...`
Expected: PASS

- [ ] **Step 7: Vet and commit**

```bash
cd relay && go vet ./... && gofmt -w hub.go chat_routing_test.go
cd .. && git add relay/hub.go relay/chat_routing_test.go
git commit -m "feat(relay): route chat messages; first relay integration tests"
```

---

### Task 8: iOS event model and transcript

**Files:**
- Create: `Claude Orchestrator.iOS/ClrcCore/Sources/ClrcCore/ChatEvent.swift`
- Create: `Claude Orchestrator.iOS/ClrcCore/Sources/ClrcCore/ChatTranscript.swift`
- Test: `Claude Orchestrator.iOS/ClrcCore/Tests/ClrcCoreTests/ChatEventTests.swift`
- Test: `Claude Orchestrator.iOS/ClrcCore/Tests/ClrcCoreTests/ChatTranscriptTests.swift`

**Interfaces:**
- Consumes: the wire format from Task 2/3
- Produces: `public enum ChatEventKind`, `public struct ChatEvent`, `public struct ChatTurn`, `public struct ChatTranscript` with `applying(_:) -> ChatTranscript`, `hasGap(before:) -> Bool`, `lastSeq`, `turns`

- [ ] **Step 1: Write the failing tests**

`ChatEventTests.swift`:

```swift
import Testing
import Foundation
@testable import ClrcCore

@Test("Decodes a text event")
func decodesTextEvent() throws {
    let json = #"{"kind":"text","seq":3,"ts":"2026-08-15T00:00:00Z","text":"hello"}"#
    let event = try JSONDecoder().decode(ChatEvent.self, from: Data(json.utf8))
    #expect(event.kind == .text)
    #expect(event.seq == 3)
    #expect(event.text == "hello")
}

@Test("Decodes a tool call")
func decodesToolUse() throws {
    let json = #"{"kind":"tool_use","seq":1,"ts":"t","tool_id":"t1","name":"Bash","input":"{\"command\":\"ls\"}"}"#
    let event = try JSONDecoder().decode(ChatEvent.self, from: Data(json.utf8))
    #expect(event.kind == .toolUse)
    #expect(event.name == "Bash")
    #expect(event.toolID == "t1")
}

@Test("Decodes turn_end metrics")
func decodesTurnEnd() throws {
    let json = #"{"kind":"turn_end","seq":9,"ts":"t","num_turns":2,"cost_usd":0.05,"duration_ms":4877}"#
    let event = try JSONDecoder().decode(ChatEvent.self, from: Data(json.utf8))
    #expect(event.kind == .turnEnd)
    #expect(event.costUSD == 0.05)
    #expect(event.durationMS == 4877)
}

// A newer agent must never break an older app.
@Test("Unknown kind decodes as .unknown rather than throwing")
func toleratesUnknownKind() throws {
    let json = #"{"kind":"something_invented_later","seq":1,"ts":"t"}"#
    let event = try JSONDecoder().decode(ChatEvent.self, from: Data(json.utf8))
    #expect(event.kind == .unknown)
    #expect(event.seq == 1)
}
```

`ChatTranscriptTests.swift`:

```swift
import Testing
@testable import ClrcCore

private func event(_ kind: ChatEventKind, _ seq: UInt64, text: String = "") -> ChatEvent {
    ChatEvent(kind: kind, seq: seq, ts: "t", text: text)
}

@Test("Applying events advances lastSeq")
func advancesLastSeq() {
    let transcript = ChatTranscript()
        .applying([event(.turnStart, 1), event(.text, 2, text: "hi")])
    #expect(transcript.lastSeq == 2)
}

@Test("Duplicate seq is ignored")
func ignoresDuplicates() {
    let transcript = ChatTranscript()
        .applying([event(.turnStart, 1), event(.text, 2, text: "hi")])
        .applying([event(.text, 2, text: "hi")])
    #expect(transcript.lastSeq == 2)
    #expect(transcript.turns.first?.events.count == 2)
}

@Test("Out-of-order arrival does not rewind lastSeq")
func ignoresStaleEvents() {
    let transcript = ChatTranscript()
        .applying([event(.turnStart, 1), event(.text, 5, text: "late")])
        .applying([event(.text, 3, text: "stale")])
    #expect(transcript.lastSeq == 5)
}

@Test("A gap is detectable so the client can request replay")
func detectsGap() {
    let transcript = ChatTranscript().applying([event(.turnStart, 1)])
    #expect(transcript.hasGap(before: 5))
    #expect(!transcript.hasGap(before: 2))
}

@Test("turn_start opens a new turn")
func groupsIntoTurns() {
    let transcript = ChatTranscript().applying([
        event(.turnStart, 1), event(.text, 2, text: "a"), event(.turnEnd, 3),
        event(.turnStart, 4), event(.text, 5, text: "b"),
    ])
    #expect(transcript.turns.count == 2)
    #expect(transcript.turns[1].events.contains { $0.text == "b" })
}

@Test("Events before any turn_start still land in a turn")
func toleratesMissingTurnStart() {
    let transcript = ChatTranscript().applying([event(.text, 1, text: "orphan")])
    #expect(transcript.turns.count == 1)
    #expect(transcript.turns[0].events.count == 1)
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd "Claude Orchestrator.iOS/ClrcCore" && swift test`
Expected: FAIL — `cannot find 'ChatEvent' in scope`.

- [ ] **Step 3: Write `ChatEvent.swift`**

```swift
import Foundation

/// Normalised event kinds sent by the agent. `unknown` is the forward-
/// compatibility escape hatch: a newer agent must never break an older app,
/// and the App Store makes the app the slowest component to update.
public enum ChatEventKind: String, Codable, Sendable {
    case turnStart = "turn_start"
    case text
    case toolUse = "tool_use"
    case toolResult = "tool_result"
    case turnEnd = "turn_end"
    case error
    case unknown

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ChatEventKind(rawValue: raw) ?? .unknown
    }
}

/// One event in a chat session. `seq` is assigned by the agent and is what
/// makes reconnection correct — the client replays only what it is missing.
public struct ChatEvent: Codable, Sendable, Identifiable, Equatable {
    public let kind: ChatEventKind
    public let seq: UInt64
    public let ts: String

    public let text: String
    public let toolID: String
    public let name: String
    public let input: String
    public let output: String
    public let ok: Bool?
    public let truncated: Bool

    public let numTurns: Int
    public let costUSD: Double
    public let durationMS: Int
    public let stopReason: String
    public let message: String

    public var id: UInt64 { seq }

    enum CodingKeys: String, CodingKey {
        case kind, seq, ts, text, name, input, output, ok, truncated, message
        case toolID = "tool_id"
        case numTurns = "num_turns"
        case costUSD = "cost_usd"
        case durationMS = "duration_ms"
        case stopReason = "stop_reason"
    }

    public init(
        kind: ChatEventKind, seq: UInt64, ts: String,
        text: String = "", toolID: String = "", name: String = "",
        input: String = "", output: String = "", ok: Bool? = nil,
        truncated: Bool = false, numTurns: Int = 0, costUSD: Double = 0,
        durationMS: Int = 0, stopReason: String = "", message: String = ""
    ) {
        self.kind = kind
        self.seq = seq
        self.ts = ts
        self.text = text
        self.toolID = toolID
        self.name = name
        self.input = input
        self.output = output
        self.ok = ok
        self.truncated = truncated
        self.numTurns = numTurns
        self.costUSD = costUSD
        self.durationMS = durationMS
        self.stopReason = stopReason
        self.message = message
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(ChatEventKind.self, forKey: .kind)
        seq = try c.decodeIfPresent(UInt64.self, forKey: .seq) ?? 0
        ts = try c.decodeIfPresent(String.self, forKey: .ts) ?? ""
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        toolID = try c.decodeIfPresent(String.self, forKey: .toolID) ?? ""
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        input = try c.decodeIfPresent(String.self, forKey: .input) ?? ""
        output = try c.decodeIfPresent(String.self, forKey: .output) ?? ""
        ok = try c.decodeIfPresent(Bool.self, forKey: .ok)
        truncated = try c.decodeIfPresent(Bool.self, forKey: .truncated) ?? false
        numTurns = try c.decodeIfPresent(Int.self, forKey: .numTurns) ?? 0
        costUSD = try c.decodeIfPresent(Double.self, forKey: .costUSD) ?? 0
        durationMS = try c.decodeIfPresent(Int.self, forKey: .durationMS) ?? 0
        stopReason = try c.decodeIfPresent(String.self, forKey: .stopReason) ?? ""
        message = try c.decodeIfPresent(String.self, forKey: .message) ?? ""
    }
}
```

- [ ] **Step 4: Write `ChatTranscript.swift`**

```swift
import Foundation

/// One turn: everything from a `turn_start` up to the next one.
public struct ChatTurn: Sendable, Identifiable, Equatable {
    public let id: UInt64
    public let events: [ChatEvent]

    public init(id: UInt64, events: [ChatEvent]) {
        self.id = id
        self.events = events
    }

    fileprivate func appending(_ event: ChatEvent) -> ChatTurn {
        ChatTurn(id: id, events: events + [event])
    }
}

/// Accumulated view of a chat session. Immutable: `applying` returns a new
/// transcript rather than mutating in place, so a stale copy can never be
/// observed mid-update.
public struct ChatTranscript: Sendable, Equatable {
    public let turns: [ChatTurn]
    public let lastSeq: UInt64

    public init(turns: [ChatTurn] = [], lastSeq: UInt64 = 0) {
        self.turns = turns
        self.lastSeq = lastSeq
    }

    /// Returns a transcript with `events` applied. Events at or below
    /// `lastSeq` are dropped, which makes duplicate delivery and out-of-order
    /// arrival both harmless.
    public func applying(_ events: [ChatEvent]) -> ChatTranscript {
        var turns = self.turns
        var lastSeq = self.lastSeq

        for event in events.sorted(by: { $0.seq < $1.seq }) where event.seq > lastSeq {
            lastSeq = event.seq

            if event.kind == .turnStart || turns.isEmpty {
                turns.append(ChatTurn(id: event.seq, events: [event]))
            } else {
                turns[turns.count - 1] = turns[turns.count - 1].appending(event)
            }
        }

        return ChatTranscript(turns: turns, lastSeq: lastSeq)
    }

    /// True when `seq` is further ahead than the next expected event, meaning
    /// something was missed and the tail should be re-requested.
    public func hasGap(before seq: UInt64) -> Bool {
        seq > lastSeq + 1
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `cd "Claude Orchestrator.iOS/ClrcCore" && swift test`
Expected: PASS — all existing suites plus the two new ones.

- [ ] **Step 6: Commit**

```bash
git add "Claude Orchestrator.iOS/ClrcCore/Sources/ClrcCore/ChatEvent.swift" \
        "Claude Orchestrator.iOS/ClrcCore/Sources/ClrcCore/ChatTranscript.swift" \
        "Claude Orchestrator.iOS/ClrcCore/Tests/ClrcCoreTests/ChatEventTests.swift" \
        "Claude Orchestrator.iOS/ClrcCore/Tests/ClrcCoreTests/ChatTranscriptTests.swift"
git commit -m "feat(ios): chat event model and replay-safe transcript in ClrcCore"
```

---

### Task 9: iOS relay client chat API

**Files:**
- Modify: `Claude Orchestrator.iOS/Claude Orchestrator/Services/RelayWebSocket.swift:216-263` (text handling), `:277-311` (send API)

**Interfaces:**
- Consumes: `ChatEvent` (Task 8); protocol from Tasks 6–7
- Produces: `RelayWebSocket.registerChatHandler(sessionID:handler:)`, `unregisterChatHandler(sessionID:)`, `sendChatConnect(agentID:sessionID:cwd:name:model:)`, `sendChatMessage(sessionID:text:)`, `sendChatInterrupt(sessionID:)`, `requestChatHistory(agentID:sessionID:afterSeq:completion:)`

- [ ] **Step 1: Add chat handler storage**

Next to `sessionHandlers` (`RelayWebSocket.swift:31`):

```swift
    typealias ChatEventHandler = (ChatEvent) -> Void
    private var chatHandlers: [String: ChatEventHandler] = [:]
    private var pendingChatHistory: [String: ([ChatEvent], UInt64) -> Void] = [:]
```

- [ ] **Step 2: Handle the two new inbound message types**

In `handleTextMessage`'s switch, before `default`:

```swift
        case "chat_event":
            guard let sessionID = payload["session_id"] as? String,
                  let raw = payload["event"],
                  let data = try? JSONSerialization.data(withJSONObject: raw),
                  let event = try? JSONDecoder().decode(ChatEvent.self, from: data) else { return }
            chatHandlers[sessionID]?(event)

        case "chat_history_result":
            guard let requestID = payload["request_id"] as? String else { return }
            let rawEvents = payload["events"] as? [[String: Any]] ?? []
            let events: [ChatEvent] = rawEvents.compactMap { dict in
                guard let data = try? JSONSerialization.data(withJSONObject: dict) else { return nil }
                return try? JSONDecoder().decode(ChatEvent.self, from: data)
            }
            let nextSeq = (payload["next_seq"] as? NSNumber)?.uint64Value ?? 1
            pendingChatHistory.removeValue(forKey: requestID)?(events, nextSeq)
```

- [ ] **Step 3: Add the send API**

Alongside the existing send methods:

```swift
    func registerChatHandler(sessionID: String, handler: @escaping ChatEventHandler) {
        chatHandlers[sessionID] = handler
    }

    func unregisterChatHandler(sessionID: String) {
        chatHandlers.removeValue(forKey: sessionID)
    }

    func sendChatConnect(agentID: String, sessionID: String, cwd: String,
                         name: String? = nil, model: String? = nil) {
        var payload: [String: Any] = [
            "agent_id": agentID,
            "session_id": sessionID,
            "kind": "chat",
            "cwd": cwd
        ]
        if let name, !name.isEmpty { payload["name"] = name }
        if let model, !model.isEmpty { payload["model"] = model }
        sendJSON(["type": "connect", "payload": payload])
    }

    func sendChatMessage(sessionID: String, text: String) {
        sendJSON(["type": "chat_send",
                  "payload": ["session_id": sessionID, "text": text] as [String: Any]])
    }

    func sendChatInterrupt(sessionID: String) {
        sendJSON(["type": "chat_interrupt",
                  "payload": ["session_id": sessionID] as [String: Any]])
    }

    /// Requests missed events. Completion runs exactly once: with the tail,
    /// or empty after a 5-second timeout.
    func requestChatHistory(agentID: String, sessionID: String, afterSeq: UInt64,
                            completion: @escaping ([ChatEvent], UInt64) -> Void) {
        let requestID = UUID().uuidString
        pendingChatHistory[requestID] = completion
        sendJSON([
            "type": "chat_history",
            "payload": [
                "agent_id": agentID, "session_id": sessionID,
                "request_id": requestID, "after_seq": afterSeq
            ] as [String: Any]
        ])
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard let self else { return }
            self.pendingChatHistory.removeValue(forKey: requestID)?([], 0)
        }
    }
```

- [ ] **Step 4: Build**

Open the Xcode project and build to a simulator, or:
`xcodebuild -project "Claude Orchestrator.iOS/Claude Orchestrator.xcodeproj" -scheme "Claude Orchestrator" -destination 'generic/platform=iOS Simulator' build`
Expected: BUILD SUCCEEDED

- [ ] **Step 5: Commit**

```bash
git add "Claude Orchestrator.iOS/Claude Orchestrator/Services/RelayWebSocket.swift"
git commit -m "feat(ios): chat send/receive API on the relay client"
```

---

### Task 10: iOS chat session model

**Files:**
- Create: `Claude Orchestrator.iOS/Claude Orchestrator/Models/ChatSession.swift`
- Modify: `Claude Orchestrator.iOS/Claude Orchestrator/Services/SessionManager.swift:8` and `:119-138`

**Interfaces:**
- Consumes: `ChatTranscript`, `ChatEvent` (Task 8); `RelayWebSocket` chat API (Task 9)
- Produces: `final class ChatSession: ObservableObject`, `SessionManager.chatSessions`, `SessionManager.createChatSession(for:cwd:name:)`

- [ ] **Step 1: Write `ChatSession.swift`**

`TerminalSession` already carries rendering plus activity parsing; chat does not go on it.

```swift
import Foundation
import Combine
import ClrcCore

/// One headless `claude` conversation on a Mac agent. Deliberately separate
/// from TerminalSession: that type owns a SwiftTerm view and ANSI parsing,
/// none of which applies here.
@MainActor
final class ChatSession: ObservableObject, Identifiable, Equatable {
    static func == (lhs: ChatSession, rhs: ChatSession) -> Bool { lhs.id == rhs.id }

    let id: String
    let agent: Agent
    let cwd: String

    @Published var customName: String
    @Published var transcript = ChatTranscript()
    @Published var isWorking = false
    @Published var lastError: String?

    init(agent: Agent, cwd: String, customName: String) {
        self.id = UUID().uuidString.lowercased()
        self.agent = agent
        self.cwd = cwd
        self.customName = customName
    }

    init(agentID: String, agentName: String, sessionID: String, cwd: String, customName: String) {
        self.id = sessionID
        self.agent = Agent(id: agentID, name: agentName, connected: true)
        self.cwd = cwd
        self.customName = customName
    }

    /// Applies one live event. A gap means events were missed while the app
    /// was backgrounded — the caller re-requests the tail rather than
    /// rendering a transcript with holes in it.
    func receive(_ event: ChatEvent) -> Bool {
        let hadGap = transcript.hasGap(before: event.seq)
        transcript = transcript.applying([event])

        switch event.kind {
        case .turnStart: isWorking = true
        case .turnEnd:   isWorking = false
        case .error:     lastError = event.message
        default:         break
        }
        return hadGap
    }

    func apply(history events: [ChatEvent]) {
        transcript = transcript.applying(events)
    }
}
```

- [ ] **Step 2: Hold chat sessions in `SessionManager`**

Next to `@Published var sessions: [TerminalSession]` (`SessionManager.swift:8`):

```swift
    @Published var chatSessions: [ChatSession] = []
```

And a creation method alongside `createSession`:

```swift
    func createChatSession(for agent: Agent, cwd: String, name: String) {
        let session = ChatSession(agent: agent, cwd: cwd, customName: name)
        chatSessions.append(session)

        relay.registerChatHandler(sessionID: session.id) { [weak self, weak session] event in
            Task { @MainActor in
                guard let self, let session else { return }
                if session.receive(event) {
                    self.relay.requestChatHistory(
                        agentID: session.agent.id,
                        sessionID: session.id,
                        afterSeq: session.transcript.lastSeq
                    ) { events, _ in
                        Task { @MainActor in session.apply(history: events) }
                    }
                }
            }
        }

        relay.sendChatConnect(agentID: agent.id, sessionID: session.id,
                              cwd: cwd, name: name)
    }

    func closeChat(_ session: ChatSession) {
        relay.unregisterChatHandler(sessionID: session.id)
        relay.sendDisconnect(sessionID: session.id)
        chatSessions.removeAll { $0.id == session.id }
    }
```

- [ ] **Step 3: Build**

Run the `xcodebuild` command from Task 9 Step 4.
Expected: BUILD SUCCEEDED

- [ ] **Step 4: Commit**

```bash
git add "Claude Orchestrator.iOS/Claude Orchestrator/Models/ChatSession.swift" \
        "Claude Orchestrator.iOS/Claude Orchestrator/Services/SessionManager.swift"
git commit -m "feat(ios): ChatSession model with gap-triggered history replay"
```

---

### Task 11: iOS chat UI

**Files:**
- Create: `Claude Orchestrator.iOS/Claude Orchestrator/Views/ChatSessionView.swift`
- Modify: `Claude Orchestrator.iOS/Claude Orchestrator/Views/NewSessionSheet.swift:144-150`
- Modify: `Claude Orchestrator.iOS/Claude Orchestrator/Views/SessionTabsView.swift`

**Interfaces:**
- Consumes: `ChatSession` (Task 10); `RelayWebSocket` chat API (Task 9)
- Produces: `struct ChatSessionView`, `struct ChatTurnView`, `struct ToolCallRow`, `struct ChatComposer`

- [ ] **Step 1: Write `ChatSessionView.swift`**

Plain text only — Markdown, syntax highlighting and diffs are sub-project 2.

```swift
import SwiftUI
import ClrcCore

struct ChatSessionView: View {
    @ObservedObject var session: ChatSession
    @EnvironmentObject var relay: RelayWebSocket
    @State private var draft = ""

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(session.transcript.turns) { turn in
                            ChatTurnView(turn: turn)
                        }
                    }
                    .padding()
                }
                .onChange(of: session.transcript.lastSeq) { _, seq in
                    withAnimation { proxy.scrollTo(seq, anchor: .bottom) }
                }
            }

            if let error = session.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
            }

            ChatComposer(
                draft: $draft,
                isWorking: session.isWorking,
                onSend: {
                    let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { return }
                    relay.sendChatMessage(sessionID: session.id, text: text)
                    draft = ""
                },
                onStop: { relay.sendChatInterrupt(sessionID: session.id) }
            )
        }
    }
}

struct ChatTurnView: View {
    let turn: ChatTurn

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(turn.events) { event in
                switch event.kind {
                case .text:
                    Text(event.text)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)

                case .toolUse:
                    ToolCallRow(event: event)

                case .error:
                    Label(event.message, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.red)

                case .turnEnd:
                    if event.costUSD > 0 {
                        Text(String(format: "%.3f $ · %d ms", event.costUSD, event.durationMS))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                case .turnStart, .toolResult, .unknown:
                    EmptyView()
                }
            }
        }
    }
}

struct ToolCallRow: View {
    let event: ChatEvent
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                expanded.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                    Text(event.name)
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                    Spacer()
                }
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)

            if expanded {
                Text(event.input)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                if event.truncated {
                    Text("truncated")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct ChatComposer: View {
    @Binding var draft: String
    let isWorking: Bool
    let onSend: () -> Void
    let onStop: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            TextField("Message", text: $draft, axis: .vertical)
                .lineLimit(1...5)
                .textFieldStyle(.roundedBorder)

            if isWorking {
                Button(action: onStop) {
                    Image(systemName: "stop.circle.fill").font(.title2)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.red)
            } else {
                Button(action: onSend) {
                    Image(systemName: "arrow.up.circle.fill").font(.title2)
                }
                .buttonStyle(.plain)
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(8)
        .background(.bar)
    }
}
```

- [ ] **Step 2: Start chat sessions from `NewSessionSheet`**

Replace `start(in:agent:dangerous:)` (`NewSessionSheet.swift:144-150`). The project choice becomes an honest `cwd` instead of a typed shell command:

```swift
    private func start(in path: String?, agent: Agent, dangerous: Bool) {
        let name = customName.trimmingCharacters(in: .whitespacesAndNewlines)
        sessionManager.createChatSession(
            for: agent,
            cwd: path ?? "~",
            name: name.isEmpty ? (path as NSString?)?.lastPathComponent ?? "claude" : name
        )
        dismiss()
    }
```

The `dangerous` parameter is now unused — chat sessions always run `bypassPermissions` per spec §3.1. Remove the `skipPermissions` toggle from `optionsSection` and the parameter from all call sites, rather than leaving a control that does nothing.

- [ ] **Step 3: Render either session kind in `SessionTabsView`**

This is the one real refactor in the plan: the view currently assumes a single session type throughout (`activeSession`, the empty check, the top bar, the terminal tab). Four surgical edits.

**3a.** Add a chat lookup next to `activeSession` (`SessionTabsView.swift:24-28`):

```swift
    var activeChatSession: ChatSession? {
        sessionManager.chatSessions.first { $0.id == selectedSessionID }
    }
```

**3b.** The empty check must consider both lists (`SessionTabsView.swift:30-37`):

```swift
    var body: some View {
        Group {
            if sessionManager.sessions.isEmpty && sessionManager.chatSessions.isEmpty {
                waitingView
            } else {
                mainView
            }
        }
    }
```

**3c.** Route the terminal tab to whichever session is selected. Replace the `terminalTab` property's contents, keeping the existing `TerminalTabContent` call for PTY sessions:

```swift
    @ViewBuilder
    private var terminalTab: some View {
        if let chat = activeChatSession {
            ChatSessionView(session: chat)
                .environmentObject(relay)
        } else if let session = activeSession {
            TerminalTabContent(session: session)
        } else {
            waitingView
        }
    }
```

**3d.** Select a chat session when one is created, and name it in the top bar. Add alongside the existing `.onChange(of: sessionManager.sessions)` (`SessionTabsView.swift:92`):

```swift
        .onChange(of: sessionManager.chatSessions) { _, chats in
            if let last = chats.last,
               selectedSessionID == nil || !chats.contains(where: { $0.id == selectedSessionID }) {
                selectedSessionID = last.id
            }
        }
```

And in `topBar`, ahead of the existing `if let session = activeSession` branch, so a chat session shows its name rather than "No Session":

```swift
            if let chat = activeChatSession {
                Button { showMachineSelector = true } label: {
                    HStack(spacing: 5) {
                        Text(chat.customName)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.primary)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
            } else if let session = activeSession {
                // ... existing SessionNameButton branch, unchanged ...
```

Note: `activeSession` falls back to `sessions.first` when nothing matches `selectedSessionID`, so **3c** checks `activeChatSession` first — otherwise selecting a chat session would still render a terminal.

- [ ] **Step 4: Build**

Run the `xcodebuild` command from Task 9 Step 4.
Expected: BUILD SUCCEEDED

- [ ] **Step 5: Mark the ANSI heuristic as superseded (spec §9.3)**

Add above `toolPattern` in `Claude Orchestrator.iOS/Claude Orchestrator/Models/TerminalSession.swift:46`:

```swift
    // NOTE: This regex-over-ANSI heuristic exists only because PTY mode has to
    // guess structure from TUI output. Chat sessions receive typed events
    // instead (see ChatEvent), so this applies to PTY sessions only and is a
    // removal candidate once chat mode covers the claude use case.
```

Do not remove the code — PTY sessions still rely on it.

- [ ] **Step 6: Manual verification on a device**

1. `make install && clrc restart` on the Mac.
2. In the app, create a session and pick a project folder.
3. Send "list the files here and tell me what this project is".
4. Confirm: text is selectable, tool calls appear collapsed and expand on tap, the stop button appears while working, and no ANSI escapes are visible anywhere.
5. Background the app for 30 seconds during a long turn, reopen, and confirm the transcript has no holes.

- [ ] **Step 7: Commit**

```bash
git add "Claude Orchestrator.iOS/Claude Orchestrator/Views/" \
        "Claude Orchestrator.iOS/Claude Orchestrator/Models/TerminalSession.swift"
git commit -m "feat(ios): native chat UI for headless claude sessions"
```

---

## Verification

- [ ] `cd agent && go test -race ./... && go vet ./...`
- [ ] `cd relay && go test -race ./... && go vet ./...`
- [ ] `cd "Claude Orchestrator.iOS/ClrcCore" && swift test`
- [ ] iOS app builds and the Task 11 Step 5 walkthrough passes on a device
- [ ] An **old** build of the app can still open a PTY session against the new agent (backward compatibility by omission of `kind`)
