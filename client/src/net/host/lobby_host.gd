class_name LobbyHost
extends RefCounted
## Godot-hosted lobby server (stack decision 2b), first cut for the 50-player
## load test. TCPServer + WebSocketPeer speaking proto/v1 through the
## godobuf codec. No MultiplayerAPI / RPCs.
##
## Each player is driven by the real LocalSim (movement + player shots).
## Enemy bullets come from HostStandinBulletField, a labeled stand-in until
## the real pattern/rules classes land on main.
##
## Tick is deadline-based: tick n is due at start + n * period. At most
## MAX_CATCH_UP overdue ticks run back to back; the rest are dropped and
## counted in skipped_ticks.

const PB := preload("res://src/net/proto/protocol_v1_pb.gd")
const LT := preload("res://src/net/host/loadtest_state_pb.gd")

const MAX_CATCH_UP: int = 5
const PERIOD_USEC: int = 50000  # 1e6 / SimConstants.TICK_HZ
const START_HP: int = 100
const EMITTER_RADIUS: float = 0.6


class HostConn:
	extends RefCounted
	var ws: WebSocketPeer
	var player: HostPlayer = null
	var opened_at_usec: int = 0
	var close_pending: bool = false


class HostPlayer:
	extends RefCounted
	var id: int = 0
	var sim: LocalSim
	var seq: int = 0
	var move_x: float = 0.0
	var move_y: float = 0.0
	var aim: float = 0.0
	var fire_held: bool = false
	var hp: int = START_HP
	var join_tick: int = 0
	var x: float = 0.0
	var y: float = 0.0
	var aim_applied: float = 0.0


# Config
var port: int = 0
var bind_address: String = "127.0.0.1"
var instance_seed: int = 1
var multiplier_m100: int = 100
var arena_size: float = 48.0
var emitter_count: int = 20
## Record stats only while at least this many players are connected (0 = any).
var expect_clients: int = 0

# State
var tick: int = 0
var skipped_ticks: int = 0
var late_ticks: int = 0
var players: Array[HostPlayer] = []
var bullets: HostStandinBulletField
var enemy_hits: int = 0
var player_deaths: int = 0
var peak_players: int = 0
var last_snapshot_bytes: int = 0
var last_full_bytes: int = 0

var _tcp := TCPServer.new()
var _conns: Array[HostConn] = []
var _next_player_id: int = 1
var _config: SimConfig
var _start_usec: int = 0
var _n: int = 0  # index of the next due tick

# Stats (only for recorded ticks)
var st_total := PackedInt64Array()
var st_net_in := PackedInt64Array()
var st_sim := PackedInt64Array()
var st_encode := PackedInt64Array()
var st_send := PackedInt64Array()
var st_bullets := PackedInt32Array()
var st_snapshot_bytes_sum: int = 0
var st_full_bytes_sum: int = 0
var st_packets_sent: int = 0
var st_first_usec: int = -1
var st_last_usec: int = -1
var st_skipped_at_start: int = -1
var st_skipped_at_end: int = 0
var st_inputs: int = 0
var _inputs_this_tick: int = 0


func _init(config: SimConfig = null) -> void:
	_config = config if config != null else SimConfig.new()


func start() -> Error:
	bullets = HostStandinBulletField.new(instance_seed, emitter_count, arena_size, arena_size)
	var err := _tcp.listen(port, bind_address)
	if err != OK:
		return err
	port = _tcp.get_local_port()
	_start_usec = Time.get_ticks_usec()
	_n = 1
	return OK


func stop() -> void:
	for c in _conns:
		c.ws.close()
	_conns.clear()
	players.clear()
	_tcp.stop()


func connection_count() -> int:
	return _conns.size()


func next_deadline_usec() -> int:
	return _start_usec + _n * PERIOD_USEC


