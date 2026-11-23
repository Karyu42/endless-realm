extends GutTest
## Host API for the lobby UI: LobbySettings, local player, world_view, imports.

const PB := preload("res://src/net/proto/protocol_v1_pb.gd")

var _host: LobbyHost
var _clients: Array[WebSocketPeer] = []


func after_each() -> void:
	for ws in _clients:
		ws.close()
	_clients.clear()
	if _host != null:
		_host.stop()
		_host = null


func _new_host() -> LobbyHost:
	var host := LobbyHost.new(SimConfig.new())
	host.port = 0
	return host


func _intent(seq: int, mx: float = 0.0, my: float = 0.0, target: int = 0) -> InputIntent:
	var it := InputIntent.from_raw(seq, mx, my, 0.0, false)
	if "interact_target_id" in it:
		it.set("interact_target_id", target)
	return it


# --- LobbySettings ----------------------------------------------------------

func test_default_settings_are_valid() -> void:
	var s := LobbySettings.new()
	assert_eq(s.max_players, 50)
	assert_eq(s.m100_min, 100)
	assert_eq(s.m100_max, 100)
	assert_true(s.imports_allowed)
	assert_true(s.offline_allowed)
	assert_eq(s.validate().size(), 0)


func test_validate_max_players_bounds() -> void:
	var s := LobbySettings.new()
	for ok in [1, 50]:
		s.max_players = ok
		assert_eq(s.validate().size(), 0, "max_players %d ok" % ok)
	for bad in [0, -1, 51]:
		s.max_players = bad
		var r := s.validate()
		assert_eq(r.size(), 1, "max_players %d rejected" % bad)
		assert_eq(r[0], "Max players must be between 1 and 50.")


func test_validate_m100_range() -> void:
	var s := LobbySettings.new()
	s.m100_min = 50
	s.m100_max = 150
	assert_eq(s.validate().size(), 0)
	for pair in [[45, 100], [100, 155], [52, 100], [100, 103]]:
		s.m100_min = pair[0]
		s.m100_max = pair[1]
		var r := s.validate()
		assert_eq(r.size(), 1, "rejects %s" % [pair])
		assert_eq(r[0], "Level multipliers must be 0.50 to 1.50 in steps of 0.05.")
	for pair in [[105, 150], [50, 95]]:
		s.m100_min = pair[0]
		s.m100_max = pair[1]
		var r := s.validate()
		assert_eq(r.size(), 1, "must include 1.00: %s" % [pair])
		assert_eq(r[0], "The multiplier range must include 1.00.")


func test_validate_name_and_join_code() -> void:
	var s := LobbySettings.new()
	s.lobby_name = "x".repeat(33)
	s.join_code = "AB0O"
	var r := s.validate()
	assert_eq(r.size(), 2)
	assert_eq(r[0], "Lobby name must be at most 32 characters.")
	assert_string_starts_with(r[1], "Join code must be")
	s.lobby_name = "Friday raid"
	s.join_code = "K7PQ"
	assert_eq(s.validate().size(), 0)


func test_duplicate_is_independent() -> void:
	var s := LobbySettings.new()
	s.lobby_name = "a"
	var c := s.duplicate_settings()
	c.lobby_name = "b"
	c.max_players = 3
	assert_eq(s.lobby_name, "a")
	assert_eq(s.max_players, 50)


func test_generated_join_code_uses_unambiguous_alphabet() -> void:
	for i in range(50):
		var code := LobbySettings.generate_join_code()
		assert_eq(code.length(), LobbySettings.JOIN_CODE_LENGTH)
		assert_true(LobbySettings.is_valid_join_code(code), code)
		for ch in ["0", "O", "1", "I", "L"]:
			assert_false(code.contains(ch), code)


# --- apply_settings / settings() --------------------------------------------

func test_apply_settings_rejects_invalid_and_keeps_old() -> void:
	_host = _new_host()
	var s := LobbySettings.new()
	s.max_players = 0
	watch_signals(_host)
	assert_eq(_host.apply_settings(s), ERR_INVALID_PARAMETER)
	assert_signal_not_emitted(_host, "settings_changed")
	assert_eq(_host.settings().max_players, 50)


