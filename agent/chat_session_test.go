package agent

import (
	"fmt"
	"os"
	"path/filepath"
	"sync"
	"syscall"
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
	want := []ChatEventKind{EventUserText, EventTurnStart, EventText, EventTurnEnd}
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

// TestChatSessionSendPublishesUserText is the regression test for review
// Finding 2: the CLI never echoes what we send it, so without an explicit
// user_text event the user's own half of the conversation never appears —
// not live, not on replay.
func TestChatSessionSendPublishesUserText(t *testing.T) {
	emit, read := collectEvents()
	s := NewChatSession("sid", t.TempDir(), "", emit)
	s.Bin = fakeClaude(t)
	defer s.Close()

	if err := s.Send("hello there"); err != nil {
		t.Fatalf("send: %v", err)
	}
	waitFor(t, read, EventTurnEnd)

	evs := read()
	if len(evs) == 0 || evs[0].Kind != EventUserText {
		t.Fatalf("expected user_text as the first published event, got %+v", evs)
	}
	if evs[0].Text != "hello there" {
		t.Fatalf("user_text.Text = %q, want %q", evs[0].Text, "hello there")
	}
}

// TestChatSessionInterruptPublishesSyntheticTurnEnd is the regression test
// for review Finding 1 (Critical): a killed process emits no `result` line,
// so nothing else would ever produce a turn_end for the interrupted turn —
// the iOS client only clears its "working" state on turn_end, so the
// composer would show Stop forever. Interrupt must publish one itself.
func TestChatSessionInterruptPublishesSyntheticTurnEnd(t *testing.T) {
	emit, read := collectEvents()
	s := NewChatSession("sid", t.TempDir(), "", emit)
	s.Bin = fakeClaude(t)
	defer s.Close()

	if err := s.Send("hello"); err != nil {
		t.Fatalf("send: %v", err)
	}
	waitFor(t, read, EventTurnEnd) // the real turn completes normally first

	s.Interrupt()

	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		for _, e := range read() {
			if e.Kind == EventTurnEnd && e.StopReason == "interrupted" {
				return
			}
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatalf("expected a synthetic interrupted turn_end from Interrupt(); got %+v", read())
}

// TestChatSessionInterruptDoesNotPublishExitError is the regression test for
// Defect 2 of the post-wave fix: SIGINT makes cmd.Wait() in readStdout
// return a non-nil error ("signal: interrupt", or a 130 exit), which used to
// be published unconditionally as an `error` event — indistinguishable, on
// the client, from a genuine crash and rendered as a sticky red banner. So
// pressing Stop, a normal and deliberate action, looked like a failure.
// Interrupt must still produce its synthetic interrupted turn_end (so the
// composer unlocks), but must not also publish an error for the exit that
// interrupt itself caused.
func TestChatSessionInterruptDoesNotPublishExitError(t *testing.T) {
	emit, read := collectEvents()
	s := NewChatSession("sid", t.TempDir(), "", emit)
	s.Bin = fakeClaude(t)

	if err := s.Send("hello"); err != nil {
		t.Fatalf("send: %v", err)
	}
	waitFor(t, read, EventTurnEnd) // the real turn completes normally first

	s.Interrupt()

	deadline := time.Now().Add(5 * time.Second)
	var sawInterruptedTurnEnd bool
	for time.Now().Before(deadline) && !sawInterruptedTurnEnd {
		for _, e := range read() {
			if e.Kind == EventTurnEnd && e.StopReason == "interrupted" {
				sawInterruptedTurnEnd = true
				break
			}
		}
		if !sawInterruptedTurnEnd {
			time.Sleep(10 * time.Millisecond)
		}
	}
	if !sawInterruptedTurnEnd {
		t.Fatalf("expected a synthetic interrupted turn_end from Interrupt(); got %+v", read())
	}

	// Close and wait for Done(): that forces this test to observe the
	// interrupted process actually being cmd.Wait()-ed on by readStdout —
	// exactly where a wrongly-published exit error would appear — before
	// checking for its absence, rather than racing that goroutine.
	s.Close()
	select {
	case <-s.Done():
	case <-time.After(5 * time.Second):
		t.Fatal("Done() never fired after Interrupt then Close")
	}

	for _, e := range read() {
		if e.Kind == EventError {
			t.Fatalf("unexpected error event after an agent-initiated interrupt: %+v", e)
		}
	}
}

// TestChatSessionNonZeroExitNotFollowingInterruptStillPublishesError is the
// companion case to TestChatSessionInterruptDoesNotPublishExitError, guarding
// against the fix overreaching: a process that exits non-zero on its own —
// not as a result of an Interrupt/Close the agent itself initiated — must
// still surface an error event. (TestChatSessionNonZeroExitSurfacesError
// below already exercises this same path; this test names it explicitly as
// the "genuine exit" half of the Defect 2 pair.)
func TestChatSessionNonZeroExitNotFollowingInterruptStillPublishesError(t *testing.T) {
	t.Setenv("FAKE_CLAUDE_MODE", "exit1")
	emit, read := collectEvents()
	s := NewChatSession("sid", t.TempDir(), "", emit)
	s.Bin = fakeClaude(t)
	defer s.Close()

	if err := s.Send("hello"); err != nil {
		t.Fatalf("send: %v", err)
	}

	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		for _, e := range read() {
			if e.Kind == EventError {
				return
			}
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatalf("expected an error event on a genuine non-zero exit unrelated to Interrupt/Close; got %+v", read())
}

// TestChatSessionInterruptWithNoProcessIsNoop confirms Interrupt does not
// fabricate a turn_end when there is nothing running to interrupt.
func TestChatSessionInterruptWithNoProcessIsNoop(t *testing.T) {
	emit, read := collectEvents()
	s := NewChatSession("sid", t.TempDir(), "", emit)
	s.Bin = fakeClaude(t) // never invoked: Send is never called
	defer s.Close()

	s.Interrupt()

	time.Sleep(50 * time.Millisecond)
	for _, e := range read() {
		if e.Kind == EventTurnEnd {
			t.Fatalf("unexpected turn_end with no process ever started: %+v", e)
		}
	}
}

// TestChatSessionInterruptSendsSIGINTNotSIGKILL is the regression test for
// review Finding 6: SIGKILL denies the CLI any chance to flush the
// transcript that --resume depends on, so Interrupt must use SIGINT. The
// fake claude here traps SIGINT and emits its own clean turn_end from the
// trap; SIGKILL cannot be trapped, so if Interrupt sent SIGKILL this test
// would time out instead of observing that turn_end.
func TestChatSessionInterruptSendsSIGINTNotSIGKILL(t *testing.T) {
	t.Setenv("FAKE_CLAUDE_MODE", "trapsigint")
	emit, read := collectEvents()
	s := NewChatSession("sid", t.TempDir(), "", emit)
	s.Bin = fakeClaude(t)
	defer s.Close()

	if err := s.Send("hello"); err != nil {
		t.Fatalf("send: %v", err)
	}
	waitFor(t, read, EventTurnStart)

	s.Interrupt()

	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		for _, e := range read() {
			if e.Kind == EventTurnEnd && e.StopReason == "end_turn" {
				return
			}
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatalf("expected the fake claude's SIGINT trap to fire (proves SIGINT, not SIGKILL, was sent); got %+v", read())
}

// TestChatSessionInterruptSignalsWholeProcessGroup is the regression test
// for the other half of review Finding 6: without Setpgid + a group signal,
// a running tool subprocess (e.g. Bash) is orphaned on interrupt because only
// the immediate child is signalled. The fake claude here forks a detached
// long-sleeping "tool" child and records its pid; if Interrupt only signals
// cmd.Process, that child outlives it.
func TestChatSessionInterruptSignalsWholeProcessGroup(t *testing.T) {
	t.Setenv("FAKE_CLAUDE_MODE", "spawnchild")
	pidFile := filepath.Join(t.TempDir(), "child.pid")
	t.Setenv("FAKE_CLAUDE_CHILD_PIDFILE", pidFile)

	emit, read := collectEvents()
	s := NewChatSession("sid", t.TempDir(), "", emit)
	s.Bin = fakeClaude(t)
	defer s.Close()

	if err := s.Send("hello"); err != nil {
		t.Fatalf("send: %v", err)
	}
	waitFor(t, read, EventTurnStart)

	var childPID int
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) && childPID == 0 {
		if data, err := os.ReadFile(pidFile); err == nil && len(data) > 0 {
			fmt.Sscanf(string(data), "%d", &childPID)
		}
		time.Sleep(10 * time.Millisecond)
	}
	if childPID == 0 {
		t.Fatal("fake claude never recorded its child pid")
	}

	s.Interrupt()

	deadline = time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		if syscall.Kill(childPID, 0) != nil {
			return // ESRCH: the child is gone — the whole group was signalled
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatalf("child pid %d outlived Interrupt(); process group was not signalled", childPID)
}

// TestChatSessionSurvivesOverlongLine is the regression test for review
// Finding 3 (Critical): on bufio.ErrTooLong, the old code's scan loop
// exited and cmd.Wait() was called while the child was still alive with
// nobody draining stdout — the child then blocks on a full pipe and Wait
// never returns. readLine must skip the offending line, publish an error,
// and keep draining so a well-formed turn after it still arrives and the
// session still reaches Done().
func TestChatSessionSurvivesOverlongLine(t *testing.T) {
	t.Setenv("FAKE_CLAUDE_MODE", "longline")
	emit, read := collectEvents()
	s := NewChatSession("sid", t.TempDir(), "", emit)
	s.Bin = fakeClaude(t)

	if err := s.Send("hello"); err != nil {
		t.Fatalf("send: %v", err)
	}

	evs := waitFor(t, read, EventTurnEnd) // must arrive despite the huge line before it

	var haveError bool
	for _, e := range evs {
		if e.Kind == EventError {
			haveError = true
		}
	}
	if !haveError {
		t.Fatalf("expected an error event for the over-long line; got %+v", evs)
	}

	s.Close()
	select {
	case <-s.Done():
	case <-time.After(5 * time.Second):
		t.Fatal("Done() never fired after an over-long stdout line — stdout draining wedged")
	}
}

// TestChatSessionNonZeroExitSurfacesError is the regression test for review
// Finding 4 (first half): the old code discarded cmd.Wait()'s result
// entirely, so a crashed process was silent. Spec §11 requires an error
// event plus a server-side log.
func TestChatSessionNonZeroExitSurfacesError(t *testing.T) {
	t.Setenv("FAKE_CLAUDE_MODE", "exit1")
	emit, read := collectEvents()
	s := NewChatSession("sid", t.TempDir(), "", emit)
	s.Bin = fakeClaude(t)
	defer s.Close()

	if err := s.Send("hello"); err != nil {
		t.Fatalf("send: %v", err)
	}

	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		for _, e := range read() {
			if e.Kind == EventError {
				return
			}
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatalf("expected an error event on non-zero exit; got %+v", read())
}

// TestChatSessionDoesNotPoisonSessionOnInstantDeath is the regression test
// for review Finding 4 (second half, the more serious one): the old code set
// s.started = true as soon as cmd.Start() succeeded. A process that starts
// and immediately dies before ever creating the session (expired auth, a bad
// --model, quota exhaustion) would then flip every later spawn to
// --resume <id> for a conversation the CLI never created — a dead session
// with no error and no recovery. started must only flip once a spawned
// process has proven the session actually exists, i.e. after its first
// successfully translated system/init line.
func TestChatSessionDoesNotPoisonSessionOnInstantDeath(t *testing.T) {
	t.Setenv("FAKE_CLAUDE_MODE", "deadonarrival")
	emit, read := collectEvents()
	s := NewChatSession("sid", t.TempDir(), "", emit)
	s.Bin = fakeClaude(t)
	defer s.Close()

	if err := s.Send("hello"); err != nil {
		t.Fatalf("send: %v", err)
	}

	deadline := time.Now().Add(5 * time.Second)
	var sawError bool
	for time.Now().Before(deadline) && !sawError {
		for _, e := range read() {
			if e.Kind == EventError {
				sawError = true
				break
			}
		}
		if !sawError {
			time.Sleep(10 * time.Millisecond)
		}
	}
	if !sawError {
		t.Fatalf("expected an error event; got %+v", read())
	}

	s.mu.Lock()
	started := s.started
	args := s.args()
	s.mu.Unlock()

	if started {
		t.Fatal("started must stay false — the process died before ever creating the session")
	}
	for _, a := range args {
		if a == "--resume" {
			t.Fatalf("next spawn must use --session-id, not --resume, on an unpoisoned session: args=%v", args)
		}
	}
}
