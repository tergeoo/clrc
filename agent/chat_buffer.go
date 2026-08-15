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
// and a client's own read limit.
//
// nextSeq always means the same thing in both branches below — "the highest
// seq this buffer has actually handed you" — so it is always safe to feed
// straight back in as afterSeq on the next call:
//   - page cut short by the byte budget: the seq of the last event actually
//     returned in this page.
//   - every matching event fit: b.next-1, the buffer's own high-water mark
//     (b.next is one *past* the last stamped seq, so b.next-1 is the last
//     one that was actually stamped; 0 if nothing has ever been appended).
//     Using b.next-1 here — not b.next, and not afterSeq unchanged — matters
//     for two reasons: b.next would skip exactly one future event (whatever
//     next gets stamped with the seq the caller was told was "next"), and
//     reporting the buffer's true tip rather than parroting afterSeq back is
//     what lets a caller notice the buffer itself has gone backwards — e.g.
//     after an agent restart resets a session's seq counter to 1 — because
//     nextSeq will come back lower than the afterSeq it asked with.
//
// The first event of a page is always included even if it alone would
// exceed maxBytes, so a pathologically large single event cannot stall
// pagination — every call makes forward progress.
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
	return all, b.next - 1
}
