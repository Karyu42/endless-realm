// Package bot is the standalone WebSocket test client used by CI smoke/soak
// and `make smoke`.
package bot

import (
	"context"
	"flag"
	"fmt"
	"math"
	"os"
	"sync"
	"sync/atomic"
	"time"

	"github.com/coder/websocket"
	"google.golang.org/protobuf/proto"

	"github.com/Karyu42/endless-realm/server/internal/instance"
	protocolv1 "github.com/Karyu42/endless-realm/server/internal/protocol/v1"
)

const (
	EnvSmokeURL         = "ER_SMOKE_URL"
	DefaultURL          = "ws://127.0.0.1:8080/ws"
	DefaultStallTimeout = 5 * time.Second
	firstSnapWait       = 10 * time.Second
	writeTO             = 5 * time.Second
	appliedSeqSlack     = 2
)

// Config is the bot contract invoked by CI (PR #5 ci.yml / soak.yml):
//
//	er-bot -url=ws://127.0.0.1:8080/ws -clients=1 -seed=1 -mult=1.0
//	er-bot -url=ws://127.0.0.1:8080/ws -clients=$N -seed=1 -mult=1.0 -duration=10m
//
// -url is the contract; if it is empty, ER_SMOKE_URL is used, then DefaultURL.
type Config struct {
	URL          string
	Clients      int
	Seed         uint64
	Mult         string
	Duration     time.Duration
	StallTimeout time.Duration
	Input        string
}

// Result is filled by a successful or failed Run. Summary is for exit 0.
type Result struct {
	Clients   int
	Snapshots uint64
	Duration  time.Duration
}

// Summary is the one-line success message printed by cmd/bot on exit 0.
func (r Result) Summary() string {
	return fmt.Sprintf("bot ok: clients=%d snapshots=%d duration=%s", r.Clients, r.Snapshots, r.Duration.Round(time.Millisecond))
}

// ParseFlags reads the CI flag contract from args (and ER_SMOKE_URL).
func ParseFlags(args []string) (Config, error) {
	return parseFlags(flag.ContinueOnError, args)
}

func parseFlags(eh flag.ErrorHandling, args []string) (Config, error) {
	fs := flag.NewFlagSet("bot", eh)
	cfg := Config{
		Clients:      1,
		Seed:         1,
		Mult:         "1.0",
		StallTimeout: DefaultStallTimeout,
		Input:        InputStatic,
	}
	fs.StringVar(&cfg.URL, "url", "", "WebSocket URL (env "+EnvSmokeURL+"; default "+DefaultURL+")")
	fs.IntVar(&cfg.Clients, "clients", cfg.Clients, "number of concurrent clients")
	fs.Uint64Var(&cfg.Seed, "seed", cfg.Seed, "expected instance seed (must match Welcome)")
	fs.StringVar(&cfg.Mult, "mult", cfg.Mult, "expected level multiplier, decimal or hundredths (must match Welcome)")
	fs.DurationVar(&cfg.Duration, "duration", 0, "soak length (e.g. 10m); if set, the bot exits 0 after this long once every client has a snapshot")
	fs.DurationVar(&cfg.StallTimeout, "stall-timeout", cfg.StallTimeout, "fail a soak if no new snapshot arrives for this long")
	fs.StringVar(&cfg.Input, "input", cfg.Input, "input pattern: static (move +X, fire) or wander (per-client turning walk, fire)")
	if err := fs.Parse(args); err != nil {
		return Config{}, err
	}
	if cfg.URL == "" {
		cfg.URL = os.Getenv(EnvSmokeURL)
	}
	if cfg.URL == "" {
		cfg.URL = DefaultURL
	}
	if cfg.Clients < 1 {
		return Config{}, fmt.Errorf("-clients must be >= 1, got %d", cfg.Clients)
	}
	if cfg.StallTimeout <= 0 {
		cfg.StallTimeout = DefaultStallTimeout
	}
	if _, err := instance.ParseMultiplier(cfg.Mult); err != nil {
		return Config{}, fmt.Errorf("-mult: %w", err)
	}
	if err := validInputMode(cfg.Input); err != nil {
		return Config{}, err
	}
	return cfg, nil
}

