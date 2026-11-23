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
	"time"

	"github.com/coder/websocket"
	"google.golang.org/protobuf/proto"

	"github.com/Karyu42/endless-realm/server/internal/instance"
	protocolv1 "github.com/Karyu42/endless-realm/server/internal/protocol/v1"
)

const (
	EnvSmokeURL   = "ER_SMOKE_URL"
	DefaultURL    = "ws://127.0.0.1:8080/ws"
	firstSnapWait = 10 * time.Second
	writeTO       = 5 * time.Second
)

// Config is the bot contract invoked by CI (PR #5 ci.yml / soak.yml):
//
//	er-bot -clients=1 -seed=1 -mult=1.0
//	er-bot -clients=$N -seed=1 -mult=1.0 -duration=10m
//
// -url is required unless ER_SMOKE_URL is set; if both are empty the
// default is DefaultURL so the current CI invocation (which does not pass
// -url) works against compose's published port.
type Config struct {
	URL      string
	Clients  int
	Seed     uint64
	Mult     string
	Duration time.Duration
}

// ParseFlags reads the CI flag contract from args (and ER_SMOKE_URL).
func ParseFlags(args []string) (Config, error) {
	return parseFlags(flag.ContinueOnError, args)
}

func parseFlags(eh flag.ErrorHandling, args []string) (Config, error) {
	fs := flag.NewFlagSet("bot", eh)
	cfg := Config{
		Clients: 1,
		Seed:    1,
		Mult:    "1.0",
	}
	fs.StringVar(&cfg.URL, "url", "", "WebSocket URL (env "+EnvSmokeURL+"; default "+DefaultURL+")")
	fs.IntVar(&cfg.Clients, "clients", cfg.Clients, "number of concurrent clients")
	fs.Uint64Var(&cfg.Seed, "seed", cfg.Seed, "expected instance seed (must match Welcome)")
	fs.StringVar(&cfg.Mult, "mult", cfg.Mult, "expected level multiplier, decimal or hundredths (must match Welcome)")
	fs.DurationVar(&cfg.Duration, "duration", 0, "soak length (e.g. 10m); if set, the bot exits 0 after this long once every client has a snapshot")
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
	if _, err := instance.ParseMultiplier(cfg.Mult); err != nil {
		return Config{}, fmt.Errorf("-mult: %w", err)
	}
	return cfg, nil
}

// Run connects cfg.Clients clients. Every client must complete the
// handshake and receive at least one snapshot; otherwise Run returns a
// non-zero error. With -duration, clients stay connected for that long
// after the first snapshot and Run returns nil if they remain healthy.
func Run(ctx context.Context, cfg Config) error {
	m100, err := instance.ParseMultiplier(cfg.Mult)
	if err != nil {
		return err
	}
	var wg sync.WaitGroup
	errCh := make(chan error, cfg.Clients)
	for i := 0; i < cfg.Clients; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			errCh <- runOne(ctx, cfg, m100)
		}()
	}
	wg.Wait()
	close(errCh)
	for err := range errCh {
		if err != nil {
			return err
		}
	}
	return nil
}

func runOne(ctx context.Context, cfg Config, wantM100 int) error {
	conn, _, err := websocket.Dial(ctx, cfg.URL, nil)
	if err != nil {
		return fmt.Errorf("dial %s: %w", cfg.URL, err)
	}
	defer conn.Close(websocket.StatusNormalClosure, "")
	conn.SetReadLimit(64 << 10)

	hello := &protocolv1.ClientMessage{
		Payload: &protocolv1.ClientMessage_Hello{Hello: &protocolv1.Hello{ProtocolVersion: instance.ProtocolVersion}},
	}
	if err := writeMsg(ctx, conn, hello); err != nil {
		return fmt.Errorf("send Hello: %w", err)
	}

	msg, err := readMsg(ctx, conn)
	if err != nil {
		return fmt.Errorf("read handshake: %w", err)
	}
	if rej := msg.GetReject(); rej != nil {
		return fmt.Errorf("handshake rejected: %s", rej.GetReason())
	}
	w := msg.GetWelcome()
	if w == nil {
		return fmt.Errorf("handshake: expected Welcome, got %T", msg.Payload)
	}
	if w.GetProtocolVersion() != instance.ProtocolVersion {
		return fmt.Errorf("welcome protocol_version=%d, want %d", w.GetProtocolVersion(), instance.ProtocolVersion)
	}
	if w.GetInstanceSeed() != cfg.Seed {
		return fmt.Errorf("welcome seed=%d, want %d", w.GetInstanceSeed(), cfg.Seed)
	}
	gotM100 := int(math.Round(float64(w.GetMultiplier()) * 100))
	if gotM100 != wantM100 {
		return fmt.Errorf("welcome multiplier=%g (%d hundredths), want %d", w.GetMultiplier(), gotM100, wantM100)
	}

	var seq uint32 = 1
	if err := writeMsg(ctx, conn, inputMsg(seq)); err != nil {
		return fmt.Errorf("send input: %w", err)
	}

	snapCtx, cancel := context.WithTimeout(ctx, firstSnapWait)
	got, err := readMsg(snapCtx, conn)
	cancel()
	if err != nil {
		return fmt.Errorf("no snapshot: %w", err)
	}
	if got.GetSnapshot() == nil {
		if rej := got.GetReject(); rej != nil {
			return fmt.Errorf("no snapshot: rejected: %s", rej.GetReason())
		}
		return fmt.Errorf("no snapshot: got %T", got.Payload)
	}

	if cfg.Duration <= 0 {
		return nil
	}

	deadline := time.Now().Add(cfg.Duration)
	ticker := time.NewTicker(instance.TickDuration)
	defer ticker.Stop()
	for {
		if time.Now().After(deadline) {
			return nil
		}
		select {
		case <-ctx.Done():
			return fmt.Errorf("cancelled before -duration elapsed: %w", ctx.Err())
		case <-ticker.C:
			seq++
			if err := writeMsg(ctx, conn, inputMsg(seq)); err != nil {
				return fmt.Errorf("soak input: %w", err)
			}
			// Drain any pending snapshots so the buffer does not stall.
			drainCtx, drainCancel := context.WithTimeout(ctx, 200*time.Millisecond)
			_, err := readMsg(drainCtx, conn)
			drainCancel()
			if err != nil && drainCtx.Err() == nil && ctx.Err() == nil {
				return fmt.Errorf("soak read: %w", err)
			}
		}
	}
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
