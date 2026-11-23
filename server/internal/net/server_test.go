package net

import (
	"context"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/coder/websocket"
	"google.golang.org/protobuf/proto"

	"github.com/Karyu42/endless-realm/server/internal/clock"
	"github.com/Karyu42/endless-realm/server/internal/instance"
	protocolv1 "github.com/Karyu42/endless-realm/server/internal/protocol/v1"
)

func startTestServer(t *testing.T, clk *clock.Fake, seed uint64, mult float64) (*httptest.Server, *instance.Instance, context.CancelFunc) {
	t.Helper()
	inst, err := instance.New(seed, mult, clk)
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	go inst.Run(ctx)
	s := New(inst)
	hs := httptest.NewServer(s)
	t.Cleanup(func() {
		cancel()
		hs.Close()
	})
	return hs, inst, cancel
}

func wsURL(hs *httptest.Server) string {
	return "ws" + strings.TrimPrefix(hs.URL, "http") + "/ws"
}

func readServerMsg(t *testing.T, ctx context.Context, conn *websocket.Conn) *protocolv1.ServerMessage {
	t.Helper()
	typ, data, err := conn.Read(ctx)
	if err != nil {
		t.Fatalf("read: %v", err)
	}
	if typ != websocket.MessageBinary {
		t.Fatalf("got message type %v, want binary", typ)
	}
	var msg protocolv1.ServerMessage
	if err := proto.Unmarshal(data, &msg); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	return &msg
}

func writeClient(t *testing.T, ctx context.Context, conn *websocket.Conn, msg *protocolv1.ClientMessage) {
	t.Helper()
	body, err := proto.Marshal(msg)
	if err != nil {
		t.Fatal(err)
	}
	if err := conn.Write(ctx, websocket.MessageBinary, body); err != nil {
		t.Fatal(err)
	}
}

func TestHealthz(t *testing.T) {
	clk := clock.NewFake(time.Unix(1, 0))
	hs, _, _ := startTestServer(t, clk, 1, 1.0)
	res, err := http.Get(hs.URL + "/healthz")
	if err != nil {
		t.Fatal(err)
	}
	defer res.Body.Close()
	if res.StatusCode != http.StatusOK {
		t.Fatalf("status %d", res.StatusCode)
	}
	b, _ := io.ReadAll(res.Body)
	if !strings.Contains(string(b), "ok") {
		t.Fatalf("body = %q", b)
	}
}

func TestHandshakeWelcome(t *testing.T) {
	clk := clock.NewFake(time.Unix(1, 0))
	hs, inst, _ := startTestServer(t, clk, 99, 1.25)
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	conn, _, err := websocket.Dial(ctx, wsURL(hs), nil)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close(websocket.StatusNormalClosure, "")

	writeClient(t, ctx, conn, &protocolv1.ClientMessage{
		Payload: &protocolv1.ClientMessage_Hello{Hello: &protocolv1.Hello{ProtocolVersion: instance.ProtocolVersion}},
	})
	msg := readServerMsg(t, ctx, conn)
	w := msg.GetWelcome()
	if w == nil {
		t.Fatalf("want Welcome, got %#v", msg.Payload)
	}
	if w.GetProtocolVersion() != instance.ProtocolVersion {
		t.Fatalf("version %d", w.GetProtocolVersion())
	}
	if w.GetTickHz() != instance.TickRate {
		t.Fatalf("tick_hz %d", w.GetTickHz())
	}
	if w.GetInstanceSeed() != inst.Seed() {
		t.Fatalf("seed %d, want %d", w.GetInstanceSeed(), inst.Seed())
	}
	if w.GetMultiplier() != 1.25 {
		t.Fatalf("multiplier %g", w.GetMultiplier())
	}
	if w.GetPlayerId() == 0 {
		t.Fatal("player id should be non-zero")
	}
}

func TestHandshakeRejectsVersionMismatch(t *testing.T) {
	clk := clock.NewFake(time.Unix(1, 0))
	hs, _, _ := startTestServer(t, clk, 1, 1.0)
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	conn, _, err := websocket.Dial(ctx, wsURL(hs), nil)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close(websocket.StatusNormalClosure, "")

	writeClient(t, ctx, conn, &protocolv1.ClientMessage{
		Payload: &protocolv1.ClientMessage_Hello{Hello: &protocolv1.Hello{ProtocolVersion: 99}},
	})
	msg := readServerMsg(t, ctx, conn)
	rej := msg.GetReject()
	if rej == nil {
		t.Fatalf("want Reject, got %#v", msg.Payload)
	}
	if rej.GetServerProtocolVersion() != instance.ProtocolVersion {
		t.Fatalf("server version %d", rej.GetServerProtocolVersion())
	}
	if rej.GetClientProtocolVersion() != 99 {
		t.Fatalf("client version %d", rej.GetClientProtocolVersion())
	}
	if !strings.Contains(rej.GetReason(), "mismatch") {
		t.Fatalf("reason %q", rej.GetReason())
	}

	_, _, err = conn.Read(ctx)
	if err == nil {
		t.Fatal("expected connection to close after reject")
	}
}

func TestBotClientHandshakeInputSnapshot(t *testing.T) {
	// Integration: a small Go bot client connects over WebSocket, completes
	// the v1 handshake, sends an input frame, and receives a snapshot.
	clk := clock.NewFake(time.Unix(1, 0))
	hs, inst, _ := startTestServer(t, clk, 42, 0.75)
	clk.BlockUntilWaiters(1)

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	conn, _, err := websocket.Dial(ctx, wsURL(hs), nil)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close(websocket.StatusNormalClosure, "")

	writeClient(t, ctx, conn, &protocolv1.ClientMessage{
		Payload: &protocolv1.ClientMessage_Hello{Hello: &protocolv1.Hello{ProtocolVersion: 1}},
	})
	if w := readServerMsg(t, ctx, conn).GetWelcome(); w == nil {
		t.Fatal("bot did not receive Welcome")
	}

	writeClient(t, ctx, conn, &protocolv1.ClientMessage{
		Payload: &protocolv1.ClientMessage_Input{Input: &protocolv1.InputFrame{
			Seq: 7, MoveX: 1, MoveY: 0, Aim: 0, FireHeld: true,
		}},
	})

	// Give the server a moment to apply the input, then step one tick.
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		clk.Advance(instance.TickDuration)
		clk.BlockUntilWaiters(1)
		msg := readServerMsg(t, ctx, conn)
		snap := msg.GetSnapshot()
		if snap == nil {
			t.Fatalf("want Snapshot, got %#v", msg.Payload)
		}
		if snap.GetTick() == 0 {
			t.Fatal("snapshot tick should be > 0")
		}
		for _, p := range snap.GetPlayers() {
			if p.GetAppliedSeq() == 7 {
				if inst.Tick() == 0 {
					t.Fatal("instance tick still 0 after snapshot")
				}
				return
			}
		}
		// Input may have landed after this tick; try once more.
	}
	t.Fatal("bot never saw applied_seq=7 in a snapshot")
}
