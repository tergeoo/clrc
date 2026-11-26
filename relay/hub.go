package relay

import (
	"context"
	"encoding/binary"
	"encoding/json"
	"log"
	"net/http"
	"sync"
	"time"

	"nhooyr.io/websocket"
)

// AgentConn represents a connected Mac agent.
// StatusAgentReplaced closes an agent connection whose ID was registered
// again by a newer connection. The agent reconnects on it like on any drop.
const StatusAgentReplaced websocket.StatusCode = 4001

type AgentConn struct {
	ID   string
	Name string
	// Version is the agent build version from register; empty before 2.1.
	Version string
	conn    *websocket.Conn
	mu      sync.Mutex
}

func (a *AgentConn) Send(ctx context.Context, msgType websocket.MessageType, data []byte) error {
	a.mu.Lock()
	defer a.mu.Unlock()
	return a.conn.Write(ctx, msgType, data)
}

// ClientConn represents a connected iOS client.
type ClientConn struct {
	conn *websocket.Conn
	mu   sync.Mutex
	// maps session_id → agent_id for sessions this client owns
	sessions map[string]string
}

func (c *ClientConn) Send(ctx context.Context, msgType websocket.MessageType, data []byte) error {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.conn.Write(ctx, msgType, data)
}

func (c *ClientConn) SendJSON(ctx context.Context, v any) error {
	data, err := json.Marshal(v)
	if err != nil {
		return err
	}
	return c.Send(ctx, websocket.MessageText, data)
}

// Hub manages all agent and client connections.
type Hub struct {
	agents  map[string]*AgentConn
	clients map[*ClientConn]struct{}
	// session_id → (agent, client) pair
	sessions map[string]*Session
	mu       sync.RWMutex

	registerAgent    chan *AgentConn
	unregisterAgent  chan *AgentConn
	registerClient   chan *ClientConn
	unregisterClient chan *ClientConn

	// Report pushes: devices registered by clients, and the APNs sender
	// (nil when push is not configured).
	pushRegistry *PushRegistry
	pushSender   PushSender

	// request_id → chan replyAck for /chat/reply waiting on the agent.
	pendingReplies sync.Map

	// request_id → ClientConn for any pending async response (sessions_list, fs_*)
	pendingRequests sync.Map
}

type Session struct {
	ID     string
	Agent  *AgentConn
	Client *ClientConn
}

// SetPush enables report pushes through sender (nil disables them).
func (h *Hub) SetPush(sender PushSender) {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.pushSender = sender
}

func (h *Hub) push() PushSender {
	h.mu.RLock()
	defer h.mu.RUnlock()
	return h.pushSender
}

func NewHub() *Hub {
	return &Hub{
		pushRegistry:     NewPushRegistry(),
		agents:           make(map[string]*AgentConn),
		clients:          make(map[*ClientConn]struct{}),
		sessions:         make(map[string]*Session),
		registerAgent:    make(chan *AgentConn, 16),
		unregisterAgent:  make(chan *AgentConn, 16),
		registerClient:   make(chan *ClientConn, 16),
		unregisterClient: make(chan *ClientConn, 16),
	}
}

func (h *Hub) Run() {
	for {
		select {
		case agent := <-h.registerAgent:
			if replaced := h.addAgent(agent); replaced != nil {
				// The relay no longer routes to the old socket; close it so
				// that agent reconnects instead of believing it is online.
				log.Printf("Agent %s connected again; closing its previous connection", agent.ID)
				go replaced.conn.Close(StatusAgentReplaced, "replaced by a newer connection")
			}
			log.Printf("Agent registered: %s (%s), version %q", agent.Name, agent.ID, agent.Version)
			h.broadcastAgentList()

		case agent := <-h.unregisterAgent:
			if h.removeAgent(agent) {
				log.Printf("Agent disconnected: %s", agent.ID)
			} else {
				log.Printf("Stale agent connection closed: %s (a newer one is registered)", agent.ID)
			}
			h.broadcastAgentList()

		case client := <-h.registerClient:
			h.mu.Lock()
			h.clients[client] = struct{}{}
			h.mu.Unlock()

		case client := <-h.unregisterClient:
			h.mu.Lock()
			delete(h.clients, client)
			// Client disconnected unexpectedly — detach sessions (keep PTY alive on agent)
			for sid, sess := range h.sessions {
				if sess.Client == client {
					delete(h.sessions, sid)
					go func(ag *AgentConn, sessionID string) {
						ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
						defer cancel()
						msg := Message{
							Type:    "detach",
							Payload: mustMarshal(map[string]string{"session_id": sessionID}),
						}
						data, _ := json.Marshal(msg)
						ag.Send(ctx, websocket.MessageText, data)
					}(sess.Agent, sid)
				}
			}
			h.mu.Unlock()
		}
	}
}

