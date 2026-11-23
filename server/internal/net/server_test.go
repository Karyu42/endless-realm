package net

import (
	"context"
	"io"
	"math"
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

func testCtx(t *testing.T) (context.Context, context.CancelFunc) {
	t.Helper()
	return context.WithTimeout(t.Context(), 5*time.Second)
}

func startTestServer(t *testing.T, clk *clock.Fake, seed uint64, m100 int) (*httptest.Server, *instance.Instance, *Server) {
	t.Helper()
	inst, err := instance.New(seed, m100, clk)
	if err != nil {
		t.Fatal(err)
	}
	s := New(inst)
	hs := httptest.NewServer(s)
	t.Cleanup(func() {
		s.Close()
		hs.Close()
	})
	return hs, inst, s
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

func dial(t *testing.T, ctx context.Context, hs *httptest.Server) *websocket.Conn {
	t.Helper()
	conn, _, err := websocket.Dial(ctx, wsURL(hs), nil)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = conn.Close(websocket.StatusNormalClosure, "") })
	return conn
}

func TestHealthz(t *testing.T) {
	ctx, cancel := testCtx(t)
	defer cancel()
	clk := clock.NewFake(time.Unix(1, 0))
	hs, _, _ := startTestServer(t, clk, 1, 100)
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, hs.URL+"/healthz", nil)
	if err != nil {
		t.Fatal(err)
	}
	res, err := http.DefaultClient.Do(req)
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
	ctx, cancel := testCtx(t)
	defer cancel()
	clk := clock.NewFake(time.Unix(1, 0))
	hs, inst, _ := startTestServer(t, clk, 99, 125)
	conn := dial(t, ctx, hs)

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
	if int(math.Round(float64(w.GetMultiplier())*100)) != 125 {
		t.Fatalf("multiplier %g, want 1.25", w.GetMultiplier())
	}
	if w.GetM100() != 125 {
		t.Fatalf("m100 %d, want 125", w.GetM100())
	}
	if w.GetInstance() != instance.DefaultInstanceID {
		t.Fatalf("instance %d, want default %d", w.GetInstance(), instance.DefaultInstanceID)
	}
	if w.GetPlayerId() == 0 {
		t.Fatal("player id should be non-zero")
	}
}

func TestHandshakeRejectsVersionEdges(t *testing.T) {
	clk := clock.NewFake(time.Unix(1, 0))
	hs, _, _ := startTestServer(t, clk, 1, 100)

	cases := []struct {
		name string
		msg  *protocolv1.ClientMessage
		want string
	}{
		{
			name: "version 0",
			msg:  &protocolv1.ClientMessage{Payload: &protocolv1.ClientMessage_Hello{Hello: &protocolv1.Hello{ProtocolVersion: 0}}},
			want: "mismatch",
		},
		{
			name: "higher version",
			msg:  &protocolv1.ClientMessage{Payload: &protocolv1.ClientMessage_Hello{Hello: &protocolv1.Hello{ProtocolVersion: 99}}},
			want: "mismatch",
		},
		{
			name: "version 65535",
			msg:  &protocolv1.ClientMessage{Payload: &protocolv1.ClientMessage_Hello{Hello: &protocolv1.Hello{ProtocolVersion: 65535}}},
			want: "mismatch",
		},
		{
			name: "version 65536",
			msg:  &protocolv1.ClientMessage{Payload: &protocolv1.ClientMessage_Hello{Hello: &protocolv1.Hello{ProtocolVersion: 65536}}},
			want: "mismatch",
		},
		{
			name: "version max uint32",
			msg:  &protocolv1.ClientMessage{Payload: &protocolv1.ClientMessage_Hello{Hello: &protocolv1.Hello{ProtocolVersion: math.MaxUint32}}},
			want: "mismatch",
		},
		{
			name: "missing Hello",
			msg:  &protocolv1.ClientMessage{},
			want: "first message must be Hello",
		},
		{
			name: "wrong first message",
			msg:  &protocolv1.ClientMessage{Payload: &protocolv1.ClientMessage_Input{Input: &protocolv1.InputFrame{Seq: 1}}},
			want: "first message must be Hello",
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			ctx, cancel := testCtx(t)
			defer cancel()
			conn := dial(t, ctx, hs)
			writeClient(t, ctx, conn, tc.msg)
			msg := readServerMsg(t, ctx, conn)
			rej := msg.GetReject()
			if rej == nil {
				t.Fatalf("want Reject, got %#v", msg.Payload)
			}
			if rej.GetServerProtocolVersion() != instance.ProtocolVersion {
				t.Fatalf("server version %d", rej.GetServerProtocolVersion())
			}
			if !strings.Contains(rej.GetReason(), tc.want) {
				t.Fatalf("reason %q, want substring %q", rej.GetReason(), tc.want)
			}
			if _, _, err := conn.Read(ctx); err == nil {
				t.Fatal("expected connection to close after reject")
			}
		})
	}
}

