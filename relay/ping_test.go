package relay

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"nhooyr.io/websocket"
)

// TestRunPingWatchdog_HungClientDoesNotBlockForever is the load-bearing
// regression test for this fix: it is the relay-side twin of the agent's own
// regression test for commit 645ccc1 (agent/ws_client_ping_test.go). The
// relay's ping goroutine for client connections used to hand conn.Ping the
// connection's own context directly — a context with no deadline of its own.
// A client that stops responding (a phone that locks or suspends mid-session
// is the everyday version of this; the agent's version was a Mac going to
// sleep) never sends a pong back, so Ping — and the goroutine calling it —
// blocked forever.
//
// This test plays the relay's real role: an httptest server Accepts the
// WebSocket exactly as HandleClientWS does, then runs runPingWatchdog against
// the accepted connection using r.Context() — the same context HandleClientWS
// itself uses, with no deadline of its own. The "client" is a real dialed
// connection that, after the handshake, never calls Read again.
// nhooyr.io/websocket only answers incoming Ping control frames as a side
// effect of the peer's own Read loop, so a client that stops reading never
// answers a ping — a faithful simulation of a suspended phone, not a mock of
// one.
//
// Confirmed this test catches the bug it targets: temporarily changing the
// pingCtx line back to conn.Ping(ctx) (the pre-fix shape, reusing the
// undeadlined connection context directly) makes this test hang past its 3s
// assertion bound and fail with "ping watchdog did not give up ... against a
// hung client" — it does not return on its own, because ctx here is only
// ever cancelled when the httptest handler returns, which this test
// deliberately withholds until the watchdog itself finishes.
func TestRunPingWatchdog_HungClientDoesNotBlockForever(t *testing.T) {
	const (
		interval = 50 * time.Millisecond
		timeout  = 200 * time.Millisecond
		bound    = 3 * time.Second
	)

	watchdogDone := make(chan struct{})
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		conn, err := websocket.Accept(w, r, nil)
		if err != nil {
			return
		}
		defer conn.Close(websocket.StatusNormalClosure, "")
		go func() {
			runPingWatchdog(r.Context(), conn, interval, timeout)
			close(watchdogDone)
		}()
		// Keep the handler (and its accepted conn) alive until the watchdog
		// gives up on its own — exactly like HandleClientWS, whose read loop
		// keeps the request alive independently of the ping goroutine.
		<-watchdogDone
	}))
	defer srv.Close()

	dialCtx, cancelDial := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancelDial()
	wsURL := "ws" + strings.TrimPrefix(srv.URL, "http")
	conn, _, err := websocket.Dial(dialCtx, wsURL, nil)
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	// Deliberately never Read again after the handshake — simulates a client
	// that suspended (e.g. a phone locking) and stops servicing pings.
	// CloseNow, not Close: a graceful close would wait on a close-handshake
	// reply from this deliberately-unresponsive test peer.
	defer conn.CloseNow()

	select {
	case <-watchdogDone:
		// Good: a ping against the unresponsive client failed inside its own
		// bounded context and the watchdog returned instead of hanging.
	case <-time.After(bound):
		t.Fatalf("ping watchdog did not give up within %v against a hung client — the suspended-client hang is back", bound)
	}
}

// fakePinger lets runPingWatchdog be exercised without any real networking:
// its Ping blocks until its context is done, then reports that context's
// error — mirroring exactly what nhooyr.io/websocket's Conn.Ping does
// against a peer that never answers.
type fakePinger struct {
	calls int
}

func (f *fakePinger) Ping(ctx context.Context) error {
	f.calls++
	<-ctx.Done()
	return ctx.Err()
}

// TestRunPingWatchdog_BoundsEachPingIndividually is a fast, network-free
// companion to the hang test above: it proves the watchdog derives each
// ping's context from the interval/timeout it was given, not from the
// long-lived connection context, by observing that it gives up in roughly
// `timeout`, not "never" and not instantly.
func TestRunPingWatchdog_BoundsEachPingIndividually(t *testing.T) {
	p := &fakePinger{}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	const (
		interval = 10 * time.Millisecond
		timeout  = 100 * time.Millisecond
	)

	start := time.Now()
	done := make(chan struct{})
	go func() {
		runPingWatchdog(ctx, p, interval, timeout)
		close(done)
	}()

	select {
	case <-done:
	case <-time.After(2 * time.Second):
		t.Fatal("watchdog never returned")
	}
	elapsed := time.Since(start)

	if p.calls != 1 {
		t.Errorf("expected exactly one ping attempt before giving up, got %d", p.calls)
	}
	// Should give up close to `timeout` (bounded by the ping's own deadline),
	// not hang around for multiples of it and not return suspiciously fast.
	if elapsed < timeout/2 {
		t.Errorf("watchdog returned too fast (%v) — did it even wait for the ping?", elapsed)
	}
	if elapsed > 2*time.Second {
		t.Errorf("watchdog took %v to give up on a %v ping timeout", elapsed, timeout)
	}
}

// TestRunPingWatchdog_ExitsOnParentContextDone verifies clean shutdown: when
// the parent context is cancelled (the client connection tearing down for
// any other reason), the watchdog must not need a ping failure to notice —
// it should return promptly without attempting a ping at all.
func TestRunPingWatchdog_ExitsOnParentContextDone(t *testing.T) {
	p := &fakePinger{}
	ctx, cancel := context.WithCancel(context.Background())

	done := make(chan struct{})
	go func() {
		runPingWatchdog(ctx, p, time.Hour, time.Hour)
		close(done)
	}()

	cancel() // simulate the connection tearing down before any ticker fires

	select {
	case <-done:
	case <-time.After(1 * time.Second):
		t.Fatal("watchdog did not exit promptly when its context was cancelled")
	}
	if p.calls != 0 {
		t.Errorf("no ping should have been attempted, got %d calls", p.calls)
	}
}
