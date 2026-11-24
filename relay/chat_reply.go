package relay

import (
	"context"
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
		msg, _ := json.Marshal(Message{Type: "chat_send", Payload: mustMarshal(map[string]string{
			"session_id": req.SessionID, "text": text,
		})})
		ctx, cancel := context.WithTimeout(r.Context(), replySendTimeout)
		defer cancel()
		if err := agent.Send(ctx, websocket.MessageText, msg); err != nil {
			http.Error(w, "agent unreachable", http.StatusBadGateway)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		w.Write([]byte(`{"ok":true}`))
	})
}
