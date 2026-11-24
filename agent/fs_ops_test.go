package agent

import (
	"os"
	"path/filepath"
	"testing"
)

func TestFSResolveConfinesToHome(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)

	// Create a subdir + file inside home to resolve against.
	sub := filepath.Join(home, "proj")
	if err := os.MkdirAll(sub, 0755); err != nil {
		t.Fatal(err)
	}

	tests := []struct {
		name    string
		path    string
		wantErr bool
	}{
		{"home tilde", "~", false},
		{"under home via tilde", "~/proj", false},
		{"absolute under home", sub, false},
		{"absolute outside home", "/etc/passwd", true},
		{"traversal out of home", filepath.Join(home, "..", "..", "etc"), true},
		{"tilde traversal escape", "~/../../etc", true},
		{"root", "/", true},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			resolved, err := fsResolve(tt.path)
			if tt.wantErr {
				if err == nil {
					t.Errorf("fsResolve(%q) = %q, want error", tt.path, resolved)
				}
				return
			}
			if err != nil {
				t.Errorf("fsResolve(%q) unexpected error: %v", tt.path, err)
			}
		})
	}
}

func TestFSOpsRejectOutsideHome(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)

	if _, _, err := fsListDir("/etc"); err == nil {
		t.Error("fsListDir(/etc) should be rejected")
	}
	if _, err := fsRead("/etc/passwd"); err == nil {
		t.Error("fsRead(/etc/passwd) should be rejected")
	}
	if err := fsMkdir("/tmp/clrc-should-not-exist"); err == nil {
		t.Error("fsMkdir outside home should be rejected")
	}
	if err := fsDelete("/etc"); err == nil {
		t.Error("fsDelete(/etc) should be rejected")
	}
	// Sanity: an in-home op still works.
	if err := fsMkdir("~/inside"); err != nil {
		t.Errorf("fsMkdir(~/inside) should succeed, got %v", err)
	}
}

// A symlink inside home pointing outside must not let ops escape via it.
func TestFSResolveSymlinkEscapeRejected(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)

	outside := t.TempDir() // a sibling temp dir, not under home
	link := filepath.Join(home, "escape")
	if err := os.Symlink(outside, link); err != nil {
		t.Skipf("symlinks unsupported: %v", err)
	}

	if _, err := fsResolve("~/escape/secret"); err == nil {
		t.Error("fsResolve through an outward symlink should be rejected")
	}
	if _, _, err := fsListDir("~/escape"); err == nil {
		t.Error("fsListDir through an outward symlink should be rejected")
	}
}

// Deleting a symlink must remove the link itself, never the folder it points
// to — the iOS folder browser offers delete on every row.
func TestFSDeleteRemovesSymlinkNotTarget(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)

	target := filepath.Join(home, "Documents")
	if err := os.MkdirAll(filepath.Join(target, "keep"), 0o755); err != nil {
		t.Fatal(err)
	}
	link := filepath.Join(home, "proj", "docs")
	if err := os.MkdirAll(filepath.Dir(link), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(target, link); err != nil {
		t.Fatal(err)
	}

	if err := fsDelete("~/proj/docs"); err != nil {
		t.Fatalf("fsDelete: %v", err)
	}
	if _, err := os.Lstat(link); !os.IsNotExist(err) {
		t.Errorf("link still exists: %v", err)
	}
	if _, err := os.Stat(filepath.Join(target, "keep")); err != nil {
		t.Errorf("symlink target was deleted: %v", err)
	}
}

func TestFSDeleteRefusesHomeItself(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	for _, p := range []string{"~", home, "~/"} {
		if err := fsDelete(p); err == nil {
			t.Errorf("fsDelete(%q) succeeded, want refusal", p)
		}
	}
	if _, err := os.Stat(home); err != nil {
		t.Fatalf("home removed: %v", err)
	}
}
