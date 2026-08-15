package agent

import (
	"encoding/json"
	"testing"
)

func TestConnectReqDefaultsToPTYKind(t *testing.T) {
	var req connectReq
	if err := json.Unmarshal([]byte(`{"session_id":"s","cols":80,"rows":24}`), &req); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if req.Kind != "" {
		t.Fatalf("Kind = %q, want empty so it can default to pty", req.Kind)
	}
	if !req.isPTY() {
		t.Fatal("a connect with no kind must be treated as pty for backward compatibility")
	}
}

func TestConnectReqChatKind(t *testing.T) {
	var req connectReq
	body := `{"session_id":"s","kind":"chat","cwd":"~/proj","model":"m"}`
	if err := json.Unmarshal([]byte(body), &req); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if req.isPTY() {
		t.Fatal("kind=chat must not be treated as pty")
	}
	if req.Cwd != "~/proj" || req.Model != "m" {
		t.Fatalf("fields lost: %+v", req)
	}
}