## Runs every due tick (bounded catch-up). Call this from the main loop.
func service() -> void:
	var now := Time.get_ticks_usec()
	var steps: int = 0
	while now >= next_deadline_usec() and steps < MAX_CATCH_UP:
		var due := next_deadline_usec()
		run_tick()
		if now - due > PERIOD_USEC:
			late_ticks += 1
		_n += 1
		steps += 1
		now = Time.get_ticks_usec()
	if now >= next_deadline_usec():
		var overdue: int = int((now - next_deadline_usec()) / PERIOD_USEC) + 1
		skipped_ticks += overdue
		_n += overdue


## One full host tick: network in, sim, encode, send. Public for tests.
func run_tick() -> void:
	var t0 := Time.get_ticks_usec()
	_inputs_this_tick = 0
	_net_in()
	var t1 := Time.get_ticks_usec()
	tick += 1
	var new_shots: Array[PackedFloat64Array] = _step_sim()
	var t2 := Time.get_ticks_usec()
	var snap_bytes := _encode_snapshot()
	var full_bytes := _encode_full(new_shots)
	var t3 := Time.get_ticks_usec()
	var sent := _send(snap_bytes)
	var t4 := Time.get_ticks_usec()
	last_snapshot_bytes = snap_bytes.size()
	last_full_bytes = full_bytes.size()
	peak_players = maxi(peak_players, players.size())
	var record := players.size() > 0 and players.size() >= expect_clients
	if record:
		if st_first_usec < 0:
			st_first_usec = t0
			st_skipped_at_start = skipped_ticks
		st_last_usec = t4
		st_skipped_at_end = skipped_ticks
		st_total.append(t4 - t0)
		st_net_in.append(t1 - t0)
		st_sim.append(t2 - t1)
		st_encode.append(t3 - t2)
		st_send.append(t4 - t3)
		st_bullets.append(bullets.live_bullets())
		st_snapshot_bytes_sum += snap_bytes.size()
		st_full_bytes_sum += full_bytes.size()
		st_packets_sent += sent
		st_inputs += _inputs_this_tick


func _net_in() -> void:
	while _tcp.is_connection_available():
		var stream := _tcp.take_connection()
		if stream == null:
			break
		var c := HostConn.new()
		c.ws = WebSocketPeer.new()
		c.ws.outbound_buffer_size = 1 << 18
		c.opened_at_usec = Time.get_ticks_usec()
		if c.ws.accept_stream(stream) == OK:
			_conns.append(c)
	var keep: Array[HostConn] = []
	for c in _conns:
		if c.close_pending:
			c.close_pending = false
			c.ws.close(1000, "rejected")
		c.ws.poll()
		var state := c.ws.get_ready_state()
		if state == WebSocketPeer.STATE_OPEN:
			while c.ws.get_available_packet_count() > 0:
				_on_packet(c, c.ws.get_packet())
		if state == WebSocketPeer.STATE_CLOSED:
			_drop_player(c)
			continue
		keep.append(c)
	_conns = keep


func _on_packet(c: HostConn, data: PackedByteArray) -> void:
	var msg = PB.ClientMessage.new()
	if msg.from_bytes(data) != PB.PB_ERR.NO_ERRORS:
		c.ws.close(1003, "bad message")
		return
	if c.close_pending:
		return
	if msg.has_hello():
		if c.player != null:
			return
		var v: int = msg.get_hello().get_protocol_version()
		if v != SimConstants.PROTOCOL_VERSION:
			var rej = PB.ServerMessage.new()
			var r = rej.new_reject()
			r.set_server_protocol_version(SimConstants.PROTOCOL_VERSION)
			r.set_client_protocol_version(v)
			r.set_reason("unsupported protocol_version")
			c.ws.put_packet(rej.to_bytes())
			# Close a tick later: closing right away can drop the queued Reject.
			c.close_pending = true
			return
		c.player = _add_player()
		var out = PB.ServerMessage.new()
		var w = out.new_welcome()
		w.set_protocol_version(SimConstants.PROTOCOL_VERSION)
		w.set_player_id(c.player.id)
		w.set_tick_hz(SimConstants.TICK_HZ)
		w.set_instance_seed(instance_seed)
		w.set_multiplier(float(multiplier_m100) / 100.0)
		c.ws.put_packet(out.to_bytes())
	elif msg.has_input():
		if c.player == null:
			return
		var f = msg.get_input()
		var p := c.player
		var seq: int = f.get_seq()
		if seq <= p.seq:
			return  # stale or duplicate
		p.seq = seq
		p.move_x = _finite_or_zero(f.get_move_x())
		p.move_y = _finite_or_zero(f.get_move_y())
		p.aim = _finite_or_zero(f.get_aim())
		p.fire_held = f.get_fire_held()
		_inputs_this_tick += 1


