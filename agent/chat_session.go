package agent

import (
	"bufio"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"os/exec"
	"sync"
	"time"
)

// maxScanLine is the stdout line cap. bufio.Scanner defaults to 64 KB, which
// a single tool-result line easily exceeds.
const maxScanLine = 1 << 20 // 1 MB

// ChatSession owns one headless `claude` process and turns its JSONL stream
// into normalised events. The process starts lazily on the first Send and is
// respawned with --resume if it dies, so a Mac reboot is just a cold start.
type ChatSession struct {
	ID    string
	Cwd   string
	Model string
	Bin   string // overridden in tests

	emit func(sessionID string, events []ChatEvent)
	buf  *ChatBuffer

	mu       sync.Mutex
	cmd      *exec.Cmd
	stdin    io.WriteCloser
	started  bool // a process has run before, so the next spawn resumes
	closed   bool
	doneCh   chan struct{}
	doneOnce sync.Once
}

func NewChatSession(id, cwd, model string, emit func(string, []ChatEvent)) *ChatSession {
	return &ChatSession{
		ID:     id,
		Cwd:    cwd,
		Model:  model,
		Bin:    "claude",
		emit:   emit,
		buf:    NewChatBuffer(defaultChatBufferSize),
		doneCh: make(chan struct{}),
	}
}

// publish stamps events with seq and forwards them to the client.
func (s *ChatSession) publish(events ...ChatEvent) {
	if len(events) == 0 {
		return
	}
	stamped := s.buf.Append(events...)
	if s.emit != nil {
		s.emit(s.ID, stamped)
	}
}

func (s *ChatSession) publishError(format string, args ...any) {
	s.publish(ChatEvent{
		Kind:    EventError,
		TS:      time.Now().UTC().Format(time.RFC3339),
		Message: fmt.Sprintf(format, args...),
	})
}

// args builds the CLI invocation. The first spawn creates the session with
// our own session id; later spawns resume it. The two flags are mutually
// exclusive — one creates, the other continues.
func (s *ChatSession) args() []string {
	a := []string{
		"-p",
		"--input-format", "stream-json",
		"--output-format", "stream-json",
		"--verbose",
		"--permission-mode", "bypassPermissions",
	}
	if s.started {
		a = append(a, "--resume", s.ID)
	} else {
		a = append(a, "--session-id", s.ID)
	}
	if s.Model != "" {
		a = append(a, "--model", s.Model)
	}
	return a
}

// ensureProcess starts the process if it is not running. Caller holds s.mu.
func (s *ChatSession) ensureProcess() error {
	if s.cmd != nil {
		return nil
	}
	cmd := exec.Command(s.Bin, s.args()...)
	cmd.Dir = s.Cwd
	cmd.Env = cleanEnv()

	stdin, err := cmd.StdinPipe()
	if err != nil {
		return fmt.Errorf("chat session %s stdin: %w", s.ID, err)
	}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return fmt.Errorf("chat session %s stdout: %w", s.ID, err)
	}
	stderr, err := cmd.StderrPipe()
	if err != nil {
		return fmt.Errorf("chat session %s stderr: %w", s.ID, err)
	}
	if err := cmd.Start(); err != nil {
		return fmt.Errorf("start chat session %s: %w", s.ID, err)
	}

	s.cmd = cmd
	s.stdin = stdin
	s.started = true

	go s.readStdout(cmd, stdout)
	go s.readStderr(stderr)
	return nil
}

func (s *ChatSession) readStdout(cmd *exec.Cmd, stdout io.ReadCloser) {
	scanner := bufio.NewScanner(stdout)
	scanner.Buffer(make([]byte, 0, 64*1024), maxScanLine)
	for scanner.Scan() {
		ts := time.Now().UTC().Format(time.RFC3339)
		s.publish(TranslateLine(scanner.Bytes(), ts)...)
	}
	if err := scanner.Err(); err != nil {
		s.publishError("output stream error: %v", err)
	}
	_ = cmd.Wait()

	// Clear the handle so the next Send respawns with --resume.
	s.mu.Lock()
	if s.cmd == cmd {
		s.cmd = nil
		s.stdin = nil
	}
	closed := s.closed
	s.mu.Unlock()

	if closed {
		s.doneOnce.Do(func() { close(s.doneCh) })
	}
}

func (s *ChatSession) readStderr(stderr io.ReadCloser) {
	scanner := bufio.NewScanner(stderr)
	scanner.Buffer(make([]byte, 0, 64*1024), maxScanLine)
	for scanner.Scan() {
		line := scanner.Text()
		if line == "" {
			continue
		}
		log.Printf("chat session %s stderr: %s", s.ID, line)
		s.publishError("%s", line)
	}
}

// Send delivers one user message, starting or restarting the process as needed.
func (s *ChatSession) Send(text string) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	if s.closed {
		return fmt.Errorf("chat session %s is closed", s.ID)
	}
	if err := s.ensureProcess(); err != nil {
		s.publishError("could not start claude: %v", err)
		return err
	}

	msg := map[string]any{
		"type":    "user",
		"message": map[string]any{"role": "user", "content": text},
	}
	line, err := json.Marshal(msg)
	if err != nil {
		return fmt.Errorf("encode user message for %s: %w", s.ID, err)
	}
	if _, err := s.stdin.Write(append(line, '\n')); err != nil {
		s.publishError("could not deliver message: %v", err)
		return fmt.Errorf("write to chat session %s: %w", s.ID, err)
	}
	return nil
}

// Interrupt stops the current turn by killing the process. The next Send
// respawns it with --resume, which restores the conversation.
func (s *ChatSession) Interrupt() {
	s.mu.Lock()
	cmd := s.cmd
	s.mu.Unlock()
	if cmd != nil && cmd.Process != nil {
		_ = cmd.Process.Kill()
	}
}

// History returns retained events newer than afterSeq, for client replay.
func (s *ChatSession) History(afterSeq uint64) []ChatEvent {
	return s.buf.Since(afterSeq)
}

func (s *ChatSession) Close() {
	s.mu.Lock()
	if s.closed {
		s.mu.Unlock()
		return
	}
	s.closed = true
	cmd := s.cmd
	stdin := s.stdin
	s.mu.Unlock()

	if stdin != nil {
		_ = stdin.Close()
	}
	if cmd != nil && cmd.Process != nil {
		_ = cmd.Process.Kill()
	} else {
		s.doneOnce.Do(func() { close(s.doneCh) })
	}
}

func (s *ChatSession) Done() <-chan struct{} { return s.doneCh }
