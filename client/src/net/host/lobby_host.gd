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
## Class for remote players until the host-lobby protocol carries one, and
## for a join that omits a class. Must exist in the packed class data; the
## host fails closed if it does not.
## TODO(host-lobby protocol PR): take the class from the joining client.
const DEFAULT_CLASS_ID := "thornguard"
## Hosted join state (docs/design/content-v0.1.md §1, phase 1). Applies to
## players the host verifies itself (the listen-host and local players):
## - first join this host session: ready (full Focus, cooldown 0);
## - rejoin with a snapshot: the saved cooldown minus the host ticks elapsed
##   (floor 0) and the saved Focus plus normal regen over them (capped);
## - a rejoin key with no snapshot (already used, dropped, or not issued by
##   this host): conservative, the ability on full cooldown and 0 Focus.
## A local player who leaves before entering the sim leaves no snapshot
## (conservative rejoin), except the listen-host player on the built-in
## player 1: it is in the sim before the first step, so a leave then
## snapshots its ready first-join state and the rejoin is ready.
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
	var last_instance_list_tick: int = -1000


## One world the host runs: the overworld (index 0) or a portal dungeon.
## Each has its own LocalSim, ticked once per host tick.
class HostInstance:
	extends RefCounted
	enum Kind { WILDS, HEARTH, DUNGEON }
	var kind: Kind = Kind.WILDS
	## Stable lobby id -> sim id mapping for the public Hearth instance.
	var sim_ids: Dictionary = {}
	var index: int = 0
	var sim: LocalSim
	var dungeon_id: String = ""
	## "<source instance index>:<portal id>" for a dungeon, "" for the overworld.
	var portal_key: String = ""
	var seed: int = 0
	var m100: int = 100
	var grants_persistent: bool = false
	## The transfer this instance was created from (seed, M, B, E, opener),
	## so a reset rebuilds the same slice.
	var created_from: PortalTransfer = null
	var arrival_x: float = 0.0
	var arrival_y: float = 0.0
	## Distinct players this instance may admit, locked at creation (vision §6 rule 5).
	var capacity: int = 0
	var admitted: Dictionary = {}  # lobby player id -> true
	func is_overworld() -> bool:
		return kind == Kind.WILDS
	func is_hearth() -> bool:
		return kind == Kind.HEARTH
	func is_dungeon() -> bool:
		return kind == Kind.DUNGEON


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
	## Persistent entrance: no admission expiry, one instance for the life
	## of the host (never closed or replaced), capacity counts occupants.
	var persistent: bool = false
	var grants_persistent: bool = false
	var reset_when_empty: bool = false


class HostPlayer:
	extends RefCounted
	## Lobby-wide player id (Welcome.player_id); the overworld sim uses it too.
	var id: int = 0
	## Instance this player is in, and their id inside that instance's sim.
	var instance: HostInstance = null
	var sim_id: int = 0
	var loadtest_spread: bool = false
	var progression_entries: Array[Dictionary] = []
	var restore_progression: Dictionary = {}
	## HP of the body this rejoin continues (-1 = none kept).
	var restore_hp: int = -1
	var seq: int = 0
	## Last seq handed to LocalSim.apply_input. rule 7 activity tracks
	## received input frames: is_new_frame is true only when seq advanced
	## since the last step.
	var fed_seq: int = 0
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
	## vision §7.3 disconnect linger: >= 0 while the body stays in its
	## instance after the player left (no input; it can still be hit and
	## die). The seat and id stay held until then.
	var linger_until_tick: int = -1
	## Rejoin key saved at the leave ("" = none), for the linger's end.
	var linger_identity: String = ""
	func is_lingering() -> bool:
		return linger_until_tick >= 0
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
## Load test only: open the practice door plus N normal overworld entrances.
var loadtest_entrances: int = 0
## Load test only: admit each remote player to a distinct subset of them.
var loadtest_distinct_admitted: bool = false
var _loadtest_admitted: Dictionary = {}  # lobby player id -> true
const LINGER_TICKS: int = 5 * SimConstants.TICK_HZ
const EMPTY_INSTANCE_CLOSE_TICKS: int = 60 * SimConstants.TICK_HZ
const ENTRANCE_LIFETIME_TICKS: int = 120 * SimConstants.TICK_HZ
var _portal_records: Dictionary = {}  # source instance / entrance -> PortalRecord
var _next_instance_index: int = 1
var hearth: HostInstance
var _wilds_gate_id: int = 0
var _hearth_gate_id: int = 0
const GATE_RADIUS := 1.0
const HEARTH_SIZE := 16.0
const HEARTH_GATE := Vector2(8.0, 2.0)
const HEARTH_ARRIVAL := Vector2(8.0, 4.0)
var _instance_by_portal: Dictionary = {}  # portal_key -> HostInstance
var portal_rejections: int = 0
var catalog: DataCatalog
## identity key -> {"id", "cooldown", "focus"} for players who left (bounded
## FIFO). Keys are host-verified identities, never raw player ids.
var _ability_stash: Dictionary = {}
var _ability_stash_order: Array[String] = []
## Overworld player ids this host issued that are still in use: a player in
## the lobby or a rejoin snapshot. Only these are ever re-added. Bounded by
## the lobby plus MAX_ABILITY_STASH; pruned on leave, eviction and stop().
var _issued_player_ids: Dictionary = {}
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
## Bytes actually sent per viewer (shared body plus that viewer's fields).
var st_viewer_bytes_sum: int = 0
var st_viewer_packets: int = 0
var st_viewer_bytes_max: int = 0
var _tick_viewer_bytes: int = 0
var _tick_viewer_bytes_max: int = 0
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
	ow.grants_persistent = true  # the overworld keeps what players earn
	instances.append(ow)
	_configure_sim()
	_create_hearth()
	interact_validator.resolver = _resolve_bag
	on_interact = _forward_interact
	# Replaced in start(); lets a not-yet-listening host tick local players.
	bullets = HostStandinBulletField.new(instance_seed, 0, arena_size, arena_size)


func _configure_sim() -> void:
	sim.set_bounds(0.0, 0.0, arena_size, arena_size)
	sim.set_world_seed(instance_seed)
	sim.set_lobby_settings(_settings)
	if _wilds_gate_id != 0:
		var gate := sim.portal_by_id(_wilds_gate_id)
		gate.x = arena_size * 0.5
		gate.y = arena_size - GATE_RADIUS


