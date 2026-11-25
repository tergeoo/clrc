package agent

import (
	"os"
	"slices"
	"testing"
)

func TestEnsureTerm(t *testing.T) {
	tests := []struct {
		name          string
		env           []string
		wantTerm      string // expected TERM= entry, "" means must be absent-added default
		wantColorTerm string
	}{
		{
			name:          "adds defaults when missing",
			env:           []string{"PATH=/usr/bin", "HOME=/Users/x"},
			wantTerm:      "TERM=xterm-256color",
			wantColorTerm: "COLORTERM=truecolor",
		},
		{
			name:          "preserves existing TERM",
			env:           []string{"TERM=screen-256color"},
			wantTerm:      "TERM=screen-256color",
			wantColorTerm: "COLORTERM=truecolor",
		},
		{
			name:          "preserves existing COLORTERM",
			env:           []string{"COLORTERM=24bit"},
			wantTerm:      "TERM=xterm-256color",
			wantColorTerm: "COLORTERM=24bit",
		},
		{
			name:          "preserves both when present",
			env:           []string{"TERM=vt100", "COLORTERM=truecolor"},
			wantTerm:      "TERM=vt100",
			wantColorTerm: "COLORTERM=truecolor",
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := ensureTerm(tt.env)
			if !slices.Contains(got, tt.wantTerm) {
				t.Errorf("ensureTerm(%v) = %v, want to contain %q", tt.env, got, tt.wantTerm)
			}
			if !slices.Contains(got, tt.wantColorTerm) {
				t.Errorf("ensureTerm(%v) = %v, want to contain %q", tt.env, got, tt.wantColorTerm)
			}
			// Exactly one TERM= and one COLORTERM= entry (no duplicates).
			if n := countPrefix(got, "TERM="); n != 1 {
				t.Errorf("ensureTerm(%v) produced %d TERM= entries, want 1", tt.env, n)
			}
			if n := countPrefix(got, "COLORTERM="); n != 1 {
				t.Errorf("ensureTerm(%v) produced %d COLORTERM= entries, want 1", tt.env, n)
			}
		})
	}
}

func countPrefix(env []string, prefix string) int {
	n := 0
	for _, kv := range env {
		if len(kv) >= len(prefix) && kv[:len(prefix)] == prefix {
			n++
		}
	}
	return n
}

// A launchd-started agent has no TERM; PTY children must still get one.
func TestPTYEnvAdvertisesTerminal(t *testing.T) {
	t.Setenv("TERM", "")
	os.Unsetenv("TERM")
	env := ptyEnv("")
	if !slices.Contains(env, "TERM=xterm-256color") {
		t.Errorf("ptyEnv() lacks TERM=xterm-256color: %v", env)
	}
	if !slices.Contains(env, envClrcSession+"=1") {
		t.Errorf("ptyEnv() lost %s=1: %v", envClrcSession, env)
	}
}
