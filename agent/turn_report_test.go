package agent

import (
	"strings"
	"testing"
	"unicode/utf8"
)

const validBlock = "```clrc-report\n" +
	`{"v":1,"status":"needs_input","title":"Need a value","summary":"Waiting.","questions":["How many days?"],"next_steps":[],"changed_files":["a.go"],"extra":"ignored"}` +
	"\n```"

func TestScanReportBlocks(t *testing.T) {
	second := "```clrc-report\n" + `{"v":1,"status":"done","title":"Second"}` + "\n```"
	malformed := "```clrc-report\n{\"v\":1,\"status\":\n```"

	tests := []struct {
		name          string
		in            string
		wantText      string
		wantFound     bool
		wantMalformed bool
		wantTitle     string
	}{
		{name: "no block", in: "just text", wantText: "just text"},
		{name: "block at end", in: "Done.\n\n" + validBlock, wantText: "Done.", wantFound: true, wantTitle: "Need a value"},
		{name: "block mid text", in: "Before.\n" + validBlock + "\nAfter.", wantText: "Before.\n\nAfter.", wantFound: true, wantTitle: "Need a value"},
		{name: "two blocks last wins", in: validBlock + "\nmiddle\n" + second, wantText: "middle", wantFound: true, wantTitle: "Second"},
		{name: "malformed stays visible", in: "Text.\n" + malformed, wantText: "Text.\n" + malformed, wantFound: true, wantMalformed: true},
		{name: "valid then malformed", in: validBlock + "\n" + malformed, wantText: malformed, wantFound: true, wantMalformed: true},
		{name: "unterminated block", in: "Text.\n```clrc-report\n{\"v\":1,\"status\":\"failed\",\"title\":\"Cut\"}", wantText: "Text.", wantFound: true, wantTitle: "Cut"},
		{name: "other fences untouched", in: "```go\nx := 1\n```", wantText: "```go\nx := 1\n```"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := scanReportBlocks(tt.in)
			if got.text != tt.wantText {
				t.Errorf("text = %q, want %q", got.text, tt.wantText)
			}
			if got.found != tt.wantFound || got.malformed != tt.wantMalformed {
				t.Errorf("found=%v malformed=%v, want %v %v", got.found, got.malformed, tt.wantFound, tt.wantMalformed)
			}
			if tt.wantTitle != "" && (got.report == nil || got.report.Title != tt.wantTitle) {
				t.Errorf("report = %+v, want title %q", got.report, tt.wantTitle)
			}
		})
	}
}

func TestParseReportJSONNormalises(t *testing.T) {
	r, ok := parseReportJSON(`{"status":"weird","title":"x"}`)
	if !ok {
		t.Fatal("valid JSON object rejected")
	}
	if r.V != 1 || r.Status != ReportDone || r.Source != ReportFromBlock {
		t.Fatalf("normalised = %+v", r)
	}
	if _, ok := parseReportJSON(`["not","an","object"]`); ok {
		t.Fatal("array accepted as a report")
	}
}

func TestStripHeader(t *testing.T) {
	tests := []struct {
		name       string
		in         string
		wantText   string
		wantHeader string
	}{
		{name: "header first", in: "**tergeo · personal**\n\nHello", wantText: "Hello", wantHeader: "tergeo · personal"},
		{name: "leading blank lines", in: "\n\n**tergeo · personal · clrc**\nHi", wantText: "Hi", wantHeader: "tergeo · personal · clrc"},
		{name: "no header", in: "Hello\n**bold**", wantText: "Hello\n**bold**"},
		{name: "bold inside sentence", in: "**Note** this matters", wantText: "**Note** this matters"},
		{name: "header only", in: "**tergeo · work**", wantText: "", wantHeader: "tergeo · work"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			text, header := stripHeader(tt.in)
			if text != tt.wantText || header != tt.wantHeader {
				t.Errorf("got (%q, %q), want (%q, %q)", text, header, tt.wantText, tt.wantHeader)
			}
		})
	}
}

func TestTruncateWords(t *testing.T) {
	cyr := strings.Repeat("Привет мир ", 20)
	tests := []struct {
		name    string
		in      string
		max     int
		wantCut bool
		want    string
	}{
		{name: "short ascii", in: "short", max: 60, want: "short"},
		{name: "exact length", in: strings.Repeat("a", 60), max: 60, want: strings.Repeat("a", 60)},
		{name: "word boundary", in: "alpha beta gamma delta", max: 15, wantCut: true, want: "alpha beta…"},
		{name: "no space falls back to runes", in: strings.Repeat("ж", 80), max: 10, wantCut: true, want: strings.Repeat("ж", 9) + "…"},
		{name: "cyrillic summary", in: cyr, max: 200, wantCut: true},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got, cut := truncateWords(tt.in, tt.max)
			if cut != tt.wantCut {
				t.Fatalf("cut = %v, want %v", cut, tt.wantCut)
			}
			if !utf8.ValidString(got) {
				t.Fatalf("invalid UTF-8: %q", got)
			}
			if n := utf8.RuneCountInString(got); n > tt.max {
				t.Fatalf("%d runes > max %d: %q", n, tt.max, got)
			}
			if tt.want != "" && got != tt.want {
				t.Fatalf("got %q, want %q", got, tt.want)
			}
		})
	}
}

func TestCapReportKeepsWithinPayloadBudget(t *testing.T) {
	long := strings.Repeat("ю", 500)
	items := make([]string, 30)
	for i := range items {
		items[i] = long
	}
	r := TurnReport{Title: long, Summary: long, Questions: items, NextSteps: items, ChangedFiles: items}
	if !capReport(&r) {
		t.Fatal("capReport must report truncation")
	}
	if utf8.RuneCountInString(r.Title) > reportTitleRunes || utf8.RuneCountInString(r.Summary) > reportSummaryRunes {
		t.Fatalf("title/summary not capped: %d / %d runes", utf8.RuneCountInString(r.Title), utf8.RuneCountInString(r.Summary))
	}
	if size := reportSize(&r); size > maxPayloadBytes {
		t.Fatalf("encoded report is %d bytes, over %d", size, maxPayloadBytes)
	}
}

func TestEndsWithQuestion(t *testing.T) {
	for in, want := range map[string]bool{
		"Proceed?":         true,
		"Продолжить？":      true,
		"Which one? **":    true,
		"Done.":            false,
		"Is it? No, done.": false,
		"":                 false,
	} {
		if got := endsWithQuestion(in); got != want {
			t.Errorf("endsWithQuestion(%q) = %v, want %v", in, got, want)
		}
	}
}
