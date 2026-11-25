package agent

import (
	"errors"
	"fmt"
	"log"
	"os"
	"path/filepath"
)

// errProfileNotFound is returned for a strict profile that cannot be used.
var errProfileNotFound = errors.New("profile not found")

// strictProfileError is what the iPhone shows when a project's profile is
// not usable on this Mac.
func strictProfileError(name string) error {
	return fmt.Errorf("профиль «%s» не найден на этом Маке — harness sync %s: %w", name, name, errProfileNotFound)
}

// harnessEnvFile is where `c <name>` reads the profile's secrets from.
func harnessEnvFile(home, name string) string {
	return filepath.Join(home, ".config", "harness", name+".env")
}

// resolveLaunch turns a connect's profile into a LaunchProfile.
//
// An empty profile means the agent default (CLRC_PROFILE, which gets the
// same harness treatment, or an explicit CLRC_CLAUDE_CONFIG_DIR, which does
// not). With strict set, a profile that `c <name>` would refuse — invalid
// name, no config dir, or defined in ~/harness but not synced — is an error
// and nothing falls back. Without strict, a bad profile falls back to the
// agent default and the error is returned for the caller to report.
func (c *WSClient) resolveLaunch(profile string, strict bool) (LaunchProfile, error) {
	def := LaunchProfile{ConfigDir: c.cfg.ClaudeConfigDir}
	home, err := os.UserHomeDir()
	if err != nil {
		if strict {
			return LaunchProfile{}, strictProfileError(profile)
		}
		return def, fmt.Errorf("resolve home for profile %q: %w", profile, err)
	}

	if profile == "" {
		if c.cfg.Profile == "" {
			return def, nil
		}
		lp, err := launchProfileFor(home, c.cfg.Profile, false)
		if err != nil {
			return def, nil // the default was already validated at startup
		}
		return lp, nil
	}

	lp, err := launchProfileFor(home, profile, strict)
	if err != nil {
		if strict {
			return LaunchProfile{}, strictProfileError(profile)
		}
		return def, err
	}
	return lp, nil
}

// launchProfileFor builds the LaunchProfile for a named profile. requireSync
// rejects a ~/harness profile that is not synced on this Mac; otherwise such
// a profile is used as a plain config dir, as before harness support.
func launchProfileFor(home, name string, requireSync bool) (LaunchProfile, error) {
	dir, err := ResolveClaudeConfigDir(home, name, "")
	if err != nil {
		return LaunchProfile{}, err
	}
	root := harnessRoot(home)
	if !harnessProfileDefined(root, name) {
		return LaunchProfile{Name: name, ConfigDir: dir}, nil
	}
	if !harnessProfileSynced(home, name) {
		if requireSync {
			return LaunchProfile{}, fmt.Errorf("harness profile %q is not synced", name)
		}
		return LaunchProfile{Name: name, ConfigDir: dir}, nil
	}
	return LaunchProfile{Name: name, ConfigDir: dir, Harness: true, Env: readHarnessEnv(home, name)}, nil
}

// readHarnessEnv loads the profile's env file, if any. It is read on every
// launch so edits apply without restarting the agent. Values are never logged.
func readHarnessEnv(home, name string) []string {
	data, err := os.ReadFile(harnessEnvFile(home, name))
	if err != nil {
		if !errors.Is(err, os.ErrNotExist) {
			log.Printf("harness env for %q not loaded: %v", name, err)
		}
		return nil
	}
	vars, skipped := ParseEnvFile(data)
	if len(skipped) > 0 {
		log.Printf("harness env for %q: skipped unparsable lines %v", name, skipped)
	}
	return vars
}
