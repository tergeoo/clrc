// Package proto documents the WebSocket message protocol used between
// relay server, Mac agents, and iOS clients.
// This file is documentation only — not imported by any component.
package proto

import "encoding/json"

// Message is the envelope for all control messages (JSON WebSocket frames).
type Message struct {
	Type    string          `json:"type"`
	Payload json.RawMessage `json:"payload"`
}

// ─── Agent → Relay ────────────────────────────────────────────────────────────

// RegisterPayload is the first message an agent sends upon connection.
type RegisterPayload struct {
	AgentID string `json:"agent_id"` // Unique identifier from config
	Name    string `json:"name"`     // Human-readable name (e.g. hostname)
	Secret  string `json:"secret"`   // Pre-shared secret for authentication
}

// ─── Client → Relay ───────────────────────────────────────────────────────────

// AuthPayload is the first message a client sends upon connection.
type AuthPayload struct {
	Token string `json:"token"` // JWT access token
}

// ConnectPayload requests a new PTY session on a specific agent.
type ConnectPayload struct {
	AgentID   string `json:"agent_id"`   // Target agent
	SessionID string `json:"session_id"` // UUID chosen by client
	Cols      uint16 `json:"cols"`       // Initial terminal width
	Rows      uint16 `json:"rows"`       // Initial terminal height
}

// ResizePayload updates the PTY window size for an active session.
type ResizePayload struct {
	SessionID string `json:"session_id"`
	Cols      uint16 `json:"cols"`
	Rows      uint16 `json:"rows"`
}

// DisconnectPayload terminates a session.
type DisconnectPayload struct {
	SessionID string `json:"session_id"`
}

// ─── Relay → Client ───────────────────────────────────────────────────────────

// AgentListPayload is sent after auth and whenever agents connect/disconnect.
type AgentListPayload struct {
	Agents []AgentInfo `json:"agents"`
}

type AgentInfo struct {
	ID        string `json:"id"`
	Name      string `json:"name"`
	Connected bool   `json:"connected"`
}

// SessionReadyPayload confirms a session has been established on the agent.
type SessionReadyPayload struct {
	SessionID string `json:"session_id"`
}

// ErrorPayload carries a human-readable error message.
type ErrorPayload struct {
	Message string `json:"message"`
}

// ─── Binary Framing ───────────────────────────────────────────────────────────
//
// All terminal I/O uses binary WebSocket frames with the following layout:
//
//   ┌──────────────────┬─────────────────┬───────────────────┐
//   │ sid_len: uint32  │ session_id: str  │ terminal data     │
//   │ (4 bytes, BE)    │ (sid_len bytes)  │ (remaining bytes) │
//   └──────────────────┴─────────────────┴───────────────────┘
//
// Direction:
//   client → relay → agent  : keyboard/input bytes
//   agent  → relay → client : stdout/stderr ANSI bytes
