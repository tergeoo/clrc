package main

import "encoding/json"

// Message is the envelope for all control messages over WebSocket (JSON frames).
type Message struct {
	Type    string          `json:"type"`
	Payload json.RawMessage `json:"payload"`
}
