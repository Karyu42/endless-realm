// Package instance is a single in-process room with a locked level multiplier
// and a 20 Hz tick loop driven by an injectable clock.
package instance

import (
	"context"
	"fmt"
	"math"
	"sync"
	"time"

	"github.com/Karyu42/endless-realm/server/internal/clock"
)

const (
	TickRate          = 20
	TickDuration      = time.Second / TickRate
	MinMultiplier     = 0.5
	MaxMultiplier     = 1.5
	MultiplierStep    = 0.05
	multiplierStepN   = 20.0 // 1 / MultiplierStep
	multiplierStepEps = 1e-9
	ProtocolVersion   = 1
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
	seed       uint64
	multiplier float64
	clk        clock.Clock

	mu        sync.Mutex
	tick      uint32
	inputs    map[uint32]Input
	applied   map[uint32]uint32
	listeners map[chan Snapshot]struct{}
	onSubmit  func(Input)
}

// New creates an instance and locks seed and multiplier. Multiplier must be
// in [0.5, 1.5] on a 0.05 step (v0.1). If clk is nil, the wall clock is used.
func New(seed uint64, multiplier float64, clk clock.Clock) (*Instance, error) {
	if err := ValidateMultiplier(multiplier); err != nil {
		return nil, err
	}
	if clk == nil {
		clk = clock.Real{}
	}
	return &Instance{
		seed:       seed,
		multiplier: multiplier,
		clk:        clk,
		inputs:     make(map[uint32]Input),
		applied:    make(map[uint32]uint32),
		listeners:  make(map[chan Snapshot]struct{}),
	}, nil
}

// ValidateMultiplier accepts m in [MinMultiplier, MaxMultiplier] on a
// MultiplierStep (0.05) grid. NaN and ±Inf are rejected because they fail
// the inclusive range check `!(m >= Min && m <= Max)`.
func ValidateMultiplier(m float64) error {
	if !(m >= MinMultiplier && m <= MaxMultiplier) {
		return fmt.Errorf("level multiplier %g is outside [%g, %g]", m, MinMultiplier, MaxMultiplier)
	}
	scaled := m * multiplierStepN
	rounded := math.Round(scaled)
	if math.Abs(scaled-rounded) > multiplierStepEps {
		return fmt.Errorf("level multiplier %g is not a multiple of %g", m, MultiplierStep)
	}
	return nil
}

func (i *Instance) Seed() uint64 {
	return i.seed
}

func (i *Instance) Multiplier() float64 {
	return i.multiplier
}

func (i *Instance) Tick() uint32 {
	i.mu.Lock()
	defer i.mu.Unlock()
	return i.tick
}

// SetMultiplier is rejected: the multiplier is immutable after creation.
func (i *Instance) SetMultiplier(float64) error {
	return fmt.Errorf("level multiplier is locked at %g and cannot be changed after the instance is created", i.multiplier)
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

// Run steps the instance at 20 Hz until ctx is cancelled.
func (i *Instance) Run(ctx context.Context) {
	for {
		select {
		case <-ctx.Done():
			return
		case <-i.clk.After(TickDuration):
			i.Step()
		}
	}
}
