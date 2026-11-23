package bot

import (
	"bytes"
	"context"
	"flag"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/coder/websocket"
	"google.golang.org/protobuf/proto"

	"github.com/Karyu42/endless-realm/server/internal/clock"
	"github.com/Karyu42/endless-realm/server/internal/instance"
	ernet "github.com/Karyu42/endless-realm/server/internal/net"
	protocolv1 "github.com/Karyu42/endless-realm/server/internal/protocol/v1"
)

func testCtx(t *testing.T) (context.Context, context.CancelFunc) {
	t.Helper()
	return context.WithTimeout(t.Context(), 5*time.Second)
}

func TestParseFlagsCIContract(t *testing.T) {
	t.Setenv(EnvSmokeURL, "")
	cfg, err := ParseFlags([]string{"-clients=1", "-seed=1", "-mult=1.0"})
	if err != nil {
		t.Fatal(err)
	}
	if cfg.Clients != 1 || cfg.Seed != 1 || cfg.Mult != "1.0" {
		t.Fatalf("got %+v", cfg)
	}
	if cfg.URL != DefaultURL {
		t.Fatalf("url %q, want default %q", cfg.URL, DefaultURL)
	}
	if cfg.Duration != 0 {
		t.Fatalf("duration %s, want 0", cfg.Duration)
	}

	cfg, err = ParseFlags([]string{"-clients=8", "-seed=1", "-mult=1.0", "-duration=10m", "-url=ws://example.invalid/ws"})
	if err != nil {
		t.Fatal(err)
	}
	if cfg.Clients != 8 || cfg.Duration != 10*time.Minute || cfg.URL != "ws://example.invalid/ws" {
		t.Fatalf("got %+v", cfg)
	}
}

func TestParseFlagsURLFromEnv(t *testing.T) {
	t.Setenv(EnvSmokeURL, "ws://env.example/ws")
	cfg, err := ParseFlags([]string{"-clients=1", "-seed=1", "-mult=1.0"})
	if err != nil {
		t.Fatal(err)
	}
	if cfg.URL != "ws://env.example/ws" {
		t.Fatalf("url %q, want env", cfg.URL)
	}
	cfg, err = ParseFlags([]string{"-url=ws://flag.example/ws", "-clients=1", "-seed=1", "-mult=1.0"})
	if err != nil {
		t.Fatal(err)
	}
	if cfg.URL != "ws://flag.example/ws" {
		t.Fatalf("flag should win, got %q", cfg.URL)
	}
}

func TestParseFlagsHelpListsDuration(t *testing.T) {
	r, w, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	stderr := os.Stderr
	os.Stderr = w
	_, err = ParseFlags([]string{"-h"})
	_ = w.Close()
	os.Stderr = stderr
	body, _ := io.ReadAll(r)
	if err != flag.ErrHelp {
		t.Fatalf("err = %v, want ErrHelp", err)
	}
	if !bytes.Contains(body, []byte("-duration")) {
		t.Fatalf("help output missing -duration:\n%s", body)
	}
}

func TestRunHandshakeAndSnapshot(t *testing.T) {
	ctx, cancel := testCtx(t)
	defer cancel()

	inst, err := instance.New(1, 100, clock.Real{})
	if err != nil {
		t.Fatal(err)
	}
	runCtx, stopRun := context.WithCancel(ctx)
	defer stopRun()
	go inst.Run(runCtx)

	srv := ernet.NewContext(ctx, inst)
	hs := httptest.NewServer(srv)
	t.Cleanup(func() {
		srv.Close()
		hs.Close()
	})

	url := "ws" + strings.TrimPrefix(hs.URL, "http") + "/ws"
	cfg := Config{URL: url, Clients: 1, Seed: 1, Mult: "1.0"}
	if err := Run(ctx, cfg); err != nil {
		t.Fatal(err)
	}
}

func TestRunFailsOnSeedMismatch(t *testing.T) {
	ctx, cancel := testCtx(t)
	defer cancel()

	inst, err := instance.New(1, 100, clock.Real{})
	if err != nil {
		t.Fatal(err)
	}
	runCtx, stopRun := context.WithCancel(ctx)
	defer stopRun()
	go inst.Run(runCtx)

	srv := ernet.NewContext(ctx, inst)
	hs := httptest.NewServer(srv)
	t.Cleanup(func() {
		srv.Close()
		hs.Close()
	})

	url := "ws" + strings.TrimPrefix(hs.URL, "http") + "/ws"
	cfg := Config{URL: url, Clients: 1, Seed: 99, Mult: "1.0"}
	if err := Run(ctx, cfg); err == nil {
		t.Fatal("expected seed mismatch error")
	}
}

