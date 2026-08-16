package agent

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"nhooyr.io/websocket"
)

// TestRunPingWatchdog_HungPeerDoesNotBlockForever is the load-bearing
// regression test for the sleep/wake reconnect hang: a Mac agent that pings a
// peer which stopped reading (a half-open socket — exactly what a sleeping
// laptop leaves behind) must give up within a bounded time, not hang inside
// Conn.Ping forever.
//
// The test server accepts the WebSocket handshake and then never calls
// Read/Ping-handling again, so no pong is ever sent back — nhooyr.io/websocket
// only services incoming control frames as a side effect of Read. That is a
// faithful simulation of a half-open connection: the TCP handshake succeeded,
// bytes can still be written into the socket without an immediate error, but
// nothing ever answers.
//
// Confirmed this test catches the bug it targets: reverting runPingWatchdog's
// pingCtx to reuse ctx directly (i.e. conn.Ping(ctx) instead of a per-ping
// bounded context — the pre-fix shape) makes this test hang past its 3s
// assertion bound and fail with "ping watchdog did not exit in time"; it
// never returns on its own because ctx here is only cancelled by the
// assertion's own cleanup, not by anything the watchdog does.
func TestRunPingWatchdog_HungPeerDoesNotBlockForever(t *testing.T) {
	accepted := make(chan struct{})
	// releaseServer lets the test unblock the handler as soon as its
	// assertions are done, instead of relying on httptest's own (multi-second)
	// shutdown timeout to reclaim a handler goroutine that never reads.
	releaseServer := make(chan struct{})
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		conn, err := websocket.Accept(w, r, nil)
		if err != nil {
			return
		}
		close(accepted)
		// Deliberately never Read/Ping again — simulates a half-open peer
		// (e.g. a Mac that went to sleep mid-connection).
		<-releaseServer
		conn.Close(websocket.StatusInternalError, "test teardown")
	}))
	defer srv.Close()
	defer close(releaseServer)

	dialCtx, cancelDial := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancelDial()
	wsURL := "ws" + strings.TrimPrefix(srv.URL, "http")
	conn, _, err := websocket.Dial(dialCtx, wsURL, nil)
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	// CloseNow, not Close: the server-side handler deliberately never reads,
	// so a graceful Close (which waits for the peer's close-handshake reply)
	// would itself hang for nhooyr's default grace period. That is a property
	// of this deliberately-unresponsive test peer, not of the code under
	// test, so tear down the client side unilaterally.
	defer conn.CloseNow()

	select {
	case <-accepted:
	case <-time.After(2 * time.Second):
		t.Fatal("server never accepted the handshake")
	}

	// connCtx has no deadline of its own — same shape as the real connect()
	// loop. If runPingWatchdog handed this ctx straight to conn.Ping instead
	// of bounding each ping individually, Ping would block until connCtx is
	// cancelled — which only happens via cancelConn, which only the watchdog
	// itself calls. That circularity is the bug.
	connCtx, cancelConn := context.WithCancel(context.Background())
	defer cancelConn()

	const (
		interval = 50 * time.Millisecond
		timeout  = 200 * time.Millisecond
	)

	watchdogDone := make(chan struct{})
	go func() {
		runPingWatchdog(connCtx, conn, interval, timeout, cancelConn)
		close(watchdogDone)
	}()

	const bound = 3 * time.Second
	select {
	case <-watchdogDone:
		// Good: a ping against the unresponsive peer failed inside its own
		// bounded context, the watchdog called cancelConn, and returned.
	case <-time.After(bound):
		t.Fatalf("ping watchdog did not exit within %v against a hung peer — the sleep/wake hang is back", bound)
	}

	if connCtx.Err() == nil {
		t.Fatal("expected connCtx to be cancelled after a ping against a hung peer failed")
	}
}

// fakePinger lets runPingWatchdog be exercised without any real networking:
// its Ping blocks until its context is done, then reports that context's
// error — mirroring exactly what nhooyr.io/websocket's Conn.Ping does against
// a peer that never answers.
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
	connCtx, cancelConn := context.WithCancel(context.Background())
	defer cancelConn()

	const (
		interval = 10 * time.Millisecond
		timeout  = 100 * time.Millisecond
	)

	start := time.Now()
	done := make(chan struct{})
	go func() {
		runPingWatchdog(connCtx, p, interval, timeout, cancelConn)
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
	if connCtx.Err() == nil {
		t.Fatal("expected connCtx to be cancelled once the ping failed")
	}
}

// TestRunPingWatchdog_ExitsOnParentContextDone verifies clean shutdown: when
// the parent context is cancelled (agent shutting down, or the read loop
// already tore the connection down), the watchdog must not need a ping
// failure to notice — it should return promptly.
func TestRunPingWatchdog_ExitsOnParentContextDone(t *testing.T) {
	p := &fakePinger{}
	connCtx, cancelConn := context.WithCancel(context.Background())

	done := make(chan struct{})
	go func() {
		runPingWatchdog(connCtx, p, time.Hour, time.Hour, cancelConn)
		close(done)
	}()

	cancelConn() // simulate shutdown/read-loop-exit before any ticker fires

	select {
	case <-done:
	case <-time.After(1 * time.Second):
		t.Fatal("watchdog did not exit promptly when its context was cancelled")
	}
	if p.calls != 0 {
		t.Errorf("no ping should have been attempted, got %d calls", p.calls)
	}
}