## A permanent safe zone, separate from both the Wilds and dungeon slices.
## No combat content is configured here. Automatic arrival paths and banking
## are separate follow-ups; only the gate and test hook enter it in this PR.
func _create_hearth() -> void:
	hearth = HostInstance.new()
	hearth.kind = HostInstance.Kind.HEARTH
	hearth.index = _next_instance_index
	_next_instance_index += 1
	hearth.grants_persistent = true
	hearth.sim = LocalSim.new(_config, HEARTH_ARRIVAL.x, HEARTH_ARRIVAL.y, catalog)
	hearth.sim.remove_player(1)
	hearth.sim.set_id_floor(hearth.index * INSTANCE_ID_BLOCK)
	hearth.sim.configure_zone(LocalSim.ZONE_HEARTH)
	hearth.sim.set_bounds(0.0, 0.0, HEARTH_SIZE, HEARTH_SIZE)
	hearth.sim.set_lobby_settings(_settings)
	# The Wilds gate id is taken from the top of the overworld id block so it
	# never shifts the shared allocator that issues lobby player ids.
	_wilds_gate_id = _add_zone_gate(sim, Vector2(arena_size * 0.5, arena_size - GATE_RADIUS), INSTANCE_ID_BLOCK - 1)
	_hearth_gate_id = _add_zone_gate(hearth.sim, HEARTH_GATE, hearth.sim.alloc_player_id())


## Dungeons and the Wilds stay in `instances` (index order, teardown and
## load-test spread); the permanent Hearth is stepped and listed with them.
func _all_instances() -> Array[HostInstance]:
	var out: Array[HostInstance] = instances.duplicate()
	if hearth != null:
		out.append(hearth)
	return out


static func _add_zone_gate(psim: LocalSim, at: Vector2, id: int) -> int:
	var gate := PortalSnapshot.new()
	gate.id = id
	gate.x = at.x
	gate.y = at.y
	gate.radius = GATE_RADIUS
	# Reuse the public EXIT shape; host routing distinguishes this exact
	# portal id and source instance. No protocol or dungeon admission change.
	gate.kind = PortalSnapshot.KIND_EXIT
	gate.persistent = true
	gate.grants_persistent = true
	psim.add_portal(gate)
	return gate.id


## Test hook: arrivals used by joins, deaths, exits and class changes have
## intentionally not been changed yet.
func place_in_hearth_for_test(player_id: int) -> bool:
	var p := _find_player(player_id)
	return p != null and not p.is_lingering() and _enter_hearth(p)


func _enter_hearth(p: HostPlayer) -> bool:
	if p.instance == hearth:
		return false
	if not hearth.sim_ids.has(p.id):
		hearth.sim_ids[p.id] = hearth.sim.alloc_player_id()
	return _move_player(p, hearth, int(hearth.sim_ids[p.id]), HEARTH_ARRIVAL.x, HEARTH_ARRIVAL.y)


func _is_zone_gate(source: HostInstance, portal_id: int) -> bool:
	return (source.is_overworld() and portal_id == _wilds_gate_id) \
			or (source == hearth and portal_id == _hearth_gate_id)


func _walk_zone_gates() -> void:
	for p in players:
		if p.is_lingering() or not p.in_sim:
			continue
		var gate_id := _wilds_gate_id if p.instance.is_overworld() else _hearth_gate_id
		if not _is_zone_gate(p.instance, gate_id):
			continue
		var gate := p.instance.sim.portal_by_id(gate_id)
		var sp := p.instance.sim.get_player(p.sim_id)
		if gate == null or sp == null or sp.hp <= 0:
			continue
		if Vector2(sp.x, sp.y).distance_to(Vector2(gate.x, gate.y)) <= gate.radius:
			_cross_zone_gate(p)


func _cross_zone_gate(p: HostPlayer) -> void:
	if p.instance == hearth:
		# Arrive clear of the walk-through trigger, so it cannot bounce.
		_move_player(p, instances[0], p.id, arena_size * 0.5, arena_size - 3.0 * GATE_RADIUS)
	elif p.instance.is_overworld():
		_enter_hearth(p)


func start() -> Error:
	if _settings.join_code == "":
		_settings.join_code = LobbySettings.generate_join_code()
	bullets = HostStandinBulletField.new(instance_seed, emitter_count, arena_size, arena_size)
	_configure_sim()
	for i in range(loadtest_instances - 1):
		_create_loadtest_instance(i)
	if loadtest_entrances > 0:
		_open_loadtest_entrances()
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
	_issued_player_ids.clear()
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
	for inst in _all_instances():
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
## max_players. Returns the player id, or -1 if the lobby is full or the
## join is refused (an unknown or empty class, except the built-in player 1
## takeover, which uses the default).
## `character` is passed to the shared sim: null (DEFAULT_CLASS_ID), a class
## id String, or a Dictionary {class_id, x?, y?, hp?}.
## No `rejoin_token` is a first join and starts ready. The token
## remove_local_player() returned gives the player their id back with the
## state they left with, adjusted for the host time since (see
## MAX_ABILITY_STASH). Any other token (already used, dropped, or not issued
## here) starts conservative.
func add_local_player(character: Variant = null, rejoin_token: String = "") -> int:
	# A rejoin that resumes its own lingering body reuses that seat.
	if players.size() >= max_players and (rejoin_token == "" \
			or _lingering_for_identity(_LOCAL_KEY_PREFIX + rejoin_token) == null) \
			and not _free_seat_for_join():
		return -1
	# Local players are verified by the host itself: no token is a first join
	# (ready); a token is a rejoin and only its snapshot can restore state.
	var p: HostPlayer
	if rejoin_token == "":
		p = _add_player(character, "", true)
	else:
		p = _add_player(character, _LOCAL_KEY_PREFIX + rejoin_token)
	if p == null:
		return -1
	p.is_local = true
	return p.id


## Queues a local player's input for the next tick. Same rules as a remote
## InputFrame (applied once per seq, interacts go through the validator), but
## no socket and no message budget.
func submit_local_input(player_id: int, intent: InputIntent) -> void:
	var p := _find_player(player_id)
	if p == null or not p.is_local or p.is_lingering() or intent == null:
		return
	_queue_input(p, intent.seq, intent.move_x, intent.move_y, intent.aim, intent.fire_held,
			intent.interact_target_id, intent.ability_pressed)


