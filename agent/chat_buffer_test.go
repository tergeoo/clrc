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
	// nextSeq is a resume token — "ask for events after this seq" — so it
	// must be the seq of the last event actually handed back (2), not
	// NextSeq() (3, one past it). Feeding NextSeq() back as afterSeq would
	// skip whatever event is stamped with seq 3 next.
	want := events[len(events)-1].Seq
	if nextSeq != want {
		t.Fatalf("nextSeq = %d, want %d (the last returned event's seq) when the caller is fully caught up", nextSeq, want)
	}
	if nextSeq == b.NextSeq() {
		t.Fatalf("nextSeq must not equal NextSeq() (%d) — that is one past the last stamped seq and would skip a future event", b.NextSeq())
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
	// Same resume-token contract as the uncapped test above: the final page
	// is not cut, so nextSeq must be the last event's seq, not NextSeq().
	wantFinal := rest[len(rest)-1].Seq
	if finalNext != wantFinal {
		t.Fatalf("final page nextSeq = %d, want %d (the last returned event's seq)", finalNext, wantFinal)
	}
	if finalNext == b.NextSeq() {
		t.Fatalf("final page nextSeq must not equal NextSeq() (%d)", b.NextSeq())
	}
}

// TestChatBufferSincePagePagesEndToEnd is the round-trip regression test for
// Defect 1b: feed the returned nextSeq back in as afterSeq in a loop, the
// way the client now does, and confirm every event is delivered exactly
// once, in order, with none skipped — and that the loop actually
// terminates (a non-advancing nextSeq must stop it, not spin forever).
func TestChatBufferSincePagePagesEndToEnd(t *testing.T) {
	b := NewChatBuffer(1000)
	const total = 37
	payload := strings.Repeat("x", 50)
	for i := 0; i < total; i++ {
		b.Append(ChatEvent{Kind: EventText, Text: payload})
	}

	var got []ChatEvent
	afterSeq := uint64(0)
	const budget = 300 // small enough to force several pages
	const maxIterations = total + 5
	iterations := 0
	for {
		iterations++
		if iterations > maxIterations {
			t.Fatalf("did not converge after %d iterations; afterSeq=%d, got %d events so far", maxIterations, afterSeq, len(got))
		}
		page, nextSeq := b.SincePage(afterSeq, budget)
		got = append(got, page...)
		if nextSeq <= afterSeq {
			break // no progress reported — caller must stop, not loop forever
		}
		afterSeq = nextSeq
	}

	if len(got) != total {
		t.Fatalf("delivered %d events across %d pages, want %d", len(got), iterations, total)
	}
	seen := make(map[uint64]bool, total)
	for i, e := range got {
		if uint64(i+1) != e.Seq {
			t.Fatalf("event %d has seq %d, want %d — events must arrive in order", i, e.Seq, i+1)
		}
		if seen[e.Seq] {
			t.Fatalf("seq %d delivered more than once", e.Seq)
		}
		seen[e.Seq] = true
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
