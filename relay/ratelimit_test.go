package relay

import (
	"testing"
	"time"
)

func TestRateLimiterAllowsUpToLimit(t *testing.T) {
	now := time.Unix(0, 0)
	rl := newRateLimiter(3, time.Minute, func() time.Time { return now })

	for i := 0; i < 3; i++ {
		if !rl.allow("1.2.3.4") {
			t.Fatalf("attempt %d should be allowed", i+1)
		}
	}
	if rl.allow("1.2.3.4") {
		t.Error("4th attempt within window should be blocked")
	}
}

func TestRateLimiterPerIPIsolation(t *testing.T) {
	now := time.Unix(0, 0)
	rl := newRateLimiter(1, time.Minute, func() time.Time { return now })

	if !rl.allow("1.1.1.1") {
		t.Fatal("first IP first attempt should pass")
	}
	if rl.allow("1.1.1.1") {
		t.Error("first IP second attempt should block")
	}
	if !rl.allow("2.2.2.2") {
		t.Error("second IP should be independent")
	}
}

func TestRateLimiterWindowReset(t *testing.T) {
	now := time.Unix(0, 0)
	rl := newRateLimiter(1, time.Minute, func() time.Time { return now })

	if !rl.allow("9.9.9.9") {
		t.Fatal("first attempt should pass")
	}
	if rl.allow("9.9.9.9") {
		t.Fatal("second attempt in window should block")
	}
	now = now.Add(2 * time.Minute) // advance past the window
	if !rl.allow("9.9.9.9") {
		t.Error("attempt after window should pass again")
	}
}

func TestRateLimiterCleanupRemovesStale(t *testing.T) {
	now := time.Unix(0, 0)
	rl := newRateLimiter(5, time.Minute, func() time.Time { return now })

	rl.allow("3.3.3.3")
	now = now.Add(10 * time.Minute)
	rl.cleanup()
	if n := rl.trackedIPs(); n != 0 {
		t.Errorf("stale IP not cleaned: trackedIPs = %d, want 0", n)
	}
}
