class_name LobbyHost
extends RefCounted
## Godot-hosted lobby server (stack decision 2b), first cut for the 50-player
## load test. TCPServer + WebSocketPeer speaking proto/v1 through the
## godobuf codec. No MultiplayerAPI / RPCs.
##
## Each player is driven by the real LocalSim (movement + player shots).
## Enemy bullets come from HostStandinBulletField, a labeled stand-in used
## only by the load test (emitter_count > 0, set by --emitters). A normal
## lobby runs with emitter_count = 0.
##
## Lobby API for the UI (see client/README.md): apply_settings()/settings()
## with LobbySettings, a local player on the same input path as remote ones
## (add_local_player / submit_local_input), world_view() + ticked, and
## import_character() checked against the import flags.
##
## Tick is deadline-based: tick n is due at start + n * period. At most
## MAX_CATCH_UP overdue ticks run back to back; the rest are dropped and
## counted in skipped_ticks. Deadlines and connection timeouts read `clock`
## (a Callable returning microseconds), which tests replace with a fake.
## The sim never reads it.
##
## Connection limits (each a named constant below): a per-connection budget of
## incoming messages per tick, disconnect on sustained excess, a rate limit on
## Error replies, a pre-handshake timeout, and a cap on open connections.

const PB := preload("res://src/net/proto/protocol_v1_pb.gd")
const LT := preload("res://src/net/host/loadtest_state_pb.gd")

const MAX_CATCH_UP: int = 5
const PERIOD_USEC: int = 50000  # 1e6 / SimConstants.TICK_HZ
const START_HP: int = 100
const EMITTER_RADIUS: float = 0.6
## Matches the Go server's instance.DefaultInstanceID (the smoke instance).
const DEFAULT_INSTANCE_ID: int = 1

## Lobby player cap, same range and default as the Go harness (ER_MAX_PLAYERS).
const MIN_MAX_PLAYERS: int = 1
const MAX_MAX_PLAYERS: int = 50
const DEFAULT_MAX_PLAYERS: int = 50
## Upper bound for the load-test-only override (--loadtest-unsafe-max-players).
const LOADTEST_UNSAFE_MAX_PLAYERS_LIMIT: int = 1000
## Extra connection slots above max_players for handshakes and spectators.
const CONNECTION_SLACK: int = 8
## Incoming messages decoded per connection per tick; the rest are dropped
## without decoding. A well-behaved client sends one InputFrame per tick.
const MAX_MESSAGES_PER_TICK: int = 4
## Close a connection that exceeds the budget this many ticks in a row.
const MAX_OVER_BUDGET_TICKS: int = 20
## Close a connection that has this many messages queued at once.
const MAX_QUEUED_MESSAGES: int = 256
## Error replies per connection per ERROR_WINDOW_TICKS (one second).
const MAX_ERROR_REPLIES_PER_WINDOW: int = 3
const ERROR_WINDOW_TICKS: int = 20
## A connection that has not sent Hello within this long is closed.
const HANDSHAKE_TIMEOUT_USEC: int = 5_000_000

## Stub character blob header for import_character(): magic, format
## version, flags. TODO: real character format + signature.
const IMPORT_MAGIC := "ERC"
const IMPORT_FORMAT_VERSION: int = 1
const IMPORT_FLAG_PLAYED_OFFLINE: int = 1

signal settings_changed(s: LobbySettings)
## Emitted at the end of every host tick, after the sim step and sends.
signal ticked(tick: int)


class HostConn:
	extends RefCounted
	var ws: WebSocketPeer
	var player: HostPlayer = null
	var opened_at_usec: int = 0
	var close_pending: bool = false
	var over_budget_ticks: int = 0
	var error_window_start: int = 0
	var errors_in_window: int = 0


