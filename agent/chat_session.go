package agent

import (
	"bufio"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"os/exec"
	"sync"
	"syscall"
	"time"
)

// maxScanLine is the stdout/stderr line cap. A single tool-result line can
// easily exceed a naive default, so lines are read (and, past this cap,
// discarded) by hand rather than with bufio.Scanner — see readLine.
const maxScanLine = 1 << 20 // 1 MB

// interruptGrace is how long Interrupt/Close wait after SIGINT before
// escalating to SIGKILL. SIGINT gives the CLI a chance to flush the
// transcript that --resume depends on; SIGKILL is the fallback for a process
// that does not respond.
const interruptGrace = 2 * time.Second

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

	mu    sync.Mutex
	cmd   *exec.Cmd
	stdin io.WriteCloser
	// started becomes true only once a spawned process has proven it
	// actually created the session — i.e. after its first successfully
	// translated system/init line — not merely once cmd.Start() succeeds.
	// A process that starts and immediately dies (expired auth, a bad
	// --model, quota exhaustion) must not flip this on: doing so would make
	// every later spawn pass --resume <id> for a conversation the CLI never
	// created, poisoning the session permanently and silently.
	started bool
	closed  bool

	malformedLines uint64 // count of stdout lines that failed to parse as JSON; log-only

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

	// interrupting is the set of *exec.Cmd the agent itself is in the middle
	// of tearing down via Interrupt or Close. SIGINT (and the SIGKILL
	// escalation) makes cmd.Wait() in readStdout return a non-nil error —
	// "signal: interrupt" or a 130 exit — indistinguishable, from Wait()'s
	// return value alone, from a genuine crash. Without this, pressing Stop
	// — a normal, deliberate action — would publish the same `error` event
	// (and sticky red banner on the client) as an unexpected death.
	//
	// A set keyed by cmd, not a single pointer or a session-wide bool, for
	// the same reason s.reaping is a counter, not a bool (see above):
	// Interrupt-then-Send can leave two processes outstanding at once — the
	// interrupted one, still draining in its own readStdout goroutine, and
	// the freshly respawned one — and a second Interrupt or a Close before
	// the first is reaped must not clobber the first's entry. Each entry is
	// deleted by readStdout once that specific cmd is actually reaped.
	interrupting map[*exec.Cmd]struct{}

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
	// Its own process group so Interrupt/Close can signal the whole tree
	// (e.g. a running Bash tool call), not just the immediate child.
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}

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
	s.reaping++

	go s.readStdout(cmd, stdout)
	go s.readStderr(stderr)
	return nil
}

func (s *ChatSession) readStdout(cmd *exec.Cmd, stdout io.ReadCloser) {
	reader := bufio.NewReaderSize(stdout, 64*1024)
	for {
		line, tooLong, err := readLine(reader, maxScanLine)
		if tooLong {
			s.publishError("stdout line exceeded %d bytes; line skipped", maxScanLine)
		} else if len(line) > 0 || err == nil {
			ts := time.Now().UTC().Format(time.RFC3339)
			events := TranslateLine(line, ts)
			s.noteMalformed(line, events)
			s.noteStarted(events)
			s.publish(events...)
		}
		if err != nil {
			if err != io.EOF {
				s.publishError("output stream error: %v", err)
			}
			break
		}
	}

	waitErr := cmd.Wait()

	// Clear the handle so the next Send respawns with --resume, and mark
	// this process as reaped. Both happen only now, after cmd.Wait() has
	// actually returned — never in Interrupt, which only clears the handle.
	// selfInitiated is read under the same lock: Interrupt/Close record the
	// specific cmd they are tearing down in s.interrupting, and it must be
	// checked here — before it could be overwritten by some later
	// Interrupt on a respawned process — to correctly attribute *this*
	// exit's waitErr.
	s.mu.Lock()
	_, selfInitiated := s.interrupting[cmd]
	if selfInitiated {
		delete(s.interrupting, cmd)
	}
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

	if waitErr != nil {
		log.Printf("chat session %s: process exited: %v (agent-initiated=%v)", s.ID, waitErr, selfInitiated)
		// A termination the agent itself requested (Stop, or Close tearing
		// the session down) is not a failure — do not raise the client's
		// error banner for it. A genuine unexpected exit still must.
		if !selfInitiated {
			s.publishError("claude exited: %v", waitErr)
		}
	}

	if closed && reaping == 0 {
		s.doneOnce.Do(func() { close(s.doneCh) })
	}
}

