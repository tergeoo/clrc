package agent

import (
	"bytes"
	"encoding/json"
	"log"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
)

// The agent launches ~/harness profiles the way the harness `c <name>`
// launcher does (see harness/shell/harness.zsh _harness_launch): config dir,
// the profile's env file, HARNESS_PROFILE and its launch_args.

const (
	envHarnessRoot    = "HARNESS_ROOT"
	envHarnessProfile = "HARNESS_PROFILE"
	// harnessStateFile marks a profile dir that `harness sync` has set up;
	// `c <name>` refuses profiles without it.
	harnessStateFile = ".harness-state.json"
)

// HarnessProfile is one usable (synced) harness profile on this Mac.
type HarnessProfile struct {
	Name        string
	Description string
	LaunchArgs  []string
}

// harnessRoot is $HARNESS_ROOT, or ~/harness.
func harnessRoot(home string) string {
	if root := os.Getenv(envHarnessRoot); root != "" {
		return root
	}
	return filepath.Join(home, "harness")
}

func harnessProfileFile(root, name string) string {
	return filepath.Join(root, "profiles", name, "profile.json")
}

// harnessProfileDefined reports whether the harness repo defines name,
// synced on this Mac or not. Names starting with "_" are templates.
func harnessProfileDefined(root, name string) bool {
	if !validIdent(name) {
		return false
	}
	_, err := os.Stat(harnessProfileFile(root, name))
	return err == nil
}

// harnessProfileSynced reports whether `harness sync` set up name here.
func harnessProfileSynced(home, name string) bool {
	_, err := os.Stat(filepath.Join(profileDir(home, name), harnessStateFile))
	return err == nil
}

// loadHarnessProfile reads one profile's profile.json.
func loadHarnessProfile(root, name string) (HarnessProfile, error) {
	data, err := os.ReadFile(harnessProfileFile(root, name))
	if err != nil {
		return HarnessProfile{}, err
	}
	var raw struct {
		Description string   `json:"description"`
		LaunchArgs  []string `json:"launch_args"`
	}
	if err := json.Unmarshal(data, &raw); err != nil {
		return HarnessProfile{}, err
	}
	return HarnessProfile{Name: name, Description: raw.Description, LaunchArgs: raw.LaunchArgs}, nil
}

// LoadHarnessProfiles lists the harness profiles usable on this Mac: defined
// in root, a valid name and synced. Unreadable profile.json files are
// skipped and logged; a missing root means no profiles. Sorted by name.
func LoadHarnessProfiles(home, root string) []HarnessProfile {
	entries, err := os.ReadDir(filepath.Join(root, "profiles"))
	if err != nil {
		return nil
	}
	var out []HarnessProfile
	for _, e := range entries {
		name := e.Name()
		if !e.IsDir() || !validIdent(name) || !harnessProfileSynced(home, name) {
			continue
		}
		p, err := loadHarnessProfile(root, name)
		if err != nil {
			log.Printf("harness profile %q skipped: %v", name, err)
			continue
		}
		out = append(out, p)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Name < out[j].Name })
	return out
}

var envKeyPattern = regexp.MustCompile(`^[A-Za-z_][A-Za-z0-9_]*$`)

// ParseEnvFile is ParseEnvFileWith over the agent's own environment.
func ParseEnvFile(data []byte) (vars []string, skippedLines []int) {
	return ParseEnvFileWith(data, os.LookupEnv)
}

// ParseEnvFileWith parses the subset of shell syntax that `set -a; source`
// handles in a simple env file: KEY=value, an optional `export ` prefix,
// one level of matching single or double quotes, blank lines and # comments.
// Like the shell, $VAR and ${VAR} are expanded (against earlier lines of the
// file, then lookup; unset expands to empty) except inside single quotes.
// It returns KEY=value entries and the 1-based numbers of lines it could not
// parse (callers must not log their content).
func ParseEnvFileWith(data []byte, lookup func(string) (string, bool)) (vars []string, skippedLines []int) {
	defined := map[string]string{}
	resolve := func(key string) string {
		if v, ok := defined[key]; ok {
			return v
		}
		v, _ := lookup(key)
		return v
	}
	for i, line := range strings.Split(string(bytes.ReplaceAll(data, []byte("\r\n"), []byte("\n"))), "\n") {
		line = strings.TrimSpace(line)
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		line = strings.TrimPrefix(line, "export ")
		key, value, ok := strings.Cut(line, "=")
		if !ok || !envKeyPattern.MatchString(key) {
			skippedLines = append(skippedLines, i+1)
			continue
		}
		if len(value) >= 2 && value[0] == '\'' && value[len(value)-1] == '\'' {
			value = value[1 : len(value)-1] // single quotes: literal
		} else {
			value = os.Expand(unquote(value), resolve)
		}
		defined[key] = value
		vars = append(vars, key+"="+value)
	}
	return vars, skippedLines
}

func unquote(v string) string {
	if len(v) >= 2 && (v[0] == '"' || v[0] == '\'') && v[len(v)-1] == v[0] {
		return v[1 : len(v)-1]
	}
	return v
}
