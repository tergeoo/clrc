package agent

import (
	"context"
	"fmt"
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

// Review fixes ------------------------------------------------------------

func TestGitStatusCapsFileList(t *testing.T) {
	_, repo := newRepo(t, true)
	for i := 0; i < maxStatusFiles+200; i++ {
		write(t, filepath.Join(repo, fmt.Sprintf("u%04d.txt", i)), "x\n")
	}
	st, err := gitStatus(context.Background(), "~/repo")
	if err != nil {
		t.Fatal(err)
	}
	if len(st.Files) != maxStatusFiles || !st.Truncated || st.Total != maxStatusFiles+200 {
		t.Fatalf("files=%d truncated=%v total=%d", len(st.Files), st.Truncated, st.Total)
	}
}

func TestGitDiffCapsUntrackedFiles(t *testing.T) {
	_, repo := newRepo(t, true)
	for i := 0; i < maxUntrackedDiffs+50; i++ {
		write(t, filepath.Join(repo, fmt.Sprintf("u%04d.txt", i)), "x\n")
	}
	diff, truncated, err := gitDiff(context.Background(), "~/repo", nil)
	if err != nil {
		t.Fatal(err)
	}
	if !truncated || strings.Count(diff, "diff --git") != maxUntrackedDiffs {
		t.Fatalf("truncated=%v files=%d", truncated, strings.Count(diff, "diff --git"))
	}
}

func TestGitOpsUseRepoRoot(t *testing.T) {
	_, repo := newRepo(t, true)
	sub := filepath.Join(repo, "backend")
	os.MkdirAll(sub, 0o755)
	write(t, filepath.Join(sub, "x.go"), "package x\n")
	run(t, repo, "git", "add", ".")
	run(t, repo, "git", "commit", "-q", "-m", "x")
	write(t, filepath.Join(sub, "x.go"), "package y\n")
	write(t, filepath.Join(sub, "new.go"), "package n\n")

	st, err := gitStatus(context.Background(), "~/repo/backend")
	if err != nil {
		t.Fatal(err)
	}
	paths := map[string]bool{}
	for _, f := range st.Files {
		paths[f.Path] = true
	}
	if !paths["backend/x.go"] || !paths["backend/new.go"] {
		t.Fatalf("status paths not repo-relative: %+v", st.Files)
	}
	for _, files := range [][]string{{"backend/x.go"}, {"x.go"}} {
		diff, _, err := gitDiff(context.Background(), "~/repo/backend", files)
		if err != nil || !strings.Contains(diff, "+package y") {
			t.Errorf("files %v: diff=%q err=%v", files, diff, err)
		}
	}
	all, _, _ := gitDiff(context.Background(), "~/repo/backend", nil)
	if !strings.Contains(all, "b/backend/new.go") || !strings.Contains(all, "b/backend/x.go") {
		t.Errorf("full diff paths not repo-relative: %q", all)
	}
}

func TestGitDiffLiteralPathspecs(t *testing.T) {
	_, repo := newRepo(t, true)
	os.MkdirAll(filepath.Join(repo, "app", "[id]"), 0o755)
	os.MkdirAll(filepath.Join(repo, "app", "i"), 0o755)
	write(t, filepath.Join(repo, "app", "[id]", "page.tsx"), "a\n")
	write(t, filepath.Join(repo, "app", "i", "page.tsx"), "b\n")
	run(t, repo, "git", "add", ".")
	run(t, repo, "git", "commit", "-q", "-m", "pages")
	write(t, filepath.Join(repo, "app", "[id]", "page.tsx"), "A\n")
	write(t, filepath.Join(repo, "app", "i", "page.tsx"), "B\n")

	diff, _, err := gitDiff(context.Background(), "~/repo", []string{"app/[id]/page.tsx"})
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(diff, "+A") || strings.Contains(diff, "app/i/page.tsx") {
		t.Errorf("pathspec treated as a glob: %q", diff)
	}
}