func TestHandshakeRejectsTextFrameAndGarbage(t *testing.T) {
	clk := clock.NewFake(time.Unix(1, 0))
	hs, _, _ := startTestServer(t, clk, 1, 100)

	t.Run("text frame", func(t *testing.T) {
		ctx, cancel := testCtx(t)
		defer cancel()
		conn := dial(t, ctx, hs)
		if err := conn.Write(ctx, websocket.MessageText, []byte("hello")); err != nil {
			t.Fatal(err)
		}
		msg := readServerMsg(t, ctx, conn)
		rej := msg.GetReject()
		if rej == nil {
			t.Fatalf("want Reject, got %#v", msg.Payload)
		}
		if !strings.Contains(rej.GetReason(), "binary") {
			t.Fatalf("reason %q, want binary-frame mention", rej.GetReason())
		}
	})

	t.Run("garbage bytes", func(t *testing.T) {
		ctx, cancel := testCtx(t)
		defer cancel()
		conn := dial(t, ctx, hs)
		if err := conn.Write(ctx, websocket.MessageBinary, []byte{0xff, 0x00, 0xfe, 0x01, 0x99, 'g', 'a', 'r', 'b', 'a', 'g', 'e'}); err != nil {
			t.Fatal(err)
		}
		msg := readServerMsg(t, ctx, conn)
		rej := msg.GetReject()
		if rej == nil {
			t.Fatalf("want Reject, got %#v", msg.Payload)
		}
		if rej.GetReason() == "" {
			t.Fatal("empty reject reason")
		}
		if _, _, err := conn.Read(ctx); err == nil {
			t.Fatal("expected connection to close after reject")
		}
	})
}

func TestBotClientHandshakeInputSnapshot(t *testing.T) {
	// Integration: a Go bot connects, handshakes, sends one input, then we
	// step exactly one tick and read exactly one snapshot. Sync is via
	// channels (OnSubmit), not sleeps or wall-clock deadlines.
	ctx, cancel := testCtx(t)
	defer cancel()
	clk := clock.NewFake(time.Unix(1, 0))
	hs, inst, _ := startTestServer(t, clk, 42, 75)

	submitted := make(chan instance.Input, 1)
	inst.SetOnSubmit(func(in instance.Input) { submitted <- in })

	conn := dial(t, ctx, hs)

	writeClient(t, ctx, conn, &protocolv1.ClientMessage{
		Payload: &protocolv1.ClientMessage_Hello{Hello: &protocolv1.Hello{ProtocolVersion: 1}},
	})
	if w := readServerMsg(t, ctx, conn).GetWelcome(); w == nil {
		t.Fatal("bot did not receive Welcome")
	}

	writeClient(t, ctx, conn, &protocolv1.ClientMessage{
		Payload: &protocolv1.ClientMessage_Input{Input: &protocolv1.InputFrame{
			Seq: 7, MoveX: 1, MoveY: 0, Aim: 0, FireHeld: true, AbilityPressed: true,
		}},
	})
	select {
	case in := <-submitted:
		if in.Seq != 7 {
			t.Fatalf("submitted seq = %d, want 7", in.Seq)
		}
		if !in.AbilityPressed {
			t.Fatal("ability_pressed not passed through")
		}
	case <-ctx.Done():
		t.Fatal("input was not submitted")
	}

	if snap := inst.Step(); snap.Tick != 1 {
		t.Fatalf("step tick = %d, want 1", snap.Tick)
	}
	msg := readServerMsg(t, ctx, conn)
	got := msg.GetSnapshot()
	if got == nil {
		t.Fatalf("want Snapshot, got %#v", msg.Payload)
	}
	if got.GetTick() != 1 {
		t.Fatalf("snapshot tick = %d, want 1", got.GetTick())
	}
	found := false
	for _, p := range got.GetPlayers() {
		if p.GetAppliedSeq() == 7 {
			found = true
			break
		}
	}
	if !found {
		t.Fatalf("snapshot missing applied_seq=7: %#v", got.GetPlayers())
	}
}

