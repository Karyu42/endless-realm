package net

import (
	"context"
	"io"
	"math"
	"net/http"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/coder/websocket"

	"github.com/Karyu42/endless-realm/server/internal/clock"
	"github.com/Karyu42/endless-realm/server/internal/instance"
	protocolv1 "github.com/Karyu42/endless-realm/server/internal/protocol/v1"
)

func handshakeConn(t *testing.T, ctx context.Context, hsURL string) *websocket.Conn {
	t.Helper()
	conn, _, err := websocket.Dial(ctx, "ws"+strings.TrimPrefix(hsURL, "http")+"/ws", nil)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = conn.Close(websocket.StatusNormalClosure, "") })
	writeClient(t, ctx, conn, &protocolv1.ClientMessage{
		Payload: &protocolv1.ClientMessage_Hello{Hello: &protocolv1.Hello{ProtocolVersion: instance.ProtocolVersion}},
	})
	w := readServerMsg(t, ctx, conn).GetWelcome()
	if w == nil {
		t.Fatal("missing Welcome")
	}
	if w.GetInstanceId() != instance.DefaultInstanceID {
		t.Fatalf("welcome instance_id %d, want %d", w.GetInstanceId(), instance.DefaultInstanceID)
	}
	return conn
}

func readIgnoringSnapshots(t *testing.T, ctx context.Context, conn *websocket.Conn) *protocolv1.ServerMessage {
	t.Helper()
	for {
		msg := readServerMsg(t, ctx, conn)
		if msg.GetSnapshot() != nil {
			continue
		}
		return msg
	}
}

func TestOpenPortalWireValidation(t *testing.T) {
	ctx, cancel := testCtx(t)
	defer cancel()
	clk := clock.NewFake(time.Unix(1, 0))
	hs, inst, _ := startTestServer(t, clk, 1, 100)
	runCtx, stop := context.WithCancel(ctx)
	defer stop()
	go inst.Run(runCtx)
	clk.BlockUntilWaiters(1)

	// Valid m100 passes validation, but the Go harness does not create a portal.
	for _, m := range []uint32{50, 55, 150} {
		t.Run("ok/"+strconv.FormatUint(uint64(m), 10), func(t *testing.T) {
			conn := handshakeConn(t, ctx, hs.URL)
			writeClient(t, ctx, conn, &protocolv1.ClientMessage{
				Payload: &protocolv1.ClientMessage_OpenPortal{OpenPortal: &protocolv1.OpenPortal{M100: m}},
			})
			msg := readIgnoringSnapshots(t, ctx, conn)
			err := msg.GetError()
			if err == nil {
				t.Fatalf("want Error (harness has no portal runtime), got %#v", msg.Payload)
			}
			if err.GetCode() == protocolv1.ErrorCode_INVALID_MULTIPLIER {
				t.Fatalf("valid m100 %d rejected as INVALID_MULTIPLIER: %s", m, err.GetReason())
			}
		})
	}

	invalid := []uint32{0, 45, 49, 51, 151, 155, math.MaxUint32}
	for _, m := range invalid {
		t.Run("bad/"+strconv.FormatUint(uint64(m), 10), func(t *testing.T) {
			conn := handshakeConn(t, ctx, hs.URL)
			writeClient(t, ctx, conn, &protocolv1.ClientMessage{
				Payload: &protocolv1.ClientMessage_OpenPortal{OpenPortal: &protocolv1.OpenPortal{M100: m}},
			})
			msg := readIgnoringSnapshots(t, ctx, conn)
			err := msg.GetError()
			if err == nil || err.GetCode() != protocolv1.ErrorCode_INVALID_MULTIPLIER {
				t.Fatalf("m100=%d: want INVALID_MULTIPLIER, got %#v", m, msg.Payload)
			}
		})
	}
}

func TestMetricsEndpoint(t *testing.T) {
	ctx, cancel := testCtx(t)
	defer cancel()
	clk := clock.NewFake(time.Unix(1, 0))
	hs, inst, _ := startTestServer(t, clk, 1, 100)
	runCtx, stop := context.WithCancel(ctx)
	defer stop()
	go inst.Run(runCtx)
	clk.BlockUntilWaiters(1)

	res, err := http.Get(hs.URL + "/metrics")
	if err != nil {
		t.Fatal(err)
	}
	defer res.Body.Close()
	body, _ := io.ReadAll(res.Body)
	if !strings.Contains(string(body), "er_skipped_ticks") || !strings.Contains(string(body), "er_instances 1") {
		t.Fatalf("metrics body: %s", body)
	}
}
