package instance

import (
	"context"
	"testing"
	"time"

	"github.com/Karyu42/endless-realm/server/internal/clock"
)

func TestMultiplierValidBounds(t *testing.T) {
	for _, m := range []float64{0.5, 1.0, 1.5} {
		inst, err := New(1, m, clock.NewFake(time.Unix(0, 0)))
		if err != nil {
			t.Fatalf("multiplier %g: unexpected error: %v", m, err)
		}
		if inst.Multiplier() != m {
			t.Fatalf("got multiplier %g, want %g", inst.Multiplier(), m)
		}
	}
}

func TestMultiplierRejectsOutOfRange(t *testing.T) {
	clk := clock.NewFake(time.Unix(0, 0))
	for _, m := range []float64{0.49, 1.51, 0, 2, -1} {
		if _, err := New(1, m, clk); err == nil {
			t.Fatalf("multiplier %g: want error, got nil", m)
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
	ctx, cancel := context.WithCancel(context.Background())
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
	waitTick(t, inst, 1)
	clk.BlockUntilWaiters(1)
	clk.Advance(TickDuration)
	waitTick(t, inst, 2)

	cancel()
	select {
	case <-done:
	case <-time.After(2 * time.Second):
		t.Fatal("Run did not exit after cancel")
	}
}

func waitTick(t *testing.T, inst *Instance, want uint32) {
	t.Helper()
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		if inst.Tick() >= want {
			return
		}
		time.Sleep(5 * time.Millisecond)
	}
	t.Fatalf("timed out waiting for tick %d, last = %d", want, inst.Tick())
}