// addAgent registers conn under its ID, replacing any older connection,
// and returns the replaced connection (nil if there was none).
func (h *Hub) addAgent(conn *AgentConn) *AgentConn {
	h.mu.Lock()
	defer h.mu.Unlock()
	old := h.agents[conn.ID]
	h.agents[conn.ID] = conn
	if old == conn {
		return nil
	}
	return old
}

// removeAgent drops the sessions routed through conn and, if conn is still
// the registered connection for its ID, the agent itself. A quickly
// reconnecting agent registers its new connection before the old one's
// disconnect is processed; matching by connection rather than by ID keeps
// that stale disconnect from evicting the live agent. Reports whether the
// agent was removed.
func (h *Hub) removeAgent(conn *AgentConn) bool {
	h.mu.Lock()
	defer h.mu.Unlock()
	for sid, sess := range h.sessions {
		if sess.Agent == conn {
			delete(h.sessions, sid)
		}
	}
	if h.agents[conn.ID] != conn {
		return false
	}
	delete(h.agents, conn.ID)
	return true
}

func (h *Hub) broadcastAgentList() {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	h.mu.RLock()
	agents := make([]map[string]any, 0, len(h.agents))
	for _, a := range h.agents {
		agents = append(agents, agentListEntry(a))
	}
	clients := make([]*ClientConn, 0, len(h.clients))
	for c := range h.clients {
		clients = append(clients, c)
	}
	h.mu.RUnlock()

	msg := Message{
		Type:    "agent_list",
		Payload: mustMarshal(map[string]any{"agents": agents}),
	}
	data, _ := json.Marshal(msg)

	for _, c := range clients {
		go c.Send(ctx, websocket.MessageText, data)
	}
}

// agentListEntry is one agent in an "agent_list" message. "version" is
// omitted for agents that did not report one, so old clients see no change.
func agentListEntry(a *AgentConn) map[string]any {
	entry := map[string]any{"id": a.ID, "name": a.Name, "connected": true}
	if a.Version != "" {
		entry["version"] = a.Version
	}
	return entry
}

// GetAgentList returns current agent list as JSON payload.
func (h *Hub) GetAgentList() []map[string]any {
	h.mu.RLock()
	defer h.mu.RUnlock()
	agents := make([]map[string]any, 0, len(h.agents))
	for _, a := range h.agents {
		agents = append(agents, agentListEntry(a))
	}
	return agents
}

// GetAgent returns agent by ID.
func (h *Hub) GetAgent(id string) (*AgentConn, bool) {
	h.mu.RLock()
	defer h.mu.RUnlock()
	a, ok := h.agents[id]
	return a, ok
}

// AgentCount returns the number of connected agents.
func (h *Hub) AgentCount() int {
	h.mu.RLock()
	defer h.mu.RUnlock()
	return len(h.agents)
}

// ClientCount returns the number of connected clients.
func (h *Hub) ClientCount() int {
	h.mu.RLock()
	defer h.mu.RUnlock()
	return len(h.clients)
}

// CreateSession registers a new session.
func (h *Hub) CreateSession(sessionID string, agent *AgentConn, client *ClientConn) {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.sessions[sessionID] = &Session{ID: sessionID, Agent: agent, Client: client}
}

