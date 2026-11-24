package agent

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

const (
	gitTimeout   = 10 * time.Second
	maxDiffBytes = 512 << 10
	// maxStatusFiles bounds a status reply: a non-ignored node_modules can
	// list tens of thousands of files and overflow the relay's 4 MB frame.
	maxStatusFiles = 1000
	// maxUntrackedDiffs bounds the per-file `git diff --no-index` runs.
	maxUntrackedDiffs = 200
	// gitDiffDeadline bounds a whole git_diff request.
	gitDiffDeadline = 15 * time.Second
	// emptyTree is git's well-known empty tree: the base for a repo
	// without commits.
	emptyTree = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"
)

var (
	errNotGitRepo = errors.New("not a git repository")
	errUnsafeFile = errors.New("file path is not inside the project")
)

// GitFile is one changed path in `git status`.
type GitFile struct {
	Path   string `json:"path"`
	Status string `json:"status"`
}

// GitStatus is a project's branch and changed files.
type GitStatus struct {
	Branch    string    `json:"branch"`
	Upstream  string    `json:"upstream"`
	Ahead     int       `json:"ahead"`
	Behind    int       `json:"behind"`
	Files     []GitFile `json:"files"`
	Total     int       `json:"total"`
	Truncated bool      `json:"truncated"`
}

// gitStatus reports the branch and changed files of the repo at path
// (confined to home like every fs op).
// Paths are relative to the repository root, whatever subfolder path is.
func gitStatus(ctx context.Context, path string) (GitStatus, error) {
	dir, err := fsResolve(path)
	if err != nil {
		return GitStatus{}, err
	}
	top, err := repoRoot(ctx, dir)
	if err != nil {
		return GitStatus{}, err
	}
	out, err := runGit(ctx, top, nil, "status", "--porcelain=v1", "-b", "-z", "--untracked-files=all")
	if err != nil {
		return GitStatus{}, err
	}
	st := parseGitStatus(out)
	st.Total = len(st.Files)
	if len(st.Files) > maxStatusFiles {
		st.Files = st.Files[:maxStatusFiles]
		st.Truncated = true
	}
	return st, nil
}

// repoRoot is the top level of the repository containing dir, kept inside
// the home confinement.
func repoRoot(ctx context.Context, dir string) (string, error) {
	out, err := runGit(ctx, dir, nil, "rev-parse", "--show-toplevel")
	if err != nil {
		return "", err
	}
	return fsResolve(strings.TrimSpace(string(out)))
}

func parseGitStatus(out []byte) GitStatus {
	st := GitStatus{Files: []GitFile{}}
	entries := strings.Split(string(out), "\x00")
	for i := 0; i < len(entries); i++ {
		entry := entries[i]
		if strings.HasPrefix(entry, "## ") {
			parseBranchHeader(entry[3:], &st)
			continue
		}
		if len(entry) < 4 {
			continue
		}
		x, y := entry[0], entry[1]
		status := string(x) + string(y)
		if status != "??" {
			if y != ' ' {
				status = string(y)
			} else {
				status = string(x)
			}
		}
		st.Files = append(st.Files, GitFile{Path: entry[3:], Status: status})
		if x == 'R' || x == 'C' {
			i++ // the next entry is the original path
		}
	}
	return st
}

// parseBranchHeader reads "main...origin/main [ahead 1, behind 2]",
// "No commits yet on main" or "HEAD (no branch)".
func parseBranchHeader(h string, st *GitStatus) {
	if rest, ok := strings.CutPrefix(h, "No commits yet on "); ok {
		st.Branch = rest
		return
	}
	if rest, ok := strings.CutPrefix(h, "Initial commit on "); ok {
		st.Branch = rest
		return
	}
	head, track, _ := strings.Cut(h, " [")
	st.Branch, st.Upstream, _ = strings.Cut(head, "...")
	if strings.HasPrefix(st.Branch, "HEAD (") {
		st.Branch = "HEAD"
	}
	for _, part := range strings.Split(strings.TrimSuffix(track, "]"), ", ") {
		if n, ok := strings.CutPrefix(part, "ahead "); ok {
			st.Ahead, _ = strconv.Atoi(n)
		}
		if n, ok := strings.CutPrefix(part, "behind "); ok {
			st.Behind, _ = strconv.Atoi(n)
		}
	}
}

// gitDiff returns the working-tree diff of the repo at path against HEAD
// (or the empty tree in a repo without commits), untracked files as
// additions, limited to files when given, capped at maxDiffBytes.
func gitDiff(ctx context.Context, path string, files []string) (string, bool, error) {
	ctx, cancel := context.WithTimeout(ctx, gitDiffDeadline)
	defer cancel()
	dir, err := fsResolve(path)
	if err != nil {
		return "", false, err
	}
	top, err := repoRoot(ctx, dir)
	if err != nil {
		return "", false, err
	}
	specs, err := safeRepoFiles(top, dir, files)
	if err != nil {
		return "", false, err
	}

	out := &cappedBuffer{limit: maxDiffBytes}
	base := "HEAD"
	if _, err := runGit(ctx, top, nil, "rev-parse", "--verify", "-q", "HEAD"); err != nil {
		// Exit 1 is "no such ref": a repo without commits. Anything else
		// (a timeout, a broken repo) is an error, not an empty base.
		if !isExitCode(err, 1) {
			return "", false, err
		}
		base = emptyTree
	}
	args := append([]string{"diff", base, "--no-color", "--no-ext-diff", "--no-textconv", "--"}, specs...)
	if _, err := runGit(ctx, top, out, args...); err != nil {
		return "", false, err
	}

	untracked, err := runGit(ctx, top, nil, append([]string{"ls-files", "--others", "--exclude-standard", "-z", "--"}, specs...)...)
	if err != nil {
		return "", false, err
	}
	diffed := 0
	for _, file := range strings.Split(string(untracked), "\x00") {
		if file == "" || out.full() {
			continue
		}
		if diffed == maxUntrackedDiffs {
			out.truncated = true
			break
		}
		diffed++
		// --no-index exits 1 when the files differ, which they always do here.
		if _, err := runGit(ctx, top, out, "diff", "--no-index", "--no-color", "--no-ext-diff", "--no-textconv",
			"--", os.DevNull, file); err != nil && !isExitCode(err, 1) {
			return "", false, err
		}
	}
	return out.String(), out.truncated, nil
}

