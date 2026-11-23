class_name LobbyHost
extends RefCounted
## Godot-hosted lobby server (stack decision 2b), first cut for the 50-player
## load test. TCPServer + WebSocketPeer speaking proto/v1 through the
## godobuf codec. No MultiplayerAPI / RPCs.
##
## All players share ONE LocalSim (`sim`). Each tick the host feeds every
## player's newest accepted input with sim.apply_input(id, intent), at most
## once per player, then calls sim.step() once. Joins and leaves go through
## sim.add_player / sim.remove_player and take effect at the next step.
## Enemy bullets in the load test come from HostStandinBulletField, a
## labeled stand-in used only when emitter_count > 0 (set by --emitters). A
## normal lobby runs with emitter_count = 0.
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
## Stand-in hp pool for HostStandinBulletField hits (load test only).
const START_HP: int = 100
## Class for remote players until the host-lobby protocol carries one.
## TODO(host-lobby protocol PR): take the class from the joining client.
const DEFAULT_CLASS_ID := "thornguard"
## Hosted join state (docs/design/content-v0.1.md §1, phase 1). Applies to
## players the host verifies itself (the listen-host and local players):
## - first join this host session: ready (full Focus, cooldown 0);
## - rejoin with a snapshot: the saved cooldown minus the host ticks elapsed
##   (floor 0) and the saved Focus plus normal regen over them (capped);
## - a rejoin key with no snapshot (already used, dropped, or not issued by
##   this host): conservative, the ability on full cooldown and 0 Focus.
## Remote joins always start conservative until the handshake verifies an
## identity. Snapshots live as long as this host, at most this many (oldest
## dropped), and stop() clears them.
const MAX_ABILITY_STASH: int = 256
const CONSERVATIVE := {"conservative": true}
const _LOCAL_KEY_PREFIX := "local:"
## Each instance's sim allocates entity ids from its own block, so ids
## stay unique across instances (instance k starts at k * INSTANCE_ID_BLOCK).
const INSTANCE_ID_BLOCK: int = 1 << 40
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
## A portal entry the host refused (code is a proto ErrorCode).
signal portal_rejected(player_id: int, code: int, reason: String)


class HostConn:
	extends RefCounted
	var ws: WebSocketPeer
	var player: HostPlayer = null
	var opened_at_usec: int = 0
	var close_pending: bool = false
	var over_budget_ticks: int = 0
	var error_window_start: int = 0
	var errors_in_window: int = 0


## One world the host runs: the overworld (index 0) or a portal dungeon.
## Each has its own LocalSim, ticked once per host tick.
class HostInstance:
	extends RefCounted
	var index: int = 0
	var sim: LocalSim
	var dungeon_id: String = ""
	## "<source instance index>:<portal id>" for a dungeon, "" for the overworld.
	var portal_key: String = ""
	var seed: int = 0
	var m100: int = 100
	var arrival_x: float = 0.0
	var arrival_y: float = 0.0
	## Distinct players this instance may admit, locked at creation (vision §6 rule 5).
	var capacity: int = 0
	var admitted: Dictionary = {}  # lobby player id -> true
	func is_overworld() -> bool:
		return portal_key == ""


## Admission history outlives the running sim. A closed entrance id never
## creates a replacement instance while its source portal still exists.
class PortalRecord:
	extends RefCounted
	var source: HostInstance
	var portal_id: int
	var instance_id: int = 0
	var instance: HostInstance
	var admitted: Dictionary = {}  # lobby player id -> true; never shrinks
	var sim_ids: Dictionary = {}  # lobby player id -> id inside this instance
	## Opener ids as they were in the source world, and in the lobby.
	var opener_source_id: int = 0
	var opener_lobby_id: int = 0
	var capacity: int
	var created_tick: int
	var empty_since_tick: int = -1
	var cleared: bool = false
	var closed: bool = false


class HostPlayer:
	extends RefCounted
	## Lobby-wide player id (Welcome.player_id); the overworld sim uses it too.
	var id: int = 0
	## Instance this player is in, and their id inside that instance's sim.
	var instance: HostInstance = null
	var sim_id: int = 0
	var loadtest_spread: bool = false
	var seq: int = 0
	var move_x: float = 0.0
	var move_y: float = 0.0
	var aim: float = 0.0
	var fire_held: bool = false
	## Interact presses received since the last tick: [seq, target_id] pairs,
	## in arrival order. Bounded by the per-tick message budget.
	var interacts: Array[PackedInt64Array] = []
	## One-shot ability press from an accepted frame since the last tick.
	## Cleared after the tick it is applied in.
	var ability_pressed: bool = false
	## Interact target accepted by the validator this tick, handed to the
	## shared sim as InputIntent.interact_target_id (0 = none).
	var interact_forward: int = 0
	## Stand-in hp (HostStandinBulletField hits only; the sim keeps real hp).
	var hp: int = START_HP
	var join_tick: int = 0
	var x: float = 0.0
	var y: float = 0.0
	var aim_applied: float = 0.0
	## Hosted on this machine, no socket (add_local_player).
	var is_local: bool = false
	var character: Variant = null
	## Class handed to the shared sim at join.
	var class_id: String = ""
	## True once a sim step has run with this player in it.
	var in_sim: bool = false
	## Ability state to apply right after the step that adds this player:
	## {"cooldown": int, "focus": float} for a matched identity, CONSERVATIVE
	## otherwise; {} once applied.
	var restore_ability: Dictionary = {}
	var imported_character := PackedByteArray()


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
		# Same validation and settings_changed as apply_settings(); an invalid
		# value is refused and the current cap is kept.
		var s := _settings.duplicate_settings()
		s.max_players = v
		if apply_settings(s) != OK:
			push_warning("LobbyHost.max_players refused: %s" % ", ".join(s.validate()))
