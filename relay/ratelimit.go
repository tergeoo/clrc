package relay

import (
	"sync"
	"time"
)

// rateLimiter is a fixed-window per-key limiter. It is used to throttle login
// attempts per client IP so the single shared ADMIN_PASSWORD cannot be
// brute-forced. Behind a reverse proxy the key is the proxy's address, which
// makes the limit effectively global — acceptable and un-spoofable (we do not
// trust X-Forwarded-For).
type rateLimiter struct {
	max    int
	window time.Duration
	now    func() time.Time

	mu      sync.Mutex
	windows map[string]*windowCount
}

type windowCount struct {
	start time.Time
	count int
}

func newRateLimiter(max int, window time.Duration, now func() time.Time) *rateLimiter {
	return &rateLimiter{
		max:     max,
		window:  window,
		now:     now,
		windows: make(map[string]*windowCount),
	}
}

// allow records an attempt for key and reports whether it is within the limit.
func (r *rateLimiter) allow(key string) bool {
	r.mu.Lock()
	defer r.mu.Unlock()

	t := r.now()
	w, ok := r.windows[key]
	if !ok || t.Sub(w.start) >= r.window {
		r.windows[key] = &windowCount{start: t, count: 1}
		return true
	}
	if w.count >= r.max {
		return false
	}
	w.count++
	return true
}

// cleanup drops windows whose window has fully elapsed.
func (r *rateLimiter) cleanup() {
	r.mu.Lock()
	defer r.mu.Unlock()
	t := r.now()
	for key, w := range r.windows {
		if t.Sub(w.start) >= r.window {
			delete(r.windows, key)
		}
	}
}

// trackedIPs returns the number of keys currently tracked (test helper).
func (r *rateLimiter) trackedIPs() int {
	r.mu.Lock()
	defer r.mu.Unlock()
	return len(r.windows)
}

// startCleanup runs cleanup on an interval until the process exits.
func (r *rateLimiter) startCleanup(interval time.Duration) {
	go func() {
		ticker := time.NewTicker(interval)
		defer ticker.Stop()
		for range ticker.C {
			r.cleanup()
		}
	}()
}
