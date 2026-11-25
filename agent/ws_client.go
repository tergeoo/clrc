package agent

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"strings"
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
// Name is optional — older clients don't send it. Kind is likewise optional
// and absent means "pty", which is what every pre-chat client sends.
type connectReq struct {
	SessionID string `json:"session_id"`
	Cols      uint16 `json:"cols"`
	Rows      uint16 `json:"rows"`
	Name      string `json:"name"`
	Kind      string `json:"kind"`
	Cwd       string `json:"cwd"`
	Model     string `json:"model"`
	// Profile optionally selects ~/.claude-<profile> as CLAUDE_CONFIG_DIR
	// for this session instead of the agent default.
	Profile string `json:"profile"`
	// Style optionally overrides the agent's output style (chat only).
	Style string `json:"style"`
	// ProfileStrict forbids falling back to the agent default when Profile
	// is not usable: the session is refused instead (saved projects).
	ProfileStrict bool `json:"profile_strict"`
}

// registerReq is the payload of the agent's first message, "register".
// Version is empty for agents older than 2.1.
type registerReq struct {
	AgentID string `json:"agent_id"`
	Name    string `json:"name"`
	Secret  string `json:"secret"`
	Version string `json:"version,omitempty"`
}

func newRegisterReq(cfg Config) registerReq {
	return registerReq{AgentID: cfg.AgentID, Name: cfg.Name, Secret: cfg.Secret, Version: cfg.Version}
}

// sessionsListPayload is the payload of a "sessions_list" reply.
func sessionsListPayload(requestID string, sessions []map[string]any) map[string]any {
	return map[string]any{"request_id": requestID, "sessions": sessions}
}

// isPTY reports whether this connect asks for a terminal session. Anything
// that is not explicitly "chat" is a PTY, so unknown kinds from a newer
// client degrade to current behaviour rather than failing.
func (r connectReq) isPTY() bool { return r.Kind != "chat" }

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

// pingInterval is how often the connection watchdog pings the relay.
// pingTimeout bounds each individual ping: long enough to tolerate a slow
// network, short enough that a Mac waking from sleep notices a half-open
// connection within seconds rather than never. See runPingWatchdog.
const (
	pingInterval = 30 * time.Second
	pingTimeout  = 10 * time.Second
)

// pinger is the subset of *websocket.Conn the ping watchdog needs. Extracting
// it lets tests exercise runPingWatchdog against a fake that hangs forever,
// without standing up a real socket.
type pinger interface {
	Ping(ctx context.Context) error
}

// runPingWatchdog pings conn every interval and calls cancelConn — then
// returns — the moment a ping fails or ctx ends.
//
// Each ping gets its own bounded context derived from ctx, rather than ctx
// itself. That distinction is the whole point: nhooyr.io/websocket's
// Conn.Ping blocks until a pong arrives or its context is done. On a
// half-open socket (exactly what a sleeping laptop leaves behind), the ping
// frame goes out fine — TCP hasn't given up yet — but no pong ever comes
// back. If Ping were given ctx directly (which has no deadline of its own),
// it would block forever: the watchdog would be stuck inside the very call
// meant to detect the failure, the ticker would never fire again, and
// cancelConn would never run. Bounding each ping individually guarantees the
// watchdog always resurfaces within timeout, even against a peer that never
// answers.
func runPingWatchdog(ctx context.Context, conn pinger, interval, timeout time.Duration, cancelConn context.CancelFunc) {
	ticker := time.NewTicker(interval)
	defer ticker.Stop()
	for {
		select {
		case <-ticker.C:
			pingCtx, cancelPing := context.WithTimeout(ctx, timeout)
			err := conn.Ping(pingCtx)
			cancelPing()
			if err != nil {
				log.Printf("Ping failed: %v — triggering reconnect", err)
				cancelConn()
				return
			}
		case <-ctx.Done():
			return
		}
	}
}

// WSClient manages the persistent WebSocket connection to the relay server.
type WSClient struct {
	cfg      *Config
	sessions map[string]*PTYSession
	chats    map[string]*ChatSession
	mu       sync.RWMutex
	conn     *websocket.Conn
	connMu   sync.Mutex
	// textOut, when set, receives control messages instead of the relay
	// connection (tests capture what the agent sends with it).
	textOut func(ctx context.Context, msgType string, payload any)
}

