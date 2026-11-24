package relay

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func postReply(t *testing.T, h http.Handler, token, body string) *httptest.ResponseRecorder {
	t.Helper()
	req := httptest.NewRequest(http.MethodPost, "/chat/reply", strings.NewReader(body))
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	return rec
}

func replyBody(text string) string {
	b, _ := json.Marshal(map[string]string{"agent_id": testAgentID, "session_id": testSessionID, "text": text})
	return string(b)
}

func TestChatReplyRequiresAuth(t *testing.T) {
	hub, auth, agent, _ := connectPairWithAuth(t)
	h := ChatReplyHandler(hub, auth)
	if rec := postReply(t, h, "", replyBody("1")); rec.Code != http.StatusUnauthorized {
		t.Errorf("no token: %d", rec.Code)
	}
	if rec := postReply(t, h, "garbage", replyBody("1")); rec.Code != http.StatusUnauthorized {
		t.Errorf("bad token: %d", rec.Code)
	}
	refresh, _ := auth.GenerateRefreshToken()
	if rec := postReply(t, h, refresh, replyBody("1")); rec.Code != http.StatusUnauthorized {
		t.Errorf("refresh token accepted: %d", rec.Code)
	}
	if _, ok := tryReadUntil(t, agent, "chat_send", 300*time.Millisecond); ok {
		t.Fatal("unauthenticated reply reached the agent")
	}
}

func TestChatReplyForwardsToAgent(t *testing.T) {
	hub, auth, agent, _ := connectPairWithAuth(t)
	token, _ := auth.GenerateAccessToken()
	rec := postReply(t, ChatReplyHandler(hub, auth), token, replyBody("2"))
	if rec.Code != http.StatusOK {
		t.Fatalf("status %d: %s", rec.Code, rec.Body.String())
	}
	msg := readUntil(t, agent, "chat_send")
	var pl map[string]any
	json.Unmarshal(msg.Payload, &pl)
	if pl["session_id"] != testSessionID || pl["text"] != "2" {
		t.Fatalf("forwarded = %+v", pl)
	}
	if _, leaked := pl["agent_id"]; leaked {
		t.Error("agent_id forwarded to the agent")
	}
}

func TestChatReplyAgentOffline(t *testing.T) {
	hub, auth, _, _ := connectPairWithAuth(t)
	token, _ := auth.GenerateAccessToken()
	body, _ := json.Marshal(map[string]string{"agent_id": "99999999-2222-4333-8444-555555555555", "session_id": testSessionID, "text": "1"})
	if rec := postReply(t, ChatReplyHandler(hub, auth), token, string(body)); rec.Code != http.StatusNotFound {
		t.Fatalf("offline agent: %d", rec.Code)
	}
}

func TestChatReplyValidatesInput(t *testing.T) {
	hub, auth, _, _ := connectPairWithAuth(t)
	token, _ := auth.GenerateAccessToken()
	h := ChatReplyHandler(hub, auth)
	for name, body := range map[string]string{
		"empty text":   replyBody(""),
		"long text":    replyBody(strings.Repeat("я", maxReplyBytes)),
		"bad session":  `{"agent_id":"` + testAgentID + `","session_id":"x","text":"1"}`,
		"bad agent id": `{"agent_id":"x","session_id":"` + testSessionID + `","text":"1"}`,
		"not json":     `{`,
	} {
		if rec := postReply(t, h, token, body); rec.Code != http.StatusBadRequest {
			t.Errorf("%s: %d", name, rec.Code)
		}
	}
	req := httptest.NewRequest(http.MethodGet, "/chat/reply", nil)
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	if rec.Code != http.StatusMethodNotAllowed {
		t.Errorf("GET: %d", rec.Code)
	}
}

// Review fix: a reply must not report success when the agent has no such chat.
func TestChatReplyWaitsForAgentAck(t *testing.T) {
	hub, auth, agent, _ := connectPairWithAuth(t)
	token, _ := auth.GenerateAccessToken()
	h := ChatReplyHandler(hub, auth)

	for _, tc := range []struct {
		ack  map[string]any
		want int
	}{
		{map[string]any{"ok": true}, http.StatusOK},
		{map[string]any{"ok": false, "error": "unknown chat session"}, http.StatusConflict},
	} {
		done := make(chan *httptest.ResponseRecorder, 1)
		go func() { done <- postReply(t, h, token, replyBody("1")) }()
		msg := readUntil(t, agent, "chat_send")
		var pl map[string]any
		json.Unmarshal(msg.Payload, &pl)
		reqID, _ := pl["request_id"].(string)
		if reqID == "" {
			t.Fatal("chat_send from /chat/reply carries no request_id")
		}
		ack := map[string]any{"request_id": reqID}
		for k, v := range tc.ack {
			ack[k] = v
		}
		writeMsg(t, agent, "chat_send_result", ack)
		if rec := <-done; rec.Code != tc.want {
			t.Errorf("ack %v: status %d, want %d", tc.ack, rec.Code, tc.want)
		}
	}
}

func TestChatReplyWithoutAckFromOlderAgentIsAccepted(t *testing.T) {
	hub, auth, agent, _ := connectPairWithAuth(t)
	token, _ := auth.GenerateAccessToken()
	start := time.Now()
	rec := postReply(t, ChatReplyHandler(hub, auth), token, replyBody("1"))
	readUntil(t, agent, "chat_send")
	if rec.Code != http.StatusOK || !strings.Contains(rec.Body.String(), `"confirmed":false`) {
		t.Fatalf("status %d body %s", rec.Code, rec.Body.String())
	}
	if time.Since(start) > replyAckTimeout+2*time.Second {
		t.Fatal("waited too long for an ack")
	}
}