static func _finite_or_zero(v: float) -> float:
	return v if is_finite(v) else 0.0


func _add_player() -> HostPlayer:
	var p := HostPlayer.new()
	p.id = _next_player_id
	_next_player_id += 1
	# Spread spawns over the arena deterministically by id.
	var a: float = float(p.id) * 2.399963
	var r: float = arena_size * 0.35 * sqrt(float(p.id % 50) / 50.0)
	p.sim = LocalSim.new(_config, arena_size * 0.5 + cos(a) * r, arena_size * 0.5 + sin(a) * r)
	p.sim.set_bounds(0.0, 0.0, arena_size, arena_size)
	p.join_tick = tick
	players.append(p)
	return p


func _drop_player(c: HostConn) -> void:
	if c.player == null:
		return
	players.erase(c.player)
	c.player = null


## Steps every player's LocalSim and the stand-in bullets. Returns new player
## shots as [owner, host_spawn_tick, x, y, angle].
func _step_sim() -> Array[PackedFloat64Array]:
	var n: int = players.size()
	var px := PackedFloat64Array()
	var py := PackedFloat64Array()
	var hp := PackedInt32Array()
	px.resize(n)
	py.resize(n)
	hp.resize(n)
	var shots: Array[PackedFloat64Array] = []
	for i in range(n):
		var p := players[i]
		p.sim.submit_input(InputIntent.from_raw(p.seq, p.move_x, p.move_y, p.aim, p.fire_held))
		p.sim.step()
		var snap := p.sim.snapshot()
		p.x = snap.player_x
		p.y = snap.player_y
		p.aim_applied = snap.player_aim
		px[i] = p.x
		py[i] = p.y
		hp[i] = p.hp
		var local_tick: int = p.sim.tick()
		for shot in snap.projectiles:
			if shot.spawn_tick == local_tick:
				shots.append(PackedFloat64Array([float(p.id), float(tick), shot.origin_x, shot.origin_y, atan2(shot.dir_y, shot.dir_x)]))
			_shot_vs_emitters(shot, local_tick)
	bullets.step(tick, px, py, _config.player_radius_tiles, hp)
	for i in range(n):
		if hp[i] <= 0:
			player_deaths += 1
			hp[i] = START_HP
		players[i].hp = hp[i]
	return shots


func _shot_vs_emitters(shot: SimProjectile, local_tick: int) -> void:
	var pos := shot.position_at_time(float(local_tick))
	var r: float = EMITTER_RADIUS + shot.radius_tiles
	var r2: float = r * r
	for e in range(bullets.emitters_x.size()):
		var dx: float = bullets.emitters_x[e] - pos.x
		var dy: float = bullets.emitters_y[e] - pos.y
		if dx * dx + dy * dy <= r2:
			enemy_hits += 1
			return


func _encode_snapshot() -> PackedByteArray:
	var msg = PB.ServerMessage.new()
	var s = msg.new_snapshot()
	s.set_tick(tick)
	for p in players:
		var stub = s.add_players()
		stub.set_id(p.id)
		stub.set_applied_seq(p.seq)
	return msg.to_bytes()


