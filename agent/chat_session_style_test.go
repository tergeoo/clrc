package agent

import (
	"slices"
	"testing"
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
