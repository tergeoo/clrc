package agent

import (
	"context"
	"encoding/json"
	"log"
	"os"
	"sort"
	"strings"
)

// profileEntry is one profile in a profiles_list_result.
type profileEntry struct {
	Name        string   `json:"name"`
	Description string   `json:"description"`
	LaunchArgs  []string `json:"launch_args"`
	Harness     bool     `json:"harness"`
}

// profilesListPayload is the payload of "profiles_list_result": the synced
// harness profiles plus plain ~/.claude-<name> dirs, sorted by name.
func profilesListPayload(requestID, defaultProfile string, harness []HarnessProfile, plainDirs []string) map[string]any {
	entries := make([]profileEntry, 0, len(harness)+len(plainDirs))
	for _, p := range harness {
		args := p.LaunchArgs
		if args == nil {
			args = []string{}
		}
		entries = append(entries, profileEntry{Name: p.Name, Description: p.Description, LaunchArgs: args, Harness: true})
	}
	for _, name := range plainDirs {
		entries = append(entries, profileEntry{Name: name, LaunchArgs: []string{}})
	}
	sort.Slice(entries, func(i, j int) bool { return entries[i].Name < entries[j].Name })
	return map[string]any{"request_id": requestID, "default_profile": defaultProfile, "profiles": entries}
}

// plainProfileDirs lists ~/.claude-<name> dirs with a valid name that are not
// in skip (the harness profiles already listed).
func plainProfileDirs(home string, skip map[string]bool) []string {
	entries, err := os.ReadDir(home)
	if err != nil {
		log.Printf("list profile dirs: %v", err)
		return nil
	}
	var names []string
	for _, e := range entries {
		name, ok := strings.CutPrefix(e.Name(), ".claude-")
		if !ok || !e.IsDir() || !validIdent(name) || skip[name] {
			continue
		}
		names = append(names, name)
	}
	return names
}

// handleProfilesList answers "profiles_list" with this Mac's profiles.
func (c *WSClient) handleProfilesList(ctx context.Context, payload json.RawMessage) {
	var req struct {
		RequestID string `json:"request_id"`
	}
	if err := json.Unmarshal(payload, &req); err != nil || req.RequestID == "" {
		log.Printf("Invalid profiles_list payload")
		return
	}
	home, err := os.UserHomeDir()
	if err != nil {
		log.Printf("profiles_list: resolve home: %v", err)
		return
	}
	harness := LoadHarnessProfiles(home, harnessRoot(home))
	listed := make(map[string]bool, len(harness))
	for _, p := range harness {
		listed[p.Name] = true
	}
	c.sendTextMsg(ctx, "profiles_list_result",
		profilesListPayload(req.RequestID, c.cfg.Profile, harness, plainProfileDirs(home, listed)))
}