func NewWSClient(cfg Config) *WSClient {
	return &WSClient{
		cfg:      &cfg,
		sessions: make(map[string]*PTYSession),
		chats:    make(map[string]*ChatSession),
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
	regPayload, err := json.Marshal(newRegisterReq(*c.cfg))
	if err != nil {
		return fmt.Errorf("encode register: %w", err)
	}
	regMsg, _ := json.Marshal(Message{Type: "register", Payload: regPayload})
	if err := conn.Write(ctx, websocket.MessageText, regMsg); err != nil {
		return err
	}
	log.Printf("Registered as agent: %s (%s), version %s", c.cfg.Name, c.cfg.AgentID, c.cfg.Version)

	// connCtx is cancelled when the parent ctx is done OR when a ping fails.
	// This ensures the read loop exits promptly on sleep/wake or network drop.
	connCtx, cancelConn := context.WithCancel(ctx)
	defer cancelConn()

	go runPingWatchdog(connCtx, conn, pingInterval, pingTimeout, cancelConn)

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
	case "git_status":
		c.runGitRequest(func() { c.handleGitStatus(ctx, msg.Payload) })
	case "git_diff":
		c.runGitRequest(func() { c.handleGitDiff(ctx, msg.Payload) })
	case "chat_send":
		c.handleChatSend(msg.Payload)
	case "chat_interrupt":
		c.handleChatInterrupt(msg.Payload)
	case "chat_history":
		c.handleChatHistory(ctx, msg.Payload)
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

	if !req.isPTY() {
		c.handleChatConnect(req)
		return
	}

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

	lp, err := c.resolveLaunch(req.Profile, req.ProfileStrict)
	if err != nil {
		if req.ProfileStrict {
			log.Printf("Refusing PTY session %s: %v", req.SessionID, err)
			c.sendSessionError(req.SessionID, err)
			return
		}
		log.Printf("PTY session %s: %v; using the agent default", req.SessionID, err)
	}

	sess, err := NewPTYSession(req.SessionID, command, req.Cols, req.Rows, lp, c.sendToRelay)
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

// handleChatConnect creates or reattaches a chat session. cwd goes through
// the same home-directory confinement as every other filesystem operation —
// a chat session must not become a way around it.
func (c *WSClient) handleChatConnect(req connectReq) {
	c.mu.RLock()
	existing := c.chats[req.SessionID]
	c.mu.RUnlock()
	if existing != nil {
		log.Printf("Chat session reattached: %s", req.SessionID)
		return
	}

	cwd := req.Cwd
	if cwd == "" {
		cwd = "~"
	}
	resolvedCwd, err := fsResolve(cwd)
	if err != nil {
		log.Printf("Rejecting chat session %s: %v", req.SessionID, err)
		c.sendChatError(req.SessionID, "working directory is not allowed")
		return
	}

	opts, err := c.chatOptions(req)
	if err != nil {
		log.Printf("Refusing chat session %s: %v", req.SessionID, err)
		c.sendChatError(req.SessionID, userMessage(err))
		return
	}
	sess := NewChatSessionWithOptions(req.SessionID, resolvedCwd, opts, c.sendChatEvents)

	c.mu.Lock()
	c.chats[req.SessionID] = sess
	c.mu.Unlock()

	log.Printf("Chat session started: %s (cwd: %s, style: %q, profile: %q, config dir: %q)",
		req.SessionID, resolvedCwd, opts.Style, opts.Launch.Name, opts.Launch.ConfigDir)

	go func() {
		<-sess.Done()
		c.removeChatIfCurrent(req.SessionID, sess)
		log.Printf("Chat session ended: %s", req.SessionID)
	}()
}

// chatOptions derives a chat session's spawn options from the connect
// request and the agent config. A rejected profile or style falls back to
// the agent default and is reported to the client as a non-fatal error.
func (c *WSClient) chatOptions(req connectReq) (ChatOptions, error) {
	lp, err := c.resolveLaunch(req.Profile, req.ProfileStrict)
	if err != nil {
		if req.ProfileStrict {
			return ChatOptions{}, err
		}
		log.Printf("Chat session %s: %v; using the agent default", req.SessionID, err)
		c.sendChatError(req.SessionID, "profile is not available on this Mac; using the default")
	}
	style := c.cfg.OutputStyle
	if req.Style != "" {
		if validIdent(req.Style) {
			style = req.Style
		} else {
			log.Printf("Chat session %s: ignoring invalid style %q", req.SessionID, req.Style)
		}
	}
	return ChatOptions{
		Model:        req.Model,
		Style:        style,
		Launch:       lp,
		HeaderPrefix: c.cfg.ExpectedHeaderPrefix,
	}, nil
}

// sendSessionError reports a failure that belongs to one session; the relay
// routes it to the client that owns the session.
func (c *WSClient) sendSessionError(sessionID string, err error) {
	c.sendTextMsg(context.Background(), "error", map[string]any{
		"session_id": sessionID,
		"message":    userMessage(err),
	})
}

// userMessage is the text shown on the iPhone for err: the strict profile
// message without its wrapped sentinel, else err's text.
func userMessage(err error) string {
	msg := err.Error()
	if errors.Is(err, errProfileNotFound) {
		msg = strings.TrimSuffix(msg, ": "+errProfileNotFound.Error())
	}
	return msg
}

// removeChatIfCurrent deletes the chats[id] entry only if it still points at
// sess. Without this identity check, an old session's delayed cleanup
// goroutine (its Done() can fire synchronously from Close(), well before the
// goroutine actually gets scheduled) can race a fresh connect that reuses
// the same session id: the disconnect deletes the old entry and closes it,
// the new connect finds no entry and installs a new session under the same
// id, and the stale goroutine then wakes up and deletes that new session
// instead of a no-op — orphaning it. Mirrors the identity check
// chat_session.go's readStdout already uses for cmd, for the same reason.
func (c *WSClient) removeChatIfCurrent(id string, sess *ChatSession) {
	c.mu.Lock()
	if c.chats[id] == sess {
		delete(c.chats, id)
	}
	c.mu.Unlock()
}

// sendChatEvents forwards normalised events to the relay as text frames.
func (c *WSClient) sendChatEvents(sessionID string, events []ChatEvent) {
	for _, e := range events {
		c.sendTextMsg(context.Background(), "chat_event", map[string]any{
			"session_id": sessionID,
			"event":      e,
		})
	}
}

func (c *WSClient) sendChatError(sessionID, message string) {
	c.sendTextMsg(context.Background(), "chat_event", map[string]any{
		"session_id": sessionID,
		"event": ChatEvent{
			Kind:    EventError,
			TS:      time.Now().UTC().Format(time.RFC3339),
			Message: message,
		},
	})
}

func (c *WSClient) chatSession(sessionID string) *ChatSession {
	c.mu.RLock()
	defer c.mu.RUnlock()
	return c.chats[sessionID]
}

func (c *WSClient) handleChatSend(payload json.RawMessage) {
	var req struct {
		SessionID string `json:"session_id"`
		Text      string `json:"text"`
		// Set by the relay for replies from notifications, which wait for
		// chat_send_result; plain socket sends carry none and get no reply.
		RequestID string `json:"request_id"`
	}
	if err := json.Unmarshal(payload, &req); err != nil {
		return
	}
	sess := c.chatSession(req.SessionID)
	var err error
	if sess != nil {
		if err = sess.Send(req.Text); err != nil {
			log.Printf("chat_send failed for %s: %v", req.SessionID, err)
		}
	}
	if req.RequestID != "" {
		c.sendTextMsg(context.Background(), "chat_send_result", chatSendAck(req.RequestID, sess != nil, err))
	}
}

// chatSendAck is the chat_send_result for a request that asked for one.
func chatSendAck(requestID string, found bool, err error) map[string]any {
	ack := map[string]any{"request_id": requestID, "ok": found && err == nil}
	switch {
	case !found:
		ack["error"] = "unknown chat session"
	case err != nil:
		ack["error"] = err.Error()
	}
	return ack
}

func (c *WSClient) handleChatInterrupt(payload json.RawMessage) {
	var req struct {
		SessionID string `json:"session_id"`
	}
	if err := json.Unmarshal(payload, &req); err != nil {
		return
	}
	if sess := c.chatSession(req.SessionID); sess != nil {
		sess.Interrupt()
	}
}

// chatHistoryPageBytes caps one chat_history_result batch well under both
// the relay's 4 MB message limit and the iOS client's own default 1 MiB read
// limit — the ring can hold up to defaultChatBufferSize events at up to a
// few KB each, so an unbounded replay could exceed either and, worse, get
// the agent's whole connection closed by the relay's SetReadLimit, dropping
// every session on the Mac.
const chatHistoryPageBytes = 256 * 1024

func (c *WSClient) handleChatHistory(ctx context.Context, payload json.RawMessage) {
	var req struct {
		SessionID string `json:"session_id"`
		RequestID string `json:"request_id"`
		AfterSeq  uint64 `json:"after_seq"`
	}
	if err := json.Unmarshal(payload, &req); err != nil {
		return
	}
	events := []ChatEvent{}
	var nextSeq uint64 = 1
	if sess := c.chatSession(req.SessionID); sess != nil {
		events, nextSeq = sess.HistoryPage(req.AfterSeq, chatHistoryPageBytes)
	}
	if events == nil {
		// ChatBuffer.SincePage always hands back a non-nil (possibly empty)
		// slice today, but that is an invariant of its implementation, not
		// of this function's signature — guard here too so a caller fully
		// caught up always gets JSON "events":[], never "events":null. iOS
		// tolerates null (its decoder defaults to an empty array), but
		// nothing guarantees every future client will.
		events = []ChatEvent{}
	}
	c.sendTextMsg(ctx, "chat_history_result", map[string]any{
		"request_id": req.RequestID,
		"events":     events,
		"next_seq":   nextSeq,
	})
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

	c.mu.Lock()
	chat := c.chats[req.SessionID]
	delete(c.chats, req.SessionID)
	c.mu.Unlock()
	if chat != nil {
		chat.Close()
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

	respPayload, _ := json.Marshal(sessionsListPayload(req.RequestID, sessions))
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
	if c.textOut != nil {
		c.textOut(ctx, msgType, payload)
		return
	}
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

// maxConcurrentGit bounds git requests running at once; they run off the
// read loop so a slow diff never stalls terminal input or chat.
const maxConcurrentGit = 2

var gitSlots = make(chan struct{}, maxConcurrentGit)

func (c *WSClient) runGitRequest(handle func()) {
	go func() {
		gitSlots <- struct{}{}
		defer func() { <-gitSlots }()
		handle()
	}()
}

// handleGitStatus answers git_status with the project's branch and changes.
func (c *WSClient) handleGitStatus(ctx context.Context, payload json.RawMessage) {
	var req struct {
		RequestID string `json:"request_id"`
		Path      string `json:"path"`
	}
	if err := json.Unmarshal(payload, &req); err != nil {
		return
	}
	st, err := gitStatus(ctx, req.Path)
	errStr := ""
	if err != nil {
		errStr = err.Error()
	}
	c.sendTextMsg(ctx, "git_status_result", map[string]any{
		"request_id": req.RequestID,
		"branch":     st.Branch,
		"upstream":   st.Upstream,
		"ahead":      st.Ahead,
		"behind":     st.Behind,
		"files":      st.Files,
		"total":      st.Total,
		"truncated":  st.Truncated,
		"error":      errStr,
	})
}

// handleGitDiff answers git_diff with the working-tree diff (capped).
func (c *WSClient) handleGitDiff(ctx context.Context, payload json.RawMessage) {
	var req struct {
		RequestID string   `json:"request_id"`
		Path      string   `json:"path"`
		Files     []string `json:"files"`
	}
	if err := json.Unmarshal(payload, &req); err != nil {
		return
	}
	diff, truncated, err := gitDiff(ctx, req.Path, req.Files)
	errStr := ""
	if err != nil {
		errStr = err.Error()
	}
	c.sendTextMsg(ctx, "git_diff_result", map[string]any{
		"request_id": req.RequestID,
		"diff":       diff,
		"truncated":  truncated,
		"error":      errStr,
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
