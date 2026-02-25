package main

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

// WSClient manages the persistent WebSocket connection to the relay server.
type WSClient struct {
	cfg      *Config
	sessions map[string]*PTYSession
	mu       sync.RWMutex
	conn     *websocket.Conn
	connMu   sync.Mutex
}

func NewWSClient(cfg *Config) *WSClient {
	return &WSClient{
		cfg:      cfg,
		sessions: make(map[string]*PTYSession),
	}
}

// Run maintains a persistent connection with exponential backoff on failure.
func (c *WSClient) Run(ctx context.Context) {
	backoff := time.Second
	maxBackoff := 60 * time.Second

	for {
		if err := c.connect(ctx); err != nil {
			if ctx.Err() != nil {
				return
			}
			log.Printf("Connection failed: %v. Retrying in %v...", err, backoff)
			select {
			case <-time.After(backoff):
			case <-ctx.Done():
				return
			}
			backoff = min(backoff*2, maxBackoff)
		} else {
			backoff = time.Second
		}
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

	// Ping goroutine
	pingCtx, cancelPing := context.WithCancel(ctx)
	defer cancelPing()
	go func() {
		ticker := time.NewTicker(30 * time.Second)
		defer ticker.Stop()
		for {
			select {
			case <-ticker.C:
				if err := conn.Ping(pingCtx); err != nil {
					cancelPing()
					return
				}
			case <-pingCtx.Done():
				return
			}
		}
	}()

	// Read loop
	for {
		msgType, data, err := conn.Read(ctx)
		if err != nil {
			return err
		}
		if msgType == websocket.MessageBinary {
			c.handleBinary(ctx, data)
		} else {
			c.handleText(ctx, data)
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
	var req struct {
		SessionID string `json:"session_id"`
		Cols      uint16 `json:"cols"`
		Rows      uint16 `json:"rows"`
	}
	if err := json.Unmarshal(payload, &req); err != nil {
		log.Printf("Invalid connect payload: %v", err)
		return
	}

	// Check if session already exists — reattach instead of creating new PTY
	c.mu.RLock()
	existing := c.sessions[req.SessionID]
	c.mu.RUnlock()

	if existing != nil {
		existing.SetSendFn(c.sendToRelay)
		existing.Resize(req.Cols, req.Rows)
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

	log.Printf("PTY session started: %s (command: %s, %dx%d)", req.SessionID, command, req.Cols, req.Rows)

	// Remove session from map when process exits (but don't kill it — it exits on its own)
	go func() {
		<-sess.Done()
		c.mu.Lock()
		delete(c.sessions, req.SessionID)
		c.mu.Unlock()
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
	sessions := make([]map[string]any, 0, len(c.sessions))
	for id, sess := range c.sessions {
		sessions = append(sessions, map[string]any{
			"id":   id,
			"cols": sess.Cols,
			"rows": sess.Rows,
		})
	}
	c.mu.RUnlock()

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
