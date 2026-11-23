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

	valid := []uint32{50, 55, 150}
	for _, m := range valid {
		t.Run("ok/"+strconv.FormatUint(uint64(m), 10), func(t *testing.T) {
			conn := handshakeConn(t, ctx, hs.URL)
			writeClient(t, ctx, conn, &protocolv1.ClientMessage{
				Payload: &protocolv1.ClientMessage_OpenPortal{OpenPortal: &protocolv1.OpenPortal{M100: m}},
			})
			msg := readIgnoringSnapshots(t, ctx, conn)
			ok := msg.GetOpenPortalOk()
			if ok == nil {
				t.Fatalf("want OpenPortalOk, got %#v", msg.Payload)
			}
			if ok.GetM100() != m {
				t.Fatalf("m100 %d, want %d", ok.GetM100(), m)
			}
			if ok.GetInstanceId() == 0 || ok.GetInstanceId() == instance.DefaultInstanceID {
				t.Fatalf("instance id %d is not a new portal", ok.GetInstanceId())
			}
		})
	}

	invalid := []uint32{0, 49, 51, 151, math.MaxUint32}
	for _, m := range invalid {
		t.Run("bad/"+strconv.FormatUint(uint64(m), 10), func(t *testing.T) {
			conn := handshakeConn(t, ctx, hs.URL)
			writeClient(t, ctx, conn, &protocolv1.ClientMessage{
				Payload: &protocolv1.ClientMessage_ListInstances{ListInstances: &protocolv1.ListInstances{}},
			})
			before := readIgnoringSnapshots(t, ctx, conn).GetInstanceList()
			if before == nil {
				t.Fatal("want InstanceList before open")
			}
			n := len(before.GetInstances())
			writeClient(t, ctx, conn, &protocolv1.ClientMessage{
				Payload: &protocolv1.ClientMessage_OpenPortal{OpenPortal: &protocolv1.OpenPortal{M100: m}},
			})
			msg := readIgnoringSnapshots(t, ctx, conn)
			err := msg.GetError()
			if err == nil {
				t.Fatalf("want Error, got %#v", msg.Payload)
			}
			if err.GetCode() != protocolv1.ErrorCode_INVALID_MULTIPLIER {
				t.Fatalf("code %v, want INVALID_MULTIPLIER", err.GetCode())
			}
			writeClient(t, ctx, conn, &protocolv1.ClientMessage{
				Payload: &protocolv1.ClientMessage_ListInstances{ListInstances: &protocolv1.ListInstances{}},
			})
			after := readIgnoringSnapshots(t, ctx, conn).GetInstanceList()
			if after == nil || len(after.GetInstances()) != n {
				t.Fatalf("invalid open created an instance: before=%d after=%v", n, after)
			}
		})
	}
}

