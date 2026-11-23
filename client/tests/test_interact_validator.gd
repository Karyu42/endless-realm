extends GutTest
## HostInteractValidator and the host's interact path (InputFrame.interact_target_id).

const PB := preload("res://src/net/proto/protocol_v1_pb.gd")

const BIG_ID: int = (1 << 32) + 7

var _host: LobbyHost
var _ws: WebSocketPeer


func after_each() -> void:
	if _ws != null:
		_ws.close()
		_ws = null
	if _host != null:
		_host.stop()
		_host = null


func _at(x: float, y: float) -> Callable:
	return func(_t: int, _p: int) -> Dictionary: return {"x": x, "y": y}


func test_zero_target_is_no_interact() -> void:
	var v := HostInteractValidator.new()
	v.resolver = _at(0.0, 0.0)
	assert_false(v.validate(1, 1, 0, 0.0, 0.0))
	assert_eq(v.accepted + v.dropped_unknown + v.dropped_range + v.dropped_repeat, 0)


func test_applies_at_most_once_per_seq() -> void:
	var v := HostInteractValidator.new()
	v.resolver = _at(1.0, 0.0)
	assert_true(v.validate(1, 5, 42, 0.0, 0.0), "first press on seq 5")
	assert_false(v.validate(1, 5, 42, 0.0, 0.0), "same seq again")
	assert_false(v.validate(1, 4, 42, 0.0, 0.0), "older seq")
	assert_true(v.validate(1, 6, 42, 0.0, 0.0), "next seq")
	assert_true(v.validate(2, 5, 42, 0.0, 0.0), "seqs are per player")
	assert_eq(v.dropped_repeat, 2)


func test_out_of_range_is_dropped_and_accept_range_is_allowed() -> void:
	var v := HostInteractValidator.new()
	var max_r: float = v.max_range_tiles()
	assert_gt(max_r, 0.0, "accept range loaded from data/scaling.json")
	v.resolver = _at(max_r, 0.0)
	assert_true(v.validate(1, 1, 42, 0.0, 0.0), "exactly the accept range")
	v.resolver = _at(max_r + 0.005, 0.0)
	assert_false(v.validate(1, 2, 42, 0.0, 0.0), "just past the accept range")
	assert_eq(v.dropped_range, 1)


func test_unknown_or_not_allowed_target_is_dropped() -> void:
	var v := HostInteractValidator.new()
	assert_false(v.validate(1, 1, BIG_ID, 0.0, 0.0), "default resolver knows no targets")
	v.resolver = func(t: int, p: int) -> Dictionary:
		return {"x": 0.0, "y": 0.0} if (t == 7 and p == 1) else {}
	assert_false(v.validate(2, 2, 7, 0.0, 0.0), "not allowed for player 2")
	assert_true(v.validate(1, 3, 7, 0.0, 0.0), "allowed for player 1")
	assert_eq(v.dropped_unknown, 2)


# --- through the host -------------------------------------------------------

func _start() -> void:
	_host = LobbyHost.new(SimConfig.new())
	_host.port = 0
	_host.emitter_count = 0
	assert_eq(_host.start(), OK)
	_ws = WebSocketPeer.new()
	assert_eq(_ws.connect_to_url("ws://127.0.0.1:%d/ws" % _host.port), OK)
	assert_true(_pump(func() -> bool: return _ws.get_ready_state() == WebSocketPeer.STATE_OPEN))
	var hello = PB.ClientMessage.new()
	hello.new_hello().set_protocol_version(SimConstants.PROTOCOL_VERSION)
	_ws.put_packet(hello.to_bytes())
	assert_true(_pump(func() -> bool: return _host.players.size() == 1), "player joined")


func _pump(pred: Callable) -> bool:
	for i in range(500):
		_host.run_tick()
		_ws.poll()
		if pred.call():
			return true
		OS.delay_msec(10)
	return false


func _send_input(seq: int, target: int) -> void:
	var m = PB.ClientMessage.new()
	var f = m.new_input()
	f.set_seq(seq)
	f.set_interact_target_id(target)
	_ws.put_packet(m.to_bytes())


func _errors_received() -> int:
	var n := 0
	while _ws.get_available_packet_count() > 0:
		var m = PB.ServerMessage.new()
		if m.from_bytes(_ws.get_packet()) == PB.PB_ERR.NO_ERRORS and m.has_error():
			n += 1
	return n


func test_host_decodes_target_and_calls_the_hook_once() -> void:
	_start()
	var seen: Array = []
	var p: LobbyHost.HostPlayer = _host.players[0]
	_host.interact_validator.resolver = func(t: int, _pid: int) -> Dictionary:
		return {"x": p.x, "y": p.y} if t == BIG_ID else {}
	_host.on_interact = func(pid: int, t: int) -> void: seen.append([pid, t])
	_send_input(3, BIG_ID)
	assert_true(_pump(func() -> bool: return seen.size() >= 1), "accepted press reaches the hook")
	for i in range(5):
		_host.run_tick()
	assert_eq(seen.size(), 1, "applied once")
	assert_eq(seen[0], [p.id, BIG_ID], "uint64 target id decoded intact")
	# Retransmitting a seq must not create a second interact press.
	_send_input(3, BIG_ID)
	_send_input(4, 0)
	assert_true(_pump(func() -> bool: return p.seq == 4))
	assert_eq(seen.size(), 1, "duplicate seq did not apply again")
	_send_input(5, BIG_ID)
	assert_true(_pump(func() -> bool: return seen.size() == 2), "a fresh seq can interact")


