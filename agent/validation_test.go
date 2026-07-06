package agent

import (
	"os"
	"path/filepath"
	"testing"
)

func TestValidSessionID(t *testing.T) {
	valid := []string{
		"11111111-1111-4111-8111-111111111111",
		"3c0c31d0-1a2b-4c3d-9e4f-56789abcdef0",
	}
	for _, id := range valid {
		if !validSessionID(id) {
			t.Errorf("validSessionID(%q) = false, want true", id)
		}
	}
	invalid := []string{
		"",
		"HELLO",
		"11111111-1111-1111-8111-111111111111", // wrong version
		"../../etc/passwd",
		"11111111-1111-4111-8111-111111111111/x",
		"11111111-1111-4111-8111-11111111111A", // uppercase
	}
	for _, id := range invalid {
		if validSessionID(id) {
			t.Errorf("validSessionID(%q) = true, want false", id)
		}
	}
}

// A crafted session_id must never let WriteSess escape the sessions dir.
func TestWriteSessRejectsInvalidID(t *testing.T) {
	pointSessDirAt(t)

	evil := "../../../../tmp/clrc-escape"
	WriteSess(evil, 1, "bash", "x")

	// No file should have been written for the crafted id anywhere.
	if _, err := os.Stat(filepath.Join(sessDir(), evil+".json")); err == nil {
		t.Error("WriteSess wrote a file for a traversal id")
	}
	if _, err := os.Stat("/tmp/clrc-escape.json"); err == nil {
		os.Remove("/tmp/clrc-escape.json")
		t.Error("WriteSess escaped the sessions directory")
	}
	if got := ListSess(); len(got) != 0 {
		t.Errorf("ListSess = %d, want 0 (invalid id not stored)", len(got))
	}
}
