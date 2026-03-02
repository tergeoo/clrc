package main

import (
	"context"
	"flag"
	"fmt"
	"log"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"

	"github.com/claude-orchestrator/agent"
)

const (
	logFile = "/tmp/claude-agent.log"
)

func pidFile() string {
	dir, _ := os.UserConfigDir()
	return filepath.Join(dir, "claude-agent", "agent.pid")
}

func readPID() int {
	data, err := os.ReadFile(pidFile())
	if err != nil {
		return 0
	}
	pid, _ := strconv.Atoi(strings.TrimSpace(string(data)))
	return pid
}

func writePID(pid int) {
	path := pidFile()
	_ = os.MkdirAll(filepath.Dir(path), 0700)
	_ = os.WriteFile(path, []byte(strconv.Itoa(pid)+"\n"), 0600)
}

func processRunning(pid int) bool {
	if pid <= 0 {
		return false
	}
	p, err := os.FindProcess(pid)
	if err != nil {
		return false
	}
	return p.Signal(syscall.Signal(0)) == nil
}

func cmdStart() {
	if pid := readPID(); processRunning(pid) {
		fmt.Printf("Already running (PID %d)\n", pid)
		return
	}

	self, err := os.Executable()
	if err != nil {
		log.Fatal(err)
	}

	logF, err := os.OpenFile(logFile, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0644)
	if err != nil {
		log.Fatal(err)
	}

	cmd := exec.Command(self, "_run")
	cmd.Stdout = logF
	cmd.Stderr = logF
	cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
	if err := cmd.Start(); err != nil {
		log.Fatal(err)
	}

	writePID(cmd.Process.Pid)
	fmt.Printf("Started (PID %d) — logs: %s\n", cmd.Process.Pid, logFile)
}

func cmdStop() {
	pid := readPID()
	if !processRunning(pid) {
		fmt.Println("Not running")
		_ = os.Remove(pidFile())
		return
	}
	p, _ := os.FindProcess(pid)
	if err := p.Signal(syscall.SIGTERM); err != nil {
		log.Fatal(err)
	}
	_ = os.Remove(pidFile())
	fmt.Printf("Stopped (PID %d)\n", pid)
}

func cmdStatus() {
	pid := readPID()
	if processRunning(pid) {
		fmt.Printf("Running (PID %d)\n", pid)
	} else {
		fmt.Println("Stopped")
	}
}

func cmdLogs() {
	tail := exec.Command("tail", "-f", logFile)
	tail.Stdout = os.Stdout
	tail.Stderr = os.Stderr
	tail.Stdin = os.Stdin
	_ = tail.Run()
}

// loadEnvFile sources KEY="VALUE" pairs from path into the process environment,
// skipping keys that are already set.
func loadEnvFile(path string) {
	data, err := os.ReadFile(path)
	if err != nil {
		return
	}
	for _, line := range strings.Split(string(data), "\n") {
		line = strings.TrimSpace(line)
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		k, v, ok := strings.Cut(line, "=")
		if !ok {
			continue
		}
		k = strings.TrimSpace(k)
		v = strings.Trim(strings.TrimSpace(v), `"`)
		if os.Getenv(k) == "" {
			os.Setenv(k, v)
		}
	}
}

func run() {
	// Load config file if env vars not already set (daemon mode).
	// Use XDG ~/.config path (also works on macOS for this tool).
	loadEnvFile(filepath.Join(os.Getenv("HOME"), ".config", "claude-agent", ".env"))
	var (
		relay  = flag.String("relay", "", "Override RELAY_URL")
		secret = flag.String("secret", "", "Override AGENT_SECRET")
		name   = flag.String("name", "", "Override AGENT_NAME")
	)
	args := os.Args[1:]
	if len(args) > 0 && !strings.HasPrefix(args[0], "-") {
		args = args[1:] // skip subcommand
	}
	flag.CommandLine.Parse(args)

	cfg := agent.Config{
		AgentID:        os.Getenv("AGENT_ID"),
		Name:           os.Getenv("AGENT_NAME"),
		Secret:         os.Getenv("AGENT_SECRET"),
		RelayURL:       os.Getenv("RELAY_URL"),
		DefaultCommand: os.Getenv("DEFAULT_COMMAND"),
	}
	if *relay != "" {
		cfg.RelayURL = *relay
	}
	if *secret != "" {
		cfg.Secret = *secret
	}
	if *name != "" {
		cfg.Name = *name
	}
	if err := cfg.Validate(); err != nil {
		log.Fatal(err)
	}

	log.Printf("Starting Claude Agent")
	log.Printf("  Agent ID: %s", cfg.AgentID)
	log.Printf("  Name:     %s", cfg.Name)
	log.Printf("  Relay:    %s", cfg.RelayURL)
	log.Printf("  Command:  %s", cfg.DefaultCommand)

	ctx, cancel := context.WithCancel(context.Background())
	sigs := make(chan os.Signal, 1)
	signal.Notify(sigs, syscall.SIGINT, syscall.SIGTERM)
	go func() {
		<-sigs
		cancel()
	}()

	agent.NewWSClient(cfg).Run(ctx)
	log.Println("Agent stopped.")
}

func main() {
	sub := ""
	if len(os.Args) > 1 {
		sub = os.Args[1]
	}

	switch sub {
	case "start":
		cmdStart()
	case "stop":
		cmdStop()
	case "restart":
		cmdStop()
		cmdStart()
	case "status":
		cmdStatus()
	case "logs":
		cmdLogs()
	case "_run", "": // internal daemon process or foreground run
		run()
	default:
		fmt.Fprintf(os.Stderr, "Usage: claude-agent [start|stop|restart|status|logs]\n")
		fmt.Fprintf(os.Stderr, "       claude-agent [--relay URL] [--secret SECRET] [--name NAME]\n")
		os.Exit(1)
	}
}