## Microsecond clock for deadlines and timeouts. Tests inject a fake.
var clock: Callable = Time.get_ticks_usec
## Validates interact presses (range, once per seq, known/allowed target).
var interact_validator := HostInteractValidator.new()
## Called as on_interact.call(player_id, target_id) for each accepted
## interact press, before the sim step. The default hands the target to the
## shared sim, which picks the bag up into that player's inventory.
var on_interact: Callable = Callable()
## The overworld's shared LocalSim (instances[0].sim).
var sim: LocalSim
## Every running instance; [0] is the overworld. Dungeon instances are
## created by portal transfers and torn down when empty.
var instances: Array[HostInstance] = []
## Load test only: spread joining remote players over this many dungeon
## instances (0 or 1 = everyone stays in the overworld).
var loadtest_instances: int = 0
const EMPTY_INSTANCE_CLOSE_TICKS: int = 60 * SimConstants.TICK_HZ
const ENTRANCE_LIFETIME_TICKS: int = 120 * SimConstants.TICK_HZ
var _portal_records: Dictionary = {}  # source instance / entrance -> PortalRecord
var _next_instance_index: int = 1
var _instance_by_portal: Dictionary = {}  # portal_key -> HostInstance
var portal_rejections: int = 0
var catalog: DataCatalog
## identity key -> {"id", "cooldown", "focus"} for players who left (bounded
## FIFO). Keys are host-verified identities, never raw player ids.
var _ability_stash: Dictionary = {}
var _ability_stash_order: Array[String] = []
var _builtin_taken: bool = false

# State
var tick: int = 0
var skipped_ticks: int = 0
var late_ticks: int = 0
var players: Array[HostPlayer] = []
var bullets: HostStandinBulletField
var enemy_hits: int = 0
var player_deaths: int = 0
var peak_players: int = 0
var peak_players_per_instance: Array = []
var last_snapshot_bytes: int = 0
var last_full_bytes: int = 0
# Connection-limit counters
var refused_connections: int = 0
var dropped_messages: int = 0
var budget_disconnects: int = 0
var handshake_timeouts: int = 0
var suppressed_errors: int = 0
## Ability presses handed to the sim (one per accepted pressed seq per tick).
var ability_presses: int = 0

var _settings := LobbySettings.new()
var _unsafe_max_players: int = 0
var _tcp := TCPServer.new()
var _conns: Array[HostConn] = []
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
	catalog = DataCatalog.load_default()
	sim = LocalSim.new(_config, 0.0, 0.0, catalog)
	# LocalSim starts with a solo player 1; the host owns the roster, so
	# drop it at the first step unless a host player 1 joins first.
	sim.remove_player(1)
	var ow := HostInstance.new()
	ow.index = 0
	ow.sim = sim
	instances.append(ow)
	_configure_sim()
	interact_validator.resolver = _resolve_bag
	on_interact = _forward_interact
	# Replaced in start(); lets a not-yet-listening host tick local players.
	bullets = HostStandinBulletField.new(instance_seed, 0, arena_size, arena_size)


func _configure_sim() -> void:
	sim.set_bounds(0.0, 0.0, arena_size, arena_size)
	sim.set_world_seed(instance_seed)
	sim.set_lobby_settings(_settings)


func start() -> Error:
	if _settings.join_code == "":
		_settings.join_code = LobbySettings.generate_join_code()
	bullets = HostStandinBulletField.new(instance_seed, emitter_count, arena_size, arena_size)
	_configure_sim()
	for i in range(loadtest_instances - 1):
		_create_loadtest_instance(i)
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
	for p in players:
		if p.instance != null:
			p.instance.sim.remove_player(p.sim_id)
	players.clear()
	instances.resize(1)
	_instance_by_portal.clear()
	_portal_records.clear()
	# The lobby is closing: saved ability states do not outlive it.
	_ability_stash.clear()
	_ability_stash_order.clear()
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
	for inst in instances:
		inst.sim.set_lobby_settings(_settings)
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
## `character` is passed to the shared sim: null (DEFAULT_CLASS_ID), a class
## id String, or a Dictionary {class_id, x?, y?, hp?}.
## No `rejoin_token` is a first join and starts ready. The token
## remove_local_player() returned gives the player their id back with the
## state they left with, adjusted for the host time since (see
## MAX_ABILITY_STASH). Any other token (already used, dropped, or not issued
## here) starts conservative.
func add_local_player(character: Variant = null, rejoin_token: String = "") -> int:
	if players.size() >= max_players:
		return -1
	# Local players are verified by the host itself: no token is a first join
	# (ready); a token is a rejoin and only its snapshot can restore state.
	var p: HostPlayer
	if rejoin_token == "":
		p = _add_player(character, "", true)
	else:
		p = _add_player(character, _LOCAL_KEY_PREFIX + rejoin_token)
	p.is_local = true
	return p.id


