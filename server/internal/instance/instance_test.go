package instance

import (
	"context"
	"math"
	"strings"
	"testing"
	"time"

	"github.com/Karyu42/endless-realm/server/internal/clock"
)

func testCtx(t *testing.T) (context.Context, context.CancelFunc) {
	t.Helper()
	return context.WithTimeout(t.Context(), 5*time.Second)
}

func TestAllTwentyOneValidHundredths(t *testing.T) {
	clk := clock.NewFake(time.Unix(0, 0))
	count := 0
	for m100 := MinM100; m100 <= MaxM100; m100 += M100Step {
		count++
		inst, err := New(1, m100, clk)
		if err != nil {
			t.Fatalf("M100=%d: unexpected error: %v", m100, err)
		}
		if inst.MultiplierHundredths() != m100 {
			t.Fatalf("stored %d, want %d", inst.MultiplierHundredths(), m100)
		}
	}
	if count != 21 {
		t.Fatalf("got %d valid M100 values, want 21", count)
	}
}

func TestParseMultiplierDecimalAndHundredths(t *testing.T) {
	cases := []struct {
		in   string
		want int
	}{
		{"0.50", 50},
		{"0.5", 50},
		{"1.05", 105},
		{"1.0", 100},
		{"1.50", 150},
		{"1", 100}, // bare 1 is decimal 1.00, not 1 hundredth
		{"50", 50},
		{"105", 105},
		{"150", 150},
	}
	for _, tc := range cases {
		got, err := ParseMultiplier(tc.in)
		if err != nil {
			t.Fatalf("ParseMultiplier(%q): %v", tc.in, err)
		}
		if got != tc.want {
			t.Fatalf("ParseMultiplier(%q)=%d, want %d", tc.in, got, tc.want)
		}
	}
}

func TestParseAndFloatRejectVisionCases(t *testing.T) {
	for _, s := range []string{"0.45", "1.55", "1.07", "1.053", "1.047", "0.495", "1.504", "2"} {
		if _, err := ParseMultiplier(s); err == nil {
			t.Fatalf("ParseMultiplier(%q): want error", s)
		}
	}
	for _, m := range []float64{0.45, 1.55, 1.07, 1.053, 1.047, 0.495, 1.504} {
		if _, err := MultiplierFromFloat(m); err == nil {
			t.Fatalf("MultiplierFromFloat(%g): want error", m)
		}
	}
}

func TestParseMultiplierBareIntegerHint(t *testing.T) {
	want := "integers under 10 are decimals, 10 and above are hundredths"
	for _, s := range []string{"2", "45", "107", "151"} {
		_, err := ParseMultiplier(s)
		if err == nil {
			t.Fatalf("ParseMultiplier(%q): want error", s)
		}
		if !strings.Contains(err.Error(), want) {
			t.Fatalf("ParseMultiplier(%q) error %q, want substring %q", s, err, want)
		}
	}
}

func TestMultiplierFromFloatRoundsJustPastBoundsIntoRange(t *testing.T) {
	// Values a ULP past 0.5 / 1.5 still round to 50 / 150 hundredths.
	low, err := MultiplierFromFloat(math.Nextafter(MinMultiplier, math.Inf(-1)))
	if err != nil {
		t.Fatal(err)
	}
	if low != 50 {
		t.Fatalf("just below 0.5 rounded to %d, want 50", low)
	}
	high, err := MultiplierFromFloat(math.Nextafter(MaxMultiplier, math.Inf(1)))
	if err != nil {
		t.Fatal(err)
	}
	if high != 150 {
		t.Fatalf("just above 1.5 rounded to %d, want 150", high)
	}
}

func TestMultiplierRejectsNaNInfAndOutOfRange(t *testing.T) {
	cases := []float64{
		math.NaN(),
		math.Inf(1),
		math.Inf(-1),
		0, 2, -1,
	}
	for _, m := range cases {
		if _, err := MultiplierFromFloat(m); err == nil {
			t.Fatalf("multiplier %v: want error, got nil", m)
		}
	}
	clk := clock.NewFake(time.Unix(0, 0))
	for _, m100 := range []int{0, 45, 49, 51, 104, 107, 151, 155, 200} {
		if _, err := New(1, m100, clk); err == nil {
			t.Fatalf("M100=%d: want error, got nil", m100)
		}
	}
}

func TestMultiplierFromFloatRejectsOffHundredth(t *testing.T) {
	if _, err := MultiplierFromFloat(1.049); err == nil {
		t.Fatal("1.049: want off-hundredth error")
	}
	if _, err := MultiplierFromFloat(1.053); err == nil {
		t.Fatal("1.053: want off-hundredth error")
	}
}

func TestMultiplierImmutableAfterCreation(t *testing.T) {
	inst, err := New(7, 125, clock.NewFake(time.Unix(0, 0)))
	if err != nil {
		t.Fatal(err)
	}
	if err := inst.SetMultiplier(80); err == nil {
		t.Fatal("expected SetMultiplier to fail")
	}
	if inst.MultiplierHundredths() != 125 {
		t.Fatalf("multiplier changed to %d", inst.MultiplierHundredths())
	}
	if inst.Seed() != 7 {
		t.Fatalf("seed = %d, want 7", inst.Seed())
	}
}

