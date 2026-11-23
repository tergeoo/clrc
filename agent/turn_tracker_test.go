package agent

import (
	"strings"
	"testing"
)

func kindsOf(evs []ChatEvent) []ChatEventKind {
	out := make([]ChatEventKind, 0, len(evs))
	for _, e := range evs {
		out = append(out, e.Kind)
	}
	return out
}

func findReport(t *testing.T, evs []ChatEvent) *TurnReport {
	t.Helper()
	for i, e := range evs {
		if e.Kind != EventReport {
			continue
		}
		if i+1 >= len(evs) || evs[i+1].Kind != EventTurnEnd {
			t.Fatalf("report must be immediately followed by turn_end: %v", kindsOf(evs))
		}
		return e.Report
	}
	t.Fatalf("no report in %v", kindsOf(evs))
	return nil
}

func textEv(s string) ChatEvent { return ChatEvent{Kind: EventText, Text: s} }

func toolEv(name, input string) ChatEvent {
	return ChatEvent{Kind: EventToolUse, Name: name, Input: input}
}

var turnEnd = ChatEvent{Kind: EventTurnEnd, StopReason: "end_turn"}

func TestTurnTrackerReportFromBlock(t *testing.T) {
	tr := newTurnTracker("/home/u/proj", "")
	evs := tr.process([]ChatEvent{{Kind: EventTurnStart}})
	evs = append(evs, tr.process([]ChatEvent{textEv("**tergeo · personal**\n\nWorking on it.")})...)
	evs = append(evs, tr.process([]ChatEvent{toolEv("Edit", `{"file_path":"/home/u/proj/b.go"}`)})...)
	evs = append(evs, tr.process([]ChatEvent{textEv("Finished.\n\n" + validBlock)})...)
	evs = append(evs, tr.process([]ChatEvent{turnEnd})...)

	if evs[1].Text != "Working on it." || evs[3].Text != "Finished." {
		t.Fatalf("header/block not stripped: %q / %q", evs[1].Text, evs[3].Text)
	}
	r := findReport(t, evs)
	if r.Source != ReportFromBlock || r.Status != ReportNeedsInput || r.Title != "Need a value" {
		t.Fatalf("report = %+v", r)
	}
	if r.Header != "tergeo · personal" || !r.ContextOK {
		t.Fatalf("header = %q ok=%v", r.Header, r.ContextOK)
	}
	if len(r.ChangedFiles) != 1 || r.ChangedFiles[0] != "a.go" {
		t.Fatalf("block changed_files must win: %v", r.ChangedFiles)
	}
}

func TestTurnTrackerDropsTextThatWasOnlyHeaderAndBlock(t *testing.T) {
	tr := newTurnTracker("", "")
	evs := tr.process([]ChatEvent{{Kind: EventTurnStart}, textEv("**a · b**\n" + validBlock), turnEnd})
	want := []ChatEventKind{EventTurnStart, EventReport, EventTurnEnd}
	if got := kindsOf(evs); strings.Join(kindStrings(got), ",") != strings.Join(kindStrings(want), ",") {
		t.Fatalf("kinds = %v, want %v", got, want)
	}
}

func kindStrings(ks []ChatEventKind) []string {
	out := make([]string, len(ks))
	for i, k := range ks {
		out[i] = string(k)
	}
	return out
}

func TestTurnTrackerHeaderOnlyFromFirstText(t *testing.T) {
	tr := newTurnTracker("", "")
	evs := tr.process([]ChatEvent{{Kind: EventTurnStart}, textEv("First."), textEv("**not · header**\nSecond."), turnEnd})
	if evs[2].Text != "**not · header**\nSecond." {
		t.Fatalf("a later text's bold line must stay: %q", evs[2].Text)
	}
	if r := findReport(t, evs); r.Header != "" || r.ContextOK {
		t.Fatalf("header = %q ok=%v, want none", r.Header, r.ContextOK)
	}
}

func TestTurnTrackerContextOK(t *testing.T) {
	tests := []struct {
		name   string
		prefix string
		text   string
		want   bool
	}{
		{name: "header no prefix", text: "**tergeo · personal**\nHi", want: true},
		{name: "header matching prefix", prefix: "tergeo · personal", text: "**tergeo · personal · clrc**\nHi", want: true},
		{name: "header wrong prefix", prefix: "tergeo · work", text: "**tergeo · personal**\nHi", want: false},
		{name: "missing header", text: "Hi", want: false},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			tr := newTurnTracker("", tt.prefix)
			r := findReport(t, tr.process([]ChatEvent{{Kind: EventTurnStart}, textEv(tt.text), turnEnd}))
			if r.ContextOK != tt.want {
				t.Fatalf("context_ok = %v, want %v (header %q)", r.ContextOK, tt.want, r.Header)
			}
		})
	}
}