class HostPlayer:
	extends RefCounted
	var id: int = 0
	var sim: LocalSim
	var seq: int = 0
	var move_x: float = 0.0
	var move_y: float = 0.0
	var aim: float = 0.0
	var fire_held: bool = false
	## Interact presses received since the last tick: [seq, target_id] pairs,
	## in arrival order. Bounded by the per-tick message budget.
	var interacts: Array[PackedInt64Array] = []
	var hp: int = START_HP
	var join_tick: int = 0
	var x: float = 0.0
	var y: float = 0.0
	var aim_applied: float = 0.0
	## Hosted on this machine, no socket (add_local_player).
	var is_local: bool = false
	var character: Variant = null
	var imported_character := PackedByteArray()
	## That player's sim snapshot after the last tick (for world_view).
	var last_snap: WorldSnapshot = null


# Config
var port: int = 0
var bind_address: String = "127.0.0.1"
var instance_seed: int = 1
var multiplier_m100: int = 100
var arena_size: float = 48.0
## Stand-in enemy emitters for the load test. 0 in a normal lobby.
var emitter_count: int = 0
## Record stats only while at least this many players are connected (0 = any).
var expect_clients: int = 0
## Players allowed at once. Backed by settings().max_players; prefer
## apply_settings(). Lowering it never kicks anyone, it only blocks new joins.
var max_players: int:
	get:
		return _unsafe_max_players if _unsafe_max_players > 0 else _settings.max_players
	set(v):
		_settings.max_players = v
## Microsecond clock for deadlines and timeouts. Tests inject a fake.
var clock: Callable = Time.get_ticks_usec
## Validates interact presses (range, once per seq, known/allowed target).
var interact_validator := HostInteractValidator.new()
## HOOK (#30): called as on_interact.call(player_id, target_id) for each
## accepted interact press, after that player's movement for the tick.
var on_interact: Callable = Callable()

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
# Connection-limit counters
var refused_connections: int = 0
var dropped_messages: int = 0
var budget_disconnects: int = 0
var handshake_timeouts: int = 0
var suppressed_errors: int = 0

var _settings := LobbySettings.new()
var _unsafe_max_players: int = 0
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
	# Replaced in start(); lets a not-yet-listening host tick local players.
	bullets = HostStandinBulletField.new(instance_seed, 0, arena_size, arena_size)


func start() -> Error:
	if _settings.join_code == "":
		_settings.join_code = LobbySettings.generate_join_code()
	bullets = HostStandinBulletField.new(instance_seed, emitter_count, arena_size, arena_size)
	var err := _tcp.listen(port, bind_address)
	if err != OK:
		return err
	port = _tcp.get_local_port()
	_start_usec = clock.call()
	_n = 1
	return OK


func stop() -> void:
	for c in _conns:
		c.ws.close()
	_conns.clear()
	players.clear()
	_tcp.stop()


## Validates and applies lobby settings. An empty join_code keeps the current
## code (or generates one). Lowering max_players never kicks anyone; the M
## range applies to portals opened afterwards; the import flags apply to
## future imports. Emits settings_changed with a copy.
func apply_settings(s: LobbySettings) -> Error:
	if s == null or not s.validate().is_empty():
		return ERR_INVALID_PARAMETER
	var next := s.duplicate_settings()
	if next.join_code == "":
		next.join_code = _settings.join_code if _settings.join_code != "" else LobbySettings.generate_join_code()
	_settings = next
	settings_changed.emit(_settings.duplicate_settings())
	return OK


## A copy of the current settings, including the generated join code.
func settings() -> LobbySettings:
	if _settings.join_code == "":
		_settings.join_code = LobbySettings.generate_join_code()
	return _settings.duplicate_settings()


## Load-test-only cap above MAX_MAX_PLAYERS; bypasses LobbySettings.
func set_loadtest_unsafe_max_players(n: int) -> void:
	_unsafe_max_players = n


## True if a portal at this multiplier is allowed by the lobby's M range.
## TODO(protocol PR): the Godot host has no OpenPortal handling yet; when it
## does, reject out-of-range m100 there with ErrorCode.MULTIPLIER_NOT_ALLOWED.
func is_m100_allowed(m100: int) -> bool:
	return _settings.allows_m100(m100)


## Adds a player hosted on this machine (listen server). Counts toward
## max_players. Returns the player id, or -1 if the lobby is full.
func add_local_player(character: Variant = null) -> int:
	if players.size() >= max_players:
		return -1
	var p := _add_player()
	p.is_local = true
	p.character = character
	return p.id