func TestOpenJoinListAndImmutability(t *testing.T) {
	ctx, cancel := testCtx(t)
	defer cancel()
	clk := clock.NewFake(time.Unix(1, 0))
	hs, inst, srv := startTestServer(t, clk, 1, 100)
	runCtx, stop := context.WithCancel(ctx)
	defer stop()
	go inst.Run(runCtx)
	clk.BlockUntilWaiters(1)

	a := handshakeConn(t, ctx, hs.URL)
	writeClient(t, ctx, a, &protocolv1.ClientMessage{
		Payload: &protocolv1.ClientMessage_OpenPortal{OpenPortal: &protocolv1.OpenPortal{M100: 105}},
	})
	opened := readIgnoringSnapshots(t, ctx, a).GetOpenPortalOk()
	if opened == nil || opened.GetM100() != 105 {
		t.Fatalf("open: %#v", opened)
	}
	portalID := opened.GetInstanceId()

	// Snapshots after the switch come from the new instance (tick starts at 0).
	clk.BlockUntilWaiters(1)
	clk.Advance(instance.TickDuration)
	snap := readServerMsg(t, ctx, a).GetSnapshot()
	if snap == nil || snap.GetTick() != 1 {
		t.Fatalf("want portal tick 1, got %#v", snap)
	}

	writeClient(t, ctx, a, &protocolv1.ClientMessage{
		Payload: &protocolv1.ClientMessage_ListInstances{ListInstances: &protocolv1.ListInstances{}},
	})
	list := readIgnoringSnapshots(t, ctx, a).GetInstanceList()
	if list == nil || len(list.GetInstances()) < 2 {
		t.Fatalf("list = %#v", list)
	}
	var sawDefault, sawPortal bool
	for _, inf := range list.GetInstances() {
		if inf.GetIsDefault() && inf.GetInstanceId() == instance.DefaultInstanceID {
			sawDefault = true
		}
		if inf.GetInstanceId() == portalID && inf.GetM100() == 105 && !inf.GetIsDefault() {
			sawPortal = true
			if inf.GetPlayerCount() != 1 {
				t.Fatalf("portal player_count %d, want 1", inf.GetPlayerCount())
			}
		}
	}
	if !sawDefault || !sawPortal {
		t.Fatalf("list missing default or portal: %#v", list.GetInstances())
	}

	// Re-open / change M is rejected; no new instance is created.
	writeClient(t, ctx, a, &protocolv1.ClientMessage{
		Payload: &protocolv1.ClientMessage_OpenPortal{OpenPortal: &protocolv1.OpenPortal{M100: 150}},
	})
	rej := readIgnoringSnapshots(t, ctx, a).GetError()
	if rej == nil || rej.GetCode() != protocolv1.ErrorCode_ALREADY_IN_INSTANCE {
		t.Fatalf("reopen: %#v", rej)
	}
	writeClient(t, ctx, a, &protocolv1.ClientMessage{
		Payload: &protocolv1.ClientMessage_ListInstances{ListInstances: &protocolv1.ListInstances{}},
	})
	list2 := readIgnoringSnapshots(t, ctx, a).GetInstanceList()
	if len(list2.GetInstances()) != len(list.GetInstances()) {
		t.Fatalf("reopen created an instance: %d -> %d", len(list.GetInstances()), len(list2.GetInstances()))
	}

	// Second session joins the portal.
	b := handshakeConn(t, ctx, hs.URL)
	writeClient(t, ctx, b, &protocolv1.ClientMessage{
		Payload: &protocolv1.ClientMessage_JoinInstance{JoinInstance: &protocolv1.JoinInstance{InstanceId: portalID}},
	})
	joined := readIgnoringSnapshots(t, ctx, b).GetJoinInstanceOk()
	if joined == nil || joined.GetInstanceId() != portalID || joined.GetM100() != 105 {
		t.Fatalf("join: %#v", joined)
	}

	// A session already in a portal cannot join a second one (one-instance-per-session).
	// Open from b should fail (already in a portal).
	writeClient(t, ctx, b, &protocolv1.ClientMessage{
		Payload: &protocolv1.ClientMessage_OpenPortal{OpenPortal: &protocolv1.OpenPortal{M100: 50}},
	})
	if got := readIgnoringSnapshots(t, ctx, b).GetError(); got == nil || got.GetCode() != protocolv1.ErrorCode_ALREADY_IN_INSTANCE {
		t.Fatalf("b open while in portal: %#v", got)
	}

	// Leave back to default, then one-open-per-player still blocks a second portal.
	writeClient(t, ctx, a, &protocolv1.ClientMessage{
		Payload: &protocolv1.ClientMessage_LeaveInstance{LeaveInstance: &protocolv1.LeaveInstance{}},
	})
	left := readIgnoringSnapshots(t, ctx, a).GetJoinInstanceOk()
	if left == nil || left.GetInstanceId() != instance.DefaultInstanceID {
		t.Fatalf("leave: %#v", left)
	}
	writeClient(t, ctx, a, &protocolv1.ClientMessage{
		Payload: &protocolv1.ClientMessage_OpenPortal{OpenPortal: &protocolv1.OpenPortal{M100: 50}},
	})
	if got := readIgnoringSnapshots(t, ctx, a).GetError(); got == nil || got.GetCode() != protocolv1.ErrorCode_OPEN_PORTAL_LIMIT {
		t.Fatalf("second portal from same opener: %#v", got)
	}

	// Join the same portal again from default is allowed.
	writeClient(t, ctx, a, &protocolv1.ClientMessage{
		Payload: &protocolv1.ClientMessage_JoinInstance{JoinInstance: &protocolv1.JoinInstance{InstanceId: portalID}},
	})
	if got := readIgnoringSnapshots(t, ctx, a).GetJoinInstanceOk(); got == nil || got.GetInstanceId() != portalID {
		t.Fatalf("rejoin: %#v", got)
	}

	// Unknown id.
	writeClient(t, ctx, a, &protocolv1.ClientMessage{
		Payload: &protocolv1.ClientMessage_JoinInstance{JoinInstance: &protocolv1.JoinInstance{InstanceId: 99999}},
	})
	if got := readIgnoringSnapshots(t, ctx, a).GetError(); got == nil || got.GetCode() != protocolv1.ErrorCode_INSTANCE_NOT_FOUND {
		t.Fatalf("missing instance: %#v", got)
	}

	res, err := http.Get(hs.URL + "/metrics")
	if err != nil {
		t.Fatal(err)
	}
	defer res.Body.Close()
	body, _ := io.ReadAll(res.Body)
	if !strings.Contains(string(body), "er_skipped_ticks") || !strings.Contains(string(body), "er_instances") {
		t.Fatalf("metrics body: %s", body)
	}
	_ = srv
}