## Queues a local player's input for the next tick. Same rules as a remote
## InputFrame (applied once per seq, interacts go through the validator), but
## no socket and no message budget.
func submit_local_input(player_id: int, intent: InputIntent) -> void:
	var p := _find_player(player_id)
	if p == null or not p.is_local or intent == null:
		return
	_queue_input(p, intent.seq, intent.move_x, intent.move_y, intent.aim, intent.fire_held,
			intent.interact_target_id, intent.ability_pressed)


## Removes a local player. Returns a host-issued rejoin token (random, single
## use) for add_local_player(), or "" if the player is unknown.
func remove_local_player(player_id: int) -> String:
	var p := _find_player(player_id)
	if p == null or not p.is_local:
		return ""
	var token := Crypto.new().generate_random_bytes(16).hex_encode()
	_leave(p, _LOCAL_KEY_PREFIX + token)
	return token


## Read-only view for one player after the last tick: the shared sim's
## world_view(player_id), copied field by field, so it carries everyone in
## `players` but only this player's own bags, inventory and HUD state. Adds
## the stand-in bullets when the load test runs them. Null if the player is
## unknown or not in the sim yet (joins apply at the next step).
func world_view(player_id: int) -> WorldSnapshot:
	var p := _find_player(player_id)
	if p == null or not p.in_sim or p.instance == null or p.instance.sim.get_player(p.sim_id) == null:
		return null
	var v := copy_snapshot(p.instance.sim.world_view(p.sim_id))
	# LocalSim scopes this already; explicitly retain only this viewer's
	# current-instance live bags, never bags from a previous world.
	var own: Array[GroundDrop] = []
	for bag in v.ground_drops:
		if bag.item != null and bag.item.state == ItemState.STATE_LIVE and bag.item.owner_player_id == p.sim_id:
			own.append(bag)
	v.ground_drops = own
	v.player_id = p.id
	if not p.instance.is_overworld():
		return v  # stand-in bullets are an overworld load-test aid
	if bullets != null and bullets.b_count > 0:
		# Stand-in hits are host-side; show host hp and the stand-in bullets
		# in the sim's time base.
		v.player_hp = p.hp
		v.player_max_hp = START_HP
		var offset: int = tick - v.tick
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
	return v


## Copies every script variable of a WorldSnapshot. Arrays are duplicated
## (shallow), so fields added to WorldSnapshot later come along unchanged.
static func copy_snapshot(src: WorldSnapshot) -> WorldSnapshot:
	var dst := WorldSnapshot.new()
	for prop in src.get_property_list():
		if prop["usage"] & PROPERTY_USAGE_SCRIPT_VARIABLE == 0:
			continue
		var name: StringName = prop["name"]
		var val: Variant = src.get(name)
		if val is Array:
			val = (val as Array).duplicate()
		dst.set(name, val)
	return dst


## Checks an imported character against the lobby's import flags. Called only
## when a player imports, never at Hello. Returns an ImportResult constant.
## Blob format and signature are a stub for now:
## "ERC" + version byte (1) + flags byte (bit 0 = played offline) + payload.
## Fails closed: a blob whose signature has not been verified is rejected
## with REJECTED_BAD_SIGNATURE, after the flag and format checks. Today that is
## every blob, because verification is not implemented yet.
## TODO(host-lobby protocol PR): real character format and signature check.
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
	if blob[n + 1] & IMPORT_FLAG_PLAYED_OFFLINE != 0 and not _settings.offline_allowed:
		return ImportResult.REJECTED_OFFLINE_OFF
	if not _signature_verified(blob):
		return ImportResult.REJECTED_BAD_SIGNATURE
	if not p.imported_character.is_empty():
		return ImportResult.REJECTED_ALREADY_EXISTS
	p.imported_character = blob
	return ImportResult.IMPORT_RESULT_OK


## True only when the blob's signature has actually been verified.
## TODO(host-lobby protocol PR): implement. Until then nothing verifies, so
## import_character never returns IMPORT_RESULT_OK.
func _signature_verified(_blob: PackedByteArray) -> bool:
	return false


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
		if players.size() == peak_players and _n % 20 == 0:
			peak_players_per_instance = _players_per_instance()
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
				f.get_fire_held(), f.get_interact_target_id(), f.get_ability_pressed())
	elif c.player != null and (msg.has_open_portal() or msg.has_join_instance() \
			or msg.has_list_instances() or msg.has_leave_instance()):
		# Portals are not part of this load-test host yet.
		_send_error(c, PB.ErrorCode.ERROR_CODE_UNSPECIFIED, "portals are not supported by the Godot host yet")


## Shared by remote InputFrames and submit_local_input: applied once per seq,
## interact presses queued for the validator on the next tick.
func _queue_input(p: HostPlayer, seq: int, mx: float, my: float, aim: float, fire: bool, target: int,
		ability: bool = false) -> void:
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
	if ability:
		# Not resent by clients; a later frame in the same tick keeps it.
		p.ability_pressed = true
	_inputs_this_tick += 1


