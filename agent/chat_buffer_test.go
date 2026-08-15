package agent

import (
	"strings"
	"sync"
	"testing"
)

func TestChatBufferStampsSequentialSeq(t *testing.T) {
	b := NewChatBuffer(10)
	got := b.Append(ChatEvent{Kind: EventText}, ChatEvent{Kind: EventText})
	if len(got) != 2 || got[0].Seq != 1 || got[1].Seq != 2 {
		t.Fatalf("seq not stamped from 1: %+v", got)
	}
	next := b.Append(ChatEvent{Kind: EventTurnEnd})
	if next[0].Seq != 3 {
		t.Fatalf("seq = %d, want 3", next[0].Seq)
	}
}

func TestChatBufferSinceReturnsTail(t *testing.T) {
	b := NewChatBuffer(10)
	b.Append(ChatEvent{Kind: EventText}, ChatEvent{Kind: EventText}, ChatEvent{Kind: EventText})
	tail := b.Since(1)
	if len(tail) != 2 || tail[0].Seq != 2 || tail[1].Seq != 3 {
		t.Fatalf("Since(1) = %+v, want seq 2 and 3", tail)
	}
	if len(b.Since(3)) != 0 {
		t.Fatal("Since(latest) must be empty")
	}
	if len(b.Since(0)) != 3 {
		t.Fatal("Since(0) must return everything held")
	}
}

func TestChatBufferEvictsOldest(t *testing.T) {
	b := NewChatBuffer(2)
	b.Append(ChatEvent{Kind: EventText}, ChatEvent{Kind: EventText}, ChatEvent{Kind: EventText})
	all := b.Since(0)
	if len(all) != 2 {
		t.Fatalf("held %d events, want cap of 2", len(all))
	}
	if all[0].Seq != 2 || all[1].Seq != 3 {
		t.Fatalf("wrong events retained: %+v", all)
	}
	if b.NextSeq() != 4 {
		t.Fatalf("NextSeq = %d, want 4 — eviction must not rewind the counter", b.NextSeq())
	}
}

func TestChatBufferSincePageReturnsEverythingUnderBudget(t *testing.T) {
	b := NewChatBuffer(10)
	b.Append(ChatEvent{Kind: EventText, Text: "a"}, ChatEvent{Kind: EventText, Text: "b"})
	events, nextSeq := b.SincePage(0, 1<<20) // budget far larger than these two events
	if len(events) != 2 {
		t.Fatalf("got %d events, want 2", len(events))
	}
	if nextSeq != b.NextSeq() {
		t.Fatalf("nextSeq = %d, want NextSeq() = %d when the caller is fully caught up", nextSeq, b.NextSeq())
	}
}

func TestChatBufferSincePageCapsByByteBudget(t *testing.T) {
	b := NewChatBuffer(100)
	// Each event carries a payload comfortably larger than a tiny budget, so
	// only the first should fit and the rest must be deferred to a later page.
	payload := strings.Repeat("x", 200)
	for i := 0; i < 5; i++ {
		b.Append(ChatEvent{Kind: EventText, Text: payload})
	}

	events, nextSeq := b.SincePage(0, 250) // budget: room for ~1 event, not 5
	if len(events) == 0 || len(events) >= 5 {
		t.Fatalf("got %d events, want a partial page (not 0, not all 5)", len(events))
	}
	if nextSeq != events[len(events)-1].Seq {
		t.Fatalf("nextSeq = %d, want the seq of the last event returned (%d) so the next call resumes correctly", nextSeq, events[len(events)-1].Seq)
	}
	if nextSeq == b.NextSeq() {
		t.Fatal("nextSeq must not claim the caller is caught up when events were held back")
	}

	// Paging with the returned nextSeq must eventually deliver the rest.
	rest, finalNext := b.SincePage(nextSeq, 1<<20)
	if len(events)+len(rest) != 5 {
		t.Fatalf("got %d + %d = %d events across both pages, want 5", len(events), len(rest), len(events)+len(rest))
	}
	if finalNext != b.NextSeq() {
		t.Fatalf("final page nextSeq = %d, want NextSeq() = %d", finalNext, b.NextSeq())
	}
}

func TestChatBufferSincePageAlwaysMakesProgress(t *testing.T) {
	b := NewChatBuffer(10)
	huge := strings.Repeat("x", 10_000)
	b.Append(ChatEvent{Kind: EventText, Text: huge}, ChatEvent{Kind: EventText, Text: "small"})

	// A budget smaller than even the first event must still return that
	// first event — otherwise a pathologically large single event could
	// stall pagination forever.
	events, nextSeq := b.SincePage(0, 10)
	if len(events) != 1 {
		t.Fatalf("got %d events, want exactly 1 (forced progress) when the budget is tiny", len(events))
	}
	if nextSeq != events[0].Seq {
		t.Fatalf("nextSeq = %d, want %d", nextSeq, events[0].Seq)
	}
}

func TestChatBufferIsConcurrencySafe(t *testing.T) {
	b := NewChatBuffer(1000)
	var wg sync.WaitGroup
	for i := 0; i < 50; i++ {
		wg.Add(2)
		go func() { defer wg.Done(); b.Append(ChatEvent{Kind: EventText}) }()
		go func() { defer wg.Done(); _ = b.Since(0) }()
	}
	wg.Wait()
	if got := len(b.Since(0)); got != 50 {
		t.Fatalf("held %d events, want 50", got)
	}
}