## Queues a local player's input for the next tick. Same rules as a remote
## InputFrame (applied once per seq, interacts go through the validator), but
## no socket and no message budget.
func submit_local_input(player_id: int, intent: InputIntent) -> void:
	var p := _find_player(player_id)
	if p == null or not p.is_local or intent == null:
		return
	var target = intent.get("interact_target_id")
	_queue_input(p, intent.seq, intent.move_x, intent.move_y, intent.aim, intent.fire_held,
			int(target) if target != null else 0)


func remove_local_player(player_id: int) -> void:
	var p := _find_player(player_id)
	if p == null or not p.is_local:
		return
	interact_validator.forget_player(p.id)
	players.erase(p)


## Read-only view for one player after the last tick: that player's sim
## snapshot plus the other players and any stand-in bullets. Null if the
## player is unknown or has not been simulated yet.
func world_view(player_id: int) -> WorldSnapshot:
	var p := _find_player(player_id)
	if p == null or p.last_snap == null:
		return null
	var src := p.last_snap
	var v := HostWorldSnapshot.new()
	v.tick = src.tick
	v.host_tick = tick
	v.player_id = p.id
	v.player_x = src.player_x
	v.player_y = src.player_y
	v.player_aim = src.player_aim
	v.player_hp = src.player_hp
	v.player_max_hp = src.player_max_hp
	v.player_flash_ticks = src.player_flash_ticks
	v.applied_seq = src.applied_seq
	v.projectiles = src.projectiles.duplicate()
	v.enemies = src.enemies.duplicate()
	v.pattern_bullets = src.pattern_bullets.duplicate()
	if bullets != null and bullets.b_count > 0:
		# Stand-in hits are host-side; show host hp and the stand-in bullets
		# in this player's sim time base.
		v.player_hp = p.hp
		v.player_max_hp = START_HP
		var offset: int = tick - src.tick
		for i in range(bullets.b_count):
			var b := PatternBullet.new()
			b.id = -(i + 1)
			b.spawn_tick = bullets.b_spawn[i] - offset
			b.origin_x = bullets.b_ox[i]
			b.origin_y = bullets.b_oy[i]
			b.angle_rad = atan2(bullets.b_vy[i], bullets.b_vx[i])
			b.speed = Vector2(bullets.b_vx[i], bullets.b_vy[i]).length() / SimConstants.TICK_DT
			b.lifetime_ticks = bullets.lifetime_ticks
			b.radius_tiles = bullets.bullet_radius
			v.pattern_bullets.append(b)
	for o in players:
		if o == p:
			continue
		v.others.append({"id": o.id, "x": o.x, "y": o.y, "aim": o.aim_applied, "hp": o.hp, "local": o.is_local})
	return v


## Checks an imported character against the lobby's import flags. Called only
## when a player imports, never at Hello. Returns an ImportResult constant.
## Blob format and signature are a stub for now:
## "ERC" + version byte (1) + flags byte (bit 0 = played offline) + payload.
## TODO: real character format and signature verification.
func import_character(blob: PackedByteArray, player_id: int) -> int:
	var p := _find_player(player_id)
	if p == null:
		return ImportResult.REJECTED_UNKNOWN_PLAYER
	if not _settings.imports_allowed:
		return ImportResult.REJECTED_IMPORTS_OFF
	var n: int = IMPORT_MAGIC.length()
	if blob.size() < n + 2 or blob.slice(0, n).get_string_from_ascii() != IMPORT_MAGIC:
		return ImportResult.REJECTED_BAD_FORMAT
	if blob[n] != IMPORT_FORMAT_VERSION:
		return ImportResult.REJECTED_UNSUPPORTED_VERSION
	# TODO: verify the signature; return REJECTED_BAD_SIGNATURE on failure.
	if blob[n + 1] & IMPORT_FLAG_PLAYED_OFFLINE != 0 and not _settings.offline_allowed:
		return ImportResult.REJECTED_OFFLINE_OFF
	if not p.imported_character.is_empty():
		return ImportResult.REJECTED_ALREADY_EXISTS
	p.imported_character = blob
	return ImportResult.IMPORT_RESULT_OK


