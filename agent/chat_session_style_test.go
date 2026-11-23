package agent

import (
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
	"time"
)

func TestChatSessionArgsWithStyle(t *testing.T) {
	tests := []struct {
		name    string
		style   string
		model   string
		started bool
		want    []string
	}{
		{
			name: "no style passes no settings",
			want: []string{"--session-id", "sid"},
		},
		{
			name:  "style on first spawn",
			style: "clrc-chat",
			want:  []string{"--session-id", "sid", "--settings", `{"outputStyle":"clrc-chat"}`},
		},
		{
			name:    "style kept on resume",
			style:   "clrc-brief",
			model:   "opus",
			started: true,
			want:    []string{"--resume", "sid", "--model", "opus", "--settings", `{"outputStyle":"clrc-brief"}`},
		},
	}
	base := []string{"-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose", "--permission-mode", "bypassPermissions"}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			s := NewChatSessionWithOptions("sid", "/tmp", ChatOptions{Model: tt.model, Style: tt.style}, nil)
			s.started = tt.started
			want := append(slices.Clone(base), tt.want...)
			if got := s.args(); !slices.Equal(got, want) {
				t.Fatalf("args = %v\nwant   %v", got, want)
			}
		})
	}
}

func readArgsFile(t *testing.T, path string, lines int) []string {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		data, _ := os.ReadFile(path)
		got := strings.Split(strings.TrimSpace(string(data)), "\n")
		if len(got) >= lines && got[0] != "" {
			return got
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatalf("args file %s never reached %d lines", path, lines)
	return nil
}

// TestChatSessionSpawnEnvAndStyleSurviveRespawn drives the fake CLI through
// a first spawn and a --resume respawn and checks what each process saw.
func TestChatSessionSpawnEnvAndStyleSurviveRespawn(t *testing.T) {
	argsFile := filepath.Join(t.TempDir(), "args.txt")
	configDir := t.TempDir()
	t.Setenv("FAKE_CLAUDE_ARGSFILE", argsFile)
	t.Setenv("FAKE_CLAUDE_MODE", "report")
	t.Setenv("CLAUDECODE", "1")
	t.Setenv("CLAUDE_CODE_ENTRYPOINT", "cli")

	emit, read := collectEvents()
	s := NewChatSessionWithOptions("sid", t.TempDir(), ChatOptions{Style: "clrc-brief", ConfigDir: configDir, HeaderPrefix: "tergeo"}, emit)
	s.Bin = fakeClaude(t)
	defer s.Close()

	if err := s.Send("one"); err != nil {
		t.Fatalf("send: %v", err)
	}
	waitFor(t, read, EventTurnEnd)
	s.Interrupt()
	if err := s.Send("two"); err != nil {
		t.Fatalf("send after interrupt: %v", err)
	}

	lines := readArgsFile(t, argsFile, 2)
	for i, line := range lines[:2] {
		if !strings.Contains(line, `--settings {"outputStyle":"clrc-brief"}`) {
			t.Errorf("spawn %d missing --settings: %s", i, line)
		}
		for _, want := range []string{"config=" + configDir + "|", "clrc=1|", "claudecode=|", "entry="} {
			if !strings.Contains(line, want) {
				t.Errorf("spawn %d env missing %q: %s", i, want, line)
			}
		}
	}
	if !strings.Contains(lines[1], "--resume sid") {
		t.Errorf("respawn must resume: %s", lines[1])
	}

	evs := read()
	r := findReport(t, evs)
	if r.Source != ReportFromBlock || r.Title != "Added endpoint" || r.Header != "tergeo · personal" || !r.ContextOK {
		t.Fatalf("report = %+v", r)
	}
	for _, e := range evs {
		if e.Kind == EventText && (strings.Contains(e.Text, "clrc-report") || strings.Contains(e.Text, "**tergeo")) {
			t.Fatalf("text leaks header or block: %q", e.Text)
		}
	}
}