// noteMalformed logs (and counts) a stdout line that produced no events
// because it failed to parse as JSON at all — as opposed to one that parsed
// fine but was recognised, filtered noise (e.g. system/thinking_tokens).
// Spec §11: "skip and count", server-side only — unlike an over-long line,
// this does not reach the client as an error event.
func (s *ChatSession) noteMalformed(line []byte, events []ChatEvent) {
	if len(events) != 0 || len(line) == 0 || json.Valid(line) {
		return
	}
	s.mu.Lock()
	s.malformedLines++
	n := s.malformedLines
	s.mu.Unlock()
	log.Printf("chat session %s: malformed stdout line #%d (not JSON): %.200q", s.ID, n, line)
}

// noteStarted flips s.started once the process has proven it actually
// created the session, i.e. produced a turn_start (system/init). See the
// field comment on ChatSession.started for why this must not happen at spawn time.
func (s *ChatSession) noteStarted(events []ChatEvent) {
	for _, e := range events {
		if e.Kind == EventTurnStart {
			s.mu.Lock()
			s.started = true
			s.mu.Unlock()
			return
		}
	}
}

func (s *ChatSession) readStderr(stderr io.ReadCloser) {
	reader := bufio.NewReaderSize(stderr, 64*1024)
	for {
		line, tooLong, err := readLine(reader, maxScanLine)
		if tooLong {
			s.publishError("stderr line exceeded %d bytes; line skipped", maxScanLine)
		} else if len(line) > 0 {
			log.Printf("chat session %s stderr: %s", s.ID, line)
			s.publishError("%s", line)
		}
		if err != nil {
			return
		}
	}
}

// readLine reads one newline-terminated line from r, capped at maxLen bytes
// of accumulated content. A line longer than maxLen is fully drained from r
// (so the byte stream stays in sync for whatever follows) but reported via
// tooLong with a nil line, rather than returning truncated, unparseable
// content — the caller cannot usefully use a cut-off JSON line anyway.
//
// This replaces bufio.Scanner deliberately: Scanner's ErrTooLong is
// terminal — Scan() returns false forever afterwards — which is exactly the
// bug this fixes. A single over-long line must not end the ability to read
// anything else from the pipe: the child would then block writing into a
// full, undrained pipe, and cmd.Wait() would block forever waiting for a
// process that itself is blocked waiting for a reader. readLine keeps
// consuming input from r until a real EOF or read error, no matter how many
// over-long lines it meets along the way.
func readLine(r *bufio.Reader, maxLen int) (line []byte, tooLong bool, err error) {
	var buf []byte
	for {
		chunk, e := r.ReadSlice('\n')
		if len(chunk) > 0 && !tooLong {
			if len(buf)+len(chunk) > maxLen {
				tooLong = true
				buf = nil
			} else {
				buf = append(buf, chunk...)
			}
		}
		switch e {
		case nil:
			// Delimiter found; chunk's tail is '\n'.
			if tooLong {
				return nil, true, nil
			}
			return trimNewline(buf), false, nil
		case bufio.ErrBufferFull:
			continue
		default:
			// Real read error or EOF: no more data will arrive for this line.
			if tooLong {
				return nil, true, e
			}
			return trimNewline(buf), false, e
		}
	}
}

