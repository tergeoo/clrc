package agent

import (
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