func TestTickLoopWithFakeClock(t *testing.T) {
	ctx, cancel := testCtx(t)
	defer cancel()

	clk := clock.NewFake(time.Unix(1, 0))
	inst, err := New(1, 100, clk)
	if err != nil {
		t.Fatal(err)
	}
	snaps, unsub := inst.Subscribe()
	defer unsub()

	runCtx, stopRun := context.WithCancel(ctx)
	defer stopRun()
	done := make(chan struct{})
	go func() {
		inst.Run(runCtx)
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

	stopRun()
	select {
	case <-done:
	case <-ctx.Done():
		t.Fatal("Run did not exit after cancel")
	}
}

func TestRunDeadlineSchedulingNoDrift(t *testing.T) {
	// Jumping three periods must produce three ticks (deadlines are
	// start+n*period). A delay-from-last-wake loop would only fire once.
	ctx, cancel := testCtx(t)
	defer cancel()

	start := time.Unix(1, 0)
	clk := clock.NewFake(start)
	inst, err := New(1, 100, clk)
	if err != nil {
		t.Fatal(err)
	}
	snaps, unsub := inst.Subscribe()
	defer unsub()

	runCtx, stopRun := context.WithCancel(ctx)
	defer stopRun()
	done := make(chan struct{})
	go func() {
		inst.Run(runCtx)
		close(done)
	}()

	clk.BlockUntilWaiters(1)
	clk.Advance(3 * TickDuration)
	for want := uint32(1); want <= 3; want++ {
		waitSnap(t, ctx, snaps, want)
	}
	if got := inst.Tick(); got != 3 {
		t.Fatalf("tick after 3-period jump = %d, want 3", got)
	}

	// The fourth deadline is start+4*period; a partial advance must not tick.
	clk.BlockUntilWaiters(1)
	clk.Advance(TickDuration - time.Nanosecond)
	select {
	case snap := <-snaps:
		t.Fatalf("unexpected snapshot tick %d before the 4th deadline", snap.Tick)
	default:
	}
	if got := inst.Tick(); got != 3 {
		t.Fatalf("tick after partial advance = %d, want 3", got)
	}
	clk.Advance(time.Nanosecond)
	waitSnap(t, ctx, snaps, 4)

	stopRun()
	select {
	case <-done:
	case <-ctx.Done():
		t.Fatal("Run did not exit after cancel")
	}
}

func TestRunCatchUpCapOnLongJump(t *testing.T) {
	// A 1 hour stall must not replay 72,000 ticks. At most MaxCatchUpTicks
	// steps run, then cadence resumes at the current deadline.
	ctx, cancel := testCtx(t)
	defer cancel()

	start := time.Unix(1, 0)
	clk := clock.NewFake(start)
	inst, err := New(1, 100, clk)
	if err != nil {
		t.Fatal(err)
	}
	snaps, unsub := inst.Subscribe()
	defer unsub()

	runCtx, stopRun := context.WithCancel(ctx)
	defer stopRun()
	done := make(chan struct{})
	go func() {
		inst.Run(runCtx)
		close(done)
	}()

	clk.BlockUntilWaiters(1)
	clk.Advance(time.Hour)
	// Catch-up steps complete before the next After waiter is registered.
	clk.BlockUntilWaiters(1)

	var got []uint32
drain:
	for {
		select {
		case snap := <-snaps:
			got = append(got, snap.Tick)
			if len(got) > MaxCatchUpTicks {
				t.Fatalf("produced %d ticks, cap is %d: %v", len(got), MaxCatchUpTicks, got)
			}
		default:
			break drain
		}
	}
	if n := len(got); n == 0 || n > MaxCatchUpTicks {
		t.Fatalf("after 1h jump got %d ticks %v, want 1..%d", n, got, MaxCatchUpTicks)
	}
	if inst.Tick() != uint32(len(got)) {
		t.Fatalf("tick counter %d, snapshots %d", inst.Tick(), len(got))
	}
	wantSkip := uint64(int(time.Hour/TickDuration) - len(got))
	if inst.SkippedTicks() != wantSkip {
		t.Fatalf("skipped %d, want %d", inst.SkippedTicks(), wantSkip)
	}

	// Resume normal cadence: the next period produces exactly one tick.
	clk.BlockUntilWaiters(1)
	clk.Advance(TickDuration)
	waitSnap(t, ctx, snaps, uint32(len(got)+1))
	clk.BlockUntilWaiters(1)
	clk.Advance(TickDuration)
	waitSnap(t, ctx, snaps, uint32(len(got)+2))

	stopRun()
	select {
	case <-done:
	case <-ctx.Done():
		t.Fatal("Run did not exit after cancel")
	}
}

func waitSnap(t *testing.T, ctx context.Context, snaps <-chan Snapshot, want uint32) {
	t.Helper()
	select {
	case snap := <-snaps:
		if snap.Tick != want {
			t.Fatalf("snapshot tick = %d, want %d", snap.Tick, want)
		}
	case <-ctx.Done():
		t.Fatalf("cancelled waiting for tick %d: %v", want, ctx.Err())
	}
}
