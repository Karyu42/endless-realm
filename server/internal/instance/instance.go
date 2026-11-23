// Package instance is a single in-process room with a locked level multiplier
// and a 20 Hz tick loop driven by an injectable clock.
package instance

import (
	"context"
	"errors"
	"fmt"
	"log"
	"math"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/Karyu42/endless-realm/server/internal/clock"
)

const (
	TickRate     = 20
	TickDuration = time.Second / TickRate

	// Multiplier is stored as an integer number of hundredths (M100), per
	// docs/design/vision.md §6: 50 ≤ M100 ≤ 150 and M100 % 5 == 0 (0.05 steps
	// in [0.5, 1.5]). Values above 1.5 are later.
	MinM100         = 50
	MaxM100         = 150
	M100Step        = 5
	MinMultiplier   = 0.5
	MaxMultiplier   = 1.5
	MultiplierStep  = 0.05
	ProtocolVersion = 1

	// DefaultInstanceID is the process-default instance the bot/smoke path
	// and a new session start in.
	DefaultInstanceID = uint64(1)
	// DefaultMaxPlayers is the lobby max-player default (GD spec: 1–50, default 50).
	// Portal instances cap at the lobby's configured max. Tests use a smaller value.
	DefaultMaxPlayers = 50
	MinMaxPlayers     = 1
	MaxMaxPlayers     = 50

	// MaxCatchUpTicks is the most Steps Run will take after falling behind.
	// Further overdue ticks are skipped so a long stall does not replay
	// thousands of back-to-back frames; deadlines stay start+n*period.
	MaxCatchUpTicks = 5

	hundredthsEps = 1e-9
)

// Input is one client frame waiting to be applied on the next tick.
type Input struct {
	PlayerID uint32
	Seq      uint32
	MoveX    float64
	MoveY    float64
	Aim      float64 // radians, Godot 2D convention
	FireHeld bool
}

// Snapshot is the stub state broadcast after a tick.
type Snapshot struct {
	Tick    uint32
	Players []PlayerStub
}

type PlayerStub struct {
	ID         uint32
	AppliedSeq uint32
}

type Instance struct {
	seed      uint64
	m100      int
	clk       clock.Clock
	mu        sync.Mutex
	tick      uint32
	inputs    map[uint32]Input
	applied   map[uint32]uint32
	listeners map[chan Snapshot]struct{}
	onSubmit  func(Input)
	skipped   uint64
}

// New creates an instance and locks seed and multiplier. m100 is the level
// multiplier in hundredths and must already be a valid v0.1 value. If clk is
// nil, the wall clock is used.
func New(seed uint64, m100 int, clk clock.Clock) (*Instance, error) {
	if err := ValidateM100(m100); err != nil {
		return nil, err
	}
	if clk == nil {
		clk = clock.Real{}
	}
	return &Instance{
		seed:      seed,
		m100:      m100,
		clk:       clk,
		inputs:    make(map[uint32]Input),
		applied:   make(map[uint32]uint32),
		listeners: make(map[chan Snapshot]struct{}),
	}, nil
}

// ErrInvalidMultiplier is the sentinel wrapped by multiplier validators.
var ErrInvalidMultiplier = errors.New("invalid multiplier")

// ValidateMaxPlayers accepts a lobby max-player count.
func ValidateMaxPlayers(n int) error {
	if n < MinMaxPlayers || n > MaxMaxPlayers {
		return fmt.Errorf("max players %d is outside [%d, %d]", n, MinMaxPlayers, MaxMaxPlayers)
	}
	return nil
}

// ValidateM100 accepts a multiplier in hundredths on the v0.1 grid.
func ValidateM100(m100 int) error {
	if m100 < MinM100 || m100 > MaxM100 {
		return fmt.Errorf("%w: level multiplier %d hundredths is outside [%d, %d]", ErrInvalidMultiplier, m100, MinM100, MaxM100)
	}
	if m100%M100Step != 0 {
		return fmt.Errorf("%w: level multiplier %d hundredths is not a multiple of %d (0.05 steps)", ErrInvalidMultiplier, m100, M100Step)
	}
	return nil
}