func test_apply_settings_copies_and_emits() -> void:
	_host = _new_host()
	var s := LobbySettings.new()
	s.max_players = 8
	s.m100_min = 80
	s.m100_max = 120
	s.imports_allowed = false
	s.lobby_name = "Test"
	watch_signals(_host)
	assert_eq(_host.apply_settings(s), OK)
	assert_signal_emitted(_host, "settings_changed")
	var emitted: LobbySettings = get_signal_parameters(_host, "settings_changed")[0]
	assert_eq(emitted.max_players, 8)
	s.max_players = 2  # caller's object is not live
	var got := _host.settings()
	assert_eq(got.max_players, 8)
	assert_eq(_host.max_players, 8)
	assert_eq(got.lobby_name, "Test")
	assert_false(got.imports_allowed)
	got.max_players = 3  # nor is the returned copy
	assert_eq(_host.settings().max_players, 8)
	assert_true(_host.is_m100_allowed(80))
	assert_true(_host.is_m100_allowed(120))
	assert_false(_host.is_m100_allowed(125))
	assert_false(_host.is_m100_allowed(83))


func test_generated_join_code_shows_in_settings() -> void:
	_host = _new_host()
	assert_eq(_host.start(), OK)
	var code := _host.settings().join_code
	assert_true(LobbySettings.is_valid_join_code(code), "generated: %s" % code)
	# Applying settings with an empty code keeps the generated one.
	var s := _host.settings()
	s.join_code = ""
	s.lobby_name = "renamed"
	assert_eq(_host.apply_settings(s), OK)
	assert_eq(_host.settings().join_code, code)
	# An explicit code replaces it.
	s.join_code = "RAPT42"
	assert_eq(_host.apply_settings(s), OK)
	assert_eq(_host.settings().join_code, "RAPT42")


# --- cap: lowering never kicks ----------------------------------------------

func test_lowering_max_players_does_not_kick() -> void:
	_host = _new_host()
	assert_eq(_host.start(), OK)
	var a := _host.add_local_player()
	var b := _host.add_local_player()
	var ws := WebSocketPeer.new()
	assert_eq(ws.connect_to_url("ws://127.0.0.1:%d/ws" % _host.port), OK)
	_clients.append(ws)
	assert_true(_pump(func() -> bool: return ws.get_ready_state() == WebSocketPeer.STATE_OPEN))
	ws.send(_hello())
	assert_true(_pump(func() -> bool: return _host.players.size() == 3), "remote joined")
	var s := _host.settings()
	s.max_players = 1
	assert_eq(_host.apply_settings(s), OK)
	for i in range(5):
		_host.run_tick()
	assert_eq(_host.players.size(), 3, "nobody kicked")
	assert_eq(ws.get_ready_state(), WebSocketPeer.STATE_OPEN, "remote still connected")
	assert_eq(_host.add_local_player(), -1, "new local join blocked")
	# A new remote join gets INSTANCE_FULL.
	var late := WebSocketPeer.new()
	assert_eq(late.connect_to_url("ws://127.0.0.1:%d/ws" % _host.port), OK)
	_clients.append(late)
	assert_true(_pump(func() -> bool: return late.get_ready_state() == WebSocketPeer.STATE_OPEN))
	late.send(_hello())
	var code := [-1]
	assert_true(_pump(func() -> bool:
		while late.get_available_packet_count() > 0:
			var m = PB.ServerMessage.new()
			if m.from_bytes(late.get_packet()) == PB.PB_ERR.NO_ERRORS and m.has_error():
				code[0] = m.get_error().get_code()
		return code[0] != -1), "late joiner gets an error")
	assert_eq(code[0], PB.ErrorCode.INSTANCE_FULL)
	assert_ne(a, b)


# --- local player -----------------------------------------------------------