## Removes a local player. Returns a host-issued rejoin token (random, single
## use) for add_local_player(), or "" if the player is unknown.
func remove_local_player(player_id: int) -> String:
	var p := _find_player(player_id)
	if p == null or not p.is_local or p.is_lingering():
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
	var shared := _encode_shared_snapshots()
	var snap_bytes: PackedByteArray = shared[instances[0]][1]
	var full_bytes := _encode_full(new_shots)
	var t3 := Time.get_ticks_usec()
	var sent := _send(shared)
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
		st_viewer_bytes_sum += _tick_viewer_bytes
		st_viewer_packets += sent
		st_viewer_bytes_max = maxi(st_viewer_bytes_max, _tick_viewer_bytes_max)
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
		if players.size() >= max_players and not _free_seat_for_join():
			# The Error always goes out: this connection closes right after.
			c.errors_in_window = 0
			_send_error(c, PB.ErrorCode.INSTANCE_FULL, "lobby is full")
			c.close_pending = true
			return
		c.player = _try_remote_join(c)
		if c.player == null:
			return
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
	elif c.player != null and msg.has_list_instances():
		# Listings are read-only and bounded to one per half-second per peer.
		if tick - c.last_instance_list_tick >= SimConstants.TICK_HZ / 2:
			c.last_instance_list_tick = tick
			c.ws.put_packet(_encode_instance_list(c.player))
	elif c.player != null and (msg.has_open_portal() or msg.has_join_instance() \
			or msg.has_leave_instance()):
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
	var takes_builtin := false
	# Ids come from the sim's one entity allocator, so a player id never
	# collides with an enemy, projectile or bag (or a sim-only player such
	# as LocalSim.place_ally, which never counts toward max_players).
	var saved: Dictionary = _ability_stash.get(identity, {}) if identity != "" else {}
	# The class stays with the character on every rejoin: no class change
	# while the body is lingering or held for a rejoin (there is no town or
	# Hearth sim yet, and the Wilds lock the class like a dungeon).
	var locked_class := _locked_class_for(identity, saved)
	if locked_class != "":
		var requested_class: Variant = _requested_class_id(character)
		if requested_class == null or String(requested_class) == "":
			character = _with_class(character, locked_class)
		elif String(requested_class) != locked_class:
			return null
	var resumed := _resume_lingering(identity, character)
	if resumed != null:
		return resumed
	var saved_unusable: bool = not saved.is_empty() and (
			not _stash_id_issued_here(saved) or _find_player(int(saved["id"])) != null)
	var saved_usable: bool = not saved.is_empty() and not saved_unusable
	# Class is checked before any id is issued or a seat is appended, and
	# before a snapshot is consumed.
	takes_builtin = not saved_usable and _sim_has_builtin_player()
	var class_id := _resolve_join_class(character, takes_builtin)
	if class_id == "":
		return null
	if saved_unusable:
		# Drop an unusable snapshot only once this join is going ahead.
		_ability_stash.erase(identity)
		_ability_stash_order.erase(identity)
		for id in _issued_player_ids.keys():
			_prune_issued_id(int(id))
		saved = {}  # no usable saved id: a fresh id, conservative
	if saved_usable:
		# Leave the snapshot in place until the sim accepts the seat.
		p.id = int(saved["id"])
		p.restore_progression = saved.get("progression", {})
		p.restore_hp = int(saved.get("hp", -1))
		p.restore_ability = {"cooldown": int(saved["cooldown"]), "focus": float(saved["focus"]),
				"left_tick": int(saved["left_tick"])}
	elif takes_builtin:
		p.id = 1  # reuse LocalSim's built-in player 1 before the first step
		_builtin_taken = true
	else:
		p.id = sim.alloc_player_id()
	_issued_player_ids[p.id] = true
	p.instance = instances[0]  # every join lands in the overworld
	p.sim_id = p.id
	# Spread spawns over the arena deterministically by id.
	var a: float = float(p.id) * 2.399963
	var r: float = arena_size * 0.35 * sqrt(float(p.id % 50) / 50.0)
	var rec := _sim_character(character, arena_size * 0.5 + cos(a) * r, arena_size * 0.5 + sin(a) * r)
	rec["class_id"] = class_id
	if p.restore_hp > 0:
		# A rejoin never comes back with more HP than the body left with.
		rec["hp"] = p.restore_hp
	p.character = character
	p.class_id = class_id
	p.x = float(rec["x"])
	p.y = float(rec["y"])
	var existing := sim.get_player(p.id)
	if existing != null:
		# Still in the sim (built-in player 1, or a leave not yet stepped):
		# place_player keeps them and cancels the pending removal. HP is set
		# only for a new spawn (the built-in player taken over at first
		# join); a player who never left the sim keeps the sim's HP.
		var new_spawn := takes_builtin
		# place_player is void today; call() still lets us honour a later
		# bool return without a parse error on the current signature.
		var placed: Variant = sim.call("place_player", p.id, p.x, p.y,
				int(rec["hp"]) if new_spawn and rec.has("hp") else -1)
		if placed == false or sim.get_player(p.id) == null:
			_rollback_seat(p, takes_builtin)
			return null
		_sync_position(p, sim, p.id)
		if new_spawn:
			sim.set_player_class_for(p.id, p.class_id)
		else:
			# A body still in the sim keeps its class, HP and ability state
			# (the class was locked above, before any seat was taken).
			p.class_id = existing.class_id
		_restore_ability(p)
	else:
		if sim.add_player(p.id, rec) == false:
			_rollback_seat(p, takes_builtin)
			return null
	# The host's class record always follows the sim's body.
	var joined := sim.get_player(p.id)
	if joined != null:
		p.class_id = joined.class_id
	if saved_usable:
		_ability_stash.erase(identity)
		_ability_stash_order.erase(identity)
	p.join_tick = tick
	players.append(p)
	return p


## Remote Hello path: seat the player, or send JOIN_REFUSED and close.
## `character` is unused by today's Hello (no class field yet) and is for
## tests and a later protocol that carries one.
func _try_remote_join(c: HostConn, character: Variant = null) -> HostPlayer:
	var p := _add_player(character)
	if p == null:
		# The Error always goes out: this connection closes right after.
		c.errors_in_window = 0
		_send_error(c, PB.ErrorCode.JOIN_REFUSED, "class is not valid")
		c.close_pending = true
		return null
	return p


## The class id the join asked for, or null if none was given (use default).
func _requested_class_id(character: Variant) -> Variant:
	if character is String:
		return String(character)
	if character is Dictionary:
		var d: Dictionary = character
		if d.has("class_id"):
			return String(d["class_id"])
		if d.has("class"):
			return String(d["class"])
	return null


func _catalog_has_class(class_id: String) -> bool:
	return class_id != "" and catalog != null and catalog.class_def(class_id) != null


func _default_class_id() -> String:
	if _catalog_has_class(DEFAULT_CLASS_ID):
		return DEFAULT_CLASS_ID
	push_error("LobbyHost: default class '%s' is not in the catalog" % DEFAULT_CLASS_ID)
	return ""


## A valid class id for this join, or "" to refuse. The built-in player 1
## takeover falls back to the default when none or an invalid class is given.
func _resolve_join_class(character: Variant, fallback_to_default: bool) -> String:
	var requested: Variant = _requested_class_id(character)
	if requested == null:
		return _default_class_id()
	var class_id := String(requested)
	if _catalog_has_class(class_id):
		return class_id
	if fallback_to_default:
		return _default_class_id()
	return ""


## Drop a seat that never made it into the lobby, and forget its issued id.
func _rollback_seat(p: HostPlayer, takes_builtin: bool) -> void:
	if takes_builtin:
		_builtin_taken = false
	if p != null and p.id != 0:
		# Keeps the id issued if a snapshot still names it.
		_prune_issued_id(p.id)


