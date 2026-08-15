package agent

import (
	"encoding/json"
	"strings"
)

// maxPayloadBytes caps tool input/output so a single event cannot approach
// the relay's 4 MB message limit (see spec §6.4).
const maxPayloadBytes = 4096

// ChatEventKind enumerates the normalised event types sent to clients.
// This is our contract — deliberately narrower and more stable than the
// Claude Code stream format it is derived from.
type ChatEventKind string

const (
	EventTurnStart  ChatEventKind = "turn_start"
	EventText       ChatEventKind = "text"
	EventToolUse    ChatEventKind = "tool_use"
	EventToolResult ChatEventKind = "tool_result"
	EventTurnEnd    ChatEventKind = "turn_end"
	EventError      ChatEventKind = "error"
)

// ChatEvent is one normalised event. Seq is stamped by ChatBuffer.Append,
// never by the translator — translation stays a pure function of its input.
type ChatEvent struct {
	Kind ChatEventKind `json:"kind"`
	Seq  uint64        `json:"seq"`
	TS   string        `json:"ts"`

	Text string `json:"text,omitempty"`

	ToolID    string `json:"tool_id,omitempty"`
	Name      string `json:"name,omitempty"`
	Input     string `json:"input,omitempty"`
	Output    string `json:"output,omitempty"`
	OK        *bool  `json:"ok,omitempty"`
	Truncated bool   `json:"truncated,omitempty"`

	NumTurns   int     `json:"num_turns,omitempty"`
	CostUSD    float64 `json:"cost_usd,omitempty"`
	DurationMS int     `json:"duration_ms,omitempty"`
	StopReason string  `json:"stop_reason,omitempty"`

	Message string `json:"message,omitempty"`
}

// rawLine is the subset of the Claude Code stream-json envelope we read.
type rawLine struct {
	Type    string `json:"type"`
	Subtype string `json:"subtype"`
	Message struct {
		Content []rawBlock `json:"content"`
	} `json:"message"`
	IsError       bool    `json:"is_error"`
	NumTurns      int     `json:"num_turns"`
	TotalCostUSD  float64 `json:"total_cost_usd"`
	DurationAPIMS int     `json:"duration_api_ms"`
	StopReason    string  `json:"stop_reason"`
}

type rawBlock struct {
	Type string `json:"type"`
	Text string `json:"text"`

	// tool_use
	ID    string          `json:"id"`
	Name  string          `json:"name"`
	Input json.RawMessage `json:"input"`

	// tool_result
	ToolUseID string          `json:"tool_use_id"`
	IsError   bool            `json:"is_error"`
	Content   json.RawMessage `json:"content"`
}

// truncatePayload caps a payload at maxPayloadBytes, reporting whether it cut.
// It respects UTF-8 boundaries: if truncation lands mid-sequence, the result
// is trimmed back to the last complete rune.
func truncatePayload(s string) (string, bool) {
	if len(s) <= maxPayloadBytes {
		return s, false
	}
	return strings.ToValidUTF8(s[:maxPayloadBytes], ""), true
}

// decodeContent renders a tool_result content field, which the CLI emits
// either as a plain string or as an array of blocks.
func decodeContent(raw json.RawMessage) string {
	if len(raw) == 0 {
		return ""
	}
	// Fast path: plain string.
	var s string
	if err := json.Unmarshal(raw, &s); err == nil {
		return s
	}
	// Array of blocks: extract text fields and join with newlines.
	var blocks []struct {
		Type string `json:"type"`
		Text string `json:"text"`
	}
	if err := json.Unmarshal(raw, &blocks); err == nil {
		var texts []string
		for _, b := range blocks {
			if b.Type == "text" && b.Text != "" {
				texts = append(texts, b.Text)
			}
		}
		if len(texts) > 0 {
			return strings.Join(texts, "\n")
		}
	}
	// No text blocks found: fall back to raw JSON.
	return string(raw)
}

// TranslateLine converts one raw JSONL line into zero or more normalised
// events. It is pure: no IO, no clock, no shared state. Unparseable input
// yields no events rather than an error — the CLI may write non-JSON to
// stdout and that must not kill a session.
func TranslateLine(line []byte, ts string) []ChatEvent {
	var raw rawLine
	if err := json.Unmarshal(line, &raw); err != nil {
		return nil
	}

	switch raw.Type {
	case "system":
		if raw.Subtype == "init" {
			return []ChatEvent{{Kind: EventTurnStart, TS: ts}}
		}
		return nil

	case "assistant":
		var out []ChatEvent
		for _, b := range raw.Message.Content {
			switch b.Type {
			case "text":
				if b.Text != "" {
					out = append(out, ChatEvent{Kind: EventText, TS: ts, Text: b.Text})
				}
			case "tool_use":
				input, cut := truncatePayload(string(b.Input))
				out = append(out, ChatEvent{
					Kind: EventToolUse, TS: ts,
					ToolID: b.ID, Name: b.Name,
					Input: input, Truncated: cut,
				})
			}
			// "thinking" and any future block type are deliberately dropped.
		}
		return out

	case "result":
		out := []ChatEvent{{
			Kind:       EventTurnEnd,
			TS:         ts,
			NumTurns:   raw.NumTurns,
			CostUSD:    raw.TotalCostUSD,
			DurationMS: raw.DurationAPIMS,
			StopReason: raw.StopReason,
		}}
		if raw.IsError {
			out = append(out, ChatEvent{Kind: EventError, TS: ts, Message: "turn ended with an error"})
		}
		return out

	case "user":
		var out []ChatEvent
		for _, b := range raw.Message.Content {
			if b.Type != "tool_result" {
				continue
			}
			output, cut := truncatePayload(decodeContent(b.Content))
			ok := !b.IsError
			out = append(out, ChatEvent{
				Kind: EventToolResult, TS: ts,
				ToolID: b.ToolUseID, OK: &ok,
				Output: output, Truncated: cut,
			})
		}
		return out
	}

	return nil
}
