package agent

import (
	"encoding/base64"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"
)

// FSEntry is a single directory entry returned to the client.
type FSEntry struct {
	Name    string    `json:"name"`
	IsDir   bool      `json:"is_dir"`
	Size    int64     `json:"size"`
	ModTime time.Time `json:"mod_time"`
}

const maxReadBytes = 100 * 1024 // 100 KB cap for file preview

// errOutsideHome is returned when a resolved path escapes the user's home dir.
var errOutsideHome = errors.New("path is outside the home directory")

// fsResolve expands ~, cleans the path, resolves symlinks on the existing
// portion, and confines the result to the user's home directory. Every
// filesystem op goes through this, so a client cannot read, create, or delete
// outside the home dir — including via a symlink inside it. Deliberate — see CLAUDE.md.
func fsResolve(path string) (string, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return "", err
	}

	switch {
	case path == "~":
		path = home
	case strings.HasPrefix(path, "~/"):
		path = filepath.Join(home, path[2:])
	}

	abs, err := filepath.Abs(path)
	if err != nil {
		return "", err
	}
	clean := filepath.Clean(abs)

	// Resolve symlinks on the longest existing ancestor so a symlink inside the
	// home dir (e.g. ~/link -> /etc) cannot redirect an op outside it. The leaf
	// may not exist yet (mkdir/create), so we resolve what exists and re-append.
	resolved := resolveExisting(clean)

	realHome := home
	if rh, err := filepath.EvalSymlinks(home); err == nil {
		realHome = rh
	}

	if !withinDir(realHome, resolved) {
		return "", errOutsideHome
	}
	return resolved, nil
}

// resolveExisting resolves symlinks on the longest existing prefix of p and
// re-joins the non-existent remainder.
func resolveExisting(p string) string {
	remainder := ""
	cur := p
	for {
		if real, err := filepath.EvalSymlinks(cur); err == nil {
			return filepath.Join(real, remainder)
		}
		parent := filepath.Dir(cur)
		if parent == cur {
			return p // reached the root without an existing ancestor
		}
		remainder = filepath.Join(filepath.Base(cur), remainder)
		cur = parent
	}
}

// withinDir reports whether target is dir itself or nested under it.
func withinDir(dir, target string) bool {
	rel, err := filepath.Rel(dir, target)
	if err != nil {
		return false
	}
	return rel != ".." && !strings.HasPrefix(rel, ".."+string(filepath.Separator))
}

// fsListDir lists a directory; returns resolved path + entries sorted dirs-first.
func fsListDir(path string) (resolved string, entries []FSEntry, err error) {
	resolved, err = fsResolve(path)
	if err != nil {
		return "", nil, err
	}
	dirEntries, err := os.ReadDir(resolved)
	if err != nil {
		return resolved, nil, err
	}
	entries = make([]FSEntry, 0, len(dirEntries))
	for _, e := range dirEntries {
		info, ierr := e.Info()
		if ierr != nil {
			continue
		}
		entries = append(entries, FSEntry{
			Name:    e.Name(),
			IsDir:   e.IsDir(),
			Size:    info.Size(),
			ModTime: info.ModTime().UTC().Truncate(time.Second),
		})
	}
	sort.Slice(entries, func(i, j int) bool {
		if entries[i].IsDir != entries[j].IsDir {
			return entries[i].IsDir
		}
		return entries[i].Name < entries[j].Name
	})
	return resolved, entries, nil
}

// fsMkdir creates a directory (with parents).
func fsMkdir(path string) error {
	resolved, err := fsResolve(path)
	if err != nil {
		return err
	}
	return os.MkdirAll(resolved, 0755)
}

var errDeleteHome = errors.New("refusing to delete the home directory")

// fsDelete removes a file or directory recursively. Only the parent folder is
// resolved through symlinks: the entry itself is removed as found, so deleting
// a symlink removes the link and never the folder it points to. The home
// directory itself can never be deleted.
func fsDelete(path string) error {
	resolved, err := fsResolve(path)
	if err != nil {
		return err
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return fmt.Errorf("find home directory: %w", err)
	}
	realHome := home
	if rh, err := filepath.EvalSymlinks(home); err == nil {
		realHome = rh
	}
	if resolved == realHome {
		return errDeleteHome
	}

	// Re-resolve only the parent, then name the entry itself.
	expanded := path
	switch {
	case path == "~":
		expanded = home
	case strings.HasPrefix(path, "~/"):
		expanded = filepath.Join(home, path[2:])
	}
	abs, err := filepath.Abs(expanded)
	if err != nil {
		return fmt.Errorf("resolve %q: %w", path, err)
	}
	parent, err := fsResolve(filepath.Dir(filepath.Clean(abs)))
	if err != nil {
		return err
	}
	entry := filepath.Join(parent, filepath.Base(filepath.Clean(abs)))
	if entry == realHome || !withinDir(realHome, entry) {
		return errDeleteHome
	}

	info, err := os.Lstat(entry)
	if err != nil {
		return err
	}
	if info.Mode()&os.ModeSymlink != 0 {
		return os.Remove(entry)
	}
	return os.RemoveAll(entry)
}

// fsRead reads up to maxReadBytes, returns base64-encoded content.
func fsRead(path string) (string, error) {
	resolved, err := fsResolve(path)
	if err != nil {
		return "", err
	}
	f, err := os.Open(resolved)
	if err != nil {
		return "", err
	}
	defer f.Close()

	buf := make([]byte, maxReadBytes)
	n, err := io.ReadFull(f, buf)
	if err != nil && n == 0 {
		return "", err
	}
	return base64.StdEncoding.EncodeToString(buf[:n]), nil
}