// Run connects cfg.Clients clients. Every client must complete the
// handshake and receive at least one snapshot; otherwise Run returns a
// non-zero error. With -duration, clients stay connected for that long
// after the first snapshot and Run returns nil if they remain healthy
// (ticks advance and applied_seq catches up). The first client error
// cancels the others.
func Run(ctx context.Context, cfg Config) (Result, error) {
	start := time.Now()
	res := Result{Clients: cfg.Clients}
	m100, err := instance.ParseMultiplier(cfg.Mult)
	if err != nil {
		res.Duration = time.Since(start)
		return res, err
	}
	if cfg.StallTimeout <= 0 {
		cfg.StallTimeout = DefaultStallTimeout
	}
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()

	var (
		wg    sync.WaitGroup
		once  sync.Once
		first error
		snaps atomic.Uint64
	)
	for i := 0; i < cfg.Clients; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			n, err := runOne(ctx, cfg, m100, i)
			snaps.Add(n)
			if err != nil {
				once.Do(func() {
					first = err
					cancel()
				})
			}
		}(i)
	}
	wg.Wait()
	res.Snapshots = snaps.Load()
	res.Duration = time.Since(start)
	return res, first
}

func runOne(ctx context.Context, cfg Config, wantM100, idx int) (uint64, error) {
	conn, _, err := websocket.Dial(ctx, cfg.URL, nil)
	if err != nil {
		return 0, fmt.Errorf("dial %s: %w", cfg.URL, err)
	}
	ok := false
	defer func() {
		// CloseNow avoids the ~2s close-handshake wait when the peer is frozen.
		if ok {
			_ = conn.Close(websocket.StatusNormalClosure, "")
		} else {
			_ = conn.CloseNow()
		}
	}()
	conn.SetReadLimit(64 << 10)

	hello := &protocolv1.ClientMessage{
		Payload: &protocolv1.ClientMessage_Hello{Hello: &protocolv1.Hello{ProtocolVersion: instance.ProtocolVersion}},
	}
	if err := writeMsg(ctx, conn, hello); err != nil {
		return 0, fmt.Errorf("send Hello: %w", err)
	}

	msg, err := readMsg(ctx, conn)
	if err != nil {
		return 0, fmt.Errorf("read handshake: %w", err)
	}
	if rej := msg.GetReject(); rej != nil {
		return 0, fmt.Errorf("handshake rejected: %s", rej.GetReason())
	}
	w := msg.GetWelcome()
	if w == nil {
		return 0, fmt.Errorf("handshake: expected Welcome, got %T", msg.Payload)
	}
	if w.GetProtocolVersion() != instance.ProtocolVersion {
		return 0, fmt.Errorf("welcome protocol_version=%d, want %d", w.GetProtocolVersion(), instance.ProtocolVersion)
	}
	if w.GetInstanceSeed() != cfg.Seed {
		return 0, fmt.Errorf("welcome seed=%d, want %d", w.GetInstanceSeed(), cfg.Seed)
	}
	gotM100 := int(math.Round(float64(w.GetMultiplier()) * 100))
	if gotM100 != wantM100 {
		return 0, fmt.Errorf("welcome multiplier=%g (%d hundredths), want %d", w.GetMultiplier(), gotM100, wantM100)
	}

	track := newSnapTracker(w.GetPlayerId())
	// One long-lived reader for the rest of the session. A short per-read
	// timeout would cancel this context and close the WebSocket.
	go track.read(ctx, conn)

	var seq uint32 = 1
	if err := writeMsg(ctx, conn, inputFor(cfg.Input, idx, seq)); err != nil {
		return 0, fmt.Errorf("send input: %w", err)
	}

	if err := track.waitFirst(ctx, firstSnapWait); err != nil {
		return 0, fmt.Errorf("no snapshot: %w", err)
	}
	if cfg.Duration <= 0 {
		ok = true
		return track.snapshotCount(), nil
	}

	firstTick := track.tick()
	deadline := time.Now().Add(cfg.Duration)
	ticker := time.NewTicker(instance.TickDuration)
	defer ticker.Stop()
	for {
		if time.Now().After(deadline) {
			err := track.soakOK(firstTick, seq)
			if err == nil {
				ok = true
			}
			return track.snapshotCount(), err
		}
		select {
		case <-ctx.Done():
			if err := track.err(); err != nil {
				return track.snapshotCount(), err
			}
			return 0, fmt.Errorf("cancelled before -duration elapsed: %w", ctx.Err())
		case <-ticker.C:
			if err := track.err(); err != nil {
				return 0, fmt.Errorf("soak read: %w", err)
			}
			if stalled, forAgo := track.stalled(cfg.StallTimeout); stalled {
				return 0, fmt.Errorf("no new snapshot for %s (last tick %d)", forAgo, track.tick())
			}
			seq++
			if seq == 0 {
				seq = 1
			}
			if err := writeMsg(ctx, conn, inputFor(cfg.Input, idx, seq)); err != nil {
				return 0, fmt.Errorf("soak input: %w", err)
			}
		}
	}
}

