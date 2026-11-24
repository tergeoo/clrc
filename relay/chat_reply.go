package relay

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"net/http"
	"strings"
	"time"

	"nhooyr.io/websocket"
)

const (
	maxReplyBytes     = 4 << 10
	replyMaxPerMinute = 30
	replySendTimeout  = 5 * time.Second
	// replyAckTimeout bounds the wait for the agent's chat_send_result;
	// agents older than the ack answer nothing and count as unconfirmed.
	replyAckTimeout   = 3 * time.Second
	maxReplyBodyBytes = 16 << 10
)

// ChatReplyHandler serves POST /chat/reply: an answer given from a push
// notification while the app has no socket. It needs a valid access token
// and forwards chat_send straight to the agent, which still holds the chat
// session even though the client route is gone.
func ChatReplyHandler(hub *Hub, auth *Auth) http.Handler {
	limiter := newRateLimiter(replyMaxPerMinute, time.Minute, time.Now)
	limiter.startCleanup(5 * time.Minute)

	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}
		token, ok := strings.CutPrefix(r.Header.Get("Authorization"), "Bearer ")
		if !ok || token == "" {
			http.Error(w, "unauthorized", http.StatusUnauthorized)
			return
		}
		if _, err := auth.ValidateAccessToken(token); err != nil {
			http.Error(w, "unauthorized", http.StatusUnauthorized)
			return
		}
		if !limiter.allow(clientIP(r)) {
			http.Error(w, "too many requests", http.StatusTooManyRequests)
			return
		}

		var req struct {
			AgentID   string `json:"agent_id"`
			SessionID string `json:"session_id"`
			Text      string `json:"text"`
		}
		if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, maxReplyBodyBytes)).Decode(&req); err != nil {
			http.Error(w, "invalid body", http.StatusBadRequest)
			return
		}
		text := strings.TrimSpace(req.Text)
		if !validAgentID(req.AgentID) || !validSessionID(req.SessionID) || text == "" || len(text) > maxReplyBytes {
			http.Error(w, "invalid reply", http.StatusBadRequest)
			return
		}

		agent, ok := hub.GetAgent(req.AgentID)
		if !ok {
			http.Error(w, "agent offline", http.StatusNotFound)
			return
		}
		requestID := newRequestID()
		acks := make(chan replyAck, 1)
		hub.pendingReplies.Store(requestID, acks)
		defer hub.pendingReplies.Delete(requestID)

		msg, _ := json.Marshal(Message{Type: "chat_send", Payload: mustMarshal(map[string]string{
			"session_id": req.SessionID, "text": text, "request_id": requestID,
		})})
		ctx, cancel := context.WithTimeout(r.Context(), replySendTimeout)
		defer cancel()
		if err := agent.Send(ctx, websocket.MessageText, msg); err != nil {
			http.Error(w, "agent unreachable", http.StatusBadGateway)
			return
		}

		w.Header().Set("Content-Type", "application/json")
		select {
		case ack := <-acks:
			if !ack.OK {
				// The Mac no longer has this chat (closed, agent restarted).
				w.WriteHeader(http.StatusConflict)
				json.NewEncoder(w).Encode(map[string]any{"ok": false, "error": ack.Error})
				return
			}
			w.Write([]byte(`{"ok":true,"confirmed":true}`))
		case <-time.After(replyAckTimeout):
			w.Write([]byte(`{"ok":true,"confirmed":false}`))
		case <-r.Context().Done():
		}
	})
}

// replyAck is the agent's chat_send_result for a /chat/reply.
type replyAck struct {
	RequestID string `json:"request_id"`
	OK        bool   `json:"ok"`
	Error     string `json:"error"`
}

func newRequestID() string {
	var b [16]byte
	rand.Read(b[:])
	return hex.EncodeToString(b[:])
}