static func _finite_or_zero(v: float) -> float:
	return v if is_finite(v) else 0.0


## `identity` is a host-verified key ("" = none) whose snapshot, if stored,
## is restored. Without one the player starts ready only if `ready_if_new`
## (a host-verified first join), otherwise conservative.
## TODO(handshake PR, #50): Hello carries no verifiable identity yet, so
## remote joins pass "" and always start conservative. The remote key must be
## an identity the host has verified in the handshake, never an id or
## character the client merely claims.
func _add_player(character: Variant = null, identity: String = "", ready_if_new: bool = false) -> HostPlayer:
	var p := HostPlayer.new()
	p.restore_ability = {} if ready_if_new else CONSERVATIVE
	# Ids come from the sim's one entity allocator, so a player id never
	# collides with an enemy, projectile or bag (or a sim-only player such
	# as LocalSim.place_ally, which never counts toward max_players).
	var saved: Dictionary = _ability_stash.get(identity, {}) if identity != "" else {}
	if not saved.is_empty() and _find_player(int(saved["id"])) == null:
		_ability_stash.erase(identity)
		_ability_stash_order.erase(identity)
		p.id = int(saved["id"])
		p.restore_ability = {"cooldown": int(saved["cooldown"]), "focus": float(saved["focus"]),
				"left_tick": int(saved["left_tick"])}
	elif _sim_has_builtin_player():
		p.id = 1  # reuse LocalSim's built-in player 1 before the first step
		_builtin_taken = true
	else:
		p.id = sim.alloc_player_id()
	p.instance = instances[0]  # every join lands in the overworld
	p.sim_id = p.id
	# Spread spawns over the arena deterministically by id.
	var a: float = float(p.id) * 2.399963
	var r: float = arena_size * 0.35 * sqrt(float(p.id % 50) / 50.0)
	var rec := _sim_character(character, arena_size * 0.5 + cos(a) * r, arena_size * 0.5 + sin(a) * r)
	p.character = character
	p.class_id = String(rec["class_id"])
	p.x = float(rec["x"])
	p.y = float(rec["y"])
	if sim.get_player(p.id) != null:
		# Still in the sim (built-in player 1, or a leave not yet stepped):
		# add_player cancels the pending removal; set it up in place.
		sim.add_player(p.id)
		sim.place_player(p.id, p.x, p.y, int(rec["hp"]) if rec.has("hp") else -1)
		sim.set_player_class_for(p.id, p.class_id)
		_restore_ability(p)
	else:
		sim.add_player(p.id, rec)
	p.join_tick = tick
	players.append(p)
	return p


## LocalSim spawns a solo player 1; it stays in the sim (pending removal)
## until the first step unless a host player takes it over.
func _sim_has_builtin_player() -> bool:
	return not _builtin_taken and sim.tick() == 0 and sim.get_player(1) != null


## Removes a host player from the lobby and the sim. With a host-verified
## identity, saves their ability state under it for a later rejoin.
func _leave(p: HostPlayer, identity: String = "") -> void:
	interact_validator.forget_player(p.id)
	if identity != "":
		var isim: LocalSim = p.instance.sim
		var sid: int = p.sim_id
		var saved: Dictionary = p.restore_ability
		if saved.is_empty() and isim.get_player(sid) != null:
			saved = {"cooldown": isim.ability_cooldown_ticks(sid), "focus": isim.focus(sid), "left_tick": tick}
		elif saved.has("conservative") and isim.get_player(sid) != null:
			# Left before the conservative start was applied: keep it that way.
			saved = {"cooldown": isim.world_view(sid).ability_cooldown_max, "focus": 0.0, "left_tick": tick}
		if saved.has("cooldown"):
			# A pending restore that was never applied keeps its own left_tick.
			_stash_ability(identity, {"id": p.id, "cooldown": saved["cooldown"], "focus": saved["focus"],
					"left_tick": saved["left_tick"]})
	p.instance.sim.remove_player(p.sim_id)
	players.erase(p)


func _stash_ability(key: String, saved: Dictionary) -> void:
	if _ability_stash.has(key):
		_ability_stash_order.erase(key)
	_ability_stash[key] = saved
	_ability_stash_order.append(key)
	while _ability_stash_order.size() > MAX_ABILITY_STASH:
		_ability_stash.erase(_ability_stash_order.pop_front())


## Applies p.restore_ability: a snapshot adjusted for the host ticks since
## it was taken, or CONSERVATIVE (full cooldown for the player's ability,
## 0 Focus). {} (a ready first join) leaves the sim's fresh state.
func _restore_ability(p: HostPlayer) -> void:
	var saved := p.restore_ability
	p.restore_ability = {}
	var isim: LocalSim = p.instance.sim
	var sid: int = p.sim_id
	if saved.has("cooldown"):
		var elapsed: int = maxi(0, tick - int(saved["left_tick"]))
		isim.set_ability_cooldown_ticks(sid, maxi(0, int(saved["cooldown"]) - elapsed))
		# Normal regen over the elapsed host time; set_focus caps at max Focus.
		var regen: float = isim.focus_regen_per_s(sid) * float(elapsed) * SimConstants.TICK_DT
		isim.set_focus(sid, float(saved["focus"]) + regen)
	elif saved.has("conservative"):
		isim.set_ability_cooldown_ticks(sid, isim.world_view(sid).ability_cooldown_max)
		isim.set_focus(sid, 0.0)


