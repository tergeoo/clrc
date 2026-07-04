package agent

import (
	"encoding/json"
	"testing"
	"time"
)

func TestConnectReqParsesOptionalName(t *testing.T) {
	tests := []struct {
		name    string
		payload string
		want    connectReq
	}{
		{
			name:    "with name",
			payload: `{"session_id":"abc","cols":100,"rows":30,"name":"drops.iOS"}`,
			want:    connectReq{SessionID: "abc", Cols: 100, Rows: 30, Name: "drops.iOS"},
		},
		{
			name:    "without name (old client)",
			payload: `{"session_id":"abc","cols":80,"rows":24}`,
			want:    connectReq{SessionID: "abc", Cols: 80, Rows: 24, Name: ""},
		},
		{
			name:    "extra unknown fields ignored",
			payload: `{"agent_id":"x","session_id":"abc","cols":80,"rows":24,"future":"y"}`,
			want:    connectReq{SessionID: "abc", Cols: 80, Rows: 24},
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			var got connectReq
			if err := json.Unmarshal([]byte(tt.payload), &got); err != nil {
				t.Fatalf("unmarshal: %v", err)
			}
			if got != tt.want {
				t.Errorf("got %+v, want %+v", got, tt.want)
			}
		})
	}
}

func TestBuildSessionsList(t *testing.T) {
	started := time.Date(2026, 7, 4, 10, 30, 0, 0, time.UTC)
	live := map[string]*PTYSession{
		"id-with-meta": {ID: "id-with-meta", Cols: 100, Rows: 30},
		"id-no-meta":   {ID: "id-no-meta", Cols: 80, Rows: 24},
	}
	disk := []SessionInfo{
		{ID: "id-with-meta", PID: 1, Command: "claude", Name: "drops.iOS", Started: started},
		{ID: "stale-on-disk", PID: 2, Command: "bash", Name: "gone", Started: started},
	}

	entries := buildSessionsList(live, disk)

	if len(entries) != 2 {
		t.Fatalf("got %d entries, want 2 (only live sessions listed)", len(entries))
	}
	byID := map[string]map[string]any{}
	for _, e := range entries {
		byID[e["id"].(string)] = e
	}

	withMeta, ok := byID["id-with-meta"]
	if !ok {
		t.Fatal("id-with-meta missing")
	}
	if withMeta["name"] != "drops.iOS" || withMeta["command"] != "claude" {
		t.Errorf("metadata not joined: %+v", withMeta)
	}
	if withMeta["started"] != "2026-07-04T10:30:00Z" {
		t.Errorf("started = %v, want RFC3339 UTC", withMeta["started"])
	}
	if withMeta["cols"] != uint16(100) || withMeta["rows"] != uint16(30) {
		t.Errorf("dims wrong: %+v", withMeta)
	}

	noMeta, ok := byID["id-no-meta"]
	if !ok {
		t.Fatal("id-no-meta missing")
	}
	if _, has := noMeta["name"]; has {
		t.Errorf("entry without disk metadata must omit name, got %+v", noMeta)
	}
	if _, has := byID["stale-on-disk"]; has {
		t.Error("disk-only (dead) session must not be listed")
	}
}
