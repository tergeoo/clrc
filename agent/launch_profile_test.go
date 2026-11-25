package agent

import (
	"context"
	"encoding/json"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"testing"
)

func TestBuildChildEnvHarness(t *testing.T) {
	base := []string{"PATH=/bin", "TOKEN=old", "CLAUDE_X=1", "HARNESS_PROFILE=inherited"}
	lp := LaunchProfile{
		Name: "rtd", ConfigDir: "/h/.claude-rtd", Harness: true,
		Env: []string{"TOKEN=new", "CLAUDE_CONFIG_DIR=/evil", "HARNESS_PROFILE=evil", "CLRC_SESSION=0",
			"CLAUDE_CODE_USE_BEDROCK=1"},
	}
	got := buildChildEnv(base, lp)
	for _, want := range []string{"PATH=/bin", "TOKEN=new", "HARNESS_PROFILE=rtd", "CLAUDE_CONFIG_DIR=/h/.claude-rtd",
		"CLRC_SESSION=1", "CLAUDE_CODE_USE_BEDROCK=1"} {
		if !slices.Contains(got, want) {
			t.Errorf("env lacks %q: %v", want, got)
		}
	}
	for _, key := range []string{"TOKEN=", "HARNESS_PROFILE=", "CLAUDE_CONFIG_DIR=", "CLRC_SESSION="} {
		if n := countPrefix(got, key); n != 1 {
			t.Errorf("%d entries for %s in %v, want 1", n, key, got)
		}
	}
	if slices.Contains(got, "CLAUDE_X=1") {
		t.Errorf("inherited nested-session var kept: %v", got)
	}
}

func TestBuildChildEnvPlainProfileHasNoHarnessVar(t *testing.T) {
	got := buildChildEnv([]string{"HARNESS_PROFILE=inherited"}, LaunchProfile{Name: "solo", ConfigDir: "/h/.claude-solo"})
	if countPrefix(got, "HARNESS_PROFILE=") != 0 {
		t.Errorf("plain profile got HARNESS_PROFILE: %v", got)
	}
}

// launchFixture: home with harness root (rtd synced + env file, dats defined
// but unsynced) and a plain profile dir .claude-solo.
func launchFixture(t *testing.T) (home string) {
	t.Helper()
	home, root := harnessFixture(t)
	t.Setenv("HOME", home)
	t.Setenv("HARNESS_ROOT", root)
	writeFile(t, filepath.Join(home, ".config/harness/rtd.env"), "export RTD_TOKEN='abc'\n")
	writeFile(t, filepath.Join(home, ".claude-dats/settings.json"), "{}")
	writeFile(t, filepath.Join(home, ".claude-solo/settings.json"), "{}")
	return home
}