## Builds a blob in the stub import format (for tests and the lobby UI).
static func make_stub_import_blob(played_offline: bool, payload := PackedByteArray(),
		version: int = IMPORT_FORMAT_VERSION) -> PackedByteArray:
	var out := IMPORT_MAGIC.to_ascii_buffer()
	out.append(version)
	out.append(IMPORT_FLAG_PLAYED_OFFLINE if played_offline else 0)
	out.append_array(payload)
	return out


func _find_player(player_id: int) -> HostPlayer:
	for p in players:
		if p.id == player_id:
			return p
	return null


func connection_count() -> int:
	return _conns.size()


func max_connections() -> int:
	return max_players + CONNECTION_SLACK


## Parses a --max-players / ER_MAX_PLAYERS value. Returns the value, or -1 if
## it is not an integer in [MIN_MAX_PLAYERS, MAX_MAX_PLAYERS]. Never clamps.
static func parse_max_players(value: String) -> int:
	var v := value.strip_edges()
	if not v.is_valid_int():
		return -1
	var n := v.to_int()
	if n < MIN_MAX_PLAYERS or n > MAX_MAX_PLAYERS:
		return -1
	return n


## Parses the load-test-only override. Returns -1 if invalid.
static func parse_loadtest_unsafe_max_players(value: String) -> int:
	var v := value.strip_edges()
	if not v.is_valid_int():
		return -1
	var n := v.to_int()
	if n < MIN_MAX_PLAYERS or n > LOADTEST_UNSAFE_MAX_PLAYERS_LIMIT:
		return -1
	return n


func next_deadline_usec() -> int:
	return _start_usec + _n * PERIOD_USEC


## Runs every due tick (bounded catch-up). Call this from the main loop.
func service() -> void:
	var now: int = clock.call()
	var steps: int = 0
	while now >= next_deadline_usec() and steps < MAX_CATCH_UP:
		var due := next_deadline_usec()
		run_tick()
		if now - due > PERIOD_USEC:
			late_ticks += 1
		_n += 1
		steps += 1
		now = clock.call()
	if now >= next_deadline_usec():
		var overdue: int = int((now - next_deadline_usec()) / PERIOD_USEC) + 1
		skipped_ticks += overdue
		_n += overdue


## One full host tick: network in, sim, encode, send. Public for tests.
func run_tick() -> void:
	var t0 := Time.get_ticks_usec()
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
	_inputs_this_tick = 0
	ticked.emit(tick)


func _net_in() -> void:
	var now: int = clock.call()
	while _tcp.is_connection_available():
		var stream := _tcp.take_connection()
		if stream == null:
			break
		if _conns.size() >= max_connections():
			refused_connections += 1
			stream.disconnect_from_host()
			continue
		var c := HostConn.new()
		c.ws = WebSocketPeer.new()
		c.ws.outbound_buffer_size = 1 << 18
		c.opened_at_usec = now
		if c.ws.accept_stream(stream) == OK:
			_conns.append(c)
	var keep: Array[HostConn] = []
	for c in _conns:
		if c.close_pending:
			c.close_pending = false
			c.ws.close(1000, "closed by host")
		c.ws.poll()
		var state := c.ws.get_ready_state()
		if state == WebSocketPeer.STATE_CLOSED:
			_drop_player(c)
			continue
		if c.player == null and not c.close_pending and state != WebSocketPeer.STATE_CLOSING \
				and now - c.opened_at_usec > HANDSHAKE_TIMEOUT_USEC:
			handshake_timeouts += 1
			c.ws.close(1008, "handshake timeout")
		elif state == WebSocketPeer.STATE_OPEN:
			_read_budgeted(c)
		keep.append(c)
	_conns = keep


## Decodes at most MAX_MESSAGES_PER_TICK messages; drops the rest undecoded.
func _read_budgeted(c: HostConn) -> void:
	var queued: int = c.ws.get_available_packet_count()
	if queued > MAX_QUEUED_MESSAGES:
		_close_for_budget(c)
		return
	var handled: int = 0
	while c.ws.get_available_packet_count() > 0 and c.ws.get_ready_state() == WebSocketPeer.STATE_OPEN:
		var data := c.ws.get_packet()
		if handled >= MAX_MESSAGES_PER_TICK:
			dropped_messages += 1
			continue
		handled += 1
		_on_packet(c, data)
	if queued > MAX_MESSAGES_PER_TICK:
		c.over_budget_ticks += 1
		if c.over_budget_ticks >= MAX_OVER_BUDGET_TICKS:
			_close_for_budget(c)
	else:
		c.over_budget_ticks = 0


