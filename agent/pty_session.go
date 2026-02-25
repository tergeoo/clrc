package main

import (
	"encoding/binary"
	"io"
	"log"
	"os"
	"os/exec"
	"sync"

	"github.com/creack/pty"
)

// PTYSession manages a single pseudo-terminal process.
type PTYSession struct {
	ID     string
	Cols   uint16
	Rows   uint16
	ptm    *os.File
	cmd    *exec.Cmd
	doneCh chan struct{}
	once   sync.Once

	mu     sync.RWMutex
	sendFn func(sessionID string, data []byte) // nil = detached
}

// cleanEnv returns os.Environ() with Claude Code session variables stripped
// so that a nested `claude` invocation is not rejected.
func cleanEnv() []string {
	// Variables Claude Code sets to detect nested sessions.
	blocked := []string{
		"CLAUDE_",    // CLAUDE_CODE_ENTRYPOINT, CLAUDE_CODE_SESSION_ID, etc.
		"CLAUDECODE", // CLAUDECODE=1
	}
	var env []string
	for _, kv := range os.Environ() {
		skip := false
		for _, prefix := range blocked {
			if len(kv) >= len(prefix) && kv[:len(prefix)] == prefix {
				skip = true
				break
			}
		}
		if !skip {
			env = append(env, kv)
		}
	}
	return env
}

// NewPTYSession spawns a new PTY process and starts reading its output.
func NewPTYSession(id string, command string, cols, rows uint16, sendFn func(string, []byte)) (*PTYSession, error) {
	cmd := exec.Command(command)
	cmd.Env = cleanEnv()

	ptm, err := pty.StartWithSize(cmd, &pty.Winsize{Rows: rows, Cols: cols})
	if err != nil {
		return nil, err
	}

	s := &PTYSession{
		ID:     id,
		Cols:   cols,
		Rows:   rows,
		ptm:    ptm,
		cmd:    cmd,
		doneCh: make(chan struct{}),
		sendFn: sendFn,
	}

	go s.readLoop()
	return s, nil
}

// SetSendFn updates the output callback (nil = detach, suppress output).
func (s *PTYSession) SetSendFn(fn func(string, []byte)) {
	s.mu.Lock()
	s.sendFn = fn
	s.mu.Unlock()
}

// readLoop reads PTY output and forwards to sendFn (if set).
func (s *PTYSession) readLoop() {
	defer s.Close()
	buf := make([]byte, 4096)
	for {
		n, err := s.ptm.Read(buf)
		if n > 0 {
			data := make([]byte, n)
			copy(data, buf[:n])
			s.mu.RLock()
			fn := s.sendFn
			s.mu.RUnlock()
			if fn != nil {
				fn(s.ID, data)
			}
		}
		if err != nil {
			if err != io.EOF {
				log.Printf("PTY session %s read error: %v", s.ID, err)
			}
			break
		}
	}
}

// Write sends input bytes to the PTY (stdin of the process).
func (s *PTYSession) Write(data []byte) error {
	_, err := s.ptm.Write(data)
	return err
}

// Resize updates the PTY window size.
func (s *PTYSession) Resize(cols, rows uint16) {
	s.mu.Lock()
	s.Cols = cols
	s.Rows = rows
	s.mu.Unlock()
	pty.Setsize(s.ptm, &pty.Winsize{Rows: rows, Cols: cols})
}

// Close terminates the PTY session.
func (s *PTYSession) Close() {
	s.once.Do(func() {
		s.ptm.Close()
		s.cmd.Process.Kill()
		s.cmd.Wait()
		close(s.doneCh)
	})
}

// Done returns a channel that is closed when the session exits.
func (s *PTYSession) Done() <-chan struct{} {
	return s.doneCh
}

// encodeBinaryFrame creates the wire format: [4B sid_len][sid][data]
func encodeBinaryFrame(sessionID string, data []byte) []byte {
	sidBytes := []byte(sessionID)
	frame := make([]byte, 4+len(sidBytes)+len(data))
	binary.BigEndian.PutUint32(frame[:4], uint32(len(sidBytes)))
	copy(frame[4:], sidBytes)
	copy(frame[4+len(sidBytes):], data)
	return frame
}

// decodeBinaryFrame parses the wire format.
func decodeBinaryFrame(frame []byte) (string, []byte, bool) {
	if len(frame) < 4 {
		return "", nil, false
	}
	sidLen := binary.BigEndian.Uint32(frame[:4])
	if uint32(len(frame)) < 4+sidLen {
		return "", nil, false
	}
	sessionID := string(frame[4 : 4+sidLen])
	data := frame[4+sidLen:]
	return sessionID, data, true
}