## Number of saved ability states (bounded by MAX_ABILITY_STASH).
func ability_stash_size() -> int:
	return _ability_stash.size()


## Character record for LocalSim.add_player: class (default for remote and
## null), spawn position unless the caller gave one, optional hp.
static func _sim_character(character: Variant, spawn_x: float, spawn_y: float) -> Dictionary:
	var rec := {"class_id": DEFAULT_CLASS_ID, "x": spawn_x, "y": spawn_y}
	if character is String and String(character) != "":
		rec["class_id"] = String(character)
	elif character is Dictionary:
		var d: Dictionary = character
		for k in d:
			rec[k] = d[k]
		if d.has("class") and not d.has("class_id"):
			rec["class_id"] = String(d["class"])
		rec.erase("class")
	return rec


func _drop_player(c: HostConn) -> void:
	if c.player == null:
		return
	# No verified identity on remote joins yet (see _add_player).
	_leave(c.player)
	c.player = null


## Feeds every player's newest accepted input to the sim of the instance
## they are in (once per player), steps every instance once, applies portal
## transfers, then the stand-in bullets. Returns new player shots as
## [owner, host_spawn_tick, x, y, angle].
func _step_sim() -> Array[PackedFloat64Array]:
	_sync_portal_records()
	for p in players:
		var psim: LocalSim = p.instance.sim
		var sp := psim.get_player(p.sim_id)
		if sp == null:
			continue  # joins next step; keep one-shots for then
		if not p.interacts.is_empty():
			_apply_interacts(p, sp)
		var intent := InputIntent.from_raw(p.seq, p.move_x, p.move_y, p.aim, p.fire_held)
		intent.interact_target_id = p.interact_forward
		p.interact_forward = 0
		if p.ability_pressed:
			ability_presses += 1
			intent.ability_pressed = true
			p.ability_pressed = false  # one-shot
		psim.apply_input(p.sim_id, intent)
	var stepped: Array[HostInstance] = instances.duplicate()
	for inst in stepped:
		inst.sim.step()
	var shots: Array[PackedFloat64Array] = []
	for inst in stepped:
		var done: int = inst.sim.tick()
		# Read-only walk of the sim's live shots (load-test projection and
		# stand-in emitter hits); avoids building a full world_view per tick.
		for shot in inst.sim.projectiles():
			if shot.spawn_tick == done - 1:
				shots.append(PackedFloat64Array([float(_lobby_id(inst, shot.owner_id)), float(tick),
						shot.origin_x, shot.origin_y, atan2(shot.dir_y, shot.dir_x)]))
			if inst.is_overworld() and bullets.emitters_x.size() > 0:
				_shot_vs_emitters(shot, done)
	for p in players:
		var sp := p.instance.sim.get_player(p.sim_id)
		if sp != null:
			p.in_sim = true
			if not p.restore_ability.is_empty():
				# Before any input of theirs is applied (see above).
				_restore_ability(p)
			p.x = sp.x
			p.y = sp.y
			p.aim_applied = sp.aim
	# Transfers queued during this step: the mover is rostered in the
	# destination now and first steps there next tick (one step per tick).
	for inst in stepped:
		for xfer in inst.sim.take_pending_transfers():
			_route_transfer(inst, xfer)
	if loadtest_instances > 1:
		_spread_loadtest_players()
	_teardown_empty_instances()
	# Stand-in bullets live in the overworld only.
	var ow: Array[HostPlayer] = []
	for p in players:
		if p.instance == instances[0]:
			ow.append(p)
	var n: int = ow.size()
	var px := PackedFloat64Array()
	var py := PackedFloat64Array()
	var hp := PackedInt32Array()
	px.resize(n)
	py.resize(n)
	hp.resize(n)
	for i in range(n):
		px[i] = ow[i].x
		py[i] = ow[i].y
		hp[i] = ow[i].hp
	bullets.step(tick, px, py, _config.player_radius_tiles, hp)
	for i in range(n):
		if hp[i] <= 0:
			player_deaths += 1
			hp[i] = START_HP
		ow[i].hp = hp[i]
	return shots


## Lobby id of the player with `sim_id` in `inst`, or sim_id if none.
func _lobby_id(inst: HostInstance, sim_id: int) -> int:
	if inst.is_overworld():
		return sim_id
	for p in players:
		if p.instance == inst and p.sim_id == sim_id:
			return p.id
	return sim_id


## Runs this tick's interact presses through the validator, using the
## player's position in their instance. Accepted presses go to on_interact.
func _apply_interacts(p: HostPlayer, sp: SimPlayerState) -> void:
	var pending := p.interacts
	p.interacts = []
	for press in pending:
		if interact_validator.validate(p.id, press[0], press[1], sp.x, sp.y) and on_interact.is_valid():
			on_interact.call(p.id, press[1])