// RouteToClient routes binary data from agent to the correct client.
func (h *Hub) RouteToClient(sessionID string, data []byte) {
	h.mu.RLock()
	sess, ok := h.sessions[sessionID]
	h.mu.RUnlock()
	if !ok {
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	frame := encodeBinaryFrame(sessionID, data)
	sess.Client.Send(ctx, websocket.MessageBinary, frame)
}

// RouteToAgent routes binary data from client to the correct agent.
func (h *Hub) RouteToAgent(sessionID string, data []byte) {
	h.mu.RLock()
	sess, ok := h.sessions[sessionID]
	h.mu.RUnlock()
	if !ok {
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	frame := encodeBinaryFrame(sessionID, data)
	sess.Agent.Send(ctx, websocket.MessageBinary, frame)
}

// RouteTextToClient forwards a raw text control message to the client that
// owns sessionID. Unlike RouteToClient it does not wrap in a binary frame —
// chat traffic is JSON on the text channel.
func (h *Hub) RouteTextToClient(sessionID string, data []byte) bool {
	h.mu.RLock()
	sess, ok := h.sessions[sessionID]
	h.mu.RUnlock()
	if !ok {
		return false
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	return sess.Client.Send(ctx, websocket.MessageText, data) == nil
}

// RouteTextToAgent forwards a raw text control message to the agent that
// owns sessionID.
func (h *Hub) RouteTextToAgent(sessionID string, data []byte) bool {
	h.mu.RLock()
	sess, ok := h.sessions[sessionID]
	h.mu.RUnlock()
	if !ok {
		return false
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	return sess.Agent.Send(ctx, websocket.MessageText, data) == nil
}

// encodeBinaryFrame encodes: [4 bytes session_id len][session_id][data]
func encodeBinaryFrame(sessionID string, data []byte) []byte {
	sidBytes := []byte(sessionID)
	frame := make([]byte, 4+len(sidBytes)+len(data))
	binary.BigEndian.PutUint32(frame[:4], uint32(len(sidBytes)))
	copy(frame[4:], sidBytes)
	copy(frame[4+len(sidBytes):], data)
	return frame
}

// decodeBinaryFrame decodes a binary frame, returns sessionID and payload.
func decodeBinaryFrame(frame []byte) (string, []byte, bool) {
	if len(frame) < 4 {
		return "", nil, false
	}
	sidLen := binary.BigEndian.Uint32(frame[:4])
	if uint32(len(frame)) < 4+sidLen {
		return "", nil, false
	}
	sessionID := string(frame[4 : 4+sidLen])
	data := frame[4+sidLen:]
	return sessionID, data, true
}

func mustMarshal(v any) json.RawMessage {
	b, _ := json.Marshal(v)
	return b
}

// handleAgentWS handles WebSocket connections from Mac agents.
func HandleAgentWS(w http.ResponseWriter, r *http.Request, hub *Hub, agentSecret string) {
	conn, err := websocket.Accept(w, r, &websocket.AcceptOptions{
		InsecureSkipVerify: false,
	})
	if err != nil {
		log.Printf("Agent WS accept error: %v", err)
		return
	}
	defer conn.Close(websocket.StatusNormalClosure, "")
	conn.SetReadLimit(maxMessageBytes)

	ctx := r.Context()

	// First message must be "register" — bounded so an idle unauthenticated
	// socket cannot linger (it would never be counted by the connection caps).
	handshakeCtx, cancelHandshake := context.WithTimeout(ctx, 10*time.Second)
	_, rawMsg, err := conn.Read(handshakeCtx)
	cancelHandshake()
	if err != nil {
		log.Printf("Agent register read error: %v", err)
		return
	}

	var msg Message
	if err := json.Unmarshal(rawMsg, &msg); err != nil || msg.Type != "register" {
		conn.Close(websocket.StatusPolicyViolation, "expected register message")
		return
	}

	var reg registerReq
	if err := json.Unmarshal(msg.Payload, &reg); err != nil {
		conn.Close(websocket.StatusPolicyViolation, "invalid register payload")
		return
	}

	if reg.Secret != agentSecret {
		conn.Close(websocket.StatusPolicyViolation, "invalid secret")
		return
	}

	if err := reg.validate(); err != nil {
		conn.Close(websocket.StatusPolicyViolation, "invalid agent identity")
		return
	}

	if hub.AgentCount() >= maxAgents {
		conn.Close(websocket.StatusTryAgainLater, "agent limit reached")
		return
	}

	agent := &AgentConn{
		ID:      reg.AgentID,
		Name:    reg.Name,
		Version: reg.Version,
		conn:    conn,
	}

	hub.registerAgent <- agent
	defer func() {
		hub.unregisterAgent <- agent
	}()

	// Read loop
	for {
		msgType, data, err := conn.Read(ctx)
		if err != nil {
			break
		}

		if msgType == websocket.MessageBinary {
			// Binary: [session_id_len][session_id][terminal data]
			sessionID, payload, ok := decodeBinaryFrame(data)
			if ok {
				hub.RouteToClient(sessionID, payload)
			}
		} else {
			// Text: route async responses back to waiting client
			var textMsg Message
			if err := json.Unmarshal(data, &textMsg); err != nil {
				continue
			}
			switch textMsg.Type {
			case "sessions_list", "fs_list_result", "fs_mkdir_result", "fs_delete_result", "fs_read_result", "chat_history_result",
				"git_status_result", "git_diff_result", "profiles_list_result":
				var pl struct {
					RequestID string `json:"request_id"`
				}
				json.Unmarshal(textMsg.Payload, &pl)
				if v, ok := hub.pendingRequests.LoadAndDelete(pl.RequestID); ok {
					cl := v.(*ClientConn)
					respData, _ := json.Marshal(textMsg)
					routeCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
					cl.Send(routeCtx, websocket.MessageText, respData)
					cancel()
				}
			case "error":
				// An error about one session (e.g. a refused strict profile)
				// goes to the client that owns it; agent-wide errors stay in
				// the log.
				var pl struct {
					SessionID string `json:"session_id"`
				}
				json.Unmarshal(textMsg.Payload, &pl)
				if pl.SessionID == "" {
					log.Printf("Agent %s error (no session)", agent.ID)
					break
				}
				hub.RouteTextToClient(pl.SessionID, data)
			case "chat_send_result":
				var ack replyAck
				json.Unmarshal(textMsg.Payload, &ack)
				if v, ok := hub.pendingReplies.LoadAndDelete(ack.RequestID); ok {
					select {
					case v.(chan replyAck) <- ack:
					default:
					}
				}
			case "chat_event":
				var pl struct {
					SessionID string `json:"session_id"`
					Event     struct {
						Kind   string         `json:"kind"`
						Report *reportPayload `json:"report"`
					} `json:"event"`
				}
				json.Unmarshal(textMsg.Payload, &pl)
				hub.RouteTextToClient(pl.SessionID, data)
				// Pushes go out whether or not a client is attached — a
				// backgrounded phone has no route, which is when it matters.
				if sender := hub.push(); sender != nil && pl.Event.Kind == "report" && pl.Event.Report != nil {
					pushReport(sender, hub.pushRegistry, agent.ID, pl.SessionID, *pl.Event.Report)
				}
			default:
				log.Printf("Agent %s: %s", agent.ID, data)
			}
		}
	}
}

// pingInterval is how often the relay pings a connected iOS client to check
// liveness. pingTimeout bounds each individual ping: long enough to tolerate
// a slow network, short enough that a client which stopped responding (e.g.
// a phone that locked or suspended) is noticed in seconds rather than never.
// Kept equal to the agent's own pingInterval/pingTimeout (agent/ws_client.go)
// so both ends of the link read alike.
const (
	pingInterval = 30 * time.Second
	pingTimeout  = 10 * time.Second
)

// pinger is the subset of *websocket.Conn the ping watchdog needs. Extracting
// it lets tests exercise runPingWatchdog against a real half-open connection
// without going through the full client handshake.
type pinger interface {
	Ping(ctx context.Context) error
}

// runPingWatchdog pings conn every interval until ctx is done or a ping
// fails, then returns.
//
// Each ping gets its own bounded context derived from ctx, rather than ctx
// itself. That distinction is the whole point: nhooyr.io/websocket's
// Conn.Ping blocks until a pong arrives or its context is done. ctx here
// (the connection's request context) has no deadline of its own, so a client
// that stops responding — exactly what a phone that locked or suspended
// looks like — would otherwise leave Ping, and this goroutine, blocked
// forever. This is the identical defect (and fix) already applied to the
// agent's own keepalive ping in agent/ws_client.go (commit 645ccc1); see its
// runPingWatchdog for the fuller writeup of the underlying mechanism.
//
// A failed ping is not treated as fatal to the connection here: the read
// loop in HandleClientWS independently notices a dead client once its own
// Read fails (see CLAUDE.md on connection lifecycle), so this goroutine's
// only job is to stop pinging — and stop existing — once the client is no
// longer answering, not to tear the connection down itself.
func runPingWatchdog(ctx context.Context, conn pinger, interval, timeout time.Duration) {
	ticker := time.NewTicker(interval)
	defer ticker.Stop()
	for {
		select {
		case <-ticker.C:
			pingCtx, cancelPing := context.WithTimeout(ctx, timeout)
			err := conn.Ping(pingCtx)
			cancelPing()
			if err != nil {
				return
			}
		case <-ctx.Done():
			return
		}
	}
}

// handleClientWS handles WebSocket connections from iOS clients.
func HandleClientWS(w http.ResponseWriter, r *http.Request, hub *Hub, auth *Auth) {
	conn, err := websocket.Accept(w, r, &websocket.AcceptOptions{
		InsecureSkipVerify: false,
	})
	if err != nil {
		log.Printf("Client WS accept error: %v", err)
		return
	}
	defer conn.Close(websocket.StatusNormalClosure, "")
	conn.SetReadLimit(maxMessageBytes)

	ctx := r.Context()

	// First message must be "auth" — bounded so an idle unauthenticated socket
	// cannot linger (it would never be counted by the connection caps).
	handshakeCtx, cancelHandshake := context.WithTimeout(ctx, 10*time.Second)
	_, rawMsg, err := conn.Read(handshakeCtx)
	cancelHandshake()
	if err != nil {
		return
	}

	var msg Message
	if err := json.Unmarshal(rawMsg, &msg); err != nil || msg.Type != "auth" {
		conn.Close(websocket.StatusPolicyViolation, "expected auth message")
		return
	}

	var authPayload struct {
		Token string `json:"token"`
	}
	if err := json.Unmarshal(msg.Payload, &authPayload); err != nil {
		conn.Close(websocket.StatusPolicyViolation, "invalid auth payload")
		return
	}

	if _, err := auth.ValidateAccessToken(authPayload.Token); err != nil {
		conn.Close(websocket.StatusPolicyViolation, "invalid token")
		return
	}

	if hub.ClientCount() >= maxClients {
		conn.Close(websocket.StatusTryAgainLater, "client limit reached")
		return
	}

	client := &ClientConn{
		conn:     conn,
		sessions: make(map[string]string),
	}

	hub.registerClient <- client
	defer func() {
		hub.unregisterClient <- client
	}()

	// Send current agent list
	agents := hub.GetAgentList()
	listMsg := Message{
		Type:    "agent_list",
		Payload: mustMarshal(map[string]any{"agents": agents}),
	}
	listData, _ := json.Marshal(listMsg)
	conn.Write(ctx, websocket.MessageText, listData)

	// Start ping goroutine — see runPingWatchdog for why each ping needs its
	// own bounded context rather than reusing ctx directly.
	go runPingWatchdog(ctx, conn, pingInterval, pingTimeout)

	// Read loop
	for {
		msgType, data, err := conn.Read(ctx)
		if err != nil {
			break
		}

		if msgType == websocket.MessageBinary {
			sessionID, payload, ok := decodeBinaryFrame(data)
			if ok {
				hub.RouteToAgent(sessionID, payload)
			}
			continue
		}

		// Text: control messages
		var incoming Message
		if err := json.Unmarshal(data, &incoming); err != nil {
			continue
		}

		switch incoming.Type {
		case "list_sessions", "profiles_list":
			var pl struct {
				AgentID   string `json:"agent_id"`
				RequestID string `json:"request_id"`
			}
			if err := json.Unmarshal(incoming.Payload, &pl); err != nil || pl.AgentID == "" {
				break
			}
			agent, ok := hub.GetAgent(pl.AgentID)
			if !ok {
				break
			}
			hub.pendingRequests.Store(pl.RequestID, client)
			fwd := Message{Type: incoming.Type, Payload: mustMarshal(map[string]string{"request_id": pl.RequestID})}
			fwdData, _ := json.Marshal(fwd)
			agent.Send(ctx, websocket.MessageText, fwdData)

		case "fs_list", "fs_mkdir", "fs_delete", "fs_read":
			handleClientFSRequest(ctx, incoming, client, hub)

		case "git_status", "git_diff":
			handleClientGitRequest(ctx, incoming, client, hub)

		case "push_register":
			var device PushDevice
			if err := json.Unmarshal(incoming.Payload, &device); err != nil {
				break
			}
			if err := hub.pushRegistry.Register(device); err != nil {
				log.Printf("push_register rejected: %v", err)
			}

		case "chat_send", "chat_interrupt":
			var pl struct {
				SessionID string `json:"session_id"`
			}
			if err := json.Unmarshal(incoming.Payload, &pl); err != nil {
				break
			}
			if !hub.RouteTextToAgent(pl.SessionID, data) {
				log.Printf("%s dropped: no route for session %s", incoming.Type, logSafeSessionID(pl.SessionID))
			}

		case "chat_history":
			var pl struct {
				AgentID   string `json:"agent_id"`
				SessionID string `json:"session_id"`
				RequestID string `json:"request_id"`
				AfterSeq  uint64 `json:"after_seq"`
			}
			if err := json.Unmarshal(incoming.Payload, &pl); err != nil || pl.AgentID == "" || pl.RequestID == "" {
				break
			}
			agent, ok := hub.GetAgent(pl.AgentID)
			if !ok {
				break
			}
			hub.pendingRequests.Store(pl.RequestID, client)
			fwd := Message{Type: "chat_history", Payload: mustMarshal(map[string]any{
				"session_id": pl.SessionID,
				"request_id": pl.RequestID,
				"after_seq":  pl.AfterSeq,
			})}
			fwdData, _ := json.Marshal(fwd)
			agent.Send(ctx, websocket.MessageText, fwdData)

		case "list":
			agents := hub.GetAgentList()
			resp := Message{
				Type:    "agent_list",
				Payload: mustMarshal(map[string]any{"agents": agents}),
			}
			respData, _ := json.Marshal(resp)
			conn.Write(ctx, websocket.MessageText, respData)

		case "connect":
			handleClientConnect(ctx, incoming, client, hub, conn)

		case "resize":
			handleClientResize(ctx, incoming, hub, conn)

		case "disconnect":
			handleClientDisconnect(ctx, incoming, client, hub)
		}
	}
}

func handleClientConnect(ctx context.Context, msg Message, client *ClientConn, hub *Hub, conn *websocket.Conn) {
	var payload struct {
		AgentID   string `json:"agent_id"`
		SessionID string `json:"session_id"`
		Cols      uint16 `json:"cols"`
		Rows      uint16 `json:"rows"`
	}
	if err := json.Unmarshal(msg.Payload, &payload); err != nil {
		return
	}

	if !validSessionID(payload.SessionID) {
		errMsg, _ := json.Marshal(Message{
			Type:    "error",
			Payload: mustMarshal(map[string]string{"message": "invalid session id"}),
		})
		conn.Write(ctx, websocket.MessageText, errMsg)
		return
	}

	agent, ok := hub.GetAgent(payload.AgentID)
	if !ok {
		errMsg, _ := json.Marshal(Message{
			Type:    "error",
			Payload: mustMarshal(map[string]string{"message": "agent not found"}),
		})
		conn.Write(ctx, websocket.MessageText, errMsg)
		return
	}

	hub.CreateSession(payload.SessionID, agent, client)

	// Forward connect to agent
	fwd := Message{
		Type:    "connect",
		Payload: msg.Payload,
	}
	fwdData, _ := json.Marshal(fwd)
	agent.Send(ctx, websocket.MessageText, fwdData)

	// Notify client session is ready
	ready, _ := json.Marshal(Message{
		Type:    "session_ready",
		Payload: mustMarshal(map[string]string{"session_id": payload.SessionID}),
	})
	conn.Write(ctx, websocket.MessageText, ready)
}

func handleClientResize(ctx context.Context, msg Message, hub *Hub, conn *websocket.Conn) {
	var payload struct {
		SessionID string `json:"session_id"`
		Cols      uint16 `json:"cols"`
		Rows      uint16 `json:"rows"`
	}
	if err := json.Unmarshal(msg.Payload, &payload); err != nil {
		return
	}

	hub.mu.RLock()
	sess, ok := hub.sessions[payload.SessionID]
	hub.mu.RUnlock()
	if !ok {
		return
	}

	fwd := Message{Type: "resize", Payload: msg.Payload}
	fwdData, _ := json.Marshal(fwd)
	sess.Agent.Send(ctx, websocket.MessageText, fwdData)
}

func handleClientDisconnect(ctx context.Context, msg Message, client *ClientConn, hub *Hub) {
	var payload struct {
		SessionID string `json:"session_id"`
	}
	if err := json.Unmarshal(msg.Payload, &payload); err != nil {
		return
	}

	hub.mu.Lock()
	sess, ok := hub.sessions[payload.SessionID]
	if ok {
		delete(hub.sessions, payload.SessionID)
	}
	hub.mu.Unlock()

	if ok {
		fwd := Message{Type: "disconnect", Payload: msg.Payload}
		fwdData, _ := json.Marshal(fwd)
		sess.Agent.Send(ctx, websocket.MessageText, fwdData)
	}
}

// handleClientGitRequest routes git_status / git_diff to the agent: the
// payload is forwarded as is (path, files, …) minus agent_id, and the
// *_result is matched back by request_id like the fs requests.
func handleClientGitRequest(ctx context.Context, msg Message, client *ClientConn, hub *Hub) {
	var pl map[string]json.RawMessage
	if err := json.Unmarshal(msg.Payload, &pl); err != nil {
		return
	}
	var agentID, requestID string
	json.Unmarshal(pl["agent_id"], &agentID)
	json.Unmarshal(pl["request_id"], &requestID)
	if agentID == "" || requestID == "" {
		return
	}
	agent, ok := hub.GetAgent(agentID)
	if !ok {
		return
	}
	delete(pl, "agent_id")
	hub.pendingRequests.Store(requestID, client)
	fwd := Message{Type: msg.Type, Payload: mustMarshal(pl)}
	fwdData, _ := json.Marshal(fwd)
	agent.Send(ctx, websocket.MessageText, fwdData)
}

// handleClientFSRequest routes fs_list / fs_mkdir / fs_delete / fs_read to the agent.
func handleClientFSRequest(ctx context.Context, msg Message, client *ClientConn, hub *Hub) {
	var pl struct {
		AgentID   string `json:"agent_id"`
		RequestID string `json:"request_id"`
		Path      string `json:"path"`
	}
	if err := json.Unmarshal(msg.Payload, &pl); err != nil || pl.AgentID == "" || pl.RequestID == "" {
		return
	}
	agent, ok := hub.GetAgent(pl.AgentID)
	if !ok {
		return
	}
	hub.pendingRequests.Store(pl.RequestID, client)
	// Forward to agent — strip agent_id, keep request_id and path
	fwdPayload, _ := json.Marshal(map[string]string{
		"request_id": pl.RequestID,
		"path":       pl.Path,
	})
	fwd := Message{Type: msg.Type, Payload: fwdPayload}
	fwdData, _ := json.Marshal(fwd)
	agent.Send(ctx, websocket.MessageText, fwdData)
}
