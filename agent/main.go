package main

import (
	"context"
	"flag"
	"fmt"
	"log"
	"os"
	"os/signal"
	"path/filepath"
	"syscall"

	"github.com/google/uuid"
	"gopkg.in/yaml.v3"
)

// Config holds agent configuration.
type Config struct {
	AgentID        string `yaml:"agent_id"`
	Name           string `yaml:"name"`
	Secret         string `yaml:"secret"`
	RelayURL       string `yaml:"relay_url"`
	DefaultCommand string `yaml:"default_command"`
}

func loadConfig(path string) (*Config, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var cfg Config
	if err := yaml.Unmarshal(data, &cfg); err != nil {
		return nil, err
	}
	return &cfg, nil
}

func defaultConfigPath() string {
	home, err := os.UserHomeDir()
	if err != nil {
		return "config.yaml"
	}
	return filepath.Join(home, ".config", "claude-agent", "config.yaml")
}

func initConfig(path string) error {
	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0700); err != nil {
		return err
	}
	agentID := uuid.New().String()
	secret := uuid.New().String()
	hostname, _ := os.Hostname()

	cfg := Config{
		AgentID:        agentID,
		Name:           hostname,
		Secret:         secret,
		RelayURL:       "wss://your-relay.up.railway.app",
		DefaultCommand: "claude",
	}

	data, err := yaml.Marshal(cfg)
	if err != nil {
		return err
	}
	return os.WriteFile(path, data, 0600)
}

func main() {
	var (
		configPath = flag.String("config", defaultConfigPath(), "Path to config file")
		relay      = flag.String("relay", "", "Relay URL (e.g. wss://my-relay.up.railway.app)")
		secret     = flag.String("secret", "", "Agent secret (must match relay AGENT_SECRET)")
		name       = flag.String("name", "", "Agent display name (default: hostname)")
		initFlag   = flag.Bool("init", false, "Initialize config file and exit")
	)
	flag.Parse()

	if *initFlag {
		if err := initConfig(*configPath); err != nil {
			log.Fatalf("Failed to init config: %v", err)
		}
		fmt.Printf("Config initialized at: %s\n", *configPath)
		fmt.Println("Edit the file to set relay_url and secret, then run the agent.")
		return
	}

	// Build config: try file first, fall back to flags-only mode
	var cfg *Config
	if loaded, err := loadConfig(*configPath); err == nil {
		cfg = loaded
	} else {
		// No config file — require --relay and --secret flags
		if *relay == "" || *secret == "" {
			log.Fatalf("No config file found at %s.\n\nRun with flags:\n  claude-agent --relay wss://YOUR_RELAY --secret YOUR_SECRET [--name MyMac]\n\nOr create a config:\n  claude-agent --init", *configPath)
		}
		hostname, _ := os.Hostname()
		cfg = &Config{
			AgentID:        uuid.New().String(),
			Name:           hostname,
			DefaultCommand: "bash",
		}
	}

	// Apply flag overrides
	if *relay != "" {
		cfg.RelayURL = *relay
	}
	if *secret != "" {
		cfg.Secret = *secret
	}
	if *name != "" {
		cfg.Name = *name
	}
	if cfg.DefaultCommand == "" {
		cfg.DefaultCommand = "bash"
	}

	log.Printf("Starting Claude Agent")
	log.Printf("  Agent ID: %s", cfg.AgentID)
	log.Printf("  Name:     %s", cfg.Name)
	log.Printf("  Relay:    %s", cfg.RelayURL)
	log.Printf("  Command:  %s", cfg.DefaultCommand)

	ctx, cancel := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer cancel()

	client := NewWSClient(cfg)
	client.Run(ctx)

	log.Println("Agent stopped.")
}