// safeRepoFiles turns client-supplied paths into literal pathspecs
// relative to the repository root top, refusing anything that could escape
// it or be read as a git option. A relative path may be repo-relative (git
// status) or relative to the session folder dir (report fallback); both
// readings are passed, and the one that does not exist matches nothing.
func safeRepoFiles(top, dir string, files []string) ([]string, error) {
	prefix, err := filepath.Rel(top, dir)
	if err != nil || prefix == ".." || strings.HasPrefix(prefix, "../") {
		return nil, errUnsafeFile
	}
	specs := make([]string, 0, 2*len(files))
	for _, f := range files {
		if f == "" || strings.HasPrefix(f, "-") {
			return nil, errUnsafeFile
		}
		if strings.HasPrefix(f, "~/") {
			home, err := os.UserHomeDir()
			if err != nil {
				return nil, fmt.Errorf("find home directory: %w", err)
			}
			f = filepath.Join(home, f[2:])
		}
		if filepath.IsAbs(f) {
			r, err := filepath.Rel(top, resolveExisting(filepath.Clean(f)))
			if err != nil || !safeRelative(r) {
				return nil, errUnsafeFile
			}
			specs = append(specs, r)
			continue
		}
		clean := filepath.Clean(f)
		if !safeRelative(clean) {
			return nil, errUnsafeFile
		}
		specs = append(specs, clean)
		if prefix != "." {
			if under := filepath.Join(prefix, clean); under != clean {
				specs = append(specs, under)
			}
		}
	}
	return specs, nil
}

func safeRelative(p string) bool {
	return p != ".." && !strings.HasPrefix(p, "../") && !filepath.IsAbs(p) && !strings.HasPrefix(p, "-")
}

// runGit runs git in dir with a timeout and no prompts, pagers or external
// diff drivers. Output goes to out when given (bounded), else is returned.
func runGit(ctx context.Context, dir string, out *cappedBuffer, args ...string) ([]byte, error) {
	ctx, cancel := context.WithTimeout(ctx, gitTimeout)
	defer cancel()
	full := append([]string{"--no-pager", "-c", "core.quotepath=off", "-c", "core.fsmonitor=false", "-C", dir}, args...)
	cmd := exec.CommandContext(ctx, "git", full...)
	// Literal pathspecs: «app/[id]/page.tsx» must not match «app/i/page.tsx».
	cmd.Env = append(os.Environ(), "GIT_TERMINAL_PROMPT=0", "GIT_PAGER=cat", "GIT_OPTIONAL_LOCKS=0", "GIT_LITERAL_PATHSPECS=1")
	var stdout bytes.Buffer
	var stderr bytes.Buffer
	if out != nil {
		cmd.Stdout = out
	} else {
		cmd.Stdout = &stdout
	}
	cmd.Stderr = &stderr
	if err := cmd.Run(); err != nil {
		if strings.Contains(stderr.String(), "not a git repository") {
			return nil, errNotGitRepo
		}
		if ctx.Err() != nil {
			return nil, fmt.Errorf("git %s: timed out", args[0])
		}
		return stdout.Bytes(), &gitError{err: err, stderr: strings.TrimSpace(stderr.String())}
	}
	return stdout.Bytes(), nil
}

type gitError struct {
	err    error
	stderr string
}

func (e *gitError) Error() string {
	if e.stderr != "" {
		return "git: " + e.stderr
	}
	return "git: " + e.err.Error()
}

func (e *gitError) Unwrap() error { return e.err }

func isExitCode(err error, code int) bool {
	var exitErr *exec.ExitError
	return errors.As(err, &exitErr) && exitErr.ExitCode() == code
}

// cappedBuffer keeps the first limit bytes, cut at a line end, and drops
// the rest while still draining the writer so git never blocks.
type cappedBuffer struct {
	buf       bytes.Buffer
	limit     int
	truncated bool
}

func (c *cappedBuffer) Write(p []byte) (int, error) {
	if c.truncated {
		return len(p), nil
	}
	room := c.limit - c.buf.Len()
	if len(p) <= room {
		return c.buf.Write(p)
	}
	chunk := p[:room]
	if i := bytes.LastIndexByte(chunk, '\n'); i >= 0 {
		chunk = chunk[:i+1]
	}
	c.buf.Write(chunk)
	c.truncated = true
	return len(p), nil
}

func (c *cappedBuffer) full() bool     { return c.truncated }
func (c *cappedBuffer) String() string { return c.buf.String() }
