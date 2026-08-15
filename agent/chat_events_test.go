package agent

import (
	"bytes"
	"os"
	"strings"
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

func TestDecodeContentArray(t *testing.T) {
	// tool_result with array of text blocks should extract and join with newlines.
	line := `{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","is_error":false,"content":[{"type":"text","text":"line one"},{"type":"text","text":"line two"}]}]}}`
	got := TranslateLine([]byte(line), "t")
	if len(got) != 1 {
		t.Fatalf("expected 1 event, got %d", len(got))
	}
	if got[0].Output != "line one\nline two" {
		t.Fatalf("array blocks not joined: got %q, want %q", got[0].Output, "line one\nline two")
	}
}

func TestDecodeContentPlainString(t *testing.T) {
	// tool_result with plain string content should pass through unchanged (fast path).
	line := `{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","is_error":false,"content":"plain string output"}]}}`
	got := TranslateLine([]byte(line), "t")
	if len(got) != 1 {
		t.Fatalf("expected 1 event, got %d", len(got))
	}
	if got[0].Output != "plain string output" {
		t.Fatalf("plain string corrupted: got %q", got[0].Output)
	}
}

func TestDecodeContentNoTextBlocks(t *testing.T) {
	// tool_result with array containing no text blocks should fall back to raw JSON.
	line := `{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","is_error":false,"content":[{"type":"image","source":{}}]}]}}`
	got := TranslateLine([]byte(line), "t")
	if len(got) != 1 {
		t.Fatalf("expected 1 event, got %d", len(got))
	}
	if got[0].Output == "" {
		t.Fatalf("non-text blocks should fall back to raw JSON, not empty string")
	}
	if !strings.Contains(got[0].Output, "image") {
		t.Fatalf("expected raw JSON in output, got %q", got[0].Output)
	}
}

func TestTruncatePayloadUTF8(t *testing.T) {
	// Payload with multibyte UTF-8 characters should truncate on rune boundary.
	long := strings.Repeat("я", maxPayloadBytes/2+100) // Each "я" is 2 bytes in UTF-8
	s, tr := truncatePayload(long)
	if !tr {
		t.Fatal("long payload should report truncated")
	}
	if len(s) > maxPayloadBytes {
		t.Fatalf("payload not capped: %d bytes (max %d)", len(s), maxPayloadBytes)
	}
	// Check that the result is valid UTF-8.
	if !isValidUTF8(s) {
		t.Fatalf("result contains invalid UTF-8")
	}
}

// isValidUTF8 checks if a string contains only valid UTF-8.
func isValidUTF8(s string) bool {
	for _, r := range s {
		if r == -1 { // -1 is the replacement character for invalid UTF-8
			return false
		}
	}
	return true
}