## LocalSim spawns a solo player 1; it stays in the sim (pending removal)
## until the first step unless a host player takes it over.
func _sim_has_builtin_player() -> bool:
	return not _builtin_taken and sim.tick() == 0 and sim.get_player(1) != null


## Removes a host player from the lobby. With a host-verified identity,
## saves their ability state under it for a later rejoin. A living body
## first lingers where it is, in the Wilds or a dungeon (vision §7.3); it leaves the sim
## when the linger ends (_end_linger) unless the same identity rejoins first.
func _leave(p: HostPlayer, identity: String = "") -> void:
	interact_validator.forget_player(p.id)
	var leaving := p.instance.sim.get_player(p.sim_id)
	var lingers: bool = leaving != null and leaving.hp > 0
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
			# Progression is filled in when the body leaves the sim.
			_stash_ability(identity, {"id": p.id, "cooldown": saved["cooldown"], "focus": saved["focus"],
					"left_tick": saved["left_tick"], "progression": {}, "class_id": p.class_id,
					"hp": leaving.hp if leaving != null else -1})
	if lingers:
		p.linger_until_tick = tick + LINGER_TICKS
		p.linger_identity = identity
		p.move_x = 0.0
		p.move_y = 0.0
		p.fire_held = false
		p.ability_pressed = false
		p.interacts = []
		p.interact_forward = 0
		return
	p.linger_identity = identity
	_end_linger(p)


## Takes the body out of its sim and the player out of the lobby: the end
## of a linger, or a leave with nothing to linger. Restores practice entry
## progression into the saved rejoin state (never onto a live body).
func _end_linger(p: HostPlayer) -> void:
	var leaving := p.instance.sim.get_player(p.sim_id)
	if leaving != null and p.linger_identity != "":
		var held: Dictionary = _ability_stash.get(p.linger_identity, {})
		if int(held.get("id", 0)) == p.id:
			held["hp"] = leaving.hp  # HP after any damage taken while lingering
	if leaving != null and not p.progression_entries.is_empty() and p.linger_identity != "":
		var carry := PlayerCarry.from_sim(leaving, p.instance.sim.ability_state(p.sim_id))
		_restore_entry_progression(p, carry)
		var saved: Dictionary = _ability_stash.get(p.linger_identity, {})
		if int(saved.get("id", 0)) == p.id:
			saved["progression"] = _progression_fields(carry)
	# Persistent entrances admit by occupancy, so per-player entries of
	# players who left the lobby are dropped to keep them bounded.
	for record: PortalRecord in _portal_records.values():
		if record.persistent:
			record.admitted.erase(p.id)
			record.sim_ids.erase(p.id)
	p.linger_until_tick = -1
	p.linger_identity = ""
	p.instance.sim.remove_player(p.sim_id)
	hearth.sim_ids.erase(p.id)
	players.erase(p)
	_prune_issued_id(p.id)


## Ends lingers that ran out, or whose body died or is gone (a dead body
## does not hold the instance; vision §7.3, content §2.5).
func _step_lingering() -> void:
	for p in players.duplicate():
		if not p.is_lingering():
			continue
		var body: SimPlayerState = p.instance.sim.get_player(p.sim_id)
		if body == null or body.hp <= 0 or tick >= p.linger_until_tick:
			_end_linger(p)


## The lingering player this host-verified identity left, if any.
func _lingering_for_identity(identity: String) -> HostPlayer:
	if identity == "":
		return null
	var saved: Dictionary = _ability_stash.get(identity, {})
	if saved.is_empty() or not _stash_id_issued_here(saved):
		return null
	var p := _find_player(int(saved["id"]))
	if p == null or not p.is_lingering() or p.linger_identity != identity:
		return null
	return p


## A rejoin within the linger cancels the leave: the same body, still in
## its instance, with its boss contribution, activity stamp, HP and
## ability state untouched (vision §6.1 rule 7). Only for the same class;
## anything else is not a resume.
## The class a rejoin by this identity is held to, or "" when nothing of
## the character is lingering or held for a rejoin.
func _locked_class_for(identity: String, saved: Dictionary) -> String:
	if identity == "":
		return ""
	var lingering := _lingering_for_identity(identity)
	if lingering != null:
		return lingering.class_id
	return String(saved.get("class_id", ""))


## `character` with its class set to `class_id` (for a join that named none).
static func _with_class(character: Variant, class_id: String) -> Variant:
	if character is Dictionary:
		var d: Dictionary = (character as Dictionary).duplicate()
		d["class_id"] = class_id
		return d
	return class_id


func _resume_lingering(identity: String, character: Variant) -> HostPlayer:
	var p := _lingering_for_identity(identity)
	if p == null:
		return null
	var requested: Variant = _requested_class_id(character)
	if requested != null and String(requested) != p.class_id:
		return null
	if p.instance.sim.get_player(p.sim_id) == null:
		return null
	_ability_stash.erase(identity)
	_ability_stash_order.erase(identity)
	p.linger_until_tick = -1
	p.linger_identity = ""
	# A new client numbers its input frames from the start again.
	p.seq = 0
	p.fed_seq = 0
	p.character = character
	return p


func _stash_ability(key: String, saved: Dictionary) -> void:
	saved["sim"] = sim.get_instance_id()  # the sim that issued saved["id"]
	var replaced: Dictionary = _ability_stash.get(key, {})
	if _ability_stash.has(key):
		_ability_stash_order.erase(key)
	_ability_stash[key] = saved
	_ability_stash_order.append(key)
	if not replaced.is_empty():
		_prune_issued_id(int(replaced.get("id", 0)))
	while _ability_stash_order.size() > MAX_ABILITY_STASH:
		var evicted: Dictionary = _ability_stash.get(_ability_stash_order[0], {})
		_ability_stash.erase(_ability_stash_order.pop_front())
		_prune_issued_id(int(evicted.get("id", 0)))


## Forgets an issued id once no lobby player and no snapshot holds it.
func _prune_issued_id(id: int) -> void:
	if _find_player(id) != null:
		return
	for saved: Dictionary in _ability_stash.values():
		if int(saved.get("id", 0)) == id:
			return
	_issued_player_ids.erase(id)


func issued_player_id_count() -> int:
	return _issued_player_ids.size()


## A rejoin re-adds an old player id only if this host issued it from its
## current overworld sim (alloc_player_id or the built-in player) and still
## holds it in _issued_player_ids. The sim never has to tell returning ids
## from reused ones.
func _stash_id_issued_here(saved: Dictionary) -> bool:
	var id := int(saved.get("id", 0))
	return id > 0 and id < INSTANCE_ID_BLOCK and int(saved.get("sim", 0)) == sim.get_instance_id() \
			and _issued_player_ids.has(id)


