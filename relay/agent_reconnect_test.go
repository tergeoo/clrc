package relay

import "testing"

// An agent that reconnects quickly registers its new connection before the
// relay has processed the old connection's disconnect. Removing the old
// connection must not evict the new one or its sessions.
func TestRemoveAgentKeepsNewerConnectionWithSameID(t *testing.T) {
	const id = "a86a799b-f6b8-43a7-a523-188513cad2dd"
	tests := []struct {
		name          string
		remove        string // "old" or "new"
		wantAgent     string // "new" or "" (gone)
		wantSessionOK bool
	}{
		{name: "stale disconnect of old conn is ignored", remove: "old", wantAgent: "new", wantSessionOK: true},
		{name: "disconnect of current conn removes it", remove: "new", wantAgent: "", wantSessionOK: false},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			h := NewHub()
			oldConn := &AgentConn{ID: id, Name: "old"}
			newConn := &AgentConn{ID: id, Name: "new"}
			h.addAgent(oldConn)
			h.CreateSession("11111111-1111-4111-8111-111111111111", oldConn, nil)
			h.addAgent(newConn)
			h.CreateSession("22222222-2222-4222-8222-222222222222", newConn, nil)

			gone := map[string]*AgentConn{"old": oldConn, "new": newConn}[tt.remove]
			h.removeAgent(gone)

			got, ok := h.GetAgent(id)
			switch {
			case tt.wantAgent == "" && ok:
				t.Fatalf("agent still registered as %q, want removed", got.Name)
			case tt.wantAgent != "" && (!ok || got.Name != tt.wantAgent):
				t.Fatalf("agent = %v (ok=%v), want %q", got, ok, tt.wantAgent)
			}
			h.mu.RLock()
			_, sessionOK := h.sessions["22222222-2222-4222-8222-222222222222"]
			_, oldSessionOK := h.sessions["11111111-1111-4111-8111-111111111111"]
			h.mu.RUnlock()
			if sessionOK != tt.wantSessionOK {
				t.Fatalf("new conn session present = %v, want %v", sessionOK, tt.wantSessionOK)
			}
			if tt.remove == "old" && oldSessionOK {
				t.Fatal("old conn session should be removed with the old conn")
			}
		})
	}
}
