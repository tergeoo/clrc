package agent

import (
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"
)

// Environment variables the agent sets or reads for spawned claude processes.
const (
	envClaudeConfigDir = "CLAUDE_CONFIG_DIR"
	envClrcSession     = "CLRC_SESSION"
)

// nestedSessionPrefixes are the variable prefixes Claude Code sets to detect a
// nested session. A child claude would refuse to start (or misbehave) if it
// inherited them, so they are stripped. CLAUDE_CONFIG_DIR shares the prefix
// and is stripped too; when a profile is configured it is set again
// explicitly by buildChildEnv.
var nestedSessionPrefixes = []string{"CLAUDE_", "CLAUDECODE"}

// identPattern is the allowed shape of a profile or output-style name. It is
// used to build filesystem paths and CLI flags, so it is deliberately narrow.
var identPattern = regexp.MustCompile(`^[a-z0-9-]+$`)

// validIdent reports whether s is a safe profile or style name.
func validIdent(s string) bool {
	return len(s) <= 64 && identPattern.MatchString(s)
}

// buildChildEnv returns base with nested-session variables removed, any
// inherited CLRC_SESSION replaced, CLRC_SESSION=1 added, and
// CLAUDE_CONFIG_DIR set when configDir is non-empty.
func buildChildEnv(base []string, configDir string) []string {
	env := make([]string, 0, len(base)+2)
	for _, kv := range base {
		if hasAnyPrefix(kv, nestedSessionPrefixes) || strings.HasPrefix(kv, envClrcSession+"=") {
			continue
		}
		env = append(env, kv)
	}
	env = append(env, envClrcSession+"=1")
	if configDir != "" {
		env = append(env, envClaudeConfigDir+"="+configDir)
	}
	return env
}

func hasAnyPrefix(s string, prefixes []string) bool {
	for _, p := range prefixes {
		if strings.HasPrefix(s, p) {
			return true
		}
	}
	return false
}

// childEnv is buildChildEnv over the agent's own environment.
func childEnv(configDir string) []string {
	return buildChildEnv(os.Environ(), configDir)
}

// profileDir maps a profile name to its Claude config directory.
func profileDir(home, profile string) string {
	return filepath.Join(home, ".claude-"+profile)
}

// ResolveClaudeConfigDir picks the CLAUDE_CONFIG_DIR for spawned sessions.
// An explicit directory wins over a profile; both empty means "do not set"
// (the CLI then uses its default ~/.claude). A non-empty result always names
// an existing directory; otherwise an error explains why it was rejected.
func ResolveClaudeConfigDir(home, profile, explicit string) (string, error) {
	switch {
	case explicit != "":
		return existingDir(expandHome(home, explicit))
	case profile != "":
		if !validIdent(profile) {
			return "", fmt.Errorf("profile %q must match %s", profile, identPattern)
		}
		return existingDir(profileDir(home, profile))
	default:
		return "", nil
	}
}

func expandHome(home, p string) string {
	if p == "~" {
		return home
	}
	if strings.HasPrefix(p, "~/") {
		return filepath.Join(home, p[2:])
	}
	return p
}

func existingDir(dir string) (string, error) {
	info, err := os.Stat(dir)
	if err != nil {
		return "", fmt.Errorf("claude config dir %s: %w", dir, err)
	}
	if !info.IsDir() {
		return "", fmt.Errorf("claude config dir %s is not a directory", dir)
	}
	return dir, nil
}

// DefaultOutputStyle is used when CLRC_OUTPUT_STYLE is not set at all.
const DefaultOutputStyle = "clrc-chat"

// OutputStyleFromEnv returns the configured output style: the default when
// the variable is absent, empty when it is set to "" (meaning "do not pass
// --settings"), and an error for a value that is not a safe identifier.
func OutputStyleFromEnv(lookup func(string) (string, bool)) (string, error) {
	v, ok := lookup("CLRC_OUTPUT_STYLE")
	if !ok {
		return DefaultOutputStyle, nil
	}
	v = strings.TrimSpace(v)
	if v == "" {
		return "", nil
	}
	if !validIdent(v) {
		return DefaultOutputStyle, fmt.Errorf("CLRC_OUTPUT_STYLE %q must match %s", v, identPattern)
	}
	return v, nil
}
