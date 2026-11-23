package protocolv1_test

import (
	"encoding/hex"
	"testing"

	"google.golang.org/protobuf/encoding/protowire"
	"google.golang.org/protobuf/proto"

	protocolv1 "github.com/Karyu42/endless-realm/server/internal/protocol/v1"
)

// Golden encodings shared with client/tests/test_proto_wire.gd. Field
// numbers did not change in the renames, and uint32 -> uint64 widening keeps
// the same varint bytes, so these also match what the pre-rename schema emitted
// for the same values.
const (
	bigID = uint64(1)<<32 + 7 // 4294967303, above uint32

	goldenWelcomeHex = "0801108780808010180c2001300338c801" // version 1, player bigID, 12 Hz, seed 1, instance 3, m100 200
	goldenErrorHex   = "3a0a0804120666756c6c2121"           // ServerMessage{error: ErrorReply{INSTANCE_FULL, "full!!"}}
	goldenSnapHex    = "1a0c080512080887808080101004"       // ServerMessage{snapshot: {tick 5, players [{bigID, 4}]}}
	goldenInputHex   = "120f080915000080bf2801308780808010" // ClientMessage{input: {seq 9, move_x -1, fire, target bigID}}
	goldenAbilityHex = "120408033801"                       // ClientMessage{input: {seq 3, ability_pressed}}
	// ServerMessage{snapshot: {tick 5, players [{2, 4}], bags [{bigID, 1.5, 2.25, owner 2, t_star 1, teal, spawn 40}]}}
	goldenSnapBagsHex = "1a2208051204080210041a18088780808010150000c03f1d000010402002280130023828"
)

func roundTrip[T proto.Message](t *testing.T, in T, out T) []byte {
	t.Helper()
	b, err := proto.Marshal(in)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	if err := proto.Unmarshal(b, out); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if !proto.Equal(in, out) {
		t.Fatalf("round trip changed the message:\n in %v\nout %v", in, out)
	}
	return b
}

func TestWelcomeRoundTripRenamedInstanceAndUint64PlayerID(t *testing.T) {
	in := &protocolv1.Welcome{ProtocolVersion: 1, PlayerId: bigID, TickHz: 12, InstanceSeed: 1, Instance: 3, M100: 200}
	b := roundTrip(t, in, &protocolv1.Welcome{})
	if got := hex.EncodeToString(b); got != goldenWelcomeHex {
		t.Fatalf("welcome bytes %s, want %s", got, goldenWelcomeHex)
	}
}

func TestErrorReplyRoundTripKeepsFieldSeven(t *testing.T) {
	in := &protocolv1.ServerMessage{Payload: &protocolv1.ServerMessage_Error{
		Error: &protocolv1.ErrorReply{Code: protocolv1.ErrorCode_INSTANCE_FULL, Reason: "full!!"},
	}}
	out := &protocolv1.ServerMessage{}
	b := roundTrip(t, in, out)
	if got := hex.EncodeToString(b); got != goldenErrorHex {
		t.Fatalf("error bytes %s, want %s", got, goldenErrorHex)
	}
	if out.GetError().GetCode() != protocolv1.ErrorCode_INSTANCE_FULL {
		t.Fatalf("code %v", out.GetError().GetCode())
	}
}

func TestSnapshotPlayerIDAboveUint32(t *testing.T) {
	in := &protocolv1.ServerMessage{Payload: &protocolv1.ServerMessage_Snapshot{Snapshot: &protocolv1.Snapshot{
		Tick: 5, Players: []*protocolv1.PlayerStub{{Id: bigID, AppliedSeq: 4}},
	}}}
	out := &protocolv1.ServerMessage{}
	b := roundTrip(t, in, out)
	if got := hex.EncodeToString(b); got != goldenSnapHex {
		t.Fatalf("snapshot bytes %s, want %s", got, goldenSnapHex)
	}
	if out.GetSnapshot().GetPlayers()[0].GetId() != bigID {
		t.Fatalf("id %d, want %d", out.GetSnapshot().GetPlayers()[0].GetId(), bigID)
	}
}