## Applies p.restore_ability: a snapshot adjusted for the host ticks since
## it was taken, or CONSERVATIVE (full cooldown for the player's ability,
## 0 Focus). {} (a ready first join) leaves the sim's fresh state.
func _restore_ability(p: HostPlayer) -> void:
	var saved := p.restore_ability
	p.restore_ability = {}
	var isim: LocalSim = p.instance.sim
	var sid: int = p.sim_id
	if not p.restore_progression.is_empty():
		var carry := PlayerCarry.from_sim(isim.get_player(sid), isim.ability_state(sid))
		_apply_progression(carry, p.restore_progression)
		# Progression only: no entry re-seed, stamp or boss-credit reset.
		isim.apply_carried_progression(carry)
		p.restore_progression = {}
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


## A full lobby makes room for a new join by ending the oldest linger that no
## one can resume (no host-verified identity), so lingering bodies cannot
## hold seats against real joins. Returns true if a seat is free.
func _free_seat_for_join() -> bool:
	if players.size() < max_players:
		return true
	var oldest: HostPlayer = null
	for p in players:
		if p.is_lingering() and p.linger_identity == "" \
				and (oldest == null or p.linger_until_tick < oldest.linger_until_tick):
			oldest = p
	if oldest == null:
		return false
	_end_linger(oldest)
	return players.size() < max_players


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
		# rule 7 activity tracks received input frames
		psim.apply_input(p.sim_id, intent, p.seq != p.fed_seq)
		p.fed_seq = p.seq
	var stepped: Array[HostInstance] = _all_instances()
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
	_step_lingering()
	for inst in stepped:
		if not inst.grants_persistent:
			_enforce_practice_items(inst)
			_route_practice_deaths(inst)
	# Transfers queued during this step: the mover is rostered in the
	# destination now and first steps there next tick (one step per tick).
	for inst in stepped:
		for xfer in inst.sim.take_pending_transfers():
			_route_transfer(inst, xfer)
	if loadtest_instances > 1:
		_spread_loadtest_players()
	if loadtest_distinct_admitted:
		_admit_loadtest_players()
	_walk_zone_gates()
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
	if not p.instance.grants_persistent:
		# Practice instances: no pickups, deposits or hand-offs; only the
		# exit can be used.
		var exit: PortalSnapshot = p.instance.sim.portal_by_id(target_id)
		if exit == null or exit.kind != PortalSnapshot.KIND_EXIT:
			return {}
		return {"x": exit.x, "y": exit.y}
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
	if sp == null or sc == null:
		# Fails closed: the host cannot check the join requirement.
		return [PB.ErrorCode.INSTANCE_NOT_FOUND, "portal entrance is unavailable"]
	if sc.below_join_floor(sp.level, portal.content_level):
		return [PB.ErrorCode.JOIN_REFUSED, "level is below this portal's join floor"]
	return _record_refusal(_record_for(p.instance, portal.id), p.id)


## Policy is read only from the host's packed practice entrance definition.
## Snapshot flags, transfers and network input cannot choose host policy.
func _portal_policy(portal: PortalSnapshot) -> Dictionary:
	if portal == null or portal.kind != PortalSnapshot.KIND_ENTER or catalog == null:
		return {}
	var def: DungeonDef = catalog.dungeon(portal.dungeon_id)
	if def == null or def.practice_yard_portal.is_empty():
		return {}
	var src: Dictionary = def.practice_yard_portal
	if not is_equal_approx(portal.x, float(src["x"])) or not is_equal_approx(portal.y, float(src["y"])) \
			or portal.m100 != int(src["m100"]) or portal.base_level != int(src["practice_base_level"]):
		return {"grants_persistent": def.grants_persistent}
	return src


## Players in `inst` other than `except_id` (lobby id).
func _occupants(inst: HostInstance, except_id: int) -> int:
	var n := 0
	for p in players:
		if p.instance == inst and p.id != except_id:
			n += 1
	return n


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
		var policy := _portal_policy(source.sim.portal_by_id(portal_id))
		record.persistent = bool(policy.get("persistent", false))
		record.grants_persistent = bool(policy.get("grants_persistent", false))
		# Reset is permitted only with host-enforced progression isolation.
		record.reset_when_empty = record.persistent and not record.grants_persistent and bool(policy.get("reset_when_empty", false))
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
	if record.persistent:
		if record.instance != null and _occupants(record.instance, player_id) >= record.capacity:
			return [PB.ErrorCode.INSTANCE_FULL, "portal instance is full"]
		return [0, ""]
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
	if _is_zone_gate(source, xfer.portal_id):
		# The pair is host-owned and accepts only its real source portal.
		var gate := source.sim.portal_by_id(xfer.portal_id)
		var sp := source.sim.get_player(p.sim_id)
		if not p.is_lingering() and sp != null and sp.hp > 0 and gate != null \
				and source.sim.scaling().in_accept_range(SimConstants.interact_distance(sp.x, sp.y, gate.x, gate.y)):
			_cross_zone_gate(p)
		return
	if source == hearth:
		return  # the Hearth has no dungeon entrances or other exits
	if xfer.kind == PortalTransfer.KIND_EXIT:
		# TODO(portal lifetime): Hearth routing, seal and re-entry rules;
		# for now an exit returns to the overworld.
		_move_player(p, instances[0], p.id, xfer.arrival_x, xfer.arrival_y)
		return
	if not source.grants_persistent:
		_reject_portal(p, PB.ErrorCode.INSTANCE_NOT_FOUND, "only the practice exit is available here")
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
	if dest != null and record.reset_when_empty and _no_living_player_inside(dest):
		if not _reset_instance(record):
			_reject_portal(p, PB.ErrorCode.INSTANCE_NOT_FOUND, "practice instance unavailable")
			return
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
		dest = _create_dungeon_instance(xfer, record.grants_persistent)
		if dest == null:
			_reject_portal(p, PB.ErrorCode.INSTANCE_NOT_FOUND, "dungeon unavailable or instance id space exhausted")
			return
		dest.portal_key = key
		dest.grants_persistent = record.grants_persistent
		if not dest.grants_persistent:
			dest.sim.set_item_rules(false, false)
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
func _create_dungeon_instance(xfer: PortalTransfer, grants_persistent: bool = false) -> HostInstance:
	var def: DungeonDef = catalog.dungeon(xfer.dungeon_id) if catalog != null else null
	if def == null:
		return null
	# Check the quotient before multiplication: no signed overflow can
	# wrap the block start into another instance's entity range.
	if _next_instance_index <= 0 or _next_instance_index >= LocalSim.MAX_ENTITY_ID / INSTANCE_ID_BLOCK:
		return null
	var inst := HostInstance.new()
	inst.kind = HostInstance.Kind.DUNGEON
	inst.index = _next_instance_index
	_next_instance_index += 1
	inst.dungeon_id = xfer.dungeon_id
	inst.seed = xfer.seed
	inst.m100 = xfer.m100
	inst.created_from = xfer
	inst.grants_persistent = grants_persistent
	inst.arrival_x = xfer.arrival_x
	inst.arrival_y = xfer.arrival_y
	inst.capacity = _settings.max_players
	var dsim := _build_dungeon_sim(def, xfer, inst.index * INSTANCE_ID_BLOCK, grants_persistent)
	if dsim == null:
		return null
	inst.sim = dsim
	instances.append(inst)
	return inst


