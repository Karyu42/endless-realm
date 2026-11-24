extends GutTest
## LobbyHost player cap, deadline tick, and connection limits.

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


func _start_host(max_players: int = LobbyHost.DEFAULT_MAX_PLAYERS, clock: Callable = Callable()) -> LobbyHost:
	var host := LobbyHost.new(SimConfig.new())
	host.port = 0
	host.emitter_count = 1
	host.max_players = max_players
	if clock.is_valid():
		host.clock = clock
	assert_eq(host.start(), OK, "host listens")
	return host


func _connect() -> WebSocketPeer:
	var ws := WebSocketPeer.new()
	assert_eq(ws.connect_to_url("ws://127.0.0.1:%d/ws" % _host.port), OK)
	_clients.append(ws)
	return ws


## Runs host ticks and polls every client until `pred` is true or ~5 s pass.
func _pump(pred: Callable, max_iters: int = 500) -> bool:
	for i in range(max_iters):
		_host.run_tick()
		for ws in _clients:
			ws.poll()
		if pred.call():
			return true
		OS.delay_msec(10)
	return false


func _open(ws: WebSocketPeer) -> bool:
	return _pump(func() -> bool: return ws.get_ready_state() == WebSocketPeer.STATE_OPEN)


func _hello() -> PackedByteArray:
	var msg = PB.ClientMessage.new()
	msg.new_hello().set_protocol_version(SimConstants.PROTOCOL_VERSION)
	return msg.to_bytes()


func _open_portal() -> PackedByteArray:
	var msg = PB.ClientMessage.new()
	msg.new_open_portal().set_m100(100)
	return msg.to_bytes()


## Reads queued server messages; returns [welcomes, snapshots, errors, error_codes].
func _drain(ws: WebSocketPeer, counts: Dictionary) -> void:
	while ws.get_available_packet_count() > 0:
		var m = PB.ServerMessage.new()
		if m.from_bytes(ws.get_packet()) != PB.PB_ERR.NO_ERRORS:
			counts["bad"] = counts.get("bad", 0) + 1
			continue
		if m.has_welcome():
			counts["welcome"] = counts.get("welcome", 0) + 1
		elif m.has_snapshot():
			counts["snapshot"] = counts.get("snapshot", 0) + 1
		elif m.has_error():
			counts["error"] = counts.get("error", 0) + 1
			counts["last_code"] = m.get_error().get_code()
			counts["last_reason"] = m.get_error().get_reason()


func _closed(ws: WebSocketPeer) -> bool:
	var s := ws.get_ready_state()
	return s == WebSocketPeer.STATE_CLOSED or s == WebSocketPeer.STATE_CLOSING


# --- player cap -------------------------------------------------------------

func test_max_players_default_is_50() -> void:
	var host := LobbyHost.new()
	assert_eq(LobbyHost.DEFAULT_MAX_PLAYERS, 50)
	assert_eq(host.max_players, 50)
	assert_eq(host.max_connections(), 50 + LobbyHost.CONNECTION_SLACK)


func test_parse_max_players_accepts_1_to_50_and_never_clamps() -> void:
	assert_eq(LobbyHost.parse_max_players("1"), 1)
	assert_eq(LobbyHost.parse_max_players("50"), 50)
	assert_eq(LobbyHost.parse_max_players(" 8 "), 8)
	for bad in ["0", "51", "-1", "100", "abc", "5.5", "", "1e3"]:
		assert_eq(LobbyHost.parse_max_players(bad), -1, "rejects %s" % bad)


func test_loadtest_override_has_its_own_parser() -> void:
	assert_eq(LobbyHost.parse_loadtest_unsafe_max_players("100"), 100)
	assert_eq(LobbyHost.parse_loadtest_unsafe_max_players("0"), -1)
	assert_eq(LobbyHost.parse_loadtest_unsafe_max_players(str(LobbyHost.LOADTEST_UNSAFE_MAX_PLAYERS_LIMIT + 1)), -1)


func _run_host_main(user_args: PackedStringArray) -> int:
	var args := PackedStringArray(["--headless", "--path", ProjectSettings.globalize_path("res://"),
		"-s", "res://src/net/host/host_main.gd", "--", "--host", "--port", "0", "--run-seconds", "0.2"])
	args.append_array(user_args)
	var out: Array = []
	return OS.execute(OS.get_executable_path(), args, out, true)


