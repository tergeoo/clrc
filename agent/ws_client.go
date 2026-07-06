package agent

import (
	"context"
	"encoding/json"
	"log"
	"sync"
	"time"

	"nhooyr.io/websocket"
)

// Message mirrors the relay protocol envelope.
type Message struct {
	Type    string          `json:"type"`
	Payload json.RawMessage `json:"payload"`
}

// connectReq is the payload of a "connect" control message.
// Name is optional — older clients don't send it.
type connectReq struct {
	SessionID string `json:"session_id"`
	Cols      uint16 `json:"cols"`
	Rows      uint16 `json:"rows"`
	Name      string `json:"name"`
}

// sanitizeSessionName caps the display name and strips control characters
// (it is written to disk, echoed in sessions_list, and printed by `clrc sessions`).
func sanitizeSessionName(name string) string {
	const maxLen = 128
	cleaned := make([]rune, 0, len(name))
	for _, r := range name {
		if r < 0x20 || r == 0x7f {
			continue
		}
		cleaned = append(cleaned, r)
		if len(cleaned) >= maxLen {
			break
		}
	}
	return string(cleaned)
}

// buildSessionsList joins live PTY sessions with their on-disk metadata.
// Only live sessions are returned; disk-only entries are stale.
func buildSessionsList(live map[string]*PTYSession, disk []SessionInfo) []map[string]any {
	byID := make(map[string]SessionInfo, len(disk))
	for _, d := range disk {
		byID[d.ID] = d
	}
	out := make([]map[string]any, 0, len(live))
	for id, sess := range live {
		entry := map[string]any{"id": id, "cols": sess.Cols, "rows": sess.Rows}
		if d, ok := byID[id]; ok {
			if d.Name != "" {
				entry["name"] = d.Name
			}
			entry["command"] = d.Command
			entry["started"] = d.Started.UTC().Format(time.RFC3339)
		}
		out = append(out, entry)
	}
	return out
}

// WSClient manages the persistent WebSocket connection to the relay server.
type WSClient struct {
	cfg      *Config
	sessions map[string]*PTYSession
	mu       sync.RWMutex
	conn     *websocket.Conn
	connMu   sync.Mutex
}

func NewWSClient(cfg Config) *WSClient {
	return &WSClient{
		cfg:      &cfg,
		sessions: make(map[string]*PTYSession),
	}
}

// Run maintains a persistent connection with exponential backoff on failure.
func (c *WSClient) Run(ctx context.Context) {
	CleanStaleSessions()
	backoff := time.Second
	const maxBackoff = 60 * time.Second

	for {
		start := time.Now()
		err := c.connect(ctx)
		if ctx.Err() != nil {
			return
		}
		// Reset backoff if we held a real connection (sleep/wake scenario).
		if time.Since(start) > 10*time.Second {
			backoff = time.Second
		}
		log.Printf("Connection lost: %v. Retrying in %v...", err, backoff)
		select {
		case <-time.After(backoff):
		case <-ctx.Done():
			return
		}
		backoff = min(backoff*2, maxBackoff)
	}
}

func (c *WSClient) connect(ctx context.Context) error {
	log.Printf("Connecting to relay: %s", c.cfg.RelayURL)

	conn, _, err := websocket.Dial(ctx, c.cfg.RelayURL+"/ws/agent", nil)
	if err != nil {
		return err
	}
	defer conn.Close(websocket.StatusNormalClosure, "")

	c.connMu.Lock()
	c.conn = conn
	c.connMu.Unlock()

	// Register with relay
	regPayload, _ := json.Marshal(map[string]string{
		"agent_id": c.cfg.AgentID,
		"name":     c.cfg.Name,
		"secret":   c.cfg.Secret,
	})
	regMsg, _ := json.Marshal(Message{Type: "register", Payload: regPayload})
	if err := conn.Write(ctx, websocket.MessageText, regMsg); err != nil {
		return err
	}
	log.Printf("Registered as agent: %s (%s)", c.cfg.Name, c.cfg.AgentID)

	// connCtx is cancelled when the parent ctx is done OR when a ping fails.
	// This ensures the read loop exits promptly on sleep/wake or network drop.
	connCtx, cancelConn := context.WithCancel(ctx)
	defer cancelConn()

	// Ping goroutine
	go func() {
		ticker := time.NewTicker(30 * time.Second)
		defer ticker.Stop()
		for {
			select {
			case <-ticker.C:
				if err := conn.Ping(connCtx); err != nil {
					log.Printf("Ping failed: %v — triggering reconnect", err)
					cancelConn()
					return
				}
			case <-connCtx.Done():
				return
			}
		}
	}()

	// Read loop — exits when connCtx is cancelled (ping failure or shutdown).
	for {
		msgType, data, err := conn.Read(connCtx)
		if err != nil {
			return err
		}
		if msgType == websocket.MessageBinary {
			c.handleBinary(connCtx, data)
		} else {
			c.handleText(connCtx, data)
		}
	}
}