func TestTurnTrackerFallback(t *testing.T) {
	longCyr := strings.Repeat("Изменил обработчик и тесты. ", 20)
	tests := []struct {
		name       string
		events     []ChatEvent
		wantStatus string
		wantTitle  string
		wantFiles  []string
		wantQs     int
		wantRaw    string
	}{
		{
			name:       "plain done",
			events:     []ChatEvent{textEv("## Added the endpoint\nAll tests pass."), turnEnd},
			wantStatus: ReportDone, wantTitle: "Added the endpoint",
		},
		{
			name:       "question needs input",
			events:     []ChatEvent{textEv("Two options:\n1. Keep 30 days?\n2. Keep 90 days?")},
			wantStatus: ReportNeedsInput, wantTitle: "Two options:", wantQs: 2,
		},
		{
			name: "changed files from tools",
			events: []ChatEvent{
				toolEv("Write", `{"file_path":"/home/u/proj/new.go","content":"pack`),
				toolEv("MultiEdit", `{"file_path":"/elsewhere/x.go","edits":[]}`),
				toolEv("Edit", `{"file_path":"/home/u/proj/new.go"}`),
				toolEv("Read", `{"file_path":"/home/u/proj/ignored.go"}`),
				textEv("Done."),
			},
			wantStatus: ReportDone, wantTitle: "Done.", wantFiles: []string{"new.go", "/elsewhere/x.go"},
		},
		{
			name:       "malformed block keeps raw text",
			events:     []ChatEvent{textEv("Result.\n```clrc-report\n{oops\n```")},
			wantStatus: ReportDone, wantTitle: "Result.", wantRaw: "{oops",
		},
		{
			name:       "error result fails",
			events:     []ChatEvent{textEv("Trying."), {Kind: EventTurnEnd}, {Kind: EventError, Message: "boom"}},
			wantStatus: ReportFailed, wantTitle: "Trying.",
		},
		{
			name:       "interrupted",
			events:     []ChatEvent{toolEv("Bash", `{}`), {Kind: EventTurnEnd, StopReason: "interrupted"}},
			wantStatus: ReportInProgress, wantTitle: "Interrupted",
		},
		{
			name:       "cyrillic title truncated",
			events:     []ChatEvent{textEv(longCyr)},
			wantStatus: ReportDone,
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			tr := newTurnTracker("/home/u/proj", "")
			in := append([]ChatEvent{{Kind: EventTurnStart}}, tt.events...)
			if in[len(in)-1].Kind != EventTurnEnd && in[len(in)-1].Kind != EventError {
				in = append(in, turnEnd)
			}
			evs := tr.process(in)
			r := findReport(t, evs)
			if r.Source != ReportFromFallback || r.Status != tt.wantStatus {
				t.Fatalf("source=%s status=%s, want fallback %s", r.Source, r.Status, tt.wantStatus)
			}
			if tt.wantTitle != "" && r.Title != tt.wantTitle {
				t.Fatalf("title = %q, want %q", r.Title, tt.wantTitle)
			}
			if len([]rune(r.Title)) > reportTitleRunes || len([]rune(r.Summary)) > reportSummaryRunes {
				t.Fatalf("title/summary over cap: %q / %q", r.Title, r.Summary)
			}
			if len(r.Questions) != tt.wantQs {
				t.Fatalf("questions = %v, want %d", r.Questions, tt.wantQs)
			}
			if tt.wantFiles != nil && strings.Join(r.ChangedFiles, ",") != strings.Join(tt.wantFiles, ",") {
				t.Fatalf("changed_files = %v, want %v", r.ChangedFiles, tt.wantFiles)
			}
			if tt.wantRaw != "" && !strings.Contains(evs[1].Text, tt.wantRaw) {
				t.Fatalf("malformed block hidden from text: %q", evs[1].Text)
			}
			if strings.Contains(r.Summary, "clrc-report") {
				t.Fatalf("summary leaks the block: %q", r.Summary)
			}
		})
	}
}

func TestTurnTrackerNoReportForEmptyTurn(t *testing.T) {
	tr := newTurnTracker("", "")
	evs := tr.process([]ChatEvent{{Kind: EventTurnStart}, turnEnd})
	for _, e := range evs {
		if e.Kind == EventReport {
			t.Fatalf("empty turn produced a report: %v", kindsOf(evs))
		}
	}
}

func TestTurnTrackerResetsBetweenTurns(t *testing.T) {
	tr := newTurnTracker("", "")
	tr.process([]ChatEvent{{Kind: EventTurnStart}, textEv("**a · b**\nOne"), toolEv("Edit", `{"file_path":"x.go"}`), turnEnd})
	r := findReport(t, tr.process([]ChatEvent{{Kind: EventTurnStart}, textEv("Two"), turnEnd}))
	if r.Header != "" || len(r.ChangedFiles) != 0 || r.Title != "Two" {
		t.Fatalf("state leaked across turns: %+v", r)
	}
}

func TestTurnTrackerReportListsAreNeverNull(t *testing.T) {
	tr := newTurnTracker("", "")
	r := findReport(t, tr.process([]ChatEvent{textEv("x"), turnEnd}))
	if r.Questions == nil || r.NextSteps == nil || r.ChangedFiles == nil {
		t.Fatalf("nil list in %+v", r)
	}
}