func TestInputFrameInteractTargetAboveUint32(t *testing.T) {
	in := &protocolv1.ClientMessage{Payload: &protocolv1.ClientMessage_Input{Input: &protocolv1.InputFrame{
		Seq: 9, MoveX: -1, FireHeld: true, InteractTargetId: bigID,
	}}}
	out := &protocolv1.ClientMessage{}
	b := roundTrip(t, in, out)
	if got := hex.EncodeToString(b); got != goldenInputHex {
		t.Fatalf("input bytes %s, want %s", got, goldenInputHex)
	}
	if out.GetInput().GetInteractTargetId() != bigID {
		t.Fatalf("interact_target_id %d", out.GetInput().GetInteractTargetId())
	}
}

// An old peer that still encodes player_id / id as uint32 produces bytes the
// new uint64 schema decodes to the same value.
func TestUint32EncodedIDsDecodeUnchanged(t *testing.T) {
	var old []byte
	old = protowire.AppendTag(old, 1, protowire.VarintType) // id
	old = protowire.AppendVarint(old, uint64(uint32(0xFFFFFFFF)))
	old = protowire.AppendTag(old, 2, protowire.VarintType) // applied_seq
	old = protowire.AppendVarint(old, 3)
	var p protocolv1.PlayerStub
	if err := proto.Unmarshal(old, &p); err != nil {
		t.Fatal(err)
	}
	if p.GetId() != 0xFFFFFFFF || p.GetAppliedSeq() != 3 {
		t.Fatalf("decoded %v", &p)
	}
	b, _ := proto.Marshal(&protocolv1.PlayerStub{Id: 0xFFFFFFFF, AppliedSeq: 3})
	if hex.EncodeToString(b) != hex.EncodeToString(old) {
		t.Fatalf("uint64 encoding %x differs from uint32 encoding %x", b, old)
	}
}

func TestInputFrameAbilityPressedGolden(t *testing.T) {
	in := &protocolv1.ClientMessage{Payload: &protocolv1.ClientMessage_Input{Input: &protocolv1.InputFrame{
		Seq: 3, AbilityPressed: true,
	}}}
	out := &protocolv1.ClientMessage{}
	b := roundTrip(t, in, out)
	if got := hex.EncodeToString(b); got != goldenAbilityHex {
		t.Fatalf("input bytes %s, want %s", got, goldenAbilityHex)
	}
	if !out.GetInput().GetAbilityPressed() || out.GetInput().GetSeq() != 3 {
		t.Fatalf("ability_pressed not round-tripped: %v", out.GetInput())
	}
	// Unset decodes as false (older clients).
	var old protocolv1.InputFrame
	if err := proto.Unmarshal([]byte{0x08, 0x03}, &old); err != nil || old.GetAbilityPressed() {
		t.Fatalf("unset ability_pressed should decode false (err %v)", err)
	}
}

func TestSnapshotLootBagsGolden(t *testing.T) {
	in := &protocolv1.ServerMessage{Payload: &protocolv1.ServerMessage_Snapshot{Snapshot: &protocolv1.Snapshot{
		Tick:    5,
		Players: []*protocolv1.PlayerStub{{Id: 2, AppliedSeq: 4}},
		Bags: []*protocolv1.LootBag{{
			Id: bigID, X: 1.5, Y: 2.25, OwnerPlayerId: 2, TStar: 1, BagColorKind: 2, SpawnTick: 40,
		}},
	}}}
	out := &protocolv1.ServerMessage{}
	b := roundTrip(t, in, out)
	if got := hex.EncodeToString(b); got != goldenSnapBagsHex {
		t.Fatalf("snapshot bytes %s, want %s", got, goldenSnapBagsHex)
	}
	bags := out.GetSnapshot().GetBags()
	if len(bags) != 1 || bags[0].GetId() != bigID || bags[0].GetX() != 1.5 || bags[0].GetY() != 2.25 ||
		bags[0].GetOwnerPlayerId() != 2 || bags[0].GetTStar() != 1 || bags[0].GetBagColorKind() != 2 ||
		bags[0].GetSpawnTick() != 40 {
		t.Fatalf("bags not round-tripped: %v", bags)
	}
	// A snapshot without bags keeps its old bytes (additive field).
	var old protocolv1.ServerMessage
	raw, _ := hex.DecodeString(goldenSnapHex)
	if err := proto.Unmarshal(raw, &old); err != nil || len(old.GetSnapshot().GetBags()) != 0 {
		t.Fatalf("old snapshot should decode with no bags (err %v)", err)
	}
}