// ValidateM100U32 is ValidateM100 for a wire uint32, so values above MaxInt
// (or above MaxM100) are rejected without overflowing a 32-bit int.
func ValidateM100U32(m100 uint32) error {
	if m100 > uint32(MaxM100) {
		return fmt.Errorf("%w: level multiplier %d hundredths is outside [%d, %d]", ErrInvalidMultiplier, m100, MinM100, MaxM100)
	}
	return ValidateM100(int(m100))
}

// MultiplierFromFloat accepts m only when it is a whole number of
// hundredths within hundredthsEps, then validates the v0.1 range and
// 0.05-step grid. Off-hundredth values such as 1.053 are rejected, not
// rounded. NaN and ±Inf are rejected.
func MultiplierFromFloat(m float64) (int, error) {
	if math.IsNaN(m) || math.IsInf(m, 0) {
		return 0, fmt.Errorf("%w: level multiplier %v is not a finite number", ErrInvalidMultiplier, m)
	}
	scaled := m * 100
	rounded := math.Round(scaled)
	if math.Abs(scaled-rounded) > hundredthsEps {
		return 0, fmt.Errorf("%w: level multiplier %g is not a whole number of hundredths", ErrInvalidMultiplier, m)
	}
	m100 := int(rounded)
	if err := ValidateM100(m100); err != nil {
		return 0, err
	}
	return m100, nil
}

// ParseMultiplier accepts a decimal multiplier (e.g. "1.05", "1.0") or an
// integer. Integers under 10 are decimals ("1" means 1.00); integers 10 and
// above are hundredths ("105" means 1.05). Decimals must already be whole
// hundredths (within float tolerance) and then sit on the 0.05 grid.
func ParseMultiplier(s string) (int, error) {
	s = strings.TrimSpace(s)
	if s == "" {
		return 0, fmt.Errorf("level multiplier is empty")
	}
	if strings.ContainsAny(s, ".eE") {
		m, err := strconv.ParseFloat(s, 64)
		if err != nil {
			return 0, fmt.Errorf("level multiplier %q: %w", s, err)
		}
		m100, err := MultiplierFromFloat(m)
		if err != nil {
			return 0, fmt.Errorf("level multiplier %q: %w", s, err)
		}
		return m100, nil
	}
	n, err := strconv.ParseInt(s, 10, 64)
	if err != nil {
		return 0, fmt.Errorf("level multiplier %q: %w", s, err)
	}
	if int64(int(n)) != n {
		return 0, fmt.Errorf("level multiplier %q overflows", s)
	}
	const intHint = "integers under 10 are decimals, 10 and above are hundredths"
	if n >= 0 && n < 10 {
		m100, err := MultiplierFromFloat(float64(n))
		if err != nil {
			return 0, fmt.Errorf("level multiplier %q is taken as %d.00 (%s): %w", s, n, intHint, err)
		}
		return m100, nil
	}
	m100 := int(n)
	if err := ValidateM100(m100); err != nil {
		return 0, fmt.Errorf("level multiplier %q is taken as %d hundredths (%s): %w", s, m100, intHint, err)
	}
	return m100, nil
}

// FormatMultiplier renders m100 as a two-decimal string (e.g. 105 -> "1.05").
func FormatMultiplier(m100 int) string {
	return fmt.Sprintf("%.2f", float64(m100)/100.0)
}

func (i *Instance) Seed() uint64 {
	return i.seed
}

// MultiplierHundredths is the locked M100 value stored on the instance.
func (i *Instance) MultiplierHundredths() int {
	return i.m100
}

// Multiplier is M100 / 100, for display and the Welcome float field.
func (i *Instance) Multiplier() float64 {
	return float64(i.m100) / 100.0
}