type snapTracker struct {
	mu          sync.Mutex
	playerID    uint64
	lastTick    uint32
	lastApplied uint32
	lastAt      time.Time
	gotFirst    bool
	readErr     error
	snapshots   uint64
}

func newSnapTracker(playerID uint64) *snapTracker {
	return &snapTracker{playerID: playerID}
}

func (s *snapTracker) read(ctx context.Context, conn *websocket.Conn) {
	for {
		msg, err := readMsg(ctx, conn)
		if err != nil {
			s.mu.Lock()
			if s.readErr == nil {
				s.readErr = err
			}
			s.mu.Unlock()
			return
		}
		if rej := msg.GetReject(); rej != nil {
			s.mu.Lock()
			if s.readErr == nil {
				s.readErr = fmt.Errorf("rejected: %s", rej.GetReason())
			}
			s.mu.Unlock()
			return
		}
		if snap := msg.GetSnapshot(); snap != nil {
			s.note(snap)
		}
	}
}

func (s *snapTracker) note(snap *protocolv1.Snapshot) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.lastTick = snap.GetTick()
	s.lastAt = time.Now()
	s.gotFirst = true
	s.snapshots++
	for _, p := range snap.GetPlayers() {
		if p.GetId() == s.playerID && seqIsNext(p.GetAppliedSeq(), s.lastApplied) {
			s.lastApplied = p.GetAppliedSeq()
		}
	}
}

func (s *snapTracker) waitFirst(ctx context.Context, d time.Duration) error {
	deadline := time.NewTimer(d)
	defer deadline.Stop()
	poll := time.NewTicker(5 * time.Millisecond)
	defer poll.Stop()
	for {
		s.mu.Lock()
		ok, err := s.gotFirst, s.readErr
		s.mu.Unlock()
		if err != nil {
			return err
		}
		if ok {
			return nil
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-deadline.C:
			return fmt.Errorf("timed out after %s", d)
		case <-poll.C:
		}
	}
}

func (s *snapTracker) err() error {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.readErr
}

func (s *snapTracker) tick() uint32 {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.lastTick
}

func (s *snapTracker) snapshotCount() uint64 {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.snapshots
}

func (s *snapTracker) stalled(d time.Duration) (bool, time.Duration) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.lastAt.IsZero() {
		return true, d
	}
	ago := time.Since(s.lastAt)
	return ago > d, ago
}

func (s *snapTracker) soakOK(firstTick, lastSeq uint32) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if !s.gotFirst {
		return fmt.Errorf("no snapshot")
	}
	if s.lastTick <= firstTick {
		return fmt.Errorf("ticks did not advance: first=%d last=%d", firstTick, s.lastTick)
	}
	if s.lastApplied == 0 {
		return fmt.Errorf("applied_seq never appeared in a snapshot")
	}
	if lastSeq != 0 && seqNewer(lastSeq, s.lastApplied) && lastSeq-s.lastApplied > appliedSeqSlack {
		return fmt.Errorf("applied_seq=%d did not catch up to sent seq=%d", s.lastApplied, lastSeq)
	}
	return nil
}

func inputMsg(seq uint32) *protocolv1.ClientMessage {
	return &protocolv1.ClientMessage{
		Payload: &protocolv1.ClientMessage_Input{Input: &protocolv1.InputFrame{
			Seq: seq, MoveX: 1, MoveY: 0, Aim: 0, FireHeld: true,
		}},
	}
}

func writeMsg(ctx context.Context, conn *websocket.Conn, msg *protocolv1.ClientMessage) error {
	body, err := proto.Marshal(msg)
	if err != nil {
		return err
	}
	wctx, cancel := context.WithTimeout(ctx, writeTO)
	defer cancel()
	return conn.Write(wctx, websocket.MessageBinary, body)
}

func readMsg(ctx context.Context, conn *websocket.Conn) (*protocolv1.ServerMessage, error) {
	typ, data, err := conn.Read(ctx)
	if err != nil {
		return nil, err
	}
	if typ != websocket.MessageBinary {
		return nil, fmt.Errorf("expected binary frame, got %v", typ)
	}
	var msg protocolv1.ServerMessage
	if err := proto.Unmarshal(data, &msg); err != nil {
		return nil, fmt.Errorf("decode server message: %w", err)
	}
	return &msg, nil
}
