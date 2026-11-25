package agent

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
	"time"
)

// Golden messages shared with relay/ and the iOS ClrcCore tests.
const protocolFixtureDir = "../protocol/fixtures"

func loadFixture(t *testing.T, name string) Message {
	t.Helper()
	raw, err := os.ReadFile(filepath.Join(protocolFixtureDir, name))
	if err != nil {
		t.Fatalf("read fixture %s: %v", name, err)
	}
	var msg Message
	if err := json.Unmarshal(raw, &msg); err != nil {
		t.Fatalf("decode fixture %s: %v", name, err)
	}
	return msg
}

func decodeStrict(t *testing.T, raw []byte, v any) {
	t.Helper()
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.DisallowUnknownFields()
	if err := dec.Decode(v); err != nil {
		t.Fatalf("strict decode %s: %v", raw, err)
	}
}

func assertJSONEqual(t *testing.T, got, want []byte) {
	t.Helper()
	var g, w any
	if err := json.Unmarshal(got, &g); err != nil {
		t.Fatalf("decode got: %v", err)
	}
	if err := json.Unmarshal(want, &w); err != nil {
		t.Fatalf("decode want: %v", err)
	}
	gb, _ := json.Marshal(g)
	wb, _ := json.Marshal(w)
	if !bytes.Equal(gb, wb) {
		t.Errorf("JSON mismatch\n got: %s\nwant: %s", gb, wb)
	}
}

func TestContractRegisterMatchesFixture(t *testing.T) {
	msg := loadFixture(t, "register.json")
	var want registerReq
	decodeStrict(t, msg.Payload, &want)

	cfg := Config{AgentID: want.AgentID, Name: want.Name, Secret: want.Secret, Version: want.Version}
	got, err := json.Marshal(newRegisterReq(cfg))
	if err != nil {
		t.Fatalf("marshal register: %v", err)
	}
	assertJSONEqual(t, got, msg.Payload)
}

func TestContractConnectDecodesEveryField(t *testing.T) {
	msg := loadFixture(t, "connect.json")
	var req connectReq
	decodeStrict(t, msg.Payload, &req)
	if req.SessionID == "" || req.Cols == 0 || req.Rows == 0 || req.Name == "" || req.Kind == "" ||
		req.Cwd == "" || req.Model == "" || req.Profile == "" || req.Style == "" || !req.ProfileStrict {
		t.Errorf("connect fixture left a field empty: %+v", req)
	}
}

func TestContractSessionsListMatchesFixture(t *testing.T) {
	msg := loadFixture(t, "sessions_list.json")
	var want struct {
		RequestID string            `json:"request_id"`
		Sessions  []json.RawMessage `json:"sessions"`
	}
	decodeStrict(t, msg.Payload, &want)
	var entry struct {
		ID      string `json:"id"`
		Name    string `json:"name"`
		Command string `json:"command"`
		Started string `json:"started"`
		Cols    uint16 `json:"cols"`
		Rows    uint16 `json:"rows"`
	}
	decodeStrict(t, want.Sessions[0], &entry)
	started, err := time.Parse(time.RFC3339, entry.Started)
	if err != nil {
		t.Fatalf("fixture started: %v", err)
	}

	live := map[string]*PTYSession{entry.ID: {Cols: entry.Cols, Rows: entry.Rows}}
	disk := []SessionInfo{{ID: entry.ID, Name: entry.Name, Command: entry.Command, Started: started}}
	got, err := json.Marshal(sessionsListPayload(want.RequestID, buildSessionsList(live, disk)))
	if err != nil {
		t.Fatalf("marshal sessions_list: %v", err)
	}
	assertJSONEqual(t, got, msg.Payload)
}