// trimNewline strips a single trailing "\n" or "\r\n".
func trimNewline(b []byte) []byte {
	if n := len(b); n > 0 && b[n-1] == '\n' {
		b = b[:n-1]
	}
	if n := len(b); n > 0 && b[n-1] == '\r' {
		b = b[:n-1]
	}
	return b
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

	// The CLI never echoes what we send it, so without this the user's own
	// half of the conversation never appears — not live, not on replay.
	// Published before the stdin write (and well after s.mu was released
	// above) so it lands in the buffer even if the write itself fails.
	s.publish(ChatEvent{
		Kind: EventUserText,
		TS:   time.Now().UTC().Format(time.RFC3339),
		Text: text,
	})

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

// signalGroup sends sig to cmd's whole process group (the negative pid),
// which also reaches tool subprocesses (e.g. a running Bash call) started
// under it — see the Setpgid: true set at spawn. It falls back to signalling
// just the process if the group send fails (e.g. the group already reaped).
func signalGroup(cmd *exec.Cmd, sig syscall.Signal) {
	if cmd == nil || cmd.Process == nil {
		return
	}
	if err := syscall.Kill(-cmd.Process.Pid, sig); err != nil {
		_ = cmd.Process.Signal(sig)
	}
}

// interruptThenKill sends SIGINT to cmd's process group now, and schedules a
// SIGKILL to the same group after interruptGrace. SIGINT (not SIGKILL) is
// what gives the CLI a chance to flush the transcript --resume depends on;
// the delayed SIGKILL is only the fallback for a process that does not
// respond to it. This never blocks: the escalation is scheduled, not waited
// for, so callers holding no lock or a lock across this call are both safe.
func interruptThenKill(cmd *exec.Cmd) {
	if cmd == nil || cmd.Process == nil {
		return
	}
	signalGroup(cmd, syscall.SIGINT)
	time.AfterFunc(interruptGrace, func() { signalGroup(cmd, syscall.SIGKILL) })
}

// Interrupt stops the current turn. It clears the process handles itself,
// under s.mu, immediately after signalling — it does not wait for readStdout
// to notice the exit. This makes the next Send deterministically see a nil
// s.cmd and respawn with --resume, instead of racing the reader goroutine's
// cleanup. readStdout's identity check (`if s.cmd == cmd`) then simply finds
// a mismatch here and skips its own clear, so cmd.Wait() is still only ever
// called once, from readStdout.
//
// A killed process emits no `result` line, so nothing else would ever
// produce a turn_end for this turn — the client's "working" state would
// never clear. Interrupt publishes a synthetic one itself, agent-side, after
// releasing s.mu (never call publish while holding it — see Send), so it
// lands in the buffer and replays correctly for any client, not just the one
// that tapped Stop.
func (s *ChatSession) Interrupt() {
	s.mu.Lock()
	cmd := s.cmd
	if s.cmd == cmd {
		s.cmd = nil
		s.stdin = nil
	}
	if cmd != nil && cmd.Process != nil {
		// Record which process readStdout should treat as agent-initiated,
		// so its eventual non-zero cmd.Wait() does not surface as an
		// `error` event — see the field comment on s.interrupting.
		if s.interrupting == nil {
			s.interrupting = make(map[*exec.Cmd]struct{}, 1)
		}
		s.interrupting[cmd] = struct{}{}
	}
	s.mu.Unlock()

	if cmd == nil || cmd.Process == nil {
		return
	}

	interruptThenKill(cmd)

	s.publish(ChatEvent{
		Kind:       EventTurnEnd,
		TS:         time.Now().UTC().Format(time.RFC3339),
		StopReason: "interrupted",
	})
}

// History returns retained events newer than afterSeq, for client replay.
func (s *ChatSession) History(afterSeq uint64) []ChatEvent {
	return s.buf.Since(afterSeq)
}

// HistoryPage returns a byte-budgeted page of retained events newer than
// afterSeq, plus the seq the caller should request from next. See
// ChatBuffer.SincePage.
func (s *ChatSession) HistoryPage(afterSeq uint64, maxBytes int) ([]ChatEvent, uint64) {
	return s.buf.SincePage(afterSeq, maxBytes)
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
	if cmd != nil && cmd.Process != nil {
		// Close also deliberately terminates whatever process is running —
		// see Interrupt's comment on s.interrupting for why this must be
		// recorded before signalling.
		if s.interrupting == nil {
			s.interrupting = make(map[*exec.Cmd]struct{}, 1)
		}
		s.interrupting[cmd] = struct{}{}
	}
	s.mu.Unlock()

	if stdin != nil {
		_ = stdin.Close()
	}
	interruptThenKill(cmd)
	if reaping == 0 {
		s.doneOnce.Do(func() { close(s.doneCh) })
	}
}

func (s *ChatSession) Done() <-chan struct{} { return s.doneCh }
