// Package clock provides an injectable clock so the 20 Hz tick loop can
// be driven by a fake clock in tests.
package clock

import (
	"sync"
	"time"
)

// Clock is a source of time and delayed notifications.
type Clock interface {
	Now() time.Time
	After(d time.Duration) <-chan time.Time
}

// Real is the wall clock.
type Real struct{}

func (Real) Now() time.Time                         { return time.Now() }
func (Real) After(d time.Duration) <-chan time.Time { return time.After(d) }

type waiter struct {
	at time.Time
	ch chan time.Time
}

// Fake is a deterministic clock. After() channels fire when Advance
// moves the current time to or past their deadline.
type Fake struct {
	mu      sync.Mutex
	cond    *sync.Cond
	now     time.Time
	waiters []waiter
}

func NewFake(now time.Time) *Fake {
	f := &Fake{now: now}
	f.cond = sync.NewCond(&f.mu)
	return f
}

func (f *Fake) Now() time.Time {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.now
}

func (f *Fake) After(d time.Duration) <-chan time.Time {
	f.mu.Lock()
	defer f.mu.Unlock()
	ch := make(chan time.Time, 1)
	at := f.now.Add(d)
	if !at.After(f.now) {
		ch <- f.now
		return ch
	}
	f.waiters = append(f.waiters, waiter{at: at, ch: ch})
	f.cond.Broadcast()
	return ch
}

// BlockUntilWaiters waits until at least n After-waiters are registered.
func (f *Fake) BlockUntilWaiters(n int) {
	f.mu.Lock()
	defer f.mu.Unlock()
	for len(f.waiters) < n {
		f.cond.Wait()
	}
}

// Advance moves the clock forward and fires any due waiters.
func (f *Fake) Advance(d time.Duration) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.now = f.now.Add(d)
	now := f.now
	var pending []waiter
	for _, w := range f.waiters {
		if !w.at.After(now) {
			w.ch <- now
		} else {
			pending = append(pending, w)
		}
	}
	f.waiters = pending
}