## TODO(persistence): all future save/export code must call this helper,
## not world_view or get_player: practice progression is the entry snapshot.
## No host character save/export path exists yet.
func effective_character(player_id: int) -> PlayerCarry:
	var p := _find_player(player_id)
	if p == null or p.instance == null:
		return null
	var sp := p.instance.sim.get_player(p.sim_id)
	if sp == null:
		return null
	var carry := PlayerCarry.from_sim(sp, p.instance.sim.ability_state(p.sim_id))
	if not p.progression_entries.is_empty():
		_apply_progression(carry, p.progression_entries.back()["fields"])
	else:
		carry.inventory = _copy_inventory(carry.inventory)
	return carry


## Practice instances: nothing leaves its owner's inventory. Items a
## player did not bring in are removed, brought-in items that left are put
## back, and any copy of them elsewhere in the instance is removed.
func _enforce_practice_items(inst: HostInstance) -> void:
	var owned: Dictionary = {}  # drop_id -> HostPlayer that brought it in
	var originals: Dictionary = {}  # drop_id -> ItemState (entry copy)
	var here: Array[HostPlayer] = []
	for p in players:
		if p.instance != inst or p.progression_entries.is_empty():
			continue
		here.append(p)
		var inv: PlayerInventory = p.progression_entries.back()["fields"].get("inventory")
		if inv == null:
			continue
		for item in inv.live_items():
			if item.drop_id != "":
				owned[item.drop_id] = p
				originals[item.drop_id] = item
	for p in here:
		var sp := inst.sim.get_player(p.sim_id)
		if sp == null or sp.inventory == null:
			continue
		# Each player keeps at most as many copies of an item as they brought
		# in (items without an id are counted the same way): nothing extra.
		var allowed: Dictionary = {}
		var entry_inv: PlayerInventory = p.progression_entries.back()["fields"].get("inventory")
		if entry_inv != null:
			for item in entry_inv.live_items():
				if item.drop_id == "" or owned.get(item.drop_id) == p:
					allowed[item.drop_id] = int(allowed.get(item.drop_id, 0)) + 1
		var inv := sp.inventory
		for slot in ["weapon", "armor", "charm"]:
			var eq: ItemState = inv.equipped_for(slot)
			if eq != null:
				if int(allowed.get(eq.drop_id, 0)) > 0:
					allowed[eq.drop_id] = int(allowed[eq.drop_id]) - 1
				else:
					inv.set_equipped(slot, null)
		for i in range(inv.slots.size()):
			var it: ItemState = inv.slots[i]
			if it == null or _is_equipped(inv, it):
				continue
			if int(allowed.get(it.drop_id, 0)) > 0:
				allowed[it.drop_id] = int(allowed[it.drop_id]) - 1
			else:
				inv.slots[i] = null
	if not inst.sim.ground_drops().is_empty():
		inst.sim.clear_ground_drops()  # no ground piles in a practice instance
	for p in here:
		var sp := inst.sim.get_player(p.sim_id)
		if sp == null or sp.inventory == null:
			continue
		var have := {}
		for it in sp.inventory.live_items():
			have[it.drop_id] = true
		for did in owned:
			if owned[did] == p and not have.has(did):
				sp.inventory.add((originals[did] as ItemState).duplicate_item())


func _is_equipped(inv: PlayerInventory, it: ItemState) -> bool:
	for slot in ["weapon", "armor", "charm"]:
		if inv.equipped_for(slot) == it:
			return true
	return false


## Practice instances: a player who dies leaves for the overworld (the
## Hearth stand-in) with the same restore as any other way out.
## TODO(§7 Hearth): route to the Hearth once it exists.
func _route_practice_deaths(inst: HostInstance) -> void:
	for p in players.duplicate():
		if p.instance != inst:
			continue
		var sp := inst.sim.get_player(p.sim_id)
		if sp != null and sp.hp <= 0:
			_move_player(p, instances[0], p.id, 16.0, 16.0)


## Deep inventory snapshot, preserving equipment/slot references within it.
func _copy_inventory(src: PlayerInventory) -> PlayerInventory:
	if src == null:
		return null
	var dst := PlayerInventory.new(src.slot_count)
	var copies: Dictionary = {}
	for item in src.live_items():
		copies[item] = item.duplicate_item()
	for i in range(src.slots.size()):
		dst.slots[i] = copies.get(src.slots[i])
	for slot in ["weapon", "armor", "charm"]:
		dst.set_equipped(slot, copies.get(src.equipped_for(slot)))
	return dst


## Capture all carried persistent fields, including future currencies or
## vault fields, while excluding identity and transient combat/input state.
func _progression_fields(carry: PlayerCarry) -> Dictionary:
	var fields: Dictionary = {}
	for prop in carry.get_property_list():
		var key: String = prop["name"]
		if prop["usage"] & PROPERTY_USAGE_SCRIPT_VARIABLE == 0 or key in ["player_id", "hp", "aim", "ability", "last_interact_seq"]:
			continue
		var value: Variant = carry.get(key)
		if value is PlayerInventory:
			value = _copy_inventory(value)
		elif value is Array or value is Dictionary:
			value = value.duplicate(true)
		fields[key] = value
	return fields


func _apply_progression(carry: PlayerCarry, fields: Dictionary) -> void:
	for key in fields:
		var value: Variant = fields[key]
		carry.set(key, _copy_inventory(value) if value is PlayerInventory else value)


func _restore_entry_progression(p: HostPlayer, carry: PlayerCarry) -> void:
	if not p.progression_entries.is_empty():
		var entry: Dictionary = p.progression_entries.back()
		_apply_progression(carry, entry["fields"])
		if carry.hp <= 0:
			carry.hp = int(entry.get("hp", 1))
		p.progression_entries.pop_back()


func _build_dungeon_sim(def: DungeonDef, xfer: PortalTransfer, id_floor: int, grants_persistent: bool = false) -> LocalSim:
	var dsim := LocalSim.new(_config, xfer.arrival_x, xfer.arrival_y, catalog)
	dsim.remove_player(1)  # the built-in player; gone at the first step
	if not dsim.set_id_floor(id_floor):
		return null
	dsim.set_lobby_settings(_settings)
	if not grants_persistent:
		# Practice instances: no loot bags and no item transfers (§2.5).
		dsim.set_item_rules(false, false)
	# opener_id is the opener's sim id in the SOURCE world, not the
	# destination id allocated later. Preserve that creation provenance.
	dsim.configure_dungeon(def, xfer.seed, xfer.m100, xfer.base_level, xfer.content_level,
			xfer.opener_id, xfer.opener_lp, grants_persistent)
	return dsim


