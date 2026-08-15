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

	mu      sync.Mutex
	cmd     *exec.Cmd
	stdin   io.WriteCloser
	started bool // a process has run before, so the next spawn resumes
	closed  bool

	// reaping counts processes that have been started but not yet Wait()-ed
	// on by readStdout. It is a distinct piece of state from s.cmd/s.stdin
	// on purpose: s.cmd is "the handle Send should currently write to", which
	// Interrupt clears immediately so the next Send respawns; reaping is
	// "is a subprocess still outstanding", which only readStdout may clear,
	// strictly after cmd.Wait() returns. Close must gate closing doneCh on
	// reaping, not on s.cmd == nil, or an Interrupt-then-Close can close
	// doneCh before the interrupted process has actually been reaped. A
	// counter (not a bool) because Interrupt-then-Send can leave two
	// processes outstanding at once: the interrupted one, still draining in
	// its own readStdout goroutine, and the freshly respawned one.
	reaping int

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
	s.reaping++

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

	// Clear the handle so the next Send respawns with --resume, and mark
	// this process as reaped. Both happen only now, after cmd.Wait() has
	// actually returned — never in Interrupt, which only clears the handle.
	s.mu.Lock()
	if s.cmd == cmd {
		s.cmd = nil
		s.stdin = nil
	}
	if s.reaping > 0 {
		s.reaping--
	}
	closed := s.closed
	reaping := s.reaping
	s.mu.Unlock()

	if closed && reaping == 0 {
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
//
// The lock is held only long enough to (re)spawn the process and grab the
// current stdin handle — never across the blocking pipe write or an emit
// callback. A stalled child (e.g. hung inside a tool call) must not be able
// to block Interrupt/Close by holding s.mu hostage, and emit (which in
// production writes to the relay socket) must never run under s.mu or a
// re-entrant call from the callback would deadlock on this non-reentrant
// mutex.
func (s *ChatSession) Send(text string) error {
	s.mu.Lock()
	if s.closed {
		s.mu.Unlock()
		return fmt.Errorf("chat session %s is closed", s.ID)
	}
	startErr := s.ensureProcess()
	stdin := s.stdin
	s.mu.Unlock()

	if startErr != nil {
		s.publishError("could not start claude: %v", startErr)
		return startErr
	}

	msg := map[string]any{
		"type":    "user",
		"message": map[string]any{"role": "user", "content": text},
	}
	line, err := json.Marshal(msg)
	if err != nil {
		return fmt.Errorf("encode user message for %s: %w", s.ID, err)
	}
	if _, err := stdin.Write(append(line, '\n')); err != nil {
		s.publishError("could not deliver message: %v", err)
		return fmt.Errorf("write to chat session %s: %w", s.ID, err)
	}
	return nil
}

// Interrupt stops the current turn by killing the process. It clears the
// process handles itself, under s.mu, immediately after the kill — it does
// not wait for readStdout to notice the exit. This makes the next Send
// deterministically see a nil s.cmd and respawn with --resume, instead of
// racing the reader goroutine's cleanup. readStdout's identity check
// (`if s.cmd == cmd`) then simply finds a mismatch here and skips its own
// clear, so cmd.Wait() is still only ever called once, from readStdout.
func (s *ChatSession) Interrupt() {
	s.mu.Lock()
	defer s.mu.Unlock()
	cmd := s.cmd
	if cmd != nil && cmd.Process != nil {
		_ = cmd.Process.Kill()
	}
	if s.cmd == cmd {
		s.cmd = nil
		s.stdin = nil
	}
}

// History returns retained events newer than afterSeq, for client replay.
func (s *ChatSession) History(afterSeq uint64) []ChatEvent {
	return s.buf.Since(afterSeq)
}

// NextSeq reports the seq the session's next event will receive.
func (s *ChatSession) NextSeq() uint64 { return s.buf.NextSeq() }

// Close tears the session down. If a process is still outstanding (started
// but not yet reaped by readStdout — tracked by s.reaping, not by s.cmd,
// since Interrupt clears s.cmd well before the process is actually reaped),
// Close only kills whatever live handle remains and lets readStdout close
// doneCh once reaping reaches zero. Only when nothing is outstanding does
// Close close doneCh itself.
func (s *ChatSession) Close() {
	s.mu.Lock()
	if s.closed {
		s.mu.Unlock()
		return
	}
	s.closed = true
	cmd := s.cmd
	stdin := s.stdin
	reaping := s.reaping
	s.mu.Unlock()

	if stdin != nil {
		_ = stdin.Close()
	}
	if cmd != nil && cmd.Process != nil {
		_ = cmd.Process.Kill()
	}
	if reaping == 0 {
		s.doneOnce.Do(func() { close(s.doneCh) })
	}
}

func (s *ChatSession) Done() <-chan struct{} { return s.doneCh }
