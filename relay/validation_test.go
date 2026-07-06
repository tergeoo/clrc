package relay

import "testing"

func TestValidSessionID(t *testing.T) {
	tests := []struct {
		name string
		id   string
		want bool
	}{
		{"valid lowercase v4", "11111111-1111-4111-8111-111111111111", true},
		{"valid random v4", "3c0c31d0-1a2b-4c3d-9e4f-56789abcdef0", true},
		{"uppercase rejected", "11111111-1111-4111-8111-11111111111A", false},
		{"wrong version digit", "11111111-1111-1111-8111-111111111111", false},
		{"wrong variant digit", "11111111-1111-4111-c111-111111111111", false},
		{"path traversal", "../../etc/passwd", false},
		{"empty", "", false},
		{"not a uuid", "hello", false},
		{"uuid with slash", "11111111-1111-4111-8111-111111111111/x", false},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := validSessionID(tt.id); got != tt.want {
				t.Errorf("validSessionID(%q) = %v, want %v", tt.id, got, tt.want)
			}
		})
	}
}

func TestValidAgentID(t *testing.T) {
	// agent IDs are google/uuid v4 lowercase, same shape as session IDs
	if !validAgentID("3c0c31d0-1a2b-4c3d-9e4f-56789abcdef0") {
		t.Error("valid agent UUID rejected")
	}
	if validAgentID("not-a-uuid") {
		t.Error("non-uuid agent id accepted")
	}
	if validAgentID("") {
		t.Error("empty agent id accepted")
	}
}