func test_local_player_counts_toward_cap() -> void:
	_host = _new_host()
	var s := LobbySettings.new()
	s.max_players = 2
	assert_eq(_host.apply_settings(s), OK)
	var a := _host.add_local_player()
	var b := _host.add_local_player()
	assert_gt(a, 0)
	assert_gt(b, 0)
	assert_eq(_host.add_local_player(), -1, "full")
	_host.remove_local_player(a)
	assert_eq(_host.players.size(), 1)
	assert_gt(_host.add_local_player(), 0, "room again")


func test_local_input_applies_once_per_seq() -> void:
	_host = _new_host()
	var id := _host.add_local_player()
	_host.run_tick()
	var x0 := _host.world_view(id).player_x
	_host.submit_local_input(id, _intent(1, 1.0, 0.0))
	_host.run_tick()
	var v := _host.world_view(id)
	assert_eq(v.applied_seq, 1)
	assert_gt(v.player_x, x0, "moved right")
	# Stale and duplicate seqs are ignored, like a remote InputFrame.
	_host.submit_local_input(id, _intent(1, -1.0, 0.0))
	_host.submit_local_input(id, _intent(0, -1.0, 0.0))
	var x1 := v.player_x
	_host.run_tick()
	v = _host.world_view(id)
	assert_eq(v.applied_seq, 1)
	assert_gt(v.player_x, x1, "still the seq-1 intent")


func test_local_interact_goes_through_validator_once_per_seq() -> void:
	_host = _new_host()
	var id := _host.add_local_player()
	_host.run_tick()
	var calls: Array = []
	_host.interact_validator.resolver = func(_t: int, pid: int) -> Dictionary:
		var p := _host.world_view(pid)
		return {"x": p.player_x, "y": p.player_y}
	_host.on_interact = func(pid: int, target: int) -> void: calls.append([pid, target])
	# Calls _queue_input directly so the test does not depend on InputIntent
	# carrying interact_target_id yet (#30).
	var p: LobbyHost.HostPlayer = _host.players[0]
	_host._queue_input(p, 1, 0.0, 0.0, 0.0, false, 77)
	_host._queue_input(p, 1, 0.0, 0.0, 0.0, false, 77)  # same seq: dropped before the queue
	_host.run_tick()
	assert_eq(calls, [[id, 77]])
	_host._queue_input(p, 2, 0.0, 0.0, 0.0, false, 77)
	_host.run_tick()
	assert_eq(calls.size(), 2, "new seq, new press")
	assert_eq(_host.interact_validator.accepted, 2)


# --- world_view / ticked ----------------------------------------------------

func test_world_view_after_ticks() -> void:
	_host = _new_host()
	var a := _host.add_local_player()
	var b := _host.add_local_player()
	assert_null(_host.world_view(a), "nothing before the first tick")
	watch_signals(_host)
	for i in range(3):
		_host.run_tick()
	assert_signal_emit_count(_host, "ticked", 3)
	assert_eq(get_signal_parameters(_host, "ticked", 2), [3])
	var v := _host.world_view(a)
	assert_true(v is WorldSnapshot)
	assert_true(v is HostWorldSnapshot)
	assert_eq(v.player_id, a)
	assert_eq(v.tick, 3)
	assert_eq((v as HostWorldSnapshot).host_tick, 3)
	assert_eq((v as HostWorldSnapshot).others.size(), 1)
	assert_eq((v as HostWorldSnapshot).others[0]["id"], b)
	assert_null(_host.world_view(9999), "unknown player")


func test_world_view_includes_standin_bullets_in_loadtest_mode() -> void:
	_host = _new_host()
	_host.emitter_count = 2
	assert_eq(_host.start(), OK)
	var a := _host.add_local_player()
	for i in range(30):
		_host.run_tick()
	var v := _host.world_view(a)
	assert_eq(v.pattern_bullets.size(), _host.bullets.live_bullets())
	assert_gt(v.pattern_bullets.size(), 0)


# --- imports ----------------------------------------------------------------

func test_import_result_constants_are_distinct_and_named() -> void:
	var codes := ImportResult.all()
	assert_eq(codes.size(), 8)
	var seen := {}
	for c in codes:
		assert_false(seen.has(c))
		seen[c] = true
		assert_ne(ImportResult.name_of(c), "UNKNOWN")
	assert_eq(ImportResult.IMPORT_RESULT_OK, 0)
	assert_eq(ImportResult.name_of(ImportResult.REJECTED_OFFLINE_OFF), "REJECTED_OFFLINE_OFF")