## content §2.5: no living (or lingering) player inside the instance.
func _no_living_player_inside(inst: HostInstance) -> bool:
	# Lingering bodies are still in `players` until their linger ends.
	for p in players:
		if p.instance == inst:
			var sp := inst.sim.get_player(p.sim_id)
			if sp != null and sp.hp > 0:
				return false
	return true


## Rebuilds a reset-when-empty instance in place: same instance id and id
## block, a fresh slice (rooms, boss, exit) from the creation transfer, and
## entity ids that keep counting up. Any remaining (dead) occupants are sent
## to the overworld with their entry state, never revived inside.
func _reset_instance(record: PortalRecord) -> bool:
	var inst := record.instance
	var def: DungeonDef = catalog.dungeon(inst.dungeon_id) if catalog != null else null
	if def == null or inst.created_from == null:
		return false
	var old := inst.sim
	var floor := old.alloc_player_id() + 1
	if floor >= (inst.index + 1) * INSTANCE_ID_BLOCK:
		return false
	var fresh := _build_dungeon_sim(def, inst.created_from, floor, inst.grants_persistent)
	if fresh == null:
		return false
	for p in players.duplicate():
		if p.instance == inst:
			_move_player(p, instances[0], p.id, 16.0, 16.0)
	record.sim_ids.clear()
	inst.sim = fresh
	record.cleared = false
	return true


## Moves `p` into `dest` as `dest_id` at (x, y), carrying class, level,
## inventory, HP and ability state (Focus and cooldown exactly as they are,
## never refreshed). Removal from the old sim takes effect at its next step.
func _move_player(p: HostPlayer, dest: HostInstance, dest_id: int, x: float, y: float,
		issued_now: bool = false) -> bool:
	var src: LocalSim = p.instance.sim
	var from := src.get_player(p.sim_id)
	if from == null or dest == p.instance:
		return false
	if not issued_now and not _dest_id_issued(p, dest, dest_id):
		push_warning("LobbyHost: refusing to place player %d with an id the host did not issue" % p.id)
		return false
	var carry := PlayerCarry.from_sim(from, src.ability_state(p.sim_id))
	_restore_entry_progression(p, carry)
	if not dest.grants_persistent:
		p.progression_entries.append({"instance": dest.index, "fields": _progression_fields(carry), "hp": carry.hp})
		# The practice copy must not mutate the source inventory or entry copy.
		carry.inventory = _copy_inventory(carry.inventory)
	carry.player_id = dest_id
	dest.sim.place_player(dest_id, x, y)
	dest.sim.apply_carried_player(carry, x, y)
	# The source copy is gone at its next step; it holds no items meanwhile.
	if from.inventory != null:
		from.inventory = PlayerInventory.new(from.inventory.slot_count)
	src.remove_player(p.sim_id)
	p.instance = dest
	p.sim_id = dest_id
	p.x = x
	p.y = y
	_sync_position(p, dest.sim, dest_id)
	p.interacts = []
	p.interact_forward = 0
	return true


## The sim may adjust a placement (for example out of a sealed area), so
## the host's copy of the position is read back from the sim right away.
func _sync_position(p: HostPlayer, psim: LocalSim, id: int) -> void:
	var sp := psim.get_player(id)
	if sp != null:
		p.x = sp.x
		p.y = sp.y


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
		if record.persistent:
			continue  # a persistent entrance keeps its one instance
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
	var inst := _create_dungeon_instance(xfer, true)
	if inst != null:
		inst.portal_key = "loadtest:%d" % i
		inst.capacity = 1 << 30
		_instance_by_portal[inst.portal_key] = inst


## Load test only: the packed practice door plus `loadtest_entrances` normal
## (expiring) entrances beside it, all in the overworld.
func _open_loadtest_entrances() -> void:
	sim.spawn_practice_portal("hollowmere_vault")
	for i in range(loadtest_entrances):
		var portal := sim.portal_by_id(sim.spawn_practice_portal("hollowmere_vault"))
		if portal == null:
			return
		portal.x += 1.5 * float(i + 1)
		portal.persistent = false
	_sync_portal_records()


## Load test only: worst case for per-viewer snapshot data. Each remote
## player is admitted to the normal entrances picked by the bits of its id,
## so no two players share an admitted set (up to 2^N players).
func _admit_loadtest_players() -> void:
	var entrances: Array = []
	for e in _entrance_records(instances[0]):
		if not (e[1] as PortalRecord).persistent:
			entrances.append(e[1])
	for p in players:
		if p.is_local or not p.in_sim or _loadtest_admitted.has(p.id):
			continue
		_loadtest_admitted[p.id] = true
		for j in range(entrances.size()):
			if p.id & (1 << j):
				(entrances[j] as PortalRecord).admitted[p.id] = true


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
			_move_player(p, dest, dest.sim.alloc_player_id(), dest.arrival_x, dest.arrival_y, true)


## An id is placed into `dest` only if the host's own records map it to `p`:
## the overworld uses the player's lobby id; a dungeon uses the id its sim
## issued for this player, held in that entrance's record.
func _dest_id_issued(p: HostPlayer, dest: HostInstance, dest_id: int) -> bool:
	for other in players:
		if other != p and other.instance == dest and other.sim_id == dest_id:
			return false
	if dest.is_overworld():
		return dest_id == p.id
	if dest == hearth:
		return int(hearth.sim_ids.get(p.id, 0)) == dest_id
	for record: PortalRecord in _portal_records.values():
		if record.instance == dest and int(record.sim_ids.get(p.id, 0)) == dest_id:
			return true
	return false


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



## Field 3 (ServerMessage.snapshot), length-delimited.
const SNAPSHOT_FIELD_TAG: int = (3 << 3) | 2


## One viewer's full Snapshot message (default: the overworld, no viewer).
## Same bytes the send path builds: the instance's shared body followed by
## this viewer's own fields.
func _encode_snapshot_for(bags: Array, inst: HostInstance = null, owner_id: int = -1) -> PackedByteArray:
	if inst == null:
		inst = instances[0]
	var body := _shared_snapshot_body(inst)
	body.append_array(_viewer_snapshot_body(inst, bags, owner_id))
	return _wrap_snapshot(body)


## Viewer-independent Snapshot fields of `inst`: tick, players, portals.
## Encoded once per instance per tick.
func _shared_snapshot_body(inst: HostInstance) -> PackedByteArray:
	var s = PB.Snapshot.new()
	s.set_tick(tick)
	for p in players:
		if p.instance != inst:
			continue
		var stub = s.add_players()
		stub.set_id(p.id)
		stub.set_applied_seq(p.seq)
	for portal in inst.sim.portals():
		_encode_portal(s.add_portals(), portal, inst)
	return s.to_bytes()