## interact_validator.resolver: in the player's instance, a live bag they
## own or a portal they can use now (see _resolve_portal), as {"x", "y"};
## {} for anything else. The validator applies scaling.json's accept range.
func _resolve_bag(target_id: int, player_id: int) -> Dictionary:
	var p := _find_player(player_id)
	if p == null or p.instance == null:
		return {}
	var bag: GroundDrop = p.instance.sim.bag_by_id(target_id)
	if bag == null:
		return _resolve_portal(p, target_id)
	if bag.item == null or bag.item.state != ItemState.STATE_LIVE \
			or bag.item.owner_player_id != p.sim_id:
		return {}
	return {"x": bag.x, "y": bag.y}


## A live portal in the player's instance they can use: an exit, or an
## entrance whose M the lobby allows, whose join floor they meet and whose
## instance still has room for them (refusals are reported to the player).
func _resolve_portal(p: HostPlayer, target_id: int) -> Dictionary:
	var portal: PortalSnapshot = p.instance.sim.portal_by_id(target_id)
	if portal == null or not portal.is_interactable():
		return {}
	if portal.kind == PortalSnapshot.KIND_ENTER:
		var refusal := _enter_refusal(p, portal)
		if String(refusal[1]) != "":
			_reject_portal(p, int(refusal[0]), String(refusal[1]))
			return {}
	return {"x": portal.x, "y": portal.y}


## [code, reason] for why `p` may not enter `portal` now; reason "" if they may.
func _enter_refusal(p: HostPlayer, portal: PortalSnapshot) -> Array:
	var psim: LocalSim = p.instance.sim
	if not is_m100_allowed(portal.m100) or not psim.m100_allowed(portal.m100):
		return [PB.ErrorCode.MULTIPLIER_NOT_ALLOWED, "portal multiplier is not allowed in this lobby"]
	var sp := psim.get_player(p.sim_id)
	var sc := psim.scaling()
	if sp == null or sc == null or sc.below_join_floor(sp.level, portal.content_level):
		return [PB.ErrorCode.ERROR_CODE_UNSPECIFIED, "level is below this portal's join floor"]
	return _record_refusal(_record_for(p.instance, portal.id), p.id)


## Packed scaling.json lifetime when present; otherwise vision §6.1's 120 s.
func _entrance_lifetime_ticks(record: PortalRecord) -> int:
	var sc := record.source.sim.scaling()
	if sc != null and sc.portal_entrance_lifetime_ticks > 0:
		return sc.portal_entrance_lifetime_ticks
	return ENTRANCE_LIFETIME_TICKS


func _record_for(source: HostInstance, portal_id: int) -> PortalRecord:
	var key := _portal_key(source, portal_id)
	if not _portal_records.has(key):
		var record := PortalRecord.new()
		record.source = source
		record.portal_id = portal_id
		record.capacity = _settings.max_players
		record.created_tick = tick
		_portal_records[key] = record
	return _portal_records[key]


func _sync_portal_records() -> void:
	for inst in instances:
		for portal in inst.sim.portals():
			if portal.kind == PortalSnapshot.KIND_ENTER:
				_record_for(inst, portal.id)


func _record_refusal(record: PortalRecord, player_id: int) -> Array:
	if record.closed:
		return [PB.ErrorCode.INSTANCE_NOT_FOUND, "portal entrance is closed"]
	if not record.admitted.has(player_id):
		if record.admitted.size() >= record.capacity:
			return [PB.ErrorCode.INSTANCE_FULL, "portal instance is full"]
		if tick - record.created_tick >= _entrance_lifetime_ticks(record):
			return [PB.ErrorCode.INSTANCE_NOT_FOUND, "portal entrance is closed"]
	return [0, ""]


func _portal_key(source: HostInstance, portal_id: int) -> String:
	return "%d:%d" % [source.index, portal_id]


## Tells the player (remote: an Error message) and the host (signal) why a
## portal entry was refused.
func _reject_portal(p: HostPlayer, code: int, reason: String) -> void:
	portal_rejections += 1
	portal_rejected.emit(p.id, code, reason)
	for c in _conns:
		if c.player == p:
			_send_error(c, code, reason)
			return