func test_host_main_exits_nonzero_on_out_of_range_max_players() -> void:
	assert_eq(_run_host_main(PackedStringArray(["--max-players", "51"])), 2, "--max-players 51")
	assert_eq(_run_host_main(PackedStringArray(["--max-players", "0"])), 2, "--max-players 0")
	OS.set_environment("ER_MAX_PLAYERS", "99")
	var env_code := _run_host_main(PackedStringArray())
	OS.unset_environment("ER_MAX_PLAYERS")
	assert_eq(env_code, 2, "ER_MAX_PLAYERS=99")
	assert_eq(_run_host_main(PackedStringArray(["--max-players", "50"])), 0, "50 is accepted")


## #32 item 2: a valid flag wins over an invalid ER_MAX_PLAYERS (same as the
## game boot path); exit 2 only when the value actually used is invalid.
func test_host_main_valid_flag_wins_over_invalid_env() -> void:
	OS.set_environment("ER_MAX_PLAYERS", "99")
	var flag_ok := _run_host_main(PackedStringArray(["--max-players", "8"]))
	var flag_bad := _run_host_main(PackedStringArray(["--max-players", "0"]))
	OS.set_environment("ER_MAX_PLAYERS", "8")
	var env_ok := _run_host_main(PackedStringArray())
	var env_ok_flag_bad := _run_host_main(PackedStringArray(["--max-players", "abc"]))
	OS.unset_environment("ER_MAX_PLAYERS")
	assert_eq(flag_ok, 0, "valid flag, invalid env: flag used")
	assert_eq(flag_bad, 2, "invalid flag is used and rejected")
	assert_eq(env_ok, 0, "valid env, no flag")
	assert_eq(env_ok_flag_bad, 2, "invalid flag still rejected with a valid env")


func test_full_lobby_replies_instance_full_and_closes() -> void:
	_host = _start_host(1)
	var a := _connect()
	var b := _connect()
	assert_true(_open(a) and _open(b))
	a.put_packet(_hello())
	var ca := {}
	assert_true(_pump(func() -> bool:
		_drain(a, ca)
		return ca.get("welcome", 0) == 1), "first player joins")
	b.put_packet(_hello())
	var cb := {}
	assert_true(_pump(func() -> bool:
		_drain(b, cb)
		return cb.get("error", 0) >= 1), "second player gets an Error")
	assert_eq(cb.get("last_code", -1), PB.ErrorCode.INSTANCE_FULL)
	assert_eq(cb.get("welcome", 0), 0)
	assert_true(_pump(func() -> bool: return _closed(b)), "full connection is closed")
	assert_eq(_host.players.size(), 1)


func test_full_lobby_refuses_a_join_while_a_linger_holds_the_seat() -> void:
	_host = _start_host(1)
	var a := _connect()
	assert_true(_open(a))
	a.put_packet(_hello())
	var ca := {}
	assert_true(_pump(func() -> bool:
		_drain(a, ca)
		return ca.get("welcome", 0) == 1), "first player joins")
	a.close()
	assert_true(_pump(func() -> bool:
		return _host.players.size() == 1 and _host.players[0].is_lingering()), "the dropped body lingers")
	var held: LobbyHost.HostPlayer = _host.players[0]
	var b := _connect()
	assert_true(_open(b))
	b.put_packet(_hello())
	var cb := {}
	assert_true(_pump(func() -> bool:
		_drain(b, cb)
		return cb.get("error", 0) >= 1), "the new join is refused")
	assert_eq(cb.get("last_code", -1), PB.ErrorCode.INSTANCE_FULL, "the Hello-time code the client shows as lobby_full")
	assert_eq(cb.get("last_reason", ""), "lobby is full")
	assert_eq(cb.get("welcome", 0), 0)
	assert_eq(_host.players, [held] as Array[LobbyHost.HostPlayer], "the linger keeps its seat")
	assert_eq(_host.players.size(), _host.max_players, "the lingering seat is counted")
	assert_not_null(_host.sim.get_player(held.sim_id), "the body is still there")
	# The linger resolves normally, then the seat is free again.
	assert_true(_pump(func() -> bool: return _host.players.is_empty()), "the seat frees after the linger")
	var c := _connect()
	assert_true(_open(c))
	c.put_packet(_hello())
	var cc := {}
	assert_true(_pump(func() -> bool:
		_drain(c, cc)
		return cc.get("welcome", 0) == 1), "a join after the linger gets the seat")


func _local_host(max_players: int) -> LobbyHost:
	var host := LobbyHost.new(SimConfig.new())
	host.max_players = max_players
	return host


