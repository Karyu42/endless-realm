package instance

import (
	"context"
	"crypto/rand"
	"encoding/binary"
	"fmt"
	"sync"

	"github.com/Karyu42/endless-realm/server/internal/clock"
)

// Info is a list/join view of one in-process instance.
type Info struct {
	ID      uint64
	M100    int
	Seed    uint64
	Players int
	Default bool
}

type managed struct {
	id      uint64
	inst    *Instance
	def     bool
	opener  uint32
	players map[uint32]struct{}
	cancel  context.CancelFunc
}

// Hub holds the process-default instance plus any open portals.
type Hub struct {
	mu     sync.Mutex
	ctx    context.Context
	clk    clock.Clock
	nextID uint64
	insts  map[uint64]*managed
	opened map[uint32]uint64 // opener player id -> portal instance id
}

// NewHub starts with inst as DefaultInstanceID. The caller must Run the
// default instance (existing tests and cmd/server already do). Portal
// instances created later are Run by the hub on inst.Clock().
func NewHub(ctx context.Context, inst *Instance) *Hub {
	h := &Hub{
		ctx:    ctx,
		clk:    inst.Clock(),
		nextID: DefaultInstanceID + 1,
		insts:  make(map[uint64]*managed),
		opened: make(map[uint32]uint64),
	}
	h.insts[DefaultInstanceID] = &managed{
		id:      DefaultInstanceID,
		inst:    inst,
		def:     true,
		players: make(map[uint32]struct{}),
	}
	return h
}

func (h *Hub) DefaultID() uint64 { return DefaultInstanceID }

func (h *Hub) Default() *Instance {
	h.mu.Lock()
	defer h.mu.Unlock()
	return h.insts[DefaultInstanceID].inst
}

func (h *Hub) Get(id uint64) (*Instance, bool) {
	h.mu.Lock()
	defer h.mu.Unlock()
	m, ok := h.insts[id]
	if !ok {
		return nil, false
	}
	return m.inst, true
}

func (h *Hub) List() []Info {
	h.mu.Lock()
	defer h.mu.Unlock()
	out := make([]Info, 0, len(h.insts))
	for _, m := range h.insts {
		out = append(out, m.info())
	}
	return out
}

// SkippedTicks sums the catch-up skips across every instance.
func (h *Hub) SkippedTicks() uint64 {
	h.mu.Lock()
	defer h.mu.Unlock()
	var n uint64
	for _, m := range h.insts {
		n += m.inst.SkippedTicks()
	}
	return n
}

// InstanceCount is the number of live in-process rooms.
func (h *Hub) InstanceCount() int {
	h.mu.Lock()
	defer h.mu.Unlock()
	return len(h.insts)
}

func (m *managed) info() Info {
	return Info{
		ID:      m.id,
		M100:    m.inst.MultiplierHundredths(),
		Seed:    m.inst.Seed(),
		Players: len(m.players),
		Default: m.def,
	}
}

// Arrive records a session that just connected into the default instance.
func (h *Hub) Arrive(player uint32) (*Instance, Info) {
	h.mu.Lock()
	defer h.mu.Unlock()
	m := h.insts[DefaultInstanceID]
	m.players[player] = struct{}{}
	return m.inst, m.info()
}

// Depart removes a disconnected session from whatever instance it is in.
func (h *Hub) Depart(player uint32, instID uint64) {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.detachLocked(player, instID)
}

// OpenAndJoin creates a portal instance, locks m100, and moves the opener
// into it. Nothing is created if validation or the one-instance / one-open
// portal rules fail.
func (h *Hub) OpenAndJoin(m100 uint32, player uint32, fromID uint64) (*Instance, Info, error) {
	if err := ValidateM100U32(m100); err != nil {
		return nil, Info{}, err
	}
	h.mu.Lock()
	defer h.mu.Unlock()
	from, ok := h.insts[fromID]
	if !ok {
		return nil, Info{}, fmt.Errorf("instance %d not found", fromID)
	}
	if !from.def {
		return nil, Info{}, ErrAlreadyIn
	}
	if _, exists := h.opened[player]; exists {
		return nil, Info{}, ErrOpenLimit
	}
	seed, err := randomSeed()
	if err != nil {
		return nil, Info{}, err
	}
	inst, err := New(seed, int(m100), h.clk)
	if err != nil {
		return nil, Info{}, err
	}
	id := h.nextID
	h.nextID++
	ctx, cancel := context.WithCancel(h.ctx)
	go inst.Run(ctx)
	m := &managed{
		id:      id,
		inst:    inst,
		opener:  player,
		players: map[uint32]struct{}{player: {}},
		cancel:  cancel,
	}
	h.insts[id] = m
	h.opened[player] = id
	h.detachLocked(player, fromID)
	m.players[player] = struct{}{}
	return inst, m.info(), nil
}

// Join moves a session into instID. Joining the instance the session is
// already in is a no-op success. Joining a different portal while already
// in a portal is rejected; joining the default instance is always allowed
// (leave).
func (h *Hub) Join(instID uint64, player uint32, fromID uint64) (*Instance, Info, error) {
	h.mu.Lock()
	defer h.mu.Unlock()
	to, ok := h.insts[instID]
	if !ok {
		return nil, Info{}, ErrNotFound
	}
	if instID == fromID {
		return to.inst, to.info(), nil
	}
	from, fromOK := h.insts[fromID]
	if fromOK && !from.def && !to.def {
		return nil, Info{}, ErrAlreadyIn
	}
	if !to.def && len(to.players) >= MaxParty {
		return nil, Info{}, ErrFull
	}
	h.detachLocked(player, fromID)
	to.players[player] = struct{}{}
	return to.inst, to.info(), nil
}

func (h *Hub) detachLocked(player uint32, instID uint64) {
	m, ok := h.insts[instID]
	if !ok {
		return
	}
	delete(m.players, player)
	m.inst.RemovePlayer(player)
}

// Sentinel errors mapped to protocol ErrorCode by the net layer.
var (
	ErrAlreadyIn = fmt.Errorf("already in an instance")
	ErrNotFound  = fmt.Errorf("instance not found")
	ErrFull      = fmt.Errorf("instance is full")
	ErrOpenLimit = fmt.Errorf("one open portal per player")
)

func randomSeed() (uint64, error) {
	var b [8]byte
	if _, err := rand.Read(b[:]); err != nil {
		return 0, err
	}
	return binary.LittleEndian.Uint64(b[:]), nil
}
