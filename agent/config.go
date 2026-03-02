package agent

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/google/uuid"
)

// Config holds agent configuration. Populated from environment variables.
type Config struct {
	AgentID        string
	Name           string
	Secret         string
	RelayURL       string
	DefaultCommand string
}

// agentIDFile returns the path to the persisted agent ID file.
func agentIDFile() string {
	dir, _ := os.UserConfigDir()
	return filepath.Join(dir, "clrc", "id")
}

// loadOrCreateAgentID returns a stable agent ID:
// reads from the id file, or generates + saves a new one.
func loadOrCreateAgentID() string {
	path := agentIDFile()
	if data, err := os.ReadFile(path); err == nil {
		if id := strings.TrimSpace(string(data)); id != "" {
			return id
		}
	}
	id := uuid.New().String()
	_ = os.MkdirAll(filepath.Dir(path), 0700)
	_ = os.WriteFile(path, []byte(id+"\n"), 0600)
	return id
}

// Validate fills defaults and returns an error if required fields are missing.
func (c *Config) Validate() error {
	if c.AgentID == "" {
		c.AgentID = loadOrCreateAgentID()
	}
	if c.Name == "" {
		c.Name, _ = os.Hostname()
	}
	if c.DefaultCommand == "" {
		c.DefaultCommand = "bash"
	}
	if c.RelayURL == "" || c.Secret == "" {
		return fmt.Errorf("RELAY_URL and AGENT_SECRET are required\n\n" +
			"Set them in agent/.env (dev) or in the launchd plist EnvironmentVariables (production).\n\n" +
			"Or pass as flags:\n  clrc --relay ws://HOST:8080 --secret SECRET")
	}
	return nil
}