func (i *Instance) Tick() uint32 {
	i.mu.Lock()
	defer i.mu.Unlock()
	return i.tick
}

// SetMultiplier is rejected: the multiplier is immutable after creation.
func (i *Instance) SetMultiplier(int) error {
	return fmt.Errorf("level multiplier is locked at %d hundredths and cannot be changed after the instance is created", i.m100)
}

// SetOnSubmit registers a hook invoked after an input is queued. Tests use
// this to synchronize without sleeping. The hook must not take Instance locks.
func (i *Instance) SetOnSubmit(fn func(Input)) {
	i.mu.Lock()
	defer i.mu.Unlock()
	i.onSubmit = fn
}

func (i *Instance) SubmitInput(in Input) {
	i.mu.Lock()
	i.inputs[in.PlayerID] = in
	hook := i.onSubmit
	i.mu.Unlock()
	if hook != nil {
		hook(in)
	}
}

// Subscribe receives a snapshot after every tick. The caller must Unsubscribe.
func (i *Instance) Subscribe() (<-chan Snapshot, func()) {
	ch := make(chan Snapshot, 16)
	i.mu.Lock()
	i.listeners[ch] = struct{}{}
	i.mu.Unlock()
	unsub := func() {
		i.mu.Lock()
		delete(i.listeners, ch)
		i.mu.Unlock()
	}
	return ch, unsub
}

// Step advances one authoritative tick.
func (i *Instance) Step() Snapshot {
	i.mu.Lock()
	i.tick++
	for id, in := range i.inputs {
		i.applied[id] = in.Seq
	}
	i.inputs = make(map[uint32]Input)
	snap := Snapshot{Tick: i.tick, Players: make([]PlayerStub, 0, len(i.applied))}
	for id, seq := range i.applied {
		snap.Players = append(snap.Players, PlayerStub{ID: id, AppliedSeq: seq})
	}
	listeners := make([]chan Snapshot, 0, len(i.listeners))
	for ch := range i.listeners {
		listeners = append(listeners, ch)
	}
	i.mu.Unlock()

	for _, ch := range listeners {
		select {
		case ch <- snap:
		default:
		}
	}
	return snap
}

// SkippedTicks is the number of overdue ticks dropped by the catch-up cap.
func (i *Instance) SkippedTicks() uint64 {
	i.mu.Lock()
	defer i.mu.Unlock()
	return i.skipped
}

func (i *Instance) recordSkip(n int) {
	if n <= 0 {
		return
	}
	i.mu.Lock()
	i.skipped += uint64(n)
	i.mu.Unlock()
	log.Printf("tick catch-up: skipped %d ticks (cap %d)", n, MaxCatchUpTicks)
}

// Run steps the instance at 20 Hz until ctx is cancelled. Tick deadlines are
// start + n*period so scheduling error does not accumulate from Step duration
// or from a late wake. If more than MaxCatchUpTicks deadlines are already
// overdue, the extra ticks are skipped and at most MaxCatchUpTicks steps run
// before waiting for the next future deadline.
func (i *Instance) Run(ctx context.Context) {
	start := i.clk.Now()
	n := 0 // last completed deadline index
	for {
		now := i.clk.Now()
		due := int(now.Sub(start) / TickDuration)
		if due < n {
			due = n
		}
		behind := due - n
		if behind > MaxCatchUpTicks {
			skip := behind - MaxCatchUpTicks
			i.recordSkip(skip)
			n += skip
			behind = MaxCatchUpTicks
		}
		if behind > 0 {
			i.Step()
			n++
			continue
		}
		next := start.Add(time.Duration(n+1) * TickDuration)
		delay := next.Sub(i.clk.Now())
		if delay < 0 {
			delay = 0
		}
		select {
		case <-ctx.Done():
			return
		case <-i.clk.After(delay):
			// Re-evaluate overdue ticks on wake so a large jump is capped.
		}
	}
}
