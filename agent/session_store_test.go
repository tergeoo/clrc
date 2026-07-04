package agent

import (
	"os"
	"path/filepath"
	"testing"
)

// pointSessDirAt redirects os.UserConfigDir into a temp dir for the test.
func pointSessDirAt(t *testing.T) string {
	t.Helper()
	tmp := t.TempDir()
	t.Setenv("HOME", tmp)                                      // macOS: $HOME/Library/Application Support
	t.Setenv("XDG_CONFIG_HOME", filepath.Join(tmp, ".config")) // Linux/CI
	return tmp
}

func TestWriteListRemoveSess(t *testing.T) {
	pointSessDirAt(t)

	WriteSess("11111111-1111-4111-8111-111111111111", 4242, "claude", "drops.iOS")

	got := ListSess()
	if len(got) != 1 {
		t.Fatalf("ListSess() returned %d sessions, want 1", len(got))
	}
	s := got[0]
	if s.ID != "11111111-1111-4111-8111-111111111111" ||
		s.PID != 4242 || s.Command != "claude" || s.Name != "drops.iOS" {
		t.Errorf("unexpected session: %+v", s)
	}
	if s.Started.IsZero() {
		t.Error("Started should be set")
	}

	RemoveSess(s.ID)
	if got := ListSess(); len(got) != 0 {
		t.Errorf("after RemoveSess, ListSess() = %d sessions, want 0", len(got))
	}
}

func TestWriteSessEmptyNameOmitted(t *testing.T) {
	pointSessDirAt(t)

	WriteSess("22222222-2222-4222-8222-222222222222", 1, "bash", "")

	got := ListSess()
	if len(got) != 1 {
		t.Fatalf("ListSess() returned %d sessions, want 1", len(got))
	}
	if got[0].Name != "" {
		t.Errorf("Name = %q, want empty", got[0].Name)
	}
}

func TestRenameSess(t *testing.T) {
	pointSessDirAt(t)

	id := "33333333-3333-4333-8333-333333333333"
	WriteSess(id, 7, "claude", "old-name")
	RenameSess(id, "new-name")

	got := ListSess()
	if len(got) != 1 {
		t.Fatalf("ListSess() returned %d sessions, want 1", len(got))
	}
	if got[0].Name != "new-name" {
		t.Errorf("Name = %q, want %q", got[0].Name, "new-name")
	}
	// Other fields survive the rename
	if got[0].PID != 7 || got[0].Command != "claude" {
		t.Errorf("rename clobbered fields: %+v", got[0])
	}
}

func TestRenameSessMissingFileIsNoop(t *testing.T) {
	pointSessDirAt(t)
	RenameSess("44444444-4444-4444-8444-444444444444", "x") // must not panic or create a file
	if got := ListSess(); len(got) != 0 {
		t.Errorf("RenameSess on missing id created %d entries, want 0", len(got))
	}
}

func TestListSessSkipsCorruptFiles(t *testing.T) {
	pointSessDirAt(t)
	WriteSess("55555555-5555-4555-8555-555555555555", 1, "claude", "ok")
	if err := os.WriteFile(filepath.Join(sessDir(), "garbage.json"), []byte("{not json"), 0600); err != nil {
		t.Fatal(err)
	}
	got := ListSess()
	if len(got) != 1 {
		t.Errorf("ListSess() = %d sessions, want 1 (corrupt file skipped)", len(got))
	}
}