func test_import_flags() -> void:
	_host = _new_host()
	var id := _host.add_local_player()
	var online := LobbyHost.make_stub_import_blob(false)
	var offline := LobbyHost.make_stub_import_blob(true)
	assert_eq(_host.import_character(online, 9999), ImportResult.REJECTED_UNKNOWN_PLAYER)
	assert_eq(_host.import_character(PackedByteArray([1, 2]), id), ImportResult.REJECTED_BAD_FORMAT)
	assert_eq(_host.import_character(LobbyHost.make_stub_import_blob(false, PackedByteArray(), 9), id),
			ImportResult.REJECTED_UNSUPPORTED_VERSION)
	var s := _host.settings()
	s.imports_allowed = false
	assert_eq(_host.apply_settings(s), OK)
	assert_eq(_host.import_character(online, id), ImportResult.REJECTED_IMPORTS_OFF)
	s.imports_allowed = true
	s.offline_allowed = false
	assert_eq(_host.apply_settings(s), OK)
	assert_eq(_host.import_character(offline, id), ImportResult.REJECTED_OFFLINE_OFF)
	assert_eq(_host.import_character(online, id), ImportResult.IMPORT_RESULT_OK)
	assert_eq(_host.import_character(online, id), ImportResult.REJECTED_ALREADY_EXISTS)
	var id2 := _host.add_local_player()
	s.offline_allowed = true
	assert_eq(_host.apply_settings(s), OK)
	assert_eq(_host.import_character(offline, id2), ImportResult.IMPORT_RESULT_OK)


func test_imports_off_does_not_block_hello() -> void:
	_host = _new_host()
	var s := LobbySettings.new()
	s.imports_allowed = false
	s.offline_allowed = false
	assert_eq(_host.apply_settings(s), OK)
	assert_eq(_host.start(), OK)
	var ws := WebSocketPeer.new()
	assert_eq(ws.connect_to_url("ws://127.0.0.1:%d/ws" % _host.port), OK)
	_clients.append(ws)
	assert_true(_pump(func() -> bool: return ws.get_ready_state() == WebSocketPeer.STATE_OPEN))
	ws.send(_hello())
	var welcomed := [false]
	assert_true(_pump(func() -> bool:
		while ws.get_available_packet_count() > 0:
			var m = PB.ServerMessage.new()
			if m.from_bytes(ws.get_packet()) == PB.PB_ERR.NO_ERRORS and m.has_welcome():
				welcomed[0] = true
		return welcomed[0]), "Welcome with imports off")


# --- helpers ----------------------------------------------------------------

func _hello() -> PackedByteArray:
	var msg = PB.ClientMessage.new()
	msg.new_hello().set_protocol_version(SimConstants.PROTOCOL_VERSION)
	return msg.to_bytes()


func _pump(pred: Callable, max_iters: int = 500) -> bool:
	for i in range(max_iters):
		_host.run_tick()
		for ws in _clients:
			ws.poll()
		if pred.call():
			return true
		OS.delay_msec(10)
	return false


func test_local_input_seq_survives_uint32_wrap() -> void:
	_host = _new_host()
	var id := _host.add_local_player()
	_host.submit_local_input(id, _intent(0xFFFFFFFF, 1.0, 0.0))
	_host.run_tick()
	assert_eq(_host.world_view(id).applied_seq, 0xFFFFFFFF)
	# game_session wraps 0xFFFFFFFF -> 1; that frame is newer, not stale.
	_host.submit_local_input(id, _intent(1, 0.0, 1.0))
	_host.run_tick()
	assert_eq(_host.world_view(id).applied_seq, 1)
	# And 0xFFFFFFFF is now stale.
	_host.submit_local_input(id, _intent(0xFFFFFFFF, -1.0, 0.0))
	_host.run_tick()
	assert_eq(_host.world_view(id).applied_seq, 1)
