extends GutTest
## Godot lobby host (src/net/host): proto/v1 handshake over a real local
## WebSocket, plus the stand-in bullet field used by the load test.

const PB := preload("res://src/net/proto/protocol_v1_pb.gd")

var _host: LobbyHost


func after_each() -> void:
	if _host != null:
		_host.stop()
		_host = null


func _start_host() -> LobbyHost:
	var host := LobbyHost.new(SimConfig.new())
	host.port = 0  # any free port
	host.instance_seed = 7
	host.emitter_count = 2
	assert_eq(host.start(), OK, "host listens")
	assert_gt(host.port, 0)
	return host


## Pumps host ticks and the client until `pred` is true or ~5 s pass.
func _pump(host: LobbyHost, ws: WebSocketPeer, pred: Callable) -> bool:
	for i in range(500):
		host.run_tick()
		ws.poll()
		if pred.call():
			return true
		OS.delay_msec(10)
	return false


func _read_all(ws: WebSocketPeer, into: Array) -> void:
	while ws.get_available_packet_count() > 0:
		var m = PB.ServerMessage.new()
		assert_eq(m.from_bytes(ws.get_packet()), PB.PB_ERR.NO_ERRORS, "server message decodes")
		into.append(m)


func _hello(version: int) -> PackedByteArray:
	var msg = PB.ClientMessage.new()
	msg.new_hello().set_protocol_version(version)
	return msg.to_bytes()


func test_hello_gets_welcome_then_snapshot_with_applied_seq() -> void:
	_host = _start_host()
	var ws := WebSocketPeer.new()
	assert_eq(ws.connect_to_url("ws://127.0.0.1:%d/ws" % _host.port), OK)
	assert_true(_pump(_host, ws, func() -> bool: return ws.get_ready_state() == WebSocketPeer.STATE_OPEN), "client connects")
	ws.put_packet(_hello(SimConstants.PROTOCOL_VERSION))
	var got: Array = []
	assert_true(_pump(_host, ws, func() -> bool:
		_read_all(ws, got)
		return got.size() >= 2), "welcome and a snapshot arrive")
	assert_true(got[0].has_welcome(), "first message is Welcome")
	var w = got[0].get_welcome()
	assert_eq(w.get_protocol_version(), SimConstants.PROTOCOL_VERSION)
	assert_eq(w.get_tick_hz(), SimConstants.TICK_HZ)
	assert_eq(w.get_instance_seed(), 7)
	assert_almost_eq(w.get_multiplier(), 1.0, 1e-6)
	assert_eq(w.get_m100(), 100)
	assert_eq(w.get_instance_id_value(), LobbyHost.DEFAULT_INSTANCE_ID)
	assert_true(got[1].has_snapshot(), "then a Snapshot")
	var me: int = w.get_player_id()

	var input = PB.ClientMessage.new()
	var f = input.new_input()
	f.set_seq(5)
	f.set_move_x(1.0)
	f.set_fire_held(true)
	ws.put_packet(input.to_bytes())
	var applied := [0]
	assert_true(_pump(_host, ws, func() -> bool:
		var msgs: Array = []
		_read_all(ws, msgs)
		for m in msgs:
			if m.has_snapshot():
				for p in m.get_snapshot().get_players():
					if p.get_id() == me:
						applied[0] = p.get_applied_seq()
		return applied[0] == 5), "snapshot reports applied_seq 5")
	assert_eq(_host.players.size(), 1)
	ws.close()


func test_wrong_protocol_version_is_rejected() -> void:
	_host = _start_host()
	var ws := WebSocketPeer.new()
	assert_eq(ws.connect_to_url("ws://127.0.0.1:%d/ws" % _host.port), OK)
	assert_true(_pump(_host, ws, func() -> bool: return ws.get_ready_state() == WebSocketPeer.STATE_OPEN))
	ws.put_packet(_hello(2))
	var got: Array = []
	assert_true(_pump(_host, ws, func() -> bool:
		_read_all(ws, got)
		return got.size() >= 1))
	assert_true(got[0].has_reject(), "Reject, not Welcome")
	assert_eq(got[0].get_reject().get_client_protocol_version(), 2)
	assert_eq(_host.players.size(), 0, "no player joins")


func test_standin_bullets_are_seeded_and_hit_a_player_in_their_path() -> void:
	var a := HostStandinBulletField.new(3, 4, 32.0, 32.0)
	var b := HostStandinBulletField.new(3, 4, 32.0, 32.0)
	var far_x := PackedFloat64Array([-100.0])
	var far_y := PackedFloat64Array([-100.0])
	var hp := PackedInt32Array([100])
	for t in range(1, 40):
		a.step(t, far_x, far_y, 0.35, hp)
		b.step(t, far_x, far_y, 0.35, hp)
	assert_gt(a.live_bullets(), 0, "emitters fire")
	assert_eq(a.live_bullets(), b.live_bullets(), "same seed, same bullets")
	assert_true(a.b_vx == b.b_vx and a.b_vy == b.b_vy, "same seed, same directions")
	# A player sitting on an emitter is hit by its next ring.
	var on_x := PackedFloat64Array([a.emitters_x[0]])
	var on_y := PackedFloat64Array([a.emitters_y[0]])
	for t in range(40, 40 + a.period_ticks + 1):
		a.step(t, on_x, on_y, 0.35, hp)
	assert_gt(a.hits_total, 0, "swept hit registers")
	assert_lt(hp[0], 100)


func test_portal_messages_get_an_error_not_a_disconnect() -> void:
	_host = _start_host()
	var ws := WebSocketPeer.new()
	assert_eq(ws.connect_to_url("ws://127.0.0.1:%d/ws" % _host.port), OK)
	assert_true(_pump(_host, ws, func() -> bool: return ws.get_ready_state() == WebSocketPeer.STATE_OPEN))
	ws.put_packet(_hello(SimConstants.PROTOCOL_VERSION))
	var open = PB.ClientMessage.new()
	open.new_open_portal().set_m100(100)
	ws.put_packet(open.to_bytes())
	var got: Array = []
	assert_true(_pump(_host, ws, func() -> bool:
		_read_all(ws, got)
		for m in got:
			if m.has_error():
				return true
		return false), "OpenPortal is answered with Error")
	assert_eq(ws.get_ready_state(), WebSocketPeer.STATE_OPEN, "connection stays open")
	assert_eq(_host.players.size(), 1)