## Load-test-only projection of a full snapshot (see loadtest_state.proto).
func _encode_full(new_shots: Array[PackedFloat64Array]) -> PackedByteArray:
	var full = LT.FullSnapshot.new()
	full.set_tick(tick)
	for p in players:
		var ps = full.add_players()
		ps.set_id(p.id)
		ps.set_applied_seq(p.seq)
		ps.set_x(p.x)
		ps.set_y(p.y)
		ps.set_aim(p.aim_applied)
		ps.set_hp(p.hp)
	for ev in bullets.last_spawns:
		var sp = full.add_spawns()
		sp.set_emitter_id(int(ev[0]))
		sp.set_pattern_id(HostStandinBulletField.PATTERN_RING)
		sp.set_seed(int(ev[1]))
		sp.set_spawn_tick(int(ev[2]))
		sp.set_x(ev[3])
		sp.set_y(ev[4])
	for ev in new_shots:
		var sh = full.add_shots()
		sh.set_owner(int(ev[0]))
		sh.set_spawn_tick(int(ev[1]))
		sh.set_x(ev[2])
		sh.set_y(ev[3])
		sh.set_angle(ev[4])
	return full.to_bytes()


func _send(bytes: PackedByteArray) -> int:
	var sent: int = 0
	for c in _conns:
		if c.player == null or c.ws.get_ready_state() != WebSocketPeer.STATE_OPEN:
			continue
		if c.ws.put_packet(bytes) == OK:
			sent += 1
		c.ws.poll()  # flush now instead of 50 ms later
	return sent


## Summary of recorded ticks as a Dictionary (JSON-friendly).
func stats() -> Dictionary:
	var wall_s: float = maxf(float(st_last_usec - st_first_usec) / 1e6, 1e-9)
	var nrec: int = st_total.size()
	var avg_bullets: float = 0.0
	var max_bullets: int = 0
	for b in st_bullets:
		avg_bullets += float(b)
		max_bullets = maxi(max_bullets, b)
	if nrec > 0:
		avg_bullets /= float(nrec)
	var expected_ticks: int = int(wall_s * float(SimConstants.TICK_HZ))
	return {
		"recorded_ticks": nrec,
		"recorded_wall_s": snappedf(wall_s, 0.01),
		"achieved_tick_hz": snappedf(float(nrec) / wall_s, 0.01) if nrec > 1 else 0.0,
		"expected_ticks": expected_ticks,
		"peak_players": peak_players,
		"tick_us": _pct(st_total),
		"net_in_us": _pct(st_net_in),
		"sim_us": _pct(st_sim),
		"encode_us": _pct(st_encode),
		"send_us": _pct(st_send),
		"skipped_ticks": st_skipped_at_end - maxi(st_skipped_at_start, 0),
		"skipped_ticks_total": skipped_ticks,
		"late_ticks_total": late_ticks,
		"bullets_avg": snappedf(avg_bullets, 0.1),
		"bullets_max": max_bullets,
		"snapshot_bytes_avg": snappedf(float(st_snapshot_bytes_sum) / maxf(nrec, 1), 0.1),
		"snapshot_bytes_per_client_s": snappedf(float(st_snapshot_bytes_sum) / wall_s, 1.0),
		"full_state_bytes_avg": snappedf(float(st_full_bytes_sum) / maxf(nrec, 1), 0.1),
		"full_state_bytes_per_client_s": snappedf(float(st_full_bytes_sum) / wall_s, 1.0),
		"packets_sent": st_packets_sent,
		"inputs_applied": st_inputs,
		"bullet_hits": bullets.hits_total,
		"enemy_hits": enemy_hits,
		"player_deaths": player_deaths,
	}


static func _pct(a: PackedInt64Array) -> Dictionary:
	if a.is_empty():
		return {"p50": 0, "p95": 0, "p99": 0, "max": 0, "mean": 0}
	var s := a.duplicate()
	s.sort()
	var n: int = s.size()
	var sum: int = 0
	for v in s:
		sum += v
	return {
		"p50": s[int(0.50 * (n - 1))],
		"p95": s[int(0.95 * (n - 1))],
		"p99": s[int(0.99 * (n - 1))],
		"max": s[n - 1],
		"mean": sum / n,
	}