func _close_for_budget(c: HostConn) -> void:
	budget_disconnects += 1
	c.ws.close(1008, "message rate limit")
	_drop_player(c)


## Sends an Error unless this connection used up its Error replies for the
## current window. Returns true if it was sent.
func _send_error(c: HostConn, code: int, reason: String) -> bool:
	# The window opens at the first Error and lasts ERROR_WINDOW_TICKS.
	if c.errors_in_window == 0 or tick - c.error_window_start >= ERROR_WINDOW_TICKS:
		c.error_window_start = tick
		c.errors_in_window = 0
	if c.errors_in_window >= MAX_ERROR_REPLIES_PER_WINDOW:
		suppressed_errors += 1
		return false
	c.errors_in_window += 1
	var out = PB.ServerMessage.new()
	var e = out.new_error()
	e.set_code(code)
	e.set_reason(reason)
	c.ws.put_packet(out.to_bytes())
	return true


func _on_packet(c: HostConn, data: PackedByteArray) -> void:
	var msg = PB.ClientMessage.new()
	if msg.from_bytes(data) != PB.PB_ERR.NO_ERRORS:
		c.ws.close(1003, "bad message")
		_drop_player(c)
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
		if players.size() >= max_players:
			# The Error always goes out: this connection closes right after.
			c.errors_in_window = 0
			_send_error(c, PB.ErrorCode.INSTANCE_FULL, "lobby is full")
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
		w.set_instance(DEFAULT_INSTANCE_ID)
		w.set_m100(multiplier_m100)
		c.ws.put_packet(out.to_bytes())
	elif msg.has_input():
		if c.player == null:
			return
		var f = msg.get_input()
		_queue_input(c.player, f.get_seq(), f.get_move_x(), f.get_move_y(), f.get_aim(),
				f.get_fire_held(), f.get_interact_target_id())
	elif c.player != null and (msg.has_open_portal() or msg.has_join_instance() \
			or msg.has_list_instances() or msg.has_leave_instance()):
		# Portals are not part of this load-test host yet.
		_send_error(c, PB.ErrorCode.ERROR_CODE_UNSPECIFIED, "portals are not supported by the Godot host yet")


## Shared by remote InputFrames and submit_local_input: applied once per seq,
## interact presses queued for the validator on the next tick.
func _queue_input(p: HostPlayer, seq: int, mx: float, my: float, aim: float, fire: bool, target: int) -> void:
	if not Seq.seq_is_next(seq, p.seq):
		return  # stale or duplicate, including across the uint32 wrap
	p.seq = seq
	p.move_x = _finite_or_zero(mx)
	p.move_y = _finite_or_zero(my)
	p.aim = _finite_or_zero(aim)
	p.fire_held = fire
	if target != 0:
		# Each press is evaluated, even if later frames arrive in the same tick.
		p.interacts.append(PackedInt64Array([seq, target]))
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
	interact_validator.forget_player(c.player.id)
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
		p.last_snap = snap
		p.x = snap.player_x
		p.y = snap.player_y
		p.aim_applied = snap.player_aim
		px[i] = p.x
		py[i] = p.y
		if not p.interacts.is_empty():
			_apply_interacts(p)
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


func _apply_interacts(p: HostPlayer) -> void:
	var pending := p.interacts
	p.interacts = []
	for press in pending:
		if interact_validator.validate(p.id, press[0], press[1], p.x, p.y) and on_interact.is_valid():
			on_interact.call(p.id, press[1])


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
		"max_players": max_players,
		"refused_connections": refused_connections,
		"dropped_messages": dropped_messages,
		"budget_disconnects": budget_disconnects,
		"handshake_timeouts": handshake_timeouts,
		"suppressed_errors": suppressed_errors,
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
