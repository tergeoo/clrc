package agent

import (
	"path/filepath"
	"slices"
	"strings"
)

// systemToolDirs are appended to PATH when missing so a minimal launchd or
// systemd PATH still finds Homebrew and base tools.
var systemToolDirs = []string{"/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"}

// WithToolDirs returns path extended with the directories where claude, its
// hooks and MCP servers are usually installed. The native Claude Code
// installer puts claude into ~/.local/bin and `go install` uses ~/go/bin;
// neither is on the PATH launchd gives the agent, so they are prepended.
// Directories already in path keep their position.
func WithToolDirs(path, home string) string {
	var dirs []string
	if path != "" {
		dirs = strings.Split(path, ":")
	}
	var front []string
	for _, d := range []string{filepath.Join(home, ".local", "bin"), filepath.Join(home, "go", "bin")} {
		if !slices.Contains(dirs, d) {
			front = append(front, d)
		}
	}
	dirs = append(front, dirs...)
	for _, d := range systemToolDirs {
		if !slices.Contains(dirs, d) {
			dirs = append(dirs, d)
		}
	}
	return strings.Join(dirs, ":")
}
