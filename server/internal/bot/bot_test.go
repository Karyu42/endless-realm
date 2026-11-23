package bot

import (
	"bytes"
	"context"
	"flag"
	"io"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/Karyu42/endless-realm/server/internal/clock"
	"github.com/Karyu42/endless-realm/server/internal/instance"
	ernet "github.com/Karyu42/endless-realm/server/internal/net"
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
