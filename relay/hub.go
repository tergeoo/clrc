package main

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
type AgentConn struct {
	ID   string
	Name string
	conn *websocket.Conn
	mu   sync.Mutex
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
	unregisterAgent  chan string
	registerClient   chan *ClientConn
	unregisterClient chan *ClientConn

	// request_id → ClientConn for any pending async response (sessions_list, fs_*)
	pendingRequests sync.Map
}

type Session struct {
	ID     string
	Agent  *AgentConn
	Client *ClientConn
}

func NewHub() *Hub {
	return &Hub{
		agents:           make(map[string]*AgentConn),
		clients:          make(map[*ClientConn]struct{}),
		sessions:         make(map[string]*Session),
		registerAgent:    make(chan *AgentConn, 16),
		unregisterAgent:  make(chan string, 16),
		registerClient:   make(chan *ClientConn, 16),
		unregisterClient: make(chan *ClientConn, 16),
	}
}

func (h *Hub) Run() {
	for {
		select {
		case agent := <-h.registerAgent:
			h.mu.Lock()
			h.agents[agent.ID] = agent
			h.mu.Unlock()
			log.Printf("Agent registered: %s (%s)", agent.Name, agent.ID)
			h.broadcastAgentList()

		case agentID := <-h.unregisterAgent:
			h.mu.Lock()
			delete(h.agents, agentID)
			// Clean up sessions for this agent
			for sid, sess := range h.sessions {
				if sess.Agent.ID == agentID {
					delete(h.sessions, sid)
				}
			}
			h.mu.Unlock()
			log.Printf("Agent disconnected: %s", agentID)
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

func (h *Hub) broadcastAgentList() {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	h.mu.RLock()
	agents := make([]map[string]any, 0, len(h.agents))
	for _, a := range h.agents {
		agents = append(agents, map[string]any{
			"id":        a.ID,
			"name":      a.Name,
			"connected": true,
		})
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

// GetAgentList returns current agent list as JSON payload.
func (h *Hub) GetAgentList() []map[string]any {
	h.mu.RLock()
	defer h.mu.RUnlock()
	agents := make([]map[string]any, 0, len(h.agents))
	for _, a := range h.agents {
		agents = append(agents, map[string]any{
			"id":        a.ID,
			"name":      a.Name,
			"connected": true,
		})
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
func handleAgentWS(w http.ResponseWriter, r *http.Request, hub *Hub, agentSecret string) {
	conn, err := websocket.Accept(w, r, &websocket.AcceptOptions{
		InsecureSkipVerify: false,
	})
	if err != nil {
		log.Printf("Agent WS accept error: %v", err)
		return
	}
	defer conn.Close(websocket.StatusNormalClosure, "")

	ctx := r.Context()

	// First message must be "register"
	_, rawMsg, err := conn.Read(ctx)
	if err != nil {
		log.Printf("Agent register read error: %v", err)
		return
	}

	var msg Message
	if err := json.Unmarshal(rawMsg, &msg); err != nil || msg.Type != "register" {
		conn.Close(websocket.StatusPolicyViolation, "expected register message")
		return
	}

	var reg struct {
		AgentID string `json:"agent_id"`
		Name    string `json:"name"`
		Secret  string `json:"secret"`
	}
	if err := json.Unmarshal(msg.Payload, &reg); err != nil {
		conn.Close(websocket.StatusPolicyViolation, "invalid register payload")
		return
	}

	if reg.Secret != agentSecret {
		conn.Close(websocket.StatusPolicyViolation, "invalid secret")
		return
	}

	agent := &AgentConn{
		ID:   reg.AgentID,
		Name: reg.Name,
		conn: conn,
	}

	hub.registerAgent <- agent
	defer func() {
		hub.unregisterAgent <- agent.ID
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
			case "sessions_list", "fs_list_result", "fs_mkdir_result", "fs_delete_result", "fs_read_result":
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
			default:
				log.Printf("Agent %s: %s", agent.ID, data)
			}
		}
	}
}

// handleClientWS handles WebSocket connections from iOS clients.
func handleClientWS(w http.ResponseWriter, r *http.Request, hub *Hub, auth *Auth) {
	conn, err := websocket.Accept(w, r, &websocket.AcceptOptions{
		InsecureSkipVerify: false,
	})
	if err != nil {
		log.Printf("Client WS accept error: %v", err)
		return
	}
	defer conn.Close(websocket.StatusNormalClosure, "")

	ctx := r.Context()

	// First message must be "auth"
	_, rawMsg, err := conn.Read(ctx)
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

	// Start ping goroutine
	go func() {
		ticker := time.NewTicker(30 * time.Second)
		defer ticker.Stop()
		for {
			select {
			case <-ticker.C:
				if err := conn.Ping(ctx); err != nil {
					return
				}
			case <-ctx.Done():
				return
			}
		}
	}()

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
		case "list_sessions":
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
			fwd := Message{Type: "list_sessions", Payload: mustMarshal(map[string]string{"request_id": pl.RequestID})}
			fwdData, _ := json.Marshal(fwd)
			agent.Send(ctx, websocket.MessageText, fwdData)

		case "fs_list", "fs_mkdir", "fs_delete", "fs_read":
			handleClientFSRequest(ctx, incoming, client, hub)

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