func test_host_drops_unknown_and_out_of_range_silently() -> void:
	_start()
	var seen: Array = []
	var p: LobbyHost.HostPlayer = _host.players[0]
	_host.interact_validator.resolver = func(t: int, _pid: int) -> Dictionary:
		return {"x": p.x + 3.0, "y": p.y} if t == 5 else {}
	_host.on_interact = func(pid: int, t: int) -> void: seen.append([pid, t])
	_send_input(1, 999)  # unknown
	_send_input(2, 5)    # 3 tiles away
	var v := _host.interact_validator
	assert_true(_pump(func() -> bool: return v.dropped_unknown + v.dropped_range >= 2), "both evaluated")
	for i in range(5):
		_host.run_tick()
		_ws.poll()
	assert_eq(v.dropped_unknown, 1)
	assert_eq(v.dropped_range, 1)
	assert_eq(seen.size(), 0, "nothing applied")
	assert_eq(_errors_received(), 0, "no ErrorReply")
	assert_eq(_ws.get_ready_state(), WebSocketPeer.STATE_OPEN)

func test_seq_newer_half_range_boundary() -> void:
	assert_false(Seq.seq_newer(5, 5))
	assert_false(Seq.seq_newer(4, 5))
	assert_true(Seq.seq_newer(6, 5))
	assert_true(Seq.seq_newer(1, 0xFFFFFFFF), "wrap 0xFFFFFFFF -> 1")
	# Difference of 2^31-1 is newer; 2^31 is not (the half-range boundary).
	assert_true(Seq.seq_newer(0x7FFFFFFE, 0xFFFFFFFF))
	assert_false(Seq.seq_newer(0x7FFFFFFF, 0xFFFFFFFF))
	assert_false(Seq.seq_newer(0x80000000, 0))
	assert_true(Seq.seq_newer(0x7FFFFFFF, 0))


func test_seq_is_next_treats_last_zero_as_uninitialized() -> void:
	assert_false(Seq.seq_is_next(0, 0))
	assert_true(Seq.seq_is_next(1, 0))
	assert_true(Seq.seq_is_next(0x80000000, 0), "first seq may be in the upper half")
	assert_true(Seq.seq_is_next(0xFFFFFFFF, 0))
	assert_false(Seq.seq_is_next(1, 1))
	assert_true(Seq.seq_is_next(1, 0xFFFFFFFF))


func test_interact_accepted_once_after_seq_wrap() -> void:
	var v := HostInteractValidator.new()
	v.resolver = _at(0.0, 0.0)
	assert_true(v.validate(1, 0xFFFFFFFF, 42, 0.0, 0.0), "last seq before wrap")
	assert_true(v.validate(1, 1, 42, 0.0, 0.0), "interact right after the wrap")
	assert_false(v.validate(1, 1, 42, 0.0, 0.0), "same post-wrap seq again")
	assert_eq(v.accepted, 2)
	assert_eq(v.dropped_repeat, 1)


func test_resent_pre_wrap_seq_is_dropped() -> void:
	var v := HostInteractValidator.new()
	v.resolver = _at(0.0, 0.0)
	assert_true(v.validate(1, 0xFFFFFFFF, 42, 0.0, 0.0))
	assert_true(v.validate(1, 1, 42, 0.0, 0.0))
	assert_false(v.validate(1, 0xFFFFFFFF, 42, 0.0, 0.0), "resent seq just before the wrap")
	assert_eq(v.accepted, 2)
	assert_eq(v.dropped_repeat, 1)


func test_host_applies_input_frames_across_seq_wrap() -> void:
	_start()
	var seen: Array = []
	var p: LobbyHost.HostPlayer = _host.players[0]
	_host.interact_validator.resolver = func(t: int, _pid: int) -> Dictionary:
		return {"x": p.x, "y": p.y} if t == 42 else {}
	_host.on_interact = func(pid: int, t: int) -> void: seen.append([pid, t])
	_send_input(0xFFFFFFFE, 0)
	_send_input(0xFFFFFFFF, 42)
	_send_input(1, 42)
	_send_input(2, 0)
	assert_true(_pump(func() -> bool: return p.seq == 2), "stream 0xFFFFFFFF -> 1 stays applied")
	assert_eq(seen.size(), 2, "interact at wrap and immediately after, each once")
	assert_eq(seen[0][1], 42)
	assert_eq(seen[1][1], 42)
	_send_input(0xFFFFFFFF, 42)  # resent pre-wrap seq
	_send_input(1, 42)  # resent post-wrap interact
	for i in range(5):
		_host.run_tick()
		_ws.poll()
	assert_eq(p.seq, 2, "resent pre-wrap seq did not roll the host back")
	assert_eq(seen.size(), 2, "resent wrap seqs did not apply another interact")
	_send_input(3, 42)
	assert_true(_pump(func() -> bool: return seen.size() == 3), "a fresh seq can interact")