func (c *WSClient) handleBinary(ctx context.Context, data []byte) {
	sessionID, payload, ok := decodeBinaryFrame(data)
	if !ok {
		return
	}
	c.mu.RLock()
	sess, exists := c.sessions[sessionID]
	c.mu.RUnlock()
	if !exists {
		return
	}
	if err := sess.Write(payload); err != nil {
		log.Printf("PTY write error for session %s: %v", sessionID, err)
	}
}

func (c *WSClient) handleText(ctx context.Context, data []byte) {
	var msg Message
	if err := json.Unmarshal(data, &msg); err != nil {
		return
	}

	switch msg.Type {
	case "connect":
		c.handleConnect(ctx, msg.Payload)
	case "resize":
		c.handleResize(msg.Payload)
	case "detach":
		c.handleDetach(msg.Payload)
	case "disconnect":
		c.handleDisconnect(msg.Payload)
	case "list_sessions":
		c.handleListSessions(ctx, msg.Payload)
	case "fs_list":
		c.handleFSList(ctx, msg.Payload)
	case "fs_mkdir":
		c.handleFSMkdir(ctx, msg.Payload)
	case "fs_delete":
		c.handleFSDelete(ctx, msg.Payload)
	case "fs_read":
		c.handleFSRead(ctx, msg.Payload)
	}
}

func (c *WSClient) handleConnect(ctx context.Context, payload json.RawMessage) {
	var req connectReq
	if err := json.Unmarshal(payload, &req); err != nil {
		log.Printf("Invalid connect payload: %v", err)
		return
	}
	if !validSessionID(req.SessionID) {
		log.Printf("Rejecting connect with invalid session id: %q", req.SessionID)
		return
	}
	req.Name = sanitizeSessionName(req.Name)

	// Check if session already exists — reattach instead of creating new PTY
	c.mu.RLock()
	existing := c.sessions[req.SessionID]
	c.mu.RUnlock()

	if existing != nil {
		existing.SetSendFn(c.sendToRelay)
		existing.Resize(req.Cols, req.Rows)
		if req.Name != "" {
			RenameSess(req.SessionID, req.Name) // rename-on-reconnect keeps names in sync
		}
		log.Printf("PTY session reattached: %s (%dx%d)", req.SessionID, req.Cols, req.Rows)
		return
	}

	command := c.cfg.DefaultCommand
	if command == "" {
		command = "bash"
	}

	sess, err := NewPTYSession(req.SessionID, command, req.Cols, req.Rows, c.sendToRelay)
	if err != nil {
		log.Printf("Failed to start PTY for session %s: %v", req.SessionID, err)
		return
	}

	c.mu.Lock()
	c.sessions[req.SessionID] = sess
	c.mu.Unlock()

	WriteSess(req.SessionID, sess.Pid(), command, req.Name)
	log.Printf("PTY session started: %s (command: %s, %dx%d)", req.SessionID, command, req.Cols, req.Rows)

	// Remove session from map when process exits (but don't kill it — it exits on its own)
	go func() {
		<-sess.Done()
		c.mu.Lock()
		delete(c.sessions, req.SessionID)
		c.mu.Unlock()
		RemoveSess(req.SessionID)
		log.Printf("PTY session ended: %s", req.SessionID)
	}()
}

func (c *WSClient) handleResize(payload json.RawMessage) {
	var req struct {
		SessionID string `json:"session_id"`
		Cols      uint16 `json:"cols"`
		Rows      uint16 `json:"rows"`
	}
	if err := json.Unmarshal(payload, &req); err != nil {
		return
	}
	c.mu.RLock()
	sess, ok := c.sessions[req.SessionID]
	c.mu.RUnlock()
	if ok {
		sess.Resize(req.Cols, req.Rows)
	}
}

// handleDetach: client disconnected unexpectedly — keep PTY alive, stop sending output.
func (c *WSClient) handleDetach(payload json.RawMessage) {
	var req struct {
		SessionID string `json:"session_id"`
	}
	if err := json.Unmarshal(payload, &req); err != nil {
		return
	}
	c.mu.RLock()
	sess, ok := c.sessions[req.SessionID]
	c.mu.RUnlock()
	if ok {
		sess.SetSendFn(nil)
		log.Printf("PTY session detached (client gone): %s", req.SessionID)
	}
}

// handleDisconnect: explicit close from client — kill the PTY.
func (c *WSClient) handleDisconnect(payload json.RawMessage) {
	var req struct {
		SessionID string `json:"session_id"`
	}
	if err := json.Unmarshal(payload, &req); err != nil {
		return
	}
	c.mu.Lock()
	sess, ok := c.sessions[req.SessionID]
	if ok {
		delete(c.sessions, req.SessionID)
	}
	c.mu.Unlock()
	if ok {
		sess.Close()
		log.Printf("PTY session closed by client: %s", req.SessionID)
	}
}

