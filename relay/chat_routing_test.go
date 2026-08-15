package relay

import (
	"bytes"
	"context"
	"encoding/json"
	"log"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"nhooyr.io/websocket"
)

// syncBuffer is a bytes.Buffer guarded by a mutex — log.Logger writes from
// the server's goroutine while the test reads concurrently, and plain
// bytes.Buffer is not safe for that under -race.
type syncBuffer struct {
	mu  sync.Mutex
	buf bytes.Buffer
}

func (b *syncBuffer) Write(p []byte) (int, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.buf.Write(p)
}

func (b *syncBuffer) String() string {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.buf.String()
}

const (
	testAgentSecret = "test-agent-secret"
	testAgentID     = "11111111-2222-4333-8444-555555555555"
	testSessionID   = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
)

// newTestRelay starts a hub behind an httptest server and returns its ws://
// base URL plus the Auth used to sign client tokens.
func newTestRelay(t *testing.T) (*Hub, *Auth, string) {
	t.Helper()
	hub := NewHub()
	go hub.Run()

	auth := NewAuth("test-jwt-secret", "test-admin-password")
	mux := http.NewServeMux()
	mux.HandleFunc("/ws/agent", func(w http.ResponseWriter, r *http.Request) {
		HandleAgentWS(w, r, hub, testAgentSecret)
	})
	mux.HandleFunc("/ws/client", func(w http.ResponseWriter, r *http.Request) {
		HandleClientWS(w, r, hub, auth)
	})
	srv := httptest.NewServer(mux)
	t.Cleanup(srv.Close)
	return hub, auth, "ws" + strings.TrimPrefix(srv.URL, "http")
}

func dial(t *testing.T, url string) *websocket.Conn {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	conn, _, err := websocket.Dial(ctx, url, nil)
	if err != nil {
		t.Fatalf("dial %s: %v", url, err)
	}
	t.Cleanup(func() { conn.Close(websocket.StatusNormalClosure, "") })
	return conn
}

