extends GutTest
## GDScript codec vs the Go golden bytes in
## server/internal/protocol/v1/wire_compat_test.go: renamed messages/fields
## and uint64 ids above 2^32.

const PB := preload("res://src/net/proto/protocol_v1_pb.gd")

const BIG_ID: int = (1 << 32) + 7
const GOLDEN_WELCOME := "0801108780808010180c2001300338c801"
const GOLDEN_ERROR := "3a0a0804120666756c6c2121"
const GOLDEN_SNAP := "1a0c080512080887808080101004"
const GOLDEN_INPUT := "120f080915000080bf2801308780808010"
const GOLDEN_SNAP_BAGS := "1a2008051204080210041a16088780808010150000c03f1d00001040200228013028"


func test_welcome_instance_and_uint64_player_id_match_go() -> void:
	var w = PB.Welcome.new()
	w.set_protocol_version(1)
	w.set_player_id(BIG_ID)
	w.set_tick_hz(12)
	w.set_instance_seed(1)
	w.set_instance(3)
	w.set_m100(200)
	assert_eq(w.to_bytes().hex_encode(), GOLDEN_WELCOME, "encodes like Go")
	var d = PB.Welcome.new()
	assert_eq(d.from_bytes(GOLDEN_WELCOME.hex_decode()), PB.PB_ERR.NO_ERRORS)
	assert_eq(d.get_player_id(), BIG_ID)
	assert_eq(d.get_instance(), 3)
	assert_eq(d.get_m100(), 200)


func test_error_reply_round_trip_matches_go() -> void:
	var m = PB.ServerMessage.new()
	var e = m.new_error()
	e.set_code(PB.ErrorCode.INSTANCE_FULL)
	e.set_reason("full!!")
	assert_eq(m.to_bytes().hex_encode(), GOLDEN_ERROR, "encodes like Go")
	var d = PB.ServerMessage.new()
	assert_eq(d.from_bytes(GOLDEN_ERROR.hex_decode()), PB.PB_ERR.NO_ERRORS)
	assert_true(d.has_error())
	assert_true(d.get_error() is PB.ErrorReply, "message is ErrorReply")
	assert_eq(d.get_error().get_code(), PB.ErrorCode.INSTANCE_FULL)
	assert_eq(d.get_error().get_reason(), "full!!")


func test_snapshot_player_id_above_uint32_matches_go() -> void:
	var m = PB.ServerMessage.new()
	var s = m.new_snapshot()
	s.set_tick(5)
	var p = s.add_players()
	p.set_id(BIG_ID)
	p.set_applied_seq(4)
	assert_eq(m.to_bytes().hex_encode(), GOLDEN_SNAP, "encodes like Go")
	var d = PB.ServerMessage.new()
	assert_eq(d.from_bytes(GOLDEN_SNAP.hex_decode()), PB.PB_ERR.NO_ERRORS)
	assert_eq(d.get_snapshot().get_players()[0].get_id(), BIG_ID)


func test_input_interact_target_above_uint32_matches_go() -> void:
	var m = PB.ClientMessage.new()
	var f = m.new_input()
	f.set_seq(9)
	f.set_move_x(-1.0)
	f.set_fire_held(true)
	f.set_interact_target_id(BIG_ID)
	assert_eq(m.to_bytes().hex_encode(), GOLDEN_INPUT, "encodes like Go")
	var d = PB.ClientMessage.new()
	assert_eq(d.from_bytes(GOLDEN_INPUT.hex_decode()), PB.PB_ERR.NO_ERRORS)
	assert_eq(d.get_input().get_interact_target_id(), BIG_ID)
	assert_eq(d.get_input().get_seq(), 9)


func test_unset_interact_target_decodes_as_zero() -> void:
	var m = PB.ClientMessage.new()
	m.new_input().set_seq(1)
	var d = PB.ClientMessage.new()
	assert_eq(d.from_bytes(m.to_bytes()), PB.PB_ERR.NO_ERRORS)
	assert_eq(d.get_input().get_interact_target_id(), 0)


func test_snapshot_loot_bags_match_go() -> void:
	var m = PB.ServerMessage.new()
	var s = m.new_snapshot()
	s.set_tick(5)
	var p = s.add_players()
	p.set_id(2)
	p.set_applied_seq(4)
	var b = s.add_bags()
	b.set_id(BIG_ID)
	b.set_x(1.5)
	b.set_y(2.25)
	b.set_owner_player_id(2)
	b.set_t_star(1)
	b.set_spawn_tick(40)
	assert_eq(m.to_bytes().hex_encode(), GOLDEN_SNAP_BAGS, "encodes like Go")
	var d = PB.ServerMessage.new()
	assert_eq(d.from_bytes(GOLDEN_SNAP_BAGS.hex_decode()), PB.PB_ERR.NO_ERRORS)
	var bags = d.get_snapshot().get_bags()
	assert_eq(bags.size(), 1)
	assert_eq(bags[0].get_id(), BIG_ID)
	assert_almost_eq(bags[0].get_x(), 1.5, 1e-6)
	assert_almost_eq(bags[0].get_y(), 2.25, 1e-6)
	assert_eq(bags[0].get_owner_player_id(), 2)
	assert_eq(bags[0].get_t_star(), 1)
	assert_eq(bags[0].get_spawn_tick(), 40)
	# Old snapshot bytes decode with no bags.
	var o = PB.ServerMessage.new()
	assert_eq(o.from_bytes(GOLDEN_SNAP.hex_decode()), PB.PB_ERR.NO_ERRORS)
	assert_eq(o.get_snapshot().get_bags().size(), 0)
