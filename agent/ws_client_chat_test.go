package agent

import (
	"encoding/json"
	"testing"
	"time"
)

func TestConnectReqDefaultsToPTYKind(t *testing.T) {
	var req connectReq
	if err := json.Unmarshal([]byte(`{"session_id":"s","cols":80,"rows":24}`), &req); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if req.Kind != "" {
		t.Fatalf("Kind = %q, want empty so it can default to pty", req.Kind)
	}
	if !req.isPTY() {
		t.Fatal("a connect with no kind must be treated as pty for backward compatibility")
	}
}

func TestConnectReqChatKind(t *testing.T) {
	var req connectReq
	body := `{"session_id":"s","kind":"chat","cwd":"~/proj","model":"m"}`
	if err := json.Unmarshal([]byte(body), &req); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if req.isPTY() {
		t.Fatal("kind=chat must not be treated as pty")
	}
	if req.Cwd != "~/proj" || req.Model != "m" {
		t.Fatalf("fields lost: %+v", req)
	}
}

// TestChatCleanupDoesNotOrphanReusedSessionID reproduces the race from
// review Finding 1: a chat session's cleanup goroutine wakes on Done() and
// used to delete chats[id] unconditionally. In production Done() can close
// well before that goroutine actually gets scheduled, so a fresh connect
// reusing the same session id (reattach-on-reconnect and restart-after-end
// both do this) can install a second session under that id before the first
// session's delayed cleanup runs — and the unconditional delete then removes
// the wrong (new) session.
//
// Driving this through the literal background goroutine from
// handleChatConnect is racy on the actual event ordering: this was verified
// experimentally against the pre-fix code (temporarily reverting
// removeChatIfCurrent to an unconditional delete and spawning the real
// goroutine) and it only reproduced the orphaning ~1/3 of the time — the
// synchronous map-write path in this test and the async
// process-exit-detection path in the goroutine are close enough in duration
// on this machine that either can "win". A test that only sometimes catches
// a real regression is worse than a deterministic one, so instead this test
// drives the exact sequence of events the finding describes directly and in
// order: delete + Close() s1 (mirroring handleDisconnect), wait for s1 to
// actually finish exiting, install s2 under the same id (mirroring a fresh
// connect), and only then invoke removeChatIfCurrent(id, s1) — the same call
// production's delayed goroutine makes. This exercises the identity-checked
// delete itself deterministically, at the smaller seam the task's fallback
// language allows, while still running a real (fake) claude process for s1
// so Done() reflects genuine process-exit semantics rather than a session
// that never started one.
func TestChatCleanupDoesNotOrphanReusedSessionID(t *testing.T) {
	const id = "reuse-id"
	c := &WSClient{chats: make(map[string]*ChatSession)}
	noop := func(string, []ChatEvent) {}

	s1 := NewChatSession(id, t.TempDir(), "", noop)
	s1.Bin = fakeClaude(t)
	if err := s1.Send("hello"); err != nil {
		t.Fatalf("send on s1: %v", err)
	}
	c.chats[id] = s1

	// Mirrors handleDisconnect: remove the entry, then close the session.
	c.mu.Lock()
	delete(c.chats, id)
	c.mu.Unlock()
	s1.Close()

	select {
	case <-s1.Done():
	case <-time.After(5 * time.Second):
		t.Fatal("s1 never became done")
	}

	// Mirrors a fresh connect landing before s1's delayed cleanup goroutine
	// actually gets scheduled: it finds no entry for the id and installs a
	// new session under the same id.
	s2 := NewChatSession(id, t.TempDir(), "", noop)
	defer s2.Close()
	c.mu.Lock()
	c.chats[id] = s2
	c.mu.Unlock()

	// s1's cleanup — delayed past the point above in production — now runs.
	// It must not delete the entry that now belongs to s2.
	c.removeChatIfCurrent(id, s1)

	c.mu.RLock()
	got := c.chats[id]
	c.mu.RUnlock()
	if got != s2 {
		t.Fatalf("cleanup for the old session orphaned the reused id %q: map holds %v, want s2 (%v)", id, got, s2)
	}
}