func TestResolveLaunch(t *testing.T) {
	home := launchFixture(t)
	rtd := LaunchProfile{Name: "rtd", ConfigDir: filepath.Join(home, ".claude-rtd"), Harness: true, Env: []string{"RTD_TOKEN=abc"}}
	solo := LaunchProfile{Name: "solo", ConfigDir: filepath.Join(home, ".claude-solo")}
	def := LaunchProfile{ConfigDir: "/default/dir"}

	tests := []struct {
		name       string
		cfg        Config
		profile    string
		strict     bool
		want       LaunchProfile
		wantErrHas string
	}{
		{name: "synced harness profile", profile: "rtd", want: rtd},
		{name: "plain profile dir", profile: "solo", want: solo},
		{name: "empty uses harness default", cfg: Config{Profile: "rtd", ClaudeConfigDir: rtd.ConfigDir}, want: rtd},
		{name: "empty without default", cfg: Config{ClaudeConfigDir: "/default/dir"}, want: def},
		{name: "strict unsynced harness profile", cfg: Config{ClaudeConfigDir: "/default/dir"}, profile: "dats", strict: true,
			wantErrHas: "профиль «dats» не найден на этом Маке — harness sync dats"},
		{name: "strict missing profile", cfg: Config{ClaudeConfigDir: "/default/dir"}, profile: "nope", strict: true,
			wantErrHas: "профиль «nope» не найден"},
		{name: "strict invalid name", cfg: Config{ClaudeConfigDir: "/default/dir"}, profile: "../x", strict: true,
			wantErrHas: "не найден"},
		{name: "non-strict missing falls back", cfg: Config{ClaudeConfigDir: "/default/dir"}, profile: "nope", want: def,
			wantErrHas: "nope"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			c := NewWSClient(tt.cfg)
			got, err := c.resolveLaunch(tt.profile, tt.strict)
			if tt.wantErrHas != "" {
				if err == nil || !strings.Contains(err.Error(), tt.wantErrHas) {
					t.Fatalf("err = %v, want containing %q", err, tt.wantErrHas)
				}
				if tt.strict {
					return
				}
			} else if err != nil {
				t.Fatalf("unexpected err: %v", err)
			}
			if got.Name != tt.want.Name || got.ConfigDir != tt.want.ConfigDir || got.Harness != tt.want.Harness ||
				!slices.Equal(got.Env, tt.want.Env) {
				t.Errorf("resolveLaunch = %+v, want %+v", got, tt.want)
			}
		})
	}
}

// sentMsg is one control message captured from the agent.
type sentMsg struct {
	Type    string
	Payload map[string]any
}

func capturingClient(t *testing.T, cfg Config) (*WSClient, func() []sentMsg) {
	t.Helper()
	c := NewWSClient(cfg)
	var mu sync.Mutex
	var sent []sentMsg
	c.textOut = func(_ context.Context, msgType string, payload any) {
		raw, _ := json.Marshal(payload)
		var m map[string]any
		_ = json.Unmarshal(raw, &m)
		mu.Lock()
		sent = append(sent, sentMsg{Type: msgType, Payload: m})
		mu.Unlock()
	}
	return c, func() []sentMsg {
		mu.Lock()
		defer mu.Unlock()
		return slices.Clone(sent)
	}
}

const strictSessionID = "9c1d2e3f-4a5b-4c6d-8e7f-0a1b2c3d4e5f"

func TestStrictProfileRefusesPTY(t *testing.T) {
	launchFixture(t)
	c, sent := capturingClient(t, Config{DefaultCommand: "/bin/sh"})
	c.handleConnect(context.Background(), json.RawMessage(
		`{"session_id":"`+strictSessionID+`","cols":80,"rows":24,"profile":"nope","profile_strict":true}`))

	if len(c.sessions) != 0 {
		t.Fatalf("PTY spawned despite strict profile failure")
	}
	msgs := sent()
	if len(msgs) != 1 || msgs[0].Type != "error" || msgs[0].Payload["session_id"] != strictSessionID ||
		!strings.Contains(msgs[0].Payload["message"].(string), "профиль «nope» не найден") {
		t.Fatalf("sent = %+v, want one session error", msgs)
	}
}

func TestStrictProfileRefusesChat(t *testing.T) {
	launchFixture(t)
	c, sent := capturingClient(t, Config{})
	c.handleConnect(context.Background(), json.RawMessage(
		`{"session_id":"`+strictSessionID+`","kind":"chat","cwd":"~","profile":"dats","profile_strict":true}`))

	if len(c.chats) != 0 {
		t.Fatalf("chat session created despite strict profile failure")
	}
	msgs := sent()
	if len(msgs) != 1 || msgs[0].Type != "chat_event" || msgs[0].Payload["session_id"] != strictSessionID {
		t.Fatalf("sent = %+v, want one chat error", msgs)
	}
	event, _ := msgs[0].Payload["event"].(map[string]any)
	if msg, _ := event["message"].(string); !strings.Contains(msg, "harness sync dats") {
		t.Fatalf("chat error = %q", msg)
	}
}