// handleListSessions: respond with all live PTY sessions on this agent.
func (c *WSClient) handleListSessions(ctx context.Context, payload json.RawMessage) {
	var req struct {
		RequestID string `json:"request_id"`
	}
	json.Unmarshal(payload, &req)

	c.mu.RLock()
	live := make(map[string]*PTYSession, len(c.sessions))
	for id, sess := range c.sessions {
		live[id] = sess
	}
	c.mu.RUnlock()

	sessions := buildSessionsList(live, ListSess())

	respPayload, _ := json.Marshal(map[string]any{
		"request_id": req.RequestID,
		"sessions":   sessions,
	})
	resp, _ := json.Marshal(Message{Type: "sessions_list", Payload: respPayload})

	c.connMu.Lock()
	conn := c.conn
	c.connMu.Unlock()
	if conn == nil {
		return
	}
	writeCtx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	conn.Write(writeCtx, websocket.MessageText, resp)
}

// sendToRelay sends PTY output back to the relay using binary framing.
func (c *WSClient) sendToRelay(sessionID string, data []byte) {
	c.connMu.Lock()
	conn := c.conn
	c.connMu.Unlock()
	if conn == nil {
		return
	}
	frame := encodeBinaryFrame(sessionID, data)
	writeCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if err := conn.Write(writeCtx, websocket.MessageBinary, frame); err != nil {
		log.Printf("Failed to send data for session %s: %v", sessionID, err)
	}
}

// sendTextMsg sends a JSON control message back to the relay.
func (c *WSClient) sendTextMsg(ctx context.Context, msgType string, payload any) {
	payloadBytes, _ := json.Marshal(payload)
	resp, _ := json.Marshal(Message{Type: msgType, Payload: payloadBytes})
	c.connMu.Lock()
	conn := c.conn
	c.connMu.Unlock()
	if conn == nil {
		return
	}
	writeCtx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	conn.Write(writeCtx, websocket.MessageText, resp)
}

// handleFSList lists directory contents and responds with fs_list_result.
func (c *WSClient) handleFSList(ctx context.Context, payload json.RawMessage) {
	var req struct {
		RequestID string `json:"request_id"`
		Path      string `json:"path"`
	}
	if err := json.Unmarshal(payload, &req); err != nil {
		return
	}
	resolved, entries, err := fsListDir(req.Path)
	errStr := ""
	if err != nil {
		errStr = err.Error()
		entries = nil
	}
	c.sendTextMsg(ctx, "fs_list_result", map[string]any{
		"request_id":    req.RequestID,
		"path":          req.Path,
		"resolved_path": resolved,
		"entries":       entries,
		"error":         errStr,
	})
}

// handleFSMkdir creates a directory and responds with fs_mkdir_result.
func (c *WSClient) handleFSMkdir(ctx context.Context, payload json.RawMessage) {
	var req struct {
		RequestID string `json:"request_id"`
		Path      string `json:"path"`
	}
	if err := json.Unmarshal(payload, &req); err != nil {
		return
	}
	errStr := ""
	if err := fsMkdir(req.Path); err != nil {
		errStr = err.Error()
	}
	c.sendTextMsg(ctx, "fs_mkdir_result", map[string]string{
		"request_id": req.RequestID,
		"error":      errStr,
	})
}

// handleFSDelete removes a path and responds with fs_delete_result.
func (c *WSClient) handleFSDelete(ctx context.Context, payload json.RawMessage) {
	var req struct {
		RequestID string `json:"request_id"`
		Path      string `json:"path"`
	}
	if err := json.Unmarshal(payload, &req); err != nil {
		return
	}
	errStr := ""
	if err := fsDelete(req.Path); err != nil {
		errStr = err.Error()
	}
	c.sendTextMsg(ctx, "fs_delete_result", map[string]string{
		"request_id": req.RequestID,
		"error":      errStr,
	})
}

// handleFSRead reads a file (up to 100 KB) and responds with fs_read_result.
func (c *WSClient) handleFSRead(ctx context.Context, payload json.RawMessage) {
	var req struct {
		RequestID string `json:"request_id"`
		Path      string `json:"path"`
	}
	if err := json.Unmarshal(payload, &req); err != nil {
		return
	}
	content, err := fsRead(req.Path)
	errStr := ""
	if err != nil {
		errStr = err.Error()
		content = ""
	}
	c.sendTextMsg(ctx, "fs_read_result", map[string]string{
		"request_id": req.RequestID,
		"content":    content,
		"error":      errStr,
	})
}

func min(a, b time.Duration) time.Duration {
	if a < b {
		return a
	}
	return b
}