func TestRunLoopNetworkSnapshot(t *testing.T) {
	// Network-level: the real Run loop, driven by the fake clock, delivers
	// a snapshot over the WebSocket after a handshake and one input.
	ctx, cancel := testCtx(t)
	defer cancel()

	clk := clock.NewFake(time.Unix(1, 0))
	hs, inst, _ := startTestServer(t, clk, 42, 100)

	runCtx, stopRun := context.WithCancel(ctx)
	defer stopRun()
	done := make(chan struct{})
	go func() {
		inst.Run(runCtx)
		close(done)
	}()
	clk.BlockUntilWaiters(1)

	submitted := make(chan instance.Input, 1)
	inst.SetOnSubmit(func(in instance.Input) { submitted <- in })

	conn := dial(t, ctx, hs)
	writeClient(t, ctx, conn, &protocolv1.ClientMessage{
		Payload: &protocolv1.ClientMessage_Hello{Hello: &protocolv1.Hello{ProtocolVersion: instance.ProtocolVersion}},
	})
	if w := readServerMsg(t, ctx, conn).GetWelcome(); w == nil {
		t.Fatal("missing Welcome")
	}

	writeClient(t, ctx, conn, &protocolv1.ClientMessage{
		Payload: &protocolv1.ClientMessage_Input{Input: &protocolv1.InputFrame{Seq: 3, FireHeld: true}},
	})
	select {
	case in := <-submitted:
		if in.Seq != 3 {
			t.Fatalf("submitted seq = %d, want 3", in.Seq)
		}
	case <-ctx.Done():
		t.Fatal("input was not submitted")
	}

	clk.Advance(instance.TickDuration)
	msg := readServerMsg(t, ctx, conn)
	got := msg.GetSnapshot()
	if got == nil {
		t.Fatalf("want Snapshot, got %#v", msg.Payload)
	}
	if got.GetTick() != 1 {
		t.Fatalf("snapshot tick = %d, want 1", got.GetTick())
	}
	found := false
	for _, p := range got.GetPlayers() {
		if p.GetAppliedSeq() == 3 {
			found = true
			break
		}
	}
	if !found {
		t.Fatalf("snapshot missing applied_seq=3: %#v", got.GetPlayers())
	}

	stopRun()
	select {
	case <-done:
	case <-ctx.Done():
		t.Fatal("Run did not exit after cancel")
	}
}

func TestListenURLs(t *testing.T) {
	cases := []struct {
		addr, health, connect string
	}{
		{":8080", "http://localhost:8080/healthz", "ws://localhost:8080/ws"},
		{"127.0.0.1:8080", "http://127.0.0.1:8080/healthz", "ws://127.0.0.1:8080/ws"},
		{"0.0.0.0:9000", "http://localhost:9000/healthz", "ws://localhost:9000/ws"},
		{"[::]:8080", "http://localhost:8080/healthz", "ws://localhost:8080/ws"},
		{"localhost:8080", "http://localhost:8080/healthz", "ws://localhost:8080/ws"},
	}
	for _, tc := range cases {
		health, connect := listenURLs(tc.addr)
		if health != tc.health || connect != tc.connect {
			t.Fatalf("addr %q: health=%q connect=%q, want %q %q", tc.addr, health, connect, tc.health, tc.connect)
		}
	}
}
