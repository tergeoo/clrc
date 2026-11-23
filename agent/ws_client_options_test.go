package agent

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

func TestConnectReqProfileAndStyle(t *testing.T) {
	var req connectReq
	body := `{"session_id":"s","kind":"chat","profile":"personal","style":"clrc-brief"}`
	if err := json.Unmarshal([]byte(body), &req); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if req.Profile != "personal" || req.Style != "clrc-brief" {
		t.Fatalf("fields lost: %+v", req)
	}
}

func TestChatOptions(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	personal := filepath.Join(home, ".claude-personal")
	if err := os.Mkdir(personal, 0o700); err != nil {
		t.Fatal(err)
	}
	cfg := Config{ClaudeConfigDir: "/default/dir", OutputStyle: "clrc-chat", ExpectedHeaderPrefix: "tergeo"}

	tests := []struct {
		name      string
		req       connectReq
		wantDir   string
		wantStyle string
	}{
		{name: "agent defaults", req: connectReq{}, wantDir: "/default/dir", wantStyle: "clrc-chat"},
		{name: "profile and style from phone", req: connectReq{Profile: "personal", Style: "clrc-brief"}, wantDir: personal, wantStyle: "clrc-brief"},
		{name: "missing profile falls back", req: connectReq{Profile: "work"}, wantDir: "/default/dir", wantStyle: "clrc-chat"},
		{name: "invalid profile falls back", req: connectReq{Profile: "../x"}, wantDir: "/default/dir", wantStyle: "clrc-chat"},
		{name: "invalid style falls back", req: connectReq{Style: `a"}`}, wantDir: "/default/dir", wantStyle: "clrc-chat"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			c := NewWSClient(cfg)
			got := c.chatOptions(tt.req)
			if got.ConfigDir != tt.wantDir || got.Style != tt.wantStyle || got.HeaderPrefix != "tergeo" {
				t.Fatalf("options = %+v, want dir %q style %q", got, tt.wantDir, tt.wantStyle)
			}
		})
	}
}
