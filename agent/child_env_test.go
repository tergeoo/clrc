package agent

import (
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
)

func TestBuildChildEnv(t *testing.T) {
	base := []string{
		"HOME=/Users/u",
		"PATH=/usr/bin",
		"CLAUDECODE=1",
		"CLAUDE_CODE_ENTRYPOINT=cli",
		"CLAUDE_CODE_SESSION_ID=abc",
		"CLAUDE_CONFIG_DIR=/Users/u/.claude-inherited",
		"CLRC_SESSION=0",
		"CLRC_PROFILE=personal",
	}
	tests := []struct {
		name      string
		configDir string
		want      []string
	}{
		{
			name: "no config dir keeps current behaviour",
			want: []string{"HOME=/Users/u", "PATH=/usr/bin", "CLRC_PROFILE=personal", "CLRC_SESSION=1"},
		},
		{
			name:      "config dir set explicitly",
			configDir: "/Users/u/.claude-personal",
			want: []string{"HOME=/Users/u", "PATH=/usr/bin", "CLRC_PROFILE=personal", "CLRC_SESSION=1",
				"CLAUDE_CONFIG_DIR=/Users/u/.claude-personal"},
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := buildChildEnv(base, LaunchProfile{ConfigDir: tt.configDir})
			if !slices.Equal(got, tt.want) {
				t.Fatalf("env = %v\nwant  %v", got, tt.want)
			}
		})
	}
}

func TestResolveClaudeConfigDir(t *testing.T) {
	home := t.TempDir()
	for _, d := range []string{".claude-personal", "custom"} {
		if err := os.Mkdir(filepath.Join(home, d), 0o700); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.WriteFile(filepath.Join(home, "file"), nil, 0o600); err != nil {
		t.Fatal(err)
	}
	tests := []struct {
		name     string
		profile  string
		explicit string
		want     string
		wantErr  string
	}{
		{name: "nothing set", want: ""},
		{name: "profile", profile: "personal", want: filepath.Join(home, ".claude-personal")},
		{name: "explicit wins over profile", profile: "personal", explicit: filepath.Join(home, "custom"), want: filepath.Join(home, "custom")},
		{name: "explicit with tilde", explicit: "~/custom", want: filepath.Join(home, "custom")},
		{name: "missing profile dir", profile: "work", wantErr: "no such file"},
		{name: "invalid profile name", profile: "../etc", wantErr: "must match"},
		{name: "uppercase profile rejected", profile: "Personal", wantErr: "must match"},
		{name: "explicit is a file", explicit: filepath.Join(home, "file"), wantErr: "not a directory"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got, err := ResolveClaudeConfigDir(home, tt.profile, tt.explicit)
			if tt.wantErr != "" {
				if err == nil || !strings.Contains(err.Error(), tt.wantErr) {
					t.Fatalf("err = %v, want containing %q", err, tt.wantErr)
				}
				if got != "" {
					t.Fatalf("rejected dir must not be returned, got %q", got)
				}
				return
			}
			if err != nil || got != tt.want {
				t.Fatalf("got (%q, %v), want %q", got, err, tt.want)
			}
		})
	}
}

func TestOutputStyleFromEnv(t *testing.T) {
	tests := []struct {
		name    string
		env     map[string]string
		want    string
		wantErr bool
	}{
		{name: "unset uses default", env: map[string]string{}, want: DefaultOutputStyle},
		{name: "empty disables", env: map[string]string{"CLRC_OUTPUT_STYLE": ""}, want: ""},
		{name: "explicit style", env: map[string]string{"CLRC_OUTPUT_STYLE": "clrc-brief"}, want: "clrc-brief"},
		{name: "invalid falls back", env: map[string]string{"CLRC_OUTPUT_STYLE": `x"}`}, want: DefaultOutputStyle, wantErr: true},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			lookup := func(k string) (string, bool) { v, ok := tt.env[k]; return v, ok }
			got, err := OutputStyleFromEnv(lookup)
			if (err != nil) != tt.wantErr || got != tt.want {
				t.Fatalf("got (%q, %v), want %q err=%v", got, err, tt.want, tt.wantErr)
			}
		})
	}
}