func TestParseFlagsStallTimeoutAndBareMult(t *testing.T) {
	t.Setenv(EnvSmokeURL, "")
	cfg, err := ParseFlags([]string{"-clients=1", "-seed=1", "-mult=1", "-stall-timeout=2s"})
	if err != nil {
		t.Fatal(err)
	}
	if cfg.Mult != "1" || cfg.StallTimeout != 2*time.Second {
		t.Fatalf("got %+v", cfg)
	}
	cfg, err = ParseFlags([]string{"-clients=1", "-seed=1", "-mult=1.0"})
	if err != nil {
		t.Fatal(err)
	}
	if cfg.StallTimeout != DefaultStallTimeout {
		t.Fatalf("default stall-timeout %s, want %s", cfg.StallTimeout, DefaultStallTimeout)
	}
}

func TestRunSoakShortStallOKLongStallFails(t *testing.T) {
	ctx, cancel := context.WithTimeout(t.Context(), 20*time.Second)
	defer cancel()

	ctrl := newScriptedServer()
	url := ctrl.start(t)

	t.Run("600ms stall is tolerated", func(t *testing.T) {
		sub, subCancel := context.WithTimeout(ctx, 8*time.Second)
		defer subCancel()
		errCh := make(chan error, 1)
		go func() {
			errCh <- Run(sub, Config{
				URL: url, Clients: 1, Seed: 1, Mult: "1.0",
				Duration: 1500 * time.Millisecond, StallTimeout: 5 * time.Second,
			})
		}()
		time.Sleep(200 * time.Millisecond)
		ctrl.setPaused(true)
		time.Sleep(600 * time.Millisecond)
		ctrl.setPaused(false)
		select {
		case err := <-errCh:
			if err != nil {
				t.Fatalf("600ms stall should be tolerated: %v", err)
			}
		case <-sub.Done():
			t.Fatal(sub.Err())
		}
	})

	t.Run("stall longer than stall-timeout fails", func(t *testing.T) {
		sub, subCancel := context.WithTimeout(ctx, 15*time.Second)
		defer subCancel()
		errCh := make(chan error, 1)
		start := time.Now()
		go func() {
			errCh <- Run(sub, Config{
				URL: url, Clients: 1, Seed: 1, Mult: "1.0",
				Duration: 30 * time.Second, StallTimeout: 5 * time.Second,
			})
		}()
		time.Sleep(200 * time.Millisecond)
		ctrl.setPaused(true)
		defer ctrl.setPaused(false)
		select {
		case err := <-errCh:
			if err == nil {
				t.Fatal("expected stall-timeout error")
			}
			if !strings.Contains(err.Error(), "no new snapshot") {
				t.Fatalf("err = %v, want stall message", err)
			}
			if elapsed := time.Since(start); elapsed > 12*time.Second {
				t.Fatalf("stall failure took %s, want ~5s", elapsed)
			}
		case <-sub.Done():
			t.Fatal(sub.Err())
		}
	})
}

func TestRunFirstClientErrorCancelsOthers(t *testing.T) {
	ctx, cancel := context.WithTimeout(t.Context(), 10*time.Second)
	defer cancel()

	ctrl := newScriptedServer()
	ctrl.dropAfterWelcome = 2 // close the second client after Welcome
	url := ctrl.start(t)

	start := time.Now()
	err := Run(ctx, Config{
		URL: url, Clients: 2, Seed: 1, Mult: "1.0",
		Duration: 8 * time.Second, StallTimeout: 5 * time.Second,
	})
	if err == nil {
		t.Fatal("expected an error from the dropped client")
	}
	if elapsed := time.Since(start); elapsed > 3*time.Second {
		t.Fatalf("took %s to report the first failure (other client should have been cancelled)", elapsed)
	}
}

