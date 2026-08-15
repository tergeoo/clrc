package agent

import (
	"os"
	"path/filepath"
	"sync"
	"testing"
	"time"
)

// collectEvents returns an emit fn plus a getter, for asserting on what a
// session produced without racing the reader goroutine.
func collectEvents() (func(string, []ChatEvent), func() []ChatEvent) {
	var mu sync.Mutex
	var got []ChatEvent
	emit := func(_ string, evs []ChatEvent) {
		mu.Lock()
		defer mu.Unlock()
		got = append(got, evs...)
	}
	read := func() []ChatEvent {
		mu.Lock()
		defer mu.Unlock()
		out := make([]ChatEvent, len(got))
		copy(out, got)
		return out
	}
	return emit, read
}

func fakeClaude(t *testing.T) string {
	t.Helper()
	abs, err := filepath.Abs("testdata/fake_claude.sh")
	if err != nil {
		t.Fatalf("resolve fake claude: %v", err)
	}
	if _, err := os.Stat(abs); err != nil {
		t.Fatalf("fake claude missing: %v", err)
	}
	return abs
}

func waitFor(t *testing.T, read func() []ChatEvent, kind ChatEventKind) []ChatEvent {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		evs := read()
		for _, e := range evs {
			if e.Kind == kind {
				return evs
			}
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatalf("timed out waiting for %q; got %+v", kind, read())
	return nil
}

func TestChatSessionSendProducesNormalisedTurn(t *testing.T) {
	emit, read := collectEvents()
	s := NewChatSession("sid", t.TempDir(), "", emit)
	s.Bin = fakeClaude(t)
	defer s.Close()

	if err := s.Send("hello"); err != nil {
		t.Fatalf("send: %v", err)
	}

	evs := waitFor(t, read, EventTurnEnd)

	var kinds []ChatEventKind
	for _, e := range evs {
		kinds = append(kinds, e.Kind)
	}
	want := []ChatEventKind{EventTurnStart, EventText, EventTurnEnd}
	if len(kinds) != len(want) {
		t.Fatalf("kinds = %v, want %v (noise must be filtered)", kinds, want)
	}
	for i := range want {
		if kinds[i] != want[i] {
			t.Fatalf("kinds = %v, want %v", kinds, want)
		}
	}
	for i, e := range evs {
		if e.Seq != uint64(i+1) {
			t.Fatalf("event %d has seq %d, want %d", i, e.Seq, i+1)
		}
	}
}

func TestChatSessionHistoryReplaysTail(t *testing.T) {
	emit, read := collectEvents()
	s := NewChatSession("sid", t.TempDir(), "", emit)
	s.Bin = fakeClaude(t)
	defer s.Close()

	if err := s.Send("hello"); err != nil {
		t.Fatalf("send: %v", err)
	}
	waitFor(t, read, EventTurnEnd)

	tail := s.History(1)
	if len(tail) == 0 {
		t.Fatal("History(1) returned nothing")
	}
	for _, e := range tail {
		if e.Seq <= 1 {
			t.Fatalf("History(1) leaked seq %d", e.Seq)
		}
	}
}

func TestChatSessionSurvivesMalformedLine(t *testing.T) {
	t.Setenv("FAKE_CLAUDE_MODE", "badline")
	emit, read := collectEvents()
	s := NewChatSession("sid", t.TempDir(), "", emit)
	s.Bin = fakeClaude(t)
	defer s.Close()

	if err := s.Send("hello"); err != nil {
		t.Fatalf("send: %v", err)
	}
	waitFor(t, read, EventTurnEnd) // a junk line must not abort the turn
}

func TestChatSessionRejectsMissingBinary(t *testing.T) {
	emit, read := collectEvents()
	s := NewChatSession("sid", t.TempDir(), "", emit)
	s.Bin = "/nonexistent/claude-binary"
	defer s.Close()

	_ = s.Send("hello")

	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		for _, e := range read() {
			if e.Kind == EventError {
				return
			}
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatal("expected an error event when the binary is missing")
}

func TestChatSessionRespawnsAfterProcessExit(t *testing.T) {
	emit, read := collectEvents()
	s := NewChatSession("sid", t.TempDir(), "", emit)
	s.Bin = fakeClaude(t)
	defer s.Close()

	if err := s.Send("first"); err != nil {
		t.Fatalf("send: %v", err)
	}
	waitFor(t, read, EventTurnEnd)

	s.Interrupt() // kills the process and deterministically clears s.cmd/s.stdin
	time.Sleep(10 * time.Millisecond)

	if err := s.Send("second"); err != nil {
		t.Fatalf("second send after interrupt: %v", err)
	}

	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		var ends int
		for _, e := range read() {
			if e.Kind == EventTurnEnd {
				ends++
			}
		}
		if ends >= 2 {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatalf("expected a second turn after respawn; got %+v", read())
}

// TestChatSessionInterruptThenCloseWaitsForReap is the regression test for
// fix round 2: Interrupt clears s.cmd/s.stdin immediately (so the next Send
// respawns), well before the interrupted process is actually Wait()-ed on.
// Close must not mistake that early clearing for "nothing outstanding" and
// close Done() before the process is actually reaped — it must gate on the
// internal reaping counter, not on s.cmd == nil. We assert the invariant
// directly (white-box, same package): whenever Done() is observed closed,
// s.reaping must already be 0. This is race-safe rather than a timing guess:
// in the implementation, reaping reaches 0 strictly before doneCh is closed
// (both happen under s.mu, in that order, before the close call happens
// outside the lock), so this ordering can never be observed backwards by a
// correct implementation.
func TestChatSessionInterruptThenCloseWaitsForReap(t *testing.T) {
	emit, read := collectEvents()
	s := NewChatSession("sid", t.TempDir(), "", emit)
	s.Bin = fakeClaude(t)

	if err := s.Send("hello"); err != nil {
		t.Fatalf("send: %v", err)
	}
	waitFor(t, read, EventTurnEnd)

	s.Interrupt() // process killed but not yet reaped
	s.Close()     // must not close Done() until the kill is actually reaped

	deadline := time.Now().Add(5 * time.Second)
	for {
		select {
		case <-s.Done():
			s.mu.Lock()
			reaping := s.reaping
			s.mu.Unlock()
			if reaping != 0 {
				t.Fatalf("Done() closed while reaping=%d; process not yet reaped", reaping)
			}
			return
		default:
		}
		if time.Now().After(deadline) {
			t.Fatal("timed out waiting for Done() after Interrupt then Close")
		}
		time.Sleep(5 * time.Millisecond)
	}
}

// TestChatSessionInterruptThenSendThenCloseWaitsForBothReaps covers the case
// that motivates using a counter (not a bool) for s.reaping: Interrupt
// leaves one process draining in the background, then Send respawns a
// second one, so two processes can be outstanding at once. Close must wait
// for both to be reaped before firing Done().
func TestChatSessionInterruptThenSendThenCloseWaitsForBothReaps(t *testing.T) {
	emit, read := collectEvents()
	s := NewChatSession("sid", t.TempDir(), "", emit)
	s.Bin = fakeClaude(t)

	if err := s.Send("first"); err != nil {
		t.Fatalf("first send: %v", err)
	}
	waitFor(t, read, EventTurnEnd)

	s.Interrupt() // first process killed, not yet reaped

	if err := s.Send("second"); err != nil {
		t.Fatalf("second send after interrupt: %v", err)
	}
	s.Close() // closes mid-flight: both the old and new process may be outstanding

	deadline := time.Now().Add(5 * time.Second)
	for {
		select {
		case <-s.Done():
			s.mu.Lock()
			reaping := s.reaping
			s.mu.Unlock()
			if reaping != 0 {
				t.Fatalf("Done() closed while reaping=%d; a process was not yet reaped", reaping)
			}
			return
		default:
		}
		if time.Now().After(deadline) {
			t.Fatal("timed out waiting for Done() after interrupt, send, close")
		}
		time.Sleep(5 * time.Millisecond)
	}
}

// TestChatSessionCloseNeverStartedClosesImmediately covers the path where
// Close is called on a session whose process was never spawned: there is
// nothing to reap, so Done() must close synchronously within Close, not
// hang waiting for a reader goroutine that was never started.
func TestChatSessionCloseNeverStartedClosesImmediately(t *testing.T) {
	emit, _ := collectEvents()
	s := NewChatSession("sid", t.TempDir(), "", emit)
	s.Bin = fakeClaude(t) // never invoked: Send is never called

	s.Close()

	select {
	case <-s.Done():
	default:
		t.Fatal("Close() on a never-started session must close Done() immediately")
	}
}

// TestChatSessionDoubleCloseIsSafe confirms a second Close() is a safe
// no-op: it must not panic (closing an already-closed channel panics) and
// must not hang.
func TestChatSessionDoubleCloseIsSafe(t *testing.T) {
	emit, read := collectEvents()
	s := NewChatSession("sid", t.TempDir(), "", emit)
	s.Bin = fakeClaude(t)

	if err := s.Send("hello"); err != nil {
		t.Fatalf("send: %v", err)
	}
	waitFor(t, read, EventTurnEnd)

	s.Close()
	select {
	case <-s.Done():
	case <-time.After(5 * time.Second):
		t.Fatal("Done() never closed after first Close()")
	}

	s.Close() // must be a safe no-op
}
