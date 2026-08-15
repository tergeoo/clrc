package agent

import (
	"encoding/json"
	"sync"
)

// defaultChatBufferSize is how many recent events a chat session retains for
// replay after a client reconnects.
const defaultChatBufferSize = 2000

// ChatBuffer holds the recent tail of a session's events and is the single
// place the monotonic seq counter advances. Sub-project 2 replaces the
// in-memory ring with a disk-backed log behind this same surface.
type ChatBuffer struct {
	mu   sync.Mutex
	ring []ChatEvent
	cap  int
	next uint64
}

func NewChatBuffer(capacity int) *ChatBuffer {
	if capacity <= 0 {
		capacity = defaultChatBufferSize
	}
	return &ChatBuffer{ring: make([]ChatEvent, 0, capacity), cap: capacity, next: 1}
}

// Append stamps each event with the next seq and returns the stamped copies.
// Eviction never rewinds the counter, so seq stays monotonic for the life of
// the session even after the oldest events are dropped.
func (b *ChatBuffer) Append(events ...ChatEvent) []ChatEvent {
	b.mu.Lock()
	defer b.mu.Unlock()

	stamped := make([]ChatEvent, 0, len(events))
	for _, e := range events {
		e.Seq = b.next
		b.next++
		stamped = append(stamped, e)
		b.ring = append(b.ring, e)
	}
	if overflow := len(b.ring) - b.cap; overflow > 0 {
		b.ring = append(b.ring[:0], b.ring[overflow:]...)
	}
	return stamped
}

// Since returns every retained event with Seq greater than seq.
func (b *ChatBuffer) Since(seq uint64) []ChatEvent {
	b.mu.Lock()
	defer b.mu.Unlock()

	out := make([]ChatEvent, 0, len(b.ring))
	for _, e := range b.ring {
		if e.Seq > seq {
			out = append(out, e)
		}
	}
	return out
}

// NextSeq reports the seq the next appended event will receive.
func (b *ChatBuffer) NextSeq() uint64 {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.next
}

// SincePage returns retained events with Seq > afterSeq, capped to at most
// maxBytes of JSON-encoded payload. The ring holds up to defaultChatBufferSize
// events at up to a few KB each, so a full replay of Since(afterSeq) can
// reach several MB — comfortably over both the relay's message-size limit
// and a client's own read limit. nextSeq is the seq the caller should pass
// as afterSeq on its next call: the seq of the last event actually returned,
// if the page was cut short, or NextSeq() if every retained event fit (the
// caller is fully caught up). The first event of a page is always included
// even if it alone would exceed maxBytes, so a pathologically large single
// event cannot stall pagination — every call makes forward progress.
func (b *ChatBuffer) SincePage(afterSeq uint64, maxBytes int) (events []ChatEvent, nextSeq uint64) {
	b.mu.Lock()
	defer b.mu.Unlock()

	all := make([]ChatEvent, 0, len(b.ring))
	for _, e := range b.ring {
		if e.Seq > afterSeq {
			all = append(all, e)
		}
	}

	size := 0
	for i, e := range all {
		encoded, err := json.Marshal(e)
		if err != nil {
			continue
		}
		if i > 0 && size+len(encoded) > maxBytes {
			return all[:i], all[i-1].Seq
		}
		size += len(encoded)
	}
	return all, b.next
}