func _end_lingers() -> void:
	for i in range(LobbyHost.LINGER_TICKS + 1):
		_host.run_tick()


func test_full_lobby_refuses_local_joins_while_lingers_hold_seats() -> void:
	_host = _local_host(3)
	_host.add_local_player()
	var b := _host.add_local_player()
	var c := _host.add_local_player()
	_host.run_tick()
	var pb := _host._find_player(b)
	_host._leave(pb)  # no identity, as for a dropped remote connection
	var token := _host.remove_local_player(c)  # with an identity
	assert_true(pb.is_lingering())
	assert_true(_host._find_player(c).is_lingering())
	assert_eq(_host.add_local_player(), -1, "full while lingers hold seats")
	assert_eq(_host.add_local_player("not_a_class"), -1)
	assert_eq(_host.players.size(), 3, "no linger is ended to make room")
	_host.run_tick()
	assert_eq(_host.add_local_player(), -1)
	assert_not_null(_host.sim.get_player(b))
	assert_not_null(_host.sim.get_player(c))
	_end_lingers()
	assert_eq(_host.players.size(), 1, "both seats free after the lingers")
	assert_gt(_host.add_local_player(), 0)
	assert_gt(_host.add_local_player(null, token), 0)


func test_death_during_linger_resolves_it_and_frees_the_seat() -> void:
	_host = _local_host(2)
	_host.add_local_player()
	var b := _host.add_local_player()
	_host.run_tick()
	var pb := _host._find_player(b)
	_host._leave(pb)
	assert_eq(_host.add_local_player(), -1, "refused while the linger holds the seat")
	_host.sim.get_player(b).hp = 0  # dies while lingering
	_host.run_tick()
	assert_false(_host.players.has(pb), "a death ends the linger")
	assert_gt(_host.add_local_player(), 0, "the seat is free")


# --- deadline tick ----------------------------------------------------------

func test_on_time_service_runs_one_tick() -> void:
	var now := [1_000_000]
	_host = _start_host(LobbyHost.DEFAULT_MAX_PLAYERS, func() -> int: return now[0])
	_host.service()
	assert_eq(_host.tick, 0, "nothing due before the first deadline")
	now[0] += LobbyHost.PERIOD_USEC
	_host.service()
	assert_eq(_host.tick, 1)
	assert_eq(_host.skipped_ticks, 0)


func test_catch_up_is_capped_at_five_and_the_rest_are_skipped() -> void:
	var now := [1_000_000]
	_host = _start_host(LobbyHost.DEFAULT_MAX_PLAYERS, func() -> int: return now[0])
	var start: int = now[0]
	# Ten ticks are due (deadlines 1..10); only MAX_CATCH_UP run.
	now[0] = start + 10 * LobbyHost.PERIOD_USEC + 1
	_host.service()
	assert_eq(LobbyHost.MAX_CATCH_UP, 5)
	assert_eq(_host.tick, 5, "ran exactly the catch-up cap")
	assert_eq(_host.skipped_ticks, 5, "the other five are counted as skipped")
	assert_eq(_host.next_deadline_usec(), start + 11 * LobbyHost.PERIOD_USEC, "next deadline stays on the grid")
	# Back on schedule: one more period runs one tick and skips none.
	now[0] = start + 11 * LobbyHost.PERIOD_USEC
	_host.service()
	assert_eq(_host.tick, 6)
	assert_eq(_host.skipped_ticks, 5)


func test_small_lag_catches_up_without_skipping() -> void:
	var now := [1_000_000]
	_host = _start_host(LobbyHost.DEFAULT_MAX_PLAYERS, func() -> int: return now[0])
	var start: int = now[0]
	now[0] = start + 3 * LobbyHost.PERIOD_USEC
	_host.service()
	assert_eq(_host.tick, 3)
	assert_eq(_host.skipped_ticks, 0)


# --- connection limits ------------------------------------------------------

