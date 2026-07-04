package agent

import (
	"encoding/json"
	"os"
	"path/filepath"
	"time"
)

// SessionInfo describes a live PTY session.
type SessionInfo struct {
	ID      string    `json:"id"`
	PID     int       `json:"pid"`
	Command string    `json:"command"`
	Started time.Time `json:"started"`
}

func sessDir() string {
	dir, _ := os.UserConfigDir()
	return filepath.Join(dir, "clrc", "sessions")
}

// WriteSess persists a session entry to disk.
func WriteSess(id string, pid int, command string) {
	_ = os.MkdirAll(sessDir(), 0700)
	info := SessionInfo{ID: id, PID: pid, Command: command, Started: time.Now()}
	data, _ := json.Marshal(info)
	_ = os.WriteFile(filepath.Join(sessDir(), id+".json"), data, 0600)
}

// RemoveSess deletes a session entry from disk.
func RemoveSess(id string) {
	_ = os.Remove(filepath.Join(sessDir(), id+".json"))
}

// ListSess returns all persisted session entries.
func ListSess() []SessionInfo {
	entries, err := os.ReadDir(sessDir())
	if err != nil {
		return nil
	}
	var sessions []SessionInfo
	for _, e := range entries {
		if e.IsDir() || filepath.Ext(e.Name()) != ".json" {
			continue
		}
		data, err := os.ReadFile(filepath.Join(sessDir(), e.Name()))
		if err != nil {
			continue
		}
		var info SessionInfo
		if err := json.Unmarshal(data, &info); err != nil {
			continue
		}
		sessions = append(sessions, info)
	}
	return sessions
}

// CleanStaleSessions removes all session files left over from a previous daemon run.
func CleanStaleSessions() {
	entries, _ := os.ReadDir(sessDir())
	for _, e := range entries {
		if !e.IsDir() && filepath.Ext(e.Name()) == ".json" {
			_ = os.Remove(filepath.Join(sessDir(), e.Name()))
		}
	}
}