func TestRunSoakTicksAdvance(t *testing.T) {
	ctx, cancel := testCtx(t)
	defer cancel()

	inst, err := instance.New(1, 100, clock.Real{})
	if err != nil {
		t.Fatal(err)
	}
	runCtx, stopRun := context.WithCancel(ctx)
	defer stopRun()
	go inst.Run(runCtx)

	srv := ernet.NewContext(ctx, inst)
	hs := httptest.NewServer(srv)
	t.Cleanup(func() {
		srv.Close()
		hs.Close()
	})

	url := "ws" + strings.TrimPrefix(hs.URL, "http") + "/ws"
	cfg := Config{URL: url, Clients: 1, Seed: 1, Mult: "1.0", Duration: 300 * time.Millisecond}
	if err := Run(ctx, cfg); err != nil {
		t.Fatal(err)
	}
}

type scriptedServer struct {
	mu               sync.Mutex
	paused           bool
	tick             uint32
	applied          map[uint32]uint32
	nextID           uint32
	dropAfterWelcome int // 1-based connection number to close after Welcome; 0 disables
	conns            int
}

func newScriptedServer() *scriptedServer {
	return &scriptedServer{applied: make(map[uint32]uint32), nextID: 1}
}

func (s *scriptedServer) setPaused(p bool) {
	s.mu.Lock()
	s.paused = p
	s.mu.Unlock()
}

func (s *scriptedServer) start(t *testing.T) string {
	t.Helper()
	h := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/ws" {
			http.NotFound(w, r)
			return
		}
		conn, err := websocket.Accept(w, r, &websocket.AcceptOptions{InsecureSkipVerify: true})
		if err != nil {
			return
		}
		s.handle(r.Context(), conn)
	})
	hs := httptest.NewServer(h)
	t.Cleanup(hs.Close)
	return "ws" + strings.TrimPrefix(hs.URL, "http") + "/ws"
}

func (s *scriptedServer) handle(ctx context.Context, conn *websocket.Conn) {
	defer conn.Close(websocket.StatusNormalClosure, "")
	typ, data, err := conn.Read(ctx)
	if err != nil || typ != websocket.MessageBinary {
		return
	}
	var cm protocolv1.ClientMessage
	if err := proto.Unmarshal(data, &cm); err != nil || cm.GetHello() == nil {
		return
	}
	s.mu.Lock()
	s.conns++
	id := s.nextID
	s.nextID++
	drop := s.dropAfterWelcome
	connN := s.conns
	s.mu.Unlock()

	welcome := &protocolv1.ServerMessage{Payload: &protocolv1.ServerMessage_Welcome{Welcome: &protocolv1.Welcome{
		ProtocolVersion: instance.ProtocolVersion,
		PlayerId:        id,
		TickHz:          instance.TickRate,
		InstanceSeed:    1,
		Multiplier:      1.0,
	}}}
	body, err := proto.Marshal(welcome)
	if err != nil {
		return
	}
	if err := conn.Write(ctx, websocket.MessageBinary, body); err != nil {
		return
	}
	if drop != 0 && connN == drop {
		_ = conn.Close(websocket.StatusInternalError, "dropped for test")
		return
	}

	go func() {
		for {
			typ, data, err := conn.Read(ctx)
			if err != nil {
				return
			}
			if typ != websocket.MessageBinary {
				continue
			}
			var in protocolv1.ClientMessage
			if err := proto.Unmarshal(data, &in); err != nil {
				return
			}
			if fr := in.GetInput(); fr != nil {
				s.mu.Lock()
				s.applied[id] = fr.GetSeq()
				s.mu.Unlock()
			}
		}
	}()

	ticker := time.NewTicker(20 * time.Millisecond)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			s.mu.Lock()
			paused := s.paused
			if !paused {
				s.tick++
			}
			tick := s.tick
			applied := s.applied[id]
			s.mu.Unlock()
			if paused {
				continue
			}
			snap := &protocolv1.ServerMessage{Payload: &protocolv1.ServerMessage_Snapshot{Snapshot: &protocolv1.Snapshot{
				Tick:    tick,
				Players: []*protocolv1.PlayerStub{{Id: id, AppliedSeq: applied}},
			}}}
			body, err := proto.Marshal(snap)
			if err != nil {
				return
			}
			if err := conn.Write(ctx, websocket.MessageBinary, body); err != nil {
				return
			}
		}
	}
}
