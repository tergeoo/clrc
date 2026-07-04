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
	logFile = "/tmp/clrc.log"
)

func pidFile() string {
	dir, _ := os.UserConfigDir()
	return filepath.Join(dir, "clrc", "agent.pid")
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

func cmdSessions() {
	sessions := agent.ListSess()
	if len(sessions) == 0 {
		fmt.Println("No active sessions")
		return
	}
	fmt.Printf("%-10s  %-6s  %-10s  %s\n", "SESSION", "PID", "COMMAND", "STARTED")
	fmt.Println(strings.Repeat("─", 52))
	for _, s := range sessions {
		short := s.ID
		if len(short) > 8 {
			short = short[:8]
		}
		fmt.Printf("%-10s  %-6d  %-10s  %s\n",
			short, s.PID, s.Command, s.Started.Format("15:04:05"))
	}
}

func cmdAttach() {
	sessions := agent.ListSess()
	if len(sessions) == 0 {
		fmt.Println("No active sessions")
		return
	}

	// Find session by ID prefix (or exact)
	var target *agent.SessionInfo
	if len(os.Args) >= 3 {
		prefix := os.Args[2]
		for i := range sessions {
			if strings.HasPrefix(sessions[i].ID, prefix) {
				target = &sessions[i]
				break
			}
		}
		if target == nil {
			fmt.Fprintf(os.Stderr, "Session not found: %s\n", prefix)
			os.Exit(1)
		}
	} else if len(sessions) == 1 {
		target = &sessions[0]
	} else {
		fmt.Fprintln(os.Stderr, "Multiple sessions — specify ID prefix:")
		cmdSessions()
		os.Exit(1)
	}

	// reptyr required
	reptyrPath, err := exec.LookPath("reptyr")
	if err != nil {
		fmt.Fprintln(os.Stderr, "reptyr not found. Install: brew install reptyr")
		os.Exit(1)
	}

	tmuxName := "clrc-" + target.ID[:8]

	// Check if tmux is available
	tmuxPath, tmuxErr := exec.LookPath("tmux")
	if tmuxErr != nil {
		// No tmux — just reptyr directly
		fmt.Printf("Attaching to session %s (PID %d)...\n", target.ID[:8], target.PID)
		cmd := exec.Command(reptyrPath, strconv.Itoa(target.PID))
		cmd.Stdin, cmd.Stdout, cmd.Stderr = os.Stdin, os.Stdout, os.Stderr
		_ = cmd.Run()
		return
	}

	// Check if tmux session already exists
	check := exec.Command(tmuxPath, "has-session", "-t", tmuxName)
	if check.Run() == nil {
		// Already exists — attach
		fmt.Printf("Attaching to tmux session %s...\n", tmuxName)
		cmd := exec.Command(tmuxPath, "attach", "-t", tmuxName)
		cmd.Stdin, cmd.Stdout, cmd.Stderr = os.Stdin, os.Stdout, os.Stderr
		_ = cmd.Run()
		return
	}

	// Create new tmux session running reptyr
	fmt.Printf("Attaching to session %s (PID %d) in tmux...\n", target.ID[:8], target.PID)
	cmd := exec.Command(tmuxPath, "new-session", "-s", tmuxName,
		reptyrPath, strconv.Itoa(target.PID))
	cmd.Stdin, cmd.Stdout, cmd.Stderr = os.Stdin, os.Stdout, os.Stderr
	_ = cmd.Run()
}

func configFilePath() string {
	return filepath.Join(os.Getenv("HOME"), ".config", "clrc", ".env")
}

func setConfigValue(path, key, value string) {
	_ = os.MkdirAll(filepath.Dir(path), 0700)

	var lines []string
	if data, err := os.ReadFile(path); err == nil {
		lines = strings.Split(strings.TrimRight(string(data), "\n"), "\n")
	}

	found := false
	for i, line := range lines {
		if strings.HasPrefix(line, key+"=") {
			lines[i] = fmt.Sprintf(`%s="%s"`, key, value)
			found = true
			break
		}
	}
	if !found {
		lines = append(lines, fmt.Sprintf(`%s="%s"`, key, value))
	}

	_ = os.WriteFile(path, []byte(strings.Join(lines, "\n")+"\n"), 0600)
	fmt.Printf("✓ %s = %s\n", key, value)
}

func cmdConfig() {
	fs := flag.NewFlagSet("config", flag.ExitOnError)
	relayURL := fs.String("relay-url", "", "Set RELAY_URL")
	secret   := fs.String("secret", "", "Set AGENT_SECRET")
	name     := fs.String("name", "", "Set AGENT_NAME")
	command  := fs.String("command", "", "Set DEFAULT_COMMAND")
	show     := fs.Bool("show", false, "Print current config")
	edit     := fs.Bool("edit", false, "Open config in $EDITOR")
	fs.Usage = func() {
		fmt.Fprintf(os.Stderr, "Usage: clrc config [flags]\n\n")
		fmt.Fprintf(os.Stderr, "Flags:\n")
		fs.PrintDefaults()
		fmt.Fprintf(os.Stderr, "\nExamples:\n")
		fmt.Fprintf(os.Stderr, "  clrc config                          # show current config\n")
		fmt.Fprintf(os.Stderr, "  clrc config --relay-url wss://...    # set relay URL\n")
		fmt.Fprintf(os.Stderr, "  clrc config --secret mysecret        # set agent secret\n")
		fmt.Fprintf(os.Stderr, "  clrc config --name \"My Mac\"          # set display name\n")
		fmt.Fprintf(os.Stderr, "  clrc config --command claude         # set default command\n")
		fmt.Fprintf(os.Stderr, "  clrc config --edit                   # open in $EDITOR\n")
	}
	fs.Parse(os.Args[2:])

	path := configFilePath()

	if *edit {
		editor := os.Getenv("EDITOR")
		if editor == "" {
			editor = "nano"
		}
		cmd := exec.Command(editor, path)
		cmd.Stdin, cmd.Stdout, cmd.Stderr = os.Stdin, os.Stdout, os.Stderr
		_ = cmd.Run()
		return
	}

	changed := false
	if *relayURL != "" { setConfigValue(path, "RELAY_URL", *relayURL); changed = true }
	if *secret != ""   { setConfigValue(path, "AGENT_SECRET", *secret); changed = true }
	if *name != ""     { setConfigValue(path, "AGENT_NAME", *name); changed = true }
	if *command != ""  { setConfigValue(path, "DEFAULT_COMMAND", *command); changed = true }

	if *show || !changed {
		data, err := os.ReadFile(path)
		if err != nil {
			fmt.Printf("No config at %s\n\nCreate one:\n  clrc config --relay-url wss://... --secret SECRET\n", path)
			return
		}
		fmt.Printf("# %s\n%s", path, string(data))
	}
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
	home := os.Getenv("HOME")
	loadEnvFile(filepath.Join(home, ".config", "clrc", ".env"))
	loadEnvFile(filepath.Join(home, ".config", "claude-agent", ".env")) // legacy fallback
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

	log.Printf("Starting CLRC")
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
	case "sessions":
		cmdSessions()
	case "attach":
		cmdAttach()
	case "config":
		cmdConfig()
	case "_run", "": // internal daemon process or foreground run
		run()
	default:
		fmt.Fprintf(os.Stderr, "clrc — Claude Remote Control\n\n")
		fmt.Fprintf(os.Stderr, "Usage:\n")
		fmt.Fprintf(os.Stderr, "  clrc start                           start daemon\n")
		fmt.Fprintf(os.Stderr, "  clrc stop                            stop daemon\n")
		fmt.Fprintf(os.Stderr, "  clrc restart                         restart daemon\n")
		fmt.Fprintf(os.Stderr, "  clrc status                          show status\n")
		fmt.Fprintf(os.Stderr, "  clrc logs                            tail log file\n")
		fmt.Fprintf(os.Stderr, "  clrc sessions                        list active PTY sessions\n")
		fmt.Fprintf(os.Stderr, "  clrc attach [session-id]             attach via reptyr + tmux\n")
		fmt.Fprintf(os.Stderr, "  clrc config                          show config\n")
		fmt.Fprintf(os.Stderr, "  clrc config --relay-url wss://...    set relay URL\n")
		fmt.Fprintf(os.Stderr, "  clrc config --secret SECRET          set agent secret\n")
		fmt.Fprintf(os.Stderr, "  clrc config --name \"My Mac\"          set display name\n")
		fmt.Fprintf(os.Stderr, "  clrc config --command claude         set default command\n")
		fmt.Fprintf(os.Stderr, "  clrc config --edit                   open config in $EDITOR\n")
		os.Exit(1)
	}
}
