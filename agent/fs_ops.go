package main

import (
	"encoding/base64"
	"io"
	"os"
	"path/filepath"
	"sort"
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

// fsResolve expands ~ and cleans the path.
func fsResolve(path string) string {
	if path == "~" {
		if home, err := os.UserHomeDir(); err == nil {
			return home
		}
	}
	if len(path) >= 2 && path[:2] == "~/" {
		if home, err := os.UserHomeDir(); err == nil {
			return filepath.Join(home, path[2:])
		}
	}
	return filepath.Clean(path)
}

// fsListDir lists a directory; returns resolved path + entries sorted dirs-first.
func fsListDir(path string) (resolved string, entries []FSEntry, err error) {
	resolved = fsResolve(path)
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
	return os.MkdirAll(fsResolve(path), 0755)
}

// fsDelete removes a file or directory recursively.
func fsDelete(path string) error {
	return os.RemoveAll(fsResolve(path))
}

// fsRead reads up to maxReadBytes, returns base64-encoded content.
func fsRead(path string) (string, error) {
	f, err := os.Open(fsResolve(path))
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
