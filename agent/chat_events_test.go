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
