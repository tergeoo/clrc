package relay

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// Golden messages shared with agent/ and the iOS ClrcCore tests.
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

func TestContractRegisterDecodesEveryField(t *testing.T) {
	msg := loadFixture(t, "register.json")
	dec := json.NewDecoder(bytes.NewReader(msg.Payload))
	dec.DisallowUnknownFields()
	var reg registerReq
	if err := dec.Decode(&reg); err != nil {
		t.Fatalf("strict decode register: %v", err)
	}
	if reg.AgentID == "" || reg.Name == "" || reg.Secret == "" || reg.Version == "" {
		t.Errorf("register fixture left a field empty: %+v", reg)
	}
	if err := reg.validate(); err != nil {
		t.Errorf("fixture register rejected: %v", err)
	}
}

func TestContractAgentListMatchesFixture(t *testing.T) {
	msg := loadFixture(t, "agent_list.json")
	var want struct {
		Agents []struct {
			ID      string `json:"id"`
			Name    string `json:"name"`
			Version string `json:"version"`
		} `json:"agents"`
	}
	if err := json.Unmarshal(msg.Payload, &want); err != nil {
		t.Fatalf("decode fixture: %v", err)
	}
	a := want.Agents[0]

	h := NewHub()
	h.addAgent(&AgentConn{ID: a.ID, Name: a.Name, Version: a.Version})
	got, err := json.Marshal(map[string]any{"agents": h.GetAgentList()})
	if err != nil {
		t.Fatalf("marshal agent_list: %v", err)
	}
	assertJSONEqual(t, got, msg.Payload)
}

func TestRegisterValidate(t *testing.T) {
	const id = "3f2b8c1e-9a4d-4e6f-8b7a-1c2d3e4f5a6b"
	tests := []struct {
		name    string
		reg     registerReq
		wantErr bool
	}{
		{"release version", registerReq{AgentID: id, Name: "Mac", Version: "2.1.0"}, false},
		{"local build version", registerReq{AgentID: id, Name: "Mac", Version: "2.0.0-5-gc23f7d5-dirty"}, false},
		{"pre-2.1 agent without version", registerReq{AgentID: id, Name: "Mac"}, false},
		{"bad agent id", registerReq{AgentID: "nope", Name: "Mac"}, true},
		{"name too long", registerReq{AgentID: id, Name: strings.Repeat("x", maxAgentNameLen+1)}, true},
		{"version too long", registerReq{AgentID: id, Version: strings.Repeat("1", maxAgentVersionLen+1)}, true},
		{"version with control chars", registerReq{AgentID: id, Version: "2.1.0\n\x1b[31m"}, true},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			err := tt.reg.validate()
			if (err != nil) != tt.wantErr {
				t.Errorf("validate() error = %v, wantErr %v", err, tt.wantErr)
			}
		})
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
