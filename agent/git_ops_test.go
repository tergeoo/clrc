package agent

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// newRepo creates ~/repo inside a temp HOME with one committed file.
func newRepo(t *testing.T, commit bool) (home, repo string) {
	t.Helper()
	home = t.TempDir()
	t.Setenv("HOME", home)
	repo = filepath.Join(home, "repo")
	if err := os.MkdirAll(repo, 0o755); err != nil {
		t.Fatal(err)
	}
	run(t, repo, "git", "init", "-q", "-b", "main")
	run(t, repo, "git", "config", "user.email", "t@example.com")
	run(t, repo, "git", "config", "user.name", "t")
	write(t, filepath.Join(repo, "a.txt"), "one\ntwo\n")
	if commit {
		run(t, repo, "git", "add", ".")
		run(t, repo, "git", "commit", "-q", "-m", "init")
	}
	return home, repo
}

func run(t *testing.T, dir string, name string, args ...string) {
	t.Helper()
	cmd := exec.Command(name, args...)
	cmd.Dir = dir
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("%s %v: %v\n%s", name, args, err, out)
	}
}

func write(t *testing.T, path, content string) {
	t.Helper()
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
}

func TestGitStatusReportsBranchAndFiles(t *testing.T) {
	_, repo := newRepo(t, true)
	write(t, filepath.Join(repo, "a.txt"), "one\nTWO\n")
	write(t, filepath.Join(repo, "new.txt"), "x\n")

	st, err := gitStatus(context.Background(), "~/repo")
	if err != nil {
		t.Fatalf("gitStatus: %v", err)
	}
	if st.Branch != "main" {
		t.Errorf("branch = %q, want main", st.Branch)
	}
	got := map[string]string{}
	for _, f := range st.Files {
		got[f.Path] = f.Status
	}
	if got["a.txt"] != "M" || got["new.txt"] != "??" {
		t.Errorf("files = %+v", st.Files)
	}
}

func TestGitStatusFreshRepo(t *testing.T) {
	newRepo(t, false)
	st, err := gitStatus(context.Background(), "~/repo")
	if err != nil {
		t.Fatalf("gitStatus: %v", err)
	}
	if st.Branch != "main" || len(st.Files) != 1 || st.Files[0].Status != "??" {
		t.Errorf("status = %+v", st)
	}
}

func TestGitStatusNotARepo(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	os.MkdirAll(filepath.Join(home, "plain"), 0o755)
	if _, err := gitStatus(context.Background(), "~/plain"); err == nil || err.Error() != errNotGitRepo.Error() {
		t.Fatalf("err = %v, want %v", err, errNotGitRepo)
	}
}

func TestGitDiffTrackedAndFiltered(t *testing.T) {
	_, repo := newRepo(t, true)
	write(t, filepath.Join(repo, "b.txt"), "b\n")
	run(t, repo, "git", "add", "b.txt")
	run(t, repo, "git", "commit", "-q", "-m", "b")
	write(t, filepath.Join(repo, "a.txt"), "one\nTWO\n")
	write(t, filepath.Join(repo, "b.txt"), "B\n")

	diff, truncated, err := gitDiff(context.Background(), "~/repo", []string{"a.txt"})
	if err != nil || truncated {
		t.Fatalf("gitDiff: %v truncated=%v", err, truncated)
	}
	if !strings.Contains(diff, "+TWO") || strings.Contains(diff, "b.txt") {
		t.Errorf("diff = %q", diff)
	}
	all, _, _ := gitDiff(context.Background(), "~/repo", nil)
	if !strings.Contains(all, "a.txt") || !strings.Contains(all, "b.txt") {
		t.Errorf("full diff misses files: %q", all)
	}
}

func TestGitDiffIncludesUntracked(t *testing.T) {
	_, repo := newRepo(t, true)
	write(t, filepath.Join(repo, "new.txt"), "hello\n")
	diff, _, err := gitDiff(context.Background(), "~/repo", nil)
	if err != nil {
		t.Fatalf("gitDiff: %v", err)
	}
	if !strings.Contains(diff, "new.txt") || !strings.Contains(diff, "+hello") {
		t.Errorf("untracked file missing: %q", diff)
	}
	only, _, _ := gitDiff(context.Background(), "~/repo", []string{filepath.Join(repo, "new.txt")})
	if !strings.Contains(only, "+hello") {
		t.Errorf("absolute path inside repo not accepted: %q", only)
	}
}

func TestGitDiffFreshRepo(t *testing.T) {
	newRepo(t, false)
	diff, _, err := gitDiff(context.Background(), "~/repo", nil)
	if err != nil || !strings.Contains(diff, "+one") {
		t.Fatalf("diff = %q err = %v", diff, err)
	}
}

func TestGitDiffRejectsUnsafeFiles(t *testing.T) {
	_, repo := newRepo(t, true)
	for _, bad := range [][]string{
		{"--output=/tmp/x"}, {"../etc/passwd"}, {"a/../../x"}, {"/etc/passwd"}, {""},
		{filepath.Join(filepath.Dir(repo), "other.txt")},
	} {
		if _, _, err := gitDiff(context.Background(), "~/repo", bad); err == nil {
			t.Errorf("gitDiff(%q) accepted", bad)
		}
	}
}

func TestGitDiffCapsOutput(t *testing.T) {
	_, repo := newRepo(t, true)
	write(t, filepath.Join(repo, "a.txt"), strings.Repeat("line of text that changed\n", 40_000))
	diff, truncated, err := gitDiff(context.Background(), "~/repo", nil)
	if err != nil {
		t.Fatalf("gitDiff: %v", err)
	}
	if !truncated || len(diff) > maxDiffBytes {
		t.Fatalf("len = %d truncated = %v", len(diff), truncated)
	}
}

func TestGitOpsRejectOutsideHome(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	if _, err := gitStatus(context.Background(), "/etc"); err == nil {
		t.Error("gitStatus outside home accepted")
	}
	if _, _, err := gitDiff(context.Background(), "/etc", nil); err == nil {
		t.Error("gitDiff outside home accepted")
	}
}
