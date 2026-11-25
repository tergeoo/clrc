package agent

import (
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"slices"
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

// LaunchProfile is how a session's claude is set up: its config dir and, for
// a ~/harness profile, the env that `c <name>` would give it. The zero value
// means no profile (the CLI default ~/.claude).
type LaunchProfile struct {
	// Name is the profile name; empty for the CLI default or an explicit
	// CLRC_CLAUDE_CONFIG_DIR.
	Name string
	// ConfigDir becomes CLAUDE_CONFIG_DIR; empty means "do not set".
	ConfigDir string
	// Harness marks a synced ~/harness profile: the child also gets
	// HARNESS_PROFILE=Name.
	Harness bool
	// Env holds KEY=value entries from the profile's harness env file.
	Env []string
}

// reservedEnvKeys are always set by the agent; an env file cannot change them.
var reservedEnvKeys = []string{envClaudeConfigDir, envClrcSession, envHarnessProfile}

// buildChildEnv returns base with nested-session variables, CLRC_SESSION and
// HARNESS_PROFILE removed, then lp.Env (overriding base entries with the
// same key, minus reserved keys), then CLRC_SESSION=1, HARNESS_PROFILE for a
// harness profile, and CLAUDE_CONFIG_DIR when lp has a config dir.
func buildChildEnv(base []string, lp LaunchProfile) []string {
	overridden := make(map[string]bool, len(lp.Env))
	var extra []string
	for _, kv := range lp.Env {
		key, _, _ := strings.Cut(kv, "=")
		if slices.Contains(reservedEnvKeys, key) {
			continue
		}
		overridden[key] = true
		extra = append(extra, kv)
	}

	env := make([]string, 0, len(base)+len(extra)+3)
	for _, kv := range base {
		key, _, _ := strings.Cut(kv, "=")
		if hasAnyPrefix(kv, nestedSessionPrefixes) || key == envClrcSession || key == envHarnessProfile || overridden[key] {
			continue
		}
		env = append(env, kv)
	}
	env = append(env, extra...)
	env = append(env, envClrcSession+"=1")
	if lp.Harness {
		env = append(env, envHarnessProfile+"="+lp.Name)
	}
	if lp.ConfigDir != "" {
		env = append(env, envClaudeConfigDir+"="+lp.ConfigDir)
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
func childEnv(lp LaunchProfile) []string {
	return buildChildEnv(os.Environ(), lp)
}

// Terminal capabilities advertised to PTY children when the agent has none.
// SwiftTerm on the iPhone emulates xterm with truecolor.
const (
	defaultTerm      = "xterm-256color"
	defaultColorTerm = "truecolor"
)

// ptyEnv is childEnv for a terminal session: it also guarantees TERM.
func ptyEnv(lp LaunchProfile) []string {
	return ensureTerm(childEnv(lp))
}

// ensureTerm adds TERM and COLORTERM when env lacks them. A launchd daemon
// inherits no TERM, so without this `clear` leaves scrollback behind and
// full-screen TUIs (claude, vim) fall back to a minimal terminfo.
// Values already present are kept.
func ensureTerm(env []string) []string {
	hasTerm, hasColorTerm := false, false
	for _, kv := range env {
		switch {
		case strings.HasPrefix(kv, "TERM="):
			hasTerm = true
		case strings.HasPrefix(kv, "COLORTERM="):
			hasColorTerm = true
		}
	}
	out := slices.Clone(env)
	if !hasTerm {
		out = append(out, "TERM="+defaultTerm)
	}
	if !hasColorTerm {
		out = append(out, "COLORTERM="+defaultColorTerm)
	}
	return out
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