## Applies one transfer queued by `source`'s sim: enter creates (or joins)
## the portal's dungeon instance; exit returns to the overworld.
func _route_transfer(source: HostInstance, xfer: PortalTransfer) -> void:
	var p: HostPlayer = null
	for q in players:
		if q.instance == source and q.sim_id == xfer.player_id:
			p = q
			break
	if p == null:
		return  # left during the step
	if xfer.kind == PortalTransfer.KIND_EXIT:
		# TODO(portal lifetime): Hearth routing, seal and re-entry rules;
		# for now an exit returns to the overworld.
		_move_player(p, instances[0], p.id, xfer.arrival_x, xfer.arrival_y)
		return
	if not is_m100_allowed(xfer.m100) or not source.sim.m100_allowed(xfer.m100):
		_reject_portal(p, PB.ErrorCode.MULTIPLIER_NOT_ALLOWED, "portal multiplier is not allowed in this lobby")
		return
	if source.sim.portal_by_id(xfer.portal_id) == null:
		_reject_portal(p, PB.ErrorCode.INSTANCE_NOT_FOUND, "portal entrance not found")
		return
	var key := _portal_key(source, xfer.portal_id)
	var record := _record_for(source, xfer.portal_id)
	var refusal := _record_refusal(record, p.id)
	if String(refusal[1]) != "":
		_reject_portal(p, int(refusal[0]), String(refusal[1]))
		return
	var dest: HostInstance = record.instance
	if dest == null:
		# A record with an assigned id is never restarted after closure.
		if record.instance_id != 0:
			_reject_portal(p, PB.ErrorCode.INSTANCE_NOT_FOUND, "portal instance is closed")
			return
		# The opener as they are in the source world (the sim that queued
		# this transfer), never an id from the new instance.
		xfer.opener_id = p.sim_id
		record.opener_source_id = p.sim_id
		record.opener_lobby_id = p.id
		dest = _create_dungeon_instance(xfer)
		if dest == null:
			_reject_portal(p, PB.ErrorCode.INSTANCE_NOT_FOUND, "dungeon unavailable or instance id space exhausted")
			return
		dest.portal_key = key
		dest.capacity = record.capacity
		dest.admitted = record.admitted
		record.instance = dest
		record.instance_id = dest.index
		_instance_by_portal[key] = dest
	record.admitted[p.id] = true
	record.empty_since_tick = -1
	# Re-entry keeps the player's id in this instance (and their bags there).
	if not record.sim_ids.has(p.id):
		record.sim_ids[p.id] = dest.sim.alloc_player_id()
	_move_player(p, dest, int(record.sim_ids[p.id]), dest.arrival_x, dest.arrival_y)


## A new dungeon instance with its own LocalSim, seed and multiplier (locked
## from the transfer at creation), its own entity id block, and capacity
## locked to the lobby's current max players.
func _create_dungeon_instance(xfer: PortalTransfer) -> HostInstance:
	var def: DungeonDef = catalog.dungeon(xfer.dungeon_id) if catalog != null else null
	if def == null:
		return null
	# Check the quotient before multiplication: no signed overflow can
	# wrap the block start into another instance's entity range.
	if _next_instance_index <= 0 or _next_instance_index >= LocalSim.MAX_ENTITY_ID / INSTANCE_ID_BLOCK:
		return null
	var inst := HostInstance.new()
	inst.index = _next_instance_index
	_next_instance_index += 1
	inst.dungeon_id = xfer.dungeon_id
	inst.seed = xfer.seed
	inst.m100 = xfer.m100
	inst.arrival_x = xfer.arrival_x
	inst.arrival_y = xfer.arrival_y
	inst.capacity = _settings.max_players
	var dsim := LocalSim.new(_config, xfer.arrival_x, xfer.arrival_y, catalog)
	dsim.remove_player(1)  # the built-in player; gone at the first step
	if not dsim.set_id_floor(inst.index * INSTANCE_ID_BLOCK):
		return null
	dsim.set_lobby_settings(_settings)
	# opener_id is the opener's sim id in the SOURCE world, not the
	# destination id allocated later. Preserve that creation provenance.
	dsim.configure_dungeon(def, xfer.seed, xfer.m100, xfer.base_level, xfer.content_level,
			xfer.opener_id, xfer.opener_lp)
	inst.sim = dsim
	instances.append(inst)
	return inst


## Moves `p` into `dest` as `dest_id` at (x, y), carrying class, level,
## inventory, HP and ability state (Focus and cooldown exactly as they are,
## never refreshed). Removal from the old sim takes effect at its next step.
func _move_player(p: HostPlayer, dest: HostInstance, dest_id: int, x: float, y: float) -> void:
	var src: LocalSim = p.instance.sim
	var from := src.get_player(p.sim_id)
	if from == null or dest == p.instance:
		return
	var carry := PlayerCarry.from_sim(from, src.ability_state(p.sim_id))
	carry.player_id = dest_id
	dest.sim.place_player(dest_id, x, y)
	dest.sim.apply_carried_player(carry, x, y)
	src.remove_player(p.sim_id)
	p.instance = dest
	p.sim_id = dest_id
	p.x = x
	p.y = y
	p.interacts = []
	p.interact_forward = 0


## Instance lifetime follows vision §6.1: keep progress while empty,
## then retire the entrance and sim together after the empty grace period.
func _teardown_empty_instances() -> void:
	for record: PortalRecord in _portal_records.values():
		var inst := record.instance
		if inst == null:
			continue
		# TODO(#54): read boss_defeated() / dungeon_state() once they exist;
		# cleared is recorded for deposits and later lifetime rules.
		if inst.sim.has_method("boss_defeated"):
			record.cleared = record.cleared or bool(inst.sim.call("boss_defeated"))
		var used := false
		for p in players:
			if p.instance == inst:
				used = true
				break
		if used:
			record.empty_since_tick = -1
			continue
		if record.empty_since_tick < 0:
			record.empty_since_tick = tick
		if tick - record.empty_since_tick < EMPTY_INSTANCE_CLOSE_TICKS:
			continue
		record.closed = true
		record.instance = null
		instances.erase(inst)
		_instance_by_portal.erase(inst.portal_key)
	# Records persist even when a sim is retired, while its source entrance
	# remains. Never remove a tombstone simply because its instance is empty.
	for key in _portal_records.keys():
		var record: PortalRecord = _portal_records[key]
		if record.closed and record.source.sim.portal_by_id(record.portal_id) == null:
			_portal_records.erase(key)


