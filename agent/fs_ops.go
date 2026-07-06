package agent

import (
	"encoding/base64"
	"errors"
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

// fsResolve expands ~, cleans the path, and confines the result to the user's
// home directory. Every filesystem op goes through this, so a client can never
// read, create, or delete anything outside the home dir. Deliberate — see CLAUDE.md.
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

	rel, err := filepath.Rel(home, clean)
	if err != nil {
		return "", errOutsideHome
	}
	if rel == ".." || strings.HasPrefix(rel, ".."+string(filepath.Separator)) {
		return "", errOutsideHome
	}
	return clean, nil
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

// fsDelete removes a file or directory recursively.
func fsDelete(path string) error {
	resolved, err := fsResolve(path)
	if err != nil {
		return err
	}
	return os.RemoveAll(resolved)
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
