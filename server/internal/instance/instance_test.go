package instance

import (
	"context"
	"math"
	"testing"
	"time"

	"github.com/Karyu42/endless-realm/server/internal/clock"
)

func TestMultiplierValidBoundsAndSteps(t *testing.T) {
	for _, m := range []float64{0.5, 0.55, 1.0, 1.05, 1.25, 1.5} {
		inst, err := New(1, m, clock.NewFake(time.Unix(0, 0)))
		if err != nil {
			t.Fatalf("multiplier %g: unexpected error: %v", m, err)
		}
		if inst.Multiplier() != m {
			t.Fatalf("got multiplier %g, want %g", inst.Multiplier(), m)
		}
	}
}

func TestMultiplierRejectsNaNInfAndJustPastBounds(t *testing.T) {
	clk := clock.NewFake(time.Unix(0, 0))
	cases := []float64{
		math.NaN(),
		math.Inf(1),
		math.Inf(-1),
		math.Nextafter(MinMultiplier, math.Inf(-1)),
		math.Nextafter(MaxMultiplier, math.Inf(1)),
		0, 2, -1,
	}
	for _, m := range cases {
		if _, err := New(1, m, clk); err == nil {
			t.Fatalf("multiplier %v: want error, got nil", m)
		}
	}
}

func TestMultiplierRejectsOffStep(t *testing.T) {
	for _, m := range []float64{1.07, 0.51, 0.53, 1.49} {
		if err := ValidateMultiplier(m); err == nil {
			t.Fatalf("multiplier %g: want off-step error, got nil", m)
		}
	}
}

func TestMultiplierImmutableAfterCreation(t *testing.T) {
	inst, err := New(7, 1.25, clock.NewFake(time.Unix(0, 0)))
	if err != nil {
		t.Fatal(err)
	}
	if err := inst.SetMultiplier(0.8); err == nil {
		t.Fatal("expected SetMultiplier to fail")
	}
	if inst.Multiplier() != 1.25 {
		t.Fatalf("multiplier changed to %g", inst.Multiplier())
	}
	if inst.Seed() != 7 {
		t.Fatalf("seed = %d, want 7", inst.Seed())
	}
}

func TestTickLoopWithFakeClock(t *testing.T) {
	clk := clock.NewFake(time.Unix(1, 0))
	inst, err := New(1, 1.0, clk)
	if err != nil {
		t.Fatal(err)
	}
	snaps, unsub := inst.Subscribe()
	defer unsub()

	ctx, cancel := context.WithCancel(t.Context())
	defer cancel()
	done := make(chan struct{})
	go func() {
		inst.Run(ctx)
		close(done)
	}()

	clk.BlockUntilWaiters(1)
	if got := inst.Tick(); got != 0 {
		t.Fatalf("tick before advance = %d, want 0", got)
	}

	clk.Advance(TickDuration)
	waitSnap(t, ctx, snaps, 1)
	clk.BlockUntilWaiters(1)
	clk.Advance(TickDuration)
	waitSnap(t, ctx, snaps, 2)

	cancel()
	select {
	case <-done:
	case <-t.Context().Done():
		t.Fatal("Run did not exit after cancel")
	}
}

func waitSnap(t *testing.T, ctx interface{ Done() <-chan struct{} }, snaps <-chan Snapshot, want uint32) {
	t.Helper()
	select {
	case snap := <-snaps:
		if snap.Tick != want {
			t.Fatalf("snapshot tick = %d, want %d", snap.Tick, want)
		}
	case <-ctx.Done():
		t.Fatalf("cancelled waiting for tick %d", want)
	}
}