## Load test only: a dungeon instance remote players are spread over.
func _create_loadtest_instance(i: int) -> void:
	var xfer := PortalTransfer.new()
	xfer.dungeon_id = "hollowmere_vault"
	xfer.seed = instance_seed + 1 + i
	xfer.m100 = 100
	xfer.base_level = 1
	xfer.content_level = 1
	var def: DungeonDef = catalog.dungeon(xfer.dungeon_id) if catalog != null else null
	if def != null:
		var at: Vector2 = def.arrival_point()
		xfer.arrival_x = at.x
		xfer.arrival_y = at.y
	var inst := _create_dungeon_instance(xfer)
	if inst != null:
		inst.portal_key = "loadtest:%d" % i
		inst.capacity = 1 << 30
		_instance_by_portal[inst.portal_key] = inst


## Load test only: remote players in the overworld sim are spread by id
## over the overworld and the load-test instances, once each.
func _spread_loadtest_players() -> void:
	var targets: Array[HostInstance] = [instances[0]]
	for i in range(loadtest_instances - 1):
		var inst: HostInstance = _instance_by_portal.get("loadtest:%d" % i)
		if inst != null:
			targets.append(inst)
	for p in players:
		if p.is_local or not p.in_sim or p.instance != instances[0] or p.loadtest_spread:
			continue
		p.loadtest_spread = true
		var dest: HostInstance = targets[p.id % targets.size()]
		if dest != instances[0]:
			_move_player(p, dest, dest.sim.alloc_player_id(), dest.arrival_x, dest.arrival_y)


## Default on_interact: the sim applies the pickup in this tick's step.
func _forward_interact(player_id: int, target_id: int) -> void:
	var p := _find_player(player_id)
	if p != null:
		p.interact_forward = target_id


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
	return _encode_snapshot_for([])


## Snapshot of one instance (default: the overworld) with the given bags
## (one viewer's own). Every viewer there without bags gets the same bytes.
func _encode_snapshot_for(bags: Array, inst: HostInstance = null, owner_id: int = -1) -> PackedByteArray:
	if inst == null:
		inst = instances[0]
	var msg = PB.ServerMessage.new()
	var s = msg.new_snapshot()
	s.set_tick(tick)
	for p in players:
		if p.instance != inst:
			continue
		var stub = s.add_players()
		stub.set_id(p.id)
		stub.set_applied_seq(p.seq)
	for bag in bags:
		if not inst.sim.ground_drops().has(bag):
			continue
		var b = s.add_bags()
		b.set_id((bag as GroundDrop).id)
		b.set_x(bag.x)
		b.set_y(bag.y)
		b.set_owner_player_id(owner_id if owner_id >= 0 else bag.item.owner_player_id)
		b.set_t_star(maxi(bag.t_star, 0))
		b.set_spawn_tick(maxi(bag.spawn_tick, 0))
	return msg.to_bytes()


## Live bags in every instance, grouped by owner's lobby id:
## owner_id -> Array[GroundDrop].
func _bags_by_owner() -> Dictionary:
	var out := {}
	for inst in instances:
		for bag in inst.sim.ground_drops():
			if bag.item == null or bag.item.state != ItemState.STATE_LIVE:
				continue
			var owner: int = _lobby_id(inst, bag.item.owner_player_id)
			var viewer := _find_player(owner)
			if viewer == null or viewer.instance != inst or viewer.sim_id != bag.item.owner_player_id:
				continue
			if not out.has(owner):
				out[owner] = []
			out[owner].append(bag)
	return out


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


## Sends each viewer their instance's Snapshot (`bytes` is the overworld's),
## or a per-viewer one carrying only that viewer's own bags.
func _send(bytes: PackedByteArray) -> int:
	var sent: int = 0
	var bags := _bags_by_owner()
	var by_instance := {instances[0]: bytes}
	for c in _conns:
		if c.player == null or c.ws.get_ready_state() != WebSocketPeer.STATE_OPEN:
			continue
		var inst: HostInstance = c.player.instance
		if not by_instance.has(inst):
			by_instance[inst] = _encode_snapshot_for([], inst)
		var out: PackedByteArray = by_instance[inst]
		if bags.has(c.player.id):
			out = _encode_snapshot_for(bags[c.player.id], inst, c.player.id)
		if c.ws.put_packet(out) == OK:
			sent += 1
		c.ws.poll()  # flush now instead of 50 ms later
	return sent


func _players_per_instance() -> Array:
	var out: Array = []
	for inst in instances:
		var n := 0
		for p in players:
			if p.instance == inst:
				n += 1
		out.append(n)
	return out


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
		"peak_players_per_instance": peak_players_per_instance,
		"portal_rejections": portal_rejections,
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
		"ability_presses": ability_presses,
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