func writeMsg(t *testing.T, conn *websocket.Conn, msgType string, payload any) {
	t.Helper()
	body, err := json.Marshal(Message{Type: msgType, Payload: mustMarshal(payload)})
	if err != nil {
		t.Fatalf("marshal %s: %v", msgType, err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if err := conn.Write(ctx, websocket.MessageText, body); err != nil {
		t.Fatalf("write %s: %v", msgType, err)
	}
}

// readUntil reads text frames until one has the wanted type, or times out.
func readUntil(t *testing.T, conn *websocket.Conn, want string) Message {
	t.Helper()
	msg, ok := tryReadUntil(t, conn, want, 5*time.Second)
	if !ok {
		t.Fatalf("timed out waiting for %q", want)
	}
	return msg
}

// tryReadUntil is readUntil without the fatal timeout, for asserting that a
// message type does NOT arrive within a bounded window.
func tryReadUntil(t *testing.T, conn *websocket.Conn, want string, timeout time.Duration) (Message, bool) {
	t.Helper()
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		ctx, cancel := context.WithDeadline(context.Background(), deadline)
		typ, data, err := conn.Read(ctx)
		cancel()
		if err != nil {
			return Message{}, false
		}
		if typ != websocket.MessageText {
			continue
		}
		var msg Message
		if err := json.Unmarshal(data, &msg); err != nil {
			continue
		}
		if msg.Type == want {
			return msg, true
		}
	}
	return Message{}, false
}

// connectPair wires up an agent and a client sharing one session.
func connectPair(t *testing.T) (agent, client *websocket.Conn) {
	t.Helper()
	_, auth, base := newTestRelay(t)

	agent = dial(t, base+"/ws/agent")
	writeMsg(t, agent, "register", map[string]any{
		"agent_id": testAgentID, "name": "test-mac", "secret": testAgentSecret,
	})

	token, err := auth.GenerateAccessToken()
	if err != nil {
		t.Fatalf("mint token: %v", err)
	}
	client = dial(t, base+"/ws/client")
	writeMsg(t, client, "auth", map[string]any{"token": token})

	time.Sleep(100 * time.Millisecond) // let registration settle

	writeMsg(t, client, "connect", map[string]any{
		"agent_id": testAgentID, "session_id": testSessionID,
		"kind": "chat", "cwd": "~/proj",
	})
	readUntil(t, client, "session_ready")
	return agent, client
}

func TestConnectForwardsChatFieldsVerbatim(t *testing.T) {
	agent, _ := connectPair(t)

	msg := readUntil(t, agent, "connect")
	var payload map[string]any
	if err := json.Unmarshal(msg.Payload, &payload); err != nil {
		t.Fatalf("unmarshal forwarded connect: %v", err)
	}
	if payload["kind"] != "chat" {
		t.Fatalf("kind lost in relay: %+v", payload)
	}
	if payload["cwd"] != "~/proj" {
		t.Fatalf("cwd lost in relay: %+v", payload)
	}
}

func TestChatSendRoutesClientToAgent(t *testing.T) {
	agent, client := connectPair(t)
	readUntil(t, agent, "connect")

	writeMsg(t, client, "chat_send", map[string]any{
		"session_id": testSessionID, "text": "hello there",
	})

	msg := readUntil(t, agent, "chat_send")
	var payload map[string]any
	json.Unmarshal(msg.Payload, &payload)
	if payload["text"] != "hello there" {
		t.Fatalf("text lost: %+v", payload)
	}
}

func TestChatEventRoutesAgentToClient(t *testing.T) {
	agent, client := connectPair(t)
	readUntil(t, agent, "connect")

	writeMsg(t, agent, "chat_event", map[string]any{
		"session_id": testSessionID,
		"event":      map[string]any{"kind": "text", "seq": 1, "text": "hi"},
	})

	msg := readUntil(t, client, "chat_event")
	var payload map[string]any
	json.Unmarshal(msg.Payload, &payload)
	if payload["session_id"] != testSessionID {
		t.Fatalf("session_id lost: %+v", payload)
	}
}

func TestChatHistoryUsesRequestCorrelation(t *testing.T) {
	agent, client := connectPair(t)
	readUntil(t, agent, "connect")

	writeMsg(t, client, "chat_history", map[string]any{
		"agent_id": testAgentID, "session_id": testSessionID,
		"request_id": "req-1", "after_seq": 0,
	})

	fwd := readUntil(t, agent, "chat_history")
	var fwdPayload map[string]any
	json.Unmarshal(fwd.Payload, &fwdPayload)
	if _, leaked := fwdPayload["agent_id"]; leaked {
		t.Error("agent_id must be stripped before forwarding to the agent")
	}

	writeMsg(t, agent, "chat_history_result", map[string]any{
		"request_id": "req-1", "events": []any{}, "next_seq": 1,
	})

	got := readUntil(t, client, "chat_history_result")
	var gotPayload map[string]any
	json.Unmarshal(got.Payload, &gotPayload)
	if gotPayload["request_id"] != "req-1" {
		t.Fatalf("request_id not correlated: %+v", gotPayload)
	}
}

// TestChatSendToUnknownSessionIsLogged is the regression test for review
// Finding 7 (first half): RouteTextToAgent's bool was discarded, so a
// chat_send/chat_interrupt for a session with no route (e.g. the agent
// already dropped it) vanished in total silence — exactly what would have
// made the Critical Interrupt defect visible instead of invisible.
//
// The session_id here must be well-formed (a valid UUID v4, just an unknown
// one) rather than an arbitrary string like the original "no-such-session":
// the log-injection fix (see TestChatSendToUnknownSessionLogsPlaceholderForMalformedID
// below) means only a well-formed id is ever echoed into the log verbatim.
func TestChatSendToUnknownSessionIsLogged(t *testing.T) {
	_, auth, base := newTestRelay(t)

	token, err := auth.GenerateAccessToken()
	if err != nil {
		t.Fatalf("mint token: %v", err)
	}
	client := dial(t, base+"/ws/client")
	writeMsg(t, client, "auth", map[string]any{"token": token})
	time.Sleep(100 * time.Millisecond) // let auth settle

	var logBuf syncBuffer
	orig := log.Writer()
	log.SetOutput(&logBuf)
	defer log.SetOutput(orig)

	const unknownButWellFormed = "99999999-9999-4999-8999-999999999999"
	writeMsg(t, client, "chat_send", map[string]any{
		"session_id": unknownButWellFormed, "text": "hello",
	})

	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		if strings.Contains(logBuf.String(), unknownButWellFormed) {
			return
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatalf("expected a dropped-route log for chat_send to an unknown session; got %q", logBuf.String())
}

// TestChatSendToUnknownSessionLogsPlaceholderForMalformedID is the
// regression test for the log-injection defect found in the same fix wave
// as the Critical Interrupt defect above: the relay used to log a dropped
// chat_send/chat_interrupt's session_id verbatim, straight from
// client-controlled JSON, with no validation — letting an authenticated
// client write arbitrary content into the relay's log. A malformed
// session_id must produce a log line, but must not contain the attacker's
// literal payload.
func TestChatSendToUnknownSessionLogsPlaceholderForMalformedID(t *testing.T) {
	_, auth, base := newTestRelay(t)

	token, err := auth.GenerateAccessToken()
	if err != nil {
		t.Fatalf("mint token: %v", err)
	}
	client := dial(t, base+"/ws/client")
	writeMsg(t, client, "auth", map[string]any{"token": token})
	time.Sleep(100 * time.Millisecond) // let auth settle

	var logBuf syncBuffer
	orig := log.Writer()
	log.SetOutput(&logBuf)
	defer log.SetOutput(orig)

	const payload = "injected-log-line-marker"
	writeMsg(t, client, "chat_send", map[string]any{
		"session_id": payload, "text": "hello",
	})

	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		if strings.Contains(logBuf.String(), "dropped: no route") {
			if strings.Contains(logBuf.String(), payload) {
				t.Fatalf("attacker-controlled session_id was logged verbatim: %q", logBuf.String())
			}
			return
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatalf("expected a dropped-route log for chat_send to a malformed session id; got %q", logBuf.String())
}

// TestChatHistoryRejectsEmptyRequestID mirrors the guard
// handleClientFSRequest already has (pl.RequestID == ""): storing an empty
// request_id in pendingRequests is never useful and risks one client's
// blank-request_id bug clobbering another's pending entry.
func TestChatHistoryRejectsEmptyRequestID(t *testing.T) {
	agent, client := connectPair(t)
	readUntil(t, agent, "connect")

	writeMsg(t, client, "chat_history", map[string]any{
		"agent_id": testAgentID, "session_id": testSessionID,
		"request_id": "", "after_seq": 0,
	})

	if _, ok := tryReadUntil(t, agent, "chat_history", 500*time.Millisecond); ok {
		t.Fatal("chat_history with an empty request_id must not be forwarded to the agent")
	}
}
