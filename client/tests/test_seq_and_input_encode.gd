extends GutTest
## Seq wrap (skip 0) and the InputIntent -> InputFrame encoder.

const PB := preload("res://src/net/proto/protocol_v1_pb.gd")
const BIG_ID: int = (1 << 32) + 7


func test_seq_next_wraps_and_skips_zero() -> void:
	assert_eq(Seq.next(0), 1)
	assert_eq(Seq.next(1), 2)
	assert_eq(Seq.next(0xFFFFFFFE), 0xFFFFFFFF)
	assert_eq(Seq.next(0xFFFFFFFF), 1, "uint32 wrap must skip 0")
	var seq: int = 0xFFFFFFFD
	seq = Seq.next(seq)
	seq = Seq.next(seq)
	seq = Seq.next(seq)
	assert_eq(seq, 1)
	assert_ne(seq, 0)


func test_encode_input_round_trips_interact_target_id() -> void:
	var intent := InputIntent.from_raw(9, -1.0, 0.0, 1.5, true, false, 0, BIG_ID)
	var buf := NetClient.encode_input(intent)
	var decoded = PB.ClientMessage.new()
	assert_eq(decoded.from_bytes(buf), PB.PB_ERR.NO_ERRORS)
	assert_true(decoded.has_input())
	var frame = decoded.get_input()
	assert_eq(frame.get_seq(), 9)
	assert_almost_eq(frame.get_move_x(), -1.0, 1e-6)
	assert_almost_eq(frame.get_move_y(), 0.0, 1e-6)
	assert_almost_eq(frame.get_aim(), 1.5, 1e-6)
	assert_true(frame.get_fire_held())
	assert_eq(frame.get_interact_target_id(), BIG_ID)


func test_encode_input_zero_target_means_none() -> void:
	var intent := InputIntent.from_raw(1, 0.0, 0.0, 0.0, false, true, 0, 0)
	var buf := NetClient.encode_input(intent)
	var decoded = PB.ClientMessage.new()
	assert_eq(decoded.from_bytes(buf), PB.PB_ERR.NO_ERRORS)
	assert_eq(decoded.get_input().get_interact_target_id(), 0)
	assert_eq(decoded.get_input().get_seq(), 1)