func test_flooding_client_is_budgeted_and_disconnected_without_starving_others() -> void:
	_host = _start_host()
	var observer := _connect()
	var flooder := _connect()
	assert_true(_open(observer) and _open(flooder))
	observer.put_packet(_hello())
	flooder.put_packet(_hello())
	var co := {}
	var cf := {}
	assert_true(_pump(func() -> bool:
		_drain(observer, co)
		_drain(flooder, cf)
		return co.get("welcome", 0) == 1 and cf.get("welcome", 0) == 1))
	co["snapshot"] = 0
	var ticks: int = 0
	var worst_tick_usec: int = 0
	for i in range(60):
		if flooder.get_ready_state() == WebSocketPeer.STATE_OPEN:
			for j in range(LobbyHost.MAX_MESSAGES_PER_TICK * 10):
				flooder.put_packet(_open_portal())
		flooder.poll()
		OS.delay_msec(5)
		var t0 := Time.get_ticks_usec()
		_host.run_tick()
		worst_tick_usec = maxi(worst_tick_usec, Time.get_ticks_usec() - t0)
		ticks += 1
		observer.poll()
		flooder.poll()
		_drain(observer, co)
		_drain(flooder, cf)
	# Let the last snapshots arrive.
	for i in range(20):
		OS.delay_msec(5)
		observer.poll()
		_drain(observer, co)
	assert_gt(_host.dropped_messages, 0, "excess messages are dropped")
	assert_eq(_host.budget_disconnects, 1, "sustained excess disconnects the flooder")
	assert_true(_closed(flooder), "flooder is closed")
	assert_eq(co.get("snapshot", 0), ticks, "observer got a snapshot every tick")
	assert_lt(worst_tick_usec, LobbyHost.PERIOD_USEC, "flood does not blow the tick budget")
	assert_lte(cf.get("error", 0), LobbyHost.MAX_ERROR_REPLIES_PER_WINDOW * (ticks / LobbyHost.ERROR_WINDOW_TICKS + 1),
		"Error replies stay rate limited")
	for i in range(LobbyHost.LINGER_TICKS + 1):
		_host.run_tick()
	assert_eq(_host.players.size(), 1, "flooder's player is removed after the linger")


func test_error_replies_are_rate_limited_per_connection() -> void:
	_host = _start_host()
	var ws := _connect()
	assert_true(_open(ws))
	ws.put_packet(_hello())
	var c := {}
	assert_true(_pump(func() -> bool:
		_drain(ws, c)
		return c.get("welcome", 0) == 1))
	# Two bad requests per tick stays inside the message budget, so only the
	# Error rate limit applies. Stay inside one error window.
	var sent: int = 0
	for i in range(LobbyHost.ERROR_WINDOW_TICKS - 2):
		ws.put_packet(_open_portal())
		ws.put_packet(_open_portal())
		sent += 2
		ws.poll()
		OS.delay_msec(5)
		_host.run_tick()
		ws.poll()
		_drain(ws, c)
	for i in range(10):
		OS.delay_msec(5)
		ws.poll()
		_drain(ws, c)
	assert_eq(c.get("error", 0), LobbyHost.MAX_ERROR_REPLIES_PER_WINDOW, "only the first few get an Error")
	assert_gt(_host.suppressed_errors, 0)
	assert_eq(ws.get_ready_state(), WebSocketPeer.STATE_OPEN, "rate limiting alone does not disconnect")


func test_idle_connection_without_hello_is_closed_after_timeout() -> void:
	var now := [1_000_000]
	_host = _start_host(LobbyHost.DEFAULT_MAX_PLAYERS, func() -> int: return now[0])
	var idle := _connect()
	var late := _connect()
	assert_true(_open(idle) and _open(late))
	now[0] += LobbyHost.HANDSHAKE_TIMEOUT_USEC - 1_000_000
	late.put_packet(_hello())
	var cl := {}
	assert_true(_pump(func() -> bool:
		_drain(late, cl)
		return cl.get("welcome", 0) == 1), "Hello inside the timeout is welcomed")
	now[0] += 2_000_000
	assert_true(_pump(func() -> bool: return _closed(idle)), "idle connection is closed")
	assert_eq(_host.handshake_timeouts, 1)
	assert_eq(late.get_ready_state(), WebSocketPeer.STATE_OPEN, "joined player is unaffected")


func test_connections_over_the_cap_are_refused() -> void:
	_host = _start_host(1)
	var cap := _host.max_connections()
	assert_eq(cap, 1 + LobbyHost.CONNECTION_SLACK)
	var accepted: Array[WebSocketPeer] = []
	for i in range(cap):
		accepted.append(_connect())
	assert_true(_pump(func() -> bool:
		for ws in accepted:
			if ws.get_ready_state() != WebSocketPeer.STATE_OPEN:
				return false
		return true), "connections up to the cap open")
	var extra := _connect()
	assert_true(_pump(func() -> bool: return extra.get_ready_state() == WebSocketPeer.STATE_CLOSED), "extra connection is refused")
	assert_eq(_host.refused_connections, 1)
	assert_eq(_host.connection_count(), cap)
