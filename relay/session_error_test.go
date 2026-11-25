package relay

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestProfilesListRoundTrip(t *testing.T) {
	agent, client := connectPair(t)
	readUntil(t, agent, "connect")

	writeMsg(t, client, "profiles_list", map[string]any{"agent_id": testAgentID, "request_id": "req-2"})
	fwd := readUntil(t, agent, "profiles_list")
	var fwdPayload map[string]any
	json.Unmarshal(fwd.Payload, &fwdPayload)
	if fwdPayload["request_id"] != "req-2" || fwdPayload["agent_id"] != nil {
		t.Fatalf("forwarded payload = %+v, want request_id only", fwdPayload)
	}

	raw, err := os.ReadFile(filepath.Join(protocolFixtureDir, "profiles_list_result.json"))
	if err != nil {
		t.Fatal(err)
	}
	var reply Message
	json.Unmarshal(raw, &reply)
	var replyPayload map[string]any
	json.Unmarshal(reply.Payload, &replyPayload)
	writeMsg(t, agent, "profiles_list_result", replyPayload)

	got := readUntil(t, client, "profiles_list_result")
	assertJSONEqual(t, got.Payload, reply.Payload)
}

func TestAgentSessionErrorReachesOwningClient(t *testing.T) {
	agent, client := connectPair(t)
	readUntil(t, agent, "connect")

	writeMsg(t, agent, "error", map[string]any{"session_id": testSessionID, "message": "профиль «rtd» не найден"})
	msg := readUntil(t, client, "error")
	var payload map[string]any
	json.Unmarshal(msg.Payload, &payload)
	if payload["session_id"] != testSessionID || payload["message"] != "профиль «rtd» не найден" {
		t.Fatalf("error payload = %+v", payload)
	}
}

func TestAgentErrorWithoutSessionIsNotForwarded(t *testing.T) {
	agent, client := connectPair(t)
	readUntil(t, agent, "connect")

	writeMsg(t, agent, "error", map[string]any{"message": "agent-wide problem"})
	if msg, ok := tryReadUntil(t, client, "error", 300*time.Millisecond); ok {
		t.Fatalf("client got an agent-wide error: %+v", msg)
	}
}