## One viewer's own Snapshot fields: their bags and the entrances they may
## still re-enter. Empty when there are none. Protobuf merges fields that
## follow the shared body (repeated fields append), so the two concatenate.
func _viewer_snapshot_body(inst: HostInstance, bags: Array, owner_id: int, entrances: Variant = null) -> PackedByteArray:
	if bags.is_empty() and owner_id < 0:
		return PackedByteArray()
	var s = PB.Snapshot.new()
	var any := false
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
		any = true
	if owner_id >= 0:
		for e in (entrances if entrances != null else _entrance_records(inst)):
			if _may_reenter(e[1], owner_id):
				s.add_admitted_portal_ids(e[0])
				any = true
	return s.to_bytes() if any else PackedByteArray()


## [portal id, record] for each entrance in `inst` the host has a record for.
func _entrance_records(inst: HostInstance) -> Array:
	var out: Array = []
	for portal in inst.sim.portals():
		if portal.kind != PortalSnapshot.KIND_ENTER:
			continue
		var record: PortalRecord = _portal_records.get(_portal_key(inst, portal.id))
		if record != null:
			out.append([portal.id, record])
	return out


static func _wrap_snapshot(body: PackedByteArray) -> PackedByteArray:
	var out := PackedByteArray([SNAPSHOT_FIELD_TAG])
	out.append_array(PB.PBPacker.pack_varint(body.size()))
	out.append_array(body)
	return out


## Includes only public metadata of worlds reachable from this player's
## current entrance view, plus their current world and prior admissions.
## Seeds, identities and lobby credentials are never included.
func _encode_instance_list(viewer: HostPlayer) -> PackedByteArray:
	var msg = PB.ServerMessage.new()
	var listing = msg.new_instance_list()
	for inst in _all_instances():
		var record: PortalRecord = _portal_records.get(inst.portal_key)
		if inst.is_dungeon() and inst != viewer.instance:
			if record == null or (record.source != viewer.instance and not record.admitted.has(viewer.id)):
				continue
		var info = listing.add_instances()
		info.set_instance(inst.index)
		info.set_m100(inst.m100)
		info.set_player_count(_occupants(inst, -1))
		info.set_is_default(inst.is_overworld())
		info.set_base_level(inst.created_from.base_level if inst.created_from != null else 0)
		info.set_capacity(record.capacity if record != null else _settings.max_players)
		info.set_admitted_count(_admitted_count(record) if record != null else _occupants(inst, -1))
		info.set_closed(_entrance_closed(record) if record != null else false)
	return msg.to_bytes()


func _admitted_count(record: PortalRecord) -> int:
	if record.persistent:
		return _occupants(record.instance, -1) if record.instance != null else 0
	return record.admitted.size()


## Closed for new entry, the same for every viewer.
func _entrance_closed(record: PortalRecord) -> bool:
	return record.closed or (not record.persistent \
			and tick >= record.created_tick + _entrance_lifetime_ticks(record))


## An earlier admission this player may still use (see _record_refusal).
func _may_reenter(record: PortalRecord, player_id: int) -> bool:
	return not record.closed and not record.persistent and record.admitted.has(player_id)


func _encode_portal(out, portal: PortalSnapshot, inst: HostInstance) -> void:
	out.set_id(portal.id)
	out.set_x(portal.x)
	out.set_y(portal.y)
	out.set_radius(portal.radius)
	match portal.kind:
		PortalSnapshot.KIND_ENTER: out.set_kind(PB.PortalKind.ENTER)
		PortalSnapshot.KIND_EXIT: out.set_kind(PB.PortalKind.EXIT)
		PortalSnapshot.KIND_PLACEHOLDER: out.set_kind(PB.PortalKind.PLACEHOLDER)
	out.set_dungeon_id(portal.dungeon_id)
	out.set_marker_id(portal.marker_id)
	out.set_m100(portal.m100)
	out.set_base_level(portal.base_level)
	out.set_content_level(portal.content_level)
	out.set_persistent(portal.persistent)
	out.set_grants_persistent(portal.grants_persistent)
	if portal.kind == PortalSnapshot.KIND_ENTER:
		var record: PortalRecord = _portal_records.get(_portal_key(inst, portal.id))
		if record == null:
			# An entrance must have host admission policy before advertising it.
			out.set_closed(true)
			return
		out.set_capacity(record.capacity)
		out.set_admitted_count(_admitted_count(record))
		out.set_closed(_entrance_closed(record))
		out.set_persistent(record.persistent)
		out.set_grants_persistent(record.grants_persistent)
		if not record.persistent:
			out.set_expire_tick(record.created_tick + _entrance_lifetime_ticks(record))


## Live bags in every instance, grouped by owner's lobby id:
## owner_id -> Array[GroundDrop].
func _bags_by_owner() -> Dictionary:
	var out := {}
	for inst in _all_instances():
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


## Shared Snapshot of the overworld and of every instance with a viewer:
## instance -> [body, wrapped message, entrance records]. One encode per instance per tick.
func _encode_shared_snapshots() -> Dictionary:
	var out := {}
	var wanted: Array[HostInstance] = [instances[0]]
	for c in _conns:
		if c.player != null and not wanted.has(c.player.instance):
			wanted.append(c.player.instance)
	for inst in wanted:
		var body := _shared_snapshot_body(inst)
		out[inst] = [body, _wrap_snapshot(body), _entrance_records(inst)]
	return out


## Sends each viewer their instance's shared Snapshot; a viewer with own
## fields (bags, re-enterable entrances) gets them appended to that body.
func _send(shared: Dictionary) -> int:
	var sent: int = 0
	_tick_viewer_bytes = 0
	_tick_viewer_bytes_max = 0
	var bags := _bags_by_owner()
	for c in _conns:
		if c.player == null or c.ws.get_ready_state() != WebSocketPeer.STATE_OPEN:
			continue
		var inst: HostInstance = c.player.instance
		if not shared.has(inst):
			var b := _shared_snapshot_body(inst)
			shared[inst] = [b, _wrap_snapshot(b), _entrance_records(inst)]
		var pair: Array = shared[inst]
		var out: PackedByteArray = pair[1]
		var own := _viewer_snapshot_body(inst, bags.get(c.player.id, []), c.player.id, pair[2])
		if not own.is_empty():
			var body: PackedByteArray = pair[0].duplicate()
			body.append_array(own)
			out = _wrap_snapshot(body)
		if c.ws.put_packet(out) == OK:
			sent += 1
			_tick_viewer_bytes += out.size()
			_tick_viewer_bytes_max = maxi(_tick_viewer_bytes_max, out.size())
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
		"viewer_snapshot_bytes_avg": snappedf(float(st_viewer_bytes_sum) / maxf(st_viewer_packets, 1), 0.1),
		"viewer_snapshot_bytes_max": st_viewer_bytes_max,
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
