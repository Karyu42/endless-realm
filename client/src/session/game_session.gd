extends Node
## Autoload. Owns a WorldSource, steps it at 20 Hz, and exposes snapshots for
## render interpolation. Gameplay nodes emit input and read state only.
## Solo, listen-host, and remote client all submit InputIntent through source.
## The sim itself is LocalSim (plain RefCounted game rules), not this node.
## Listen-host networking uses the Server Engineer's LobbyHost (proto/v1).

enum Mode { SOLO, HOST, CLIENT }

var config: SimConfig
var catalog: DataCatalog
var source: WorldSource
var prev_snapshot: WorldSnapshot = WorldSnapshot.new()
var curr_snapshot: WorldSnapshot = WorldSnapshot.new()
var alpha: float = 0.0
var mode: Mode = Mode.SOLO
var lobby_host: LobbyHost
var lobby_client: LobbyClient
var lobby_config: LobbyConfig
var beacon: LobbyBeaconBroadcaster
## New characters default to not played-offline (QA #28).
var played_offline: bool = false
var local_player_id: int = 1

## Latest raw input, written by the arena / virtual sticks each display frame.
var move_x: float = 0.0
var move_y: float = 0.0
var aim: float = 0.0
var fire_held: bool = false
var interact_pressed: bool = false
var inventory_slot: int = 0
## Snapshot id of the interactable the client auto-selected (0 = none).
var interact_target_id: int = 0
var ability_pressed: bool = false

var _accum: float = 0.0
var _seq: int = 0
const MAX_CATCH_UP_TICKS: int = 5


func _ready() -> void:
	config = load("res://resources/sim_config.tres") as SimConfig
	if config == null:
		config = SimConfig.new()
	catalog = DataCatalog.load_default()
	# Boot may immediately switch to host/client; default solo keeps the
	# practice yard working if the arena is opened on its own.
	start_solo()


func start_solo() -> void:
	_teardown_net()
	mode = Mode.SOLO
	local_player_id = 1
	source = _new_sim()
	_reset_snapshots()


func start_host(cfg: LobbyConfig, bind_host: String = "*") -> Error:
	_teardown_net()
	lobby_config = cfg
	var hs = cfg.host_settings
	if hs.join_code == "":
		hs.join_code = LobbyConfig.generate_join_code()
	var bind := bind_host
	if bind == "*" or bind == "":
		bind = "0.0.0.0"
	lobby_host = LobbyHost.new(config)
	lobby_host.port = cfg.ws_port
	lobby_host.bind_address = bind
	lobby_host.max_players = hs.max_players
	lobby_host.instance_seed = cfg.instance_seed
	lobby_host.multiplier_m100 = int(round(cfg.display_multiplier * 100.0))
	# TODO(host-settings): once LobbyHost.apply_settings / settings() land,
	# call apply_settings on a real LobbySettings instead of copying fields.
	var err: Error = lobby_host.start()
	if err != OK:
		lobby_host = null
		start_solo()
		return err
	cfg.ws_port = lobby_host.port
	# TODO(host-view): once add_local_player / submit_local_input /
	# remove_local_player, world_view(player_id) and the ticked signal land,
	# the host arena should render from lobby_host.world_view(local_player_id)
	# and this separate LocalSim should be dropped.
	var sim := _new_sim()
	mode = Mode.HOST
	local_player_id = 1
	source = HostWorldSource.new(lobby_host, sim)
	beacon = LobbyBeaconBroadcaster.new()
	if beacon.start(cfg, bind) != OK:
		# Discovery is optional; the host still listens on WebSocket.
		beacon = null
	_reset_snapshots()
	return OK


func start_client(url: String, offline: bool = false, join_code: String = "") -> Error:
	_teardown_net()
	played_offline = offline
	lobby_client = LobbyClient.new()
	lobby_client.name = "LobbyClient"
	add_child(lobby_client)
	var err: Error = lobby_client.connect_to(url, offline, join_code)
	if err != OK:
		lobby_client.queue_free()
		lobby_client = null
		start_solo()
		return err
	lobby_client.welcomed.connect(_on_client_welcomed)
	mode = Mode.CLIENT
	source = ClientWorldSource.new(lobby_client)
	_reset_snapshots()
	return OK


func _on_client_welcomed(pid: int) -> void:
	local_player_id = pid


func _new_sim() -> LocalSim:
	if catalog == null:
		catalog = DataCatalog.load_default()
	var sim := LocalSim.new(config, 16.0, 16.0, catalog)
	sim.set_bounds(0.0, 0.0, 32.0, 32.0)
	sim.set_world_seed(1)
	sim.set_player_class("thornguard")
	sim.apply_class_motion()
	# Practice yard: every enemy is fixed at the data E (killXP(1), Glint 1, T* = 0).
	sim.set_practice_yard(true)
	var yard_e: int = 1
	if catalog != null and catalog.scaling != null:
		yard_e = catalog.scaling.practice_yard_content_level
	sim.spawn_enemy("burrmite", 24.0, 10.0, yard_e)
	return sim


func _reset_snapshots() -> void:
	_accum = 0.0
	_seq = 0
	curr_snapshot = source.snapshot() if source != null else WorldSnapshot.new()
	prev_snapshot = curr_snapshot.duplicate_snapshot()


func _teardown_net() -> void:
	if beacon != null:
		beacon.stop()
		beacon = null
	if lobby_host != null:
		lobby_host.stop()
		lobby_host = null
	if lobby_client != null:
		lobby_client.stop()
		lobby_client.queue_free()
		lobby_client = null


func _process(delta: float) -> void:
	if lobby_host != null:
		lobby_host.service()
		if beacon != null:
			beacon.player_count = LobbyConfig.beacon_player_count(
				lobby_host.players.size(), lobby_host.max_players)
			beacon.poll(delta)
	if source == null:
		return
	var dt: float = SimConstants.TICK_DT
	_accum += delta
	var steps: int = 0
	while _accum >= dt and steps < MAX_CATCH_UP_TICKS:
		_accum -= dt
		steps += 1
		_seq += 1
		# Wrap seq as u32 to stay wire-compatible later.
		if _seq > 0xFFFFFFFF:
			_seq = 1
		var intent := InputIntent.from_raw(
			_seq, move_x, move_y, aim, fire_held, interact_pressed, inventory_slot, interact_target_id,
			ability_pressed
		)
		# Consume one-shot actions so catch-up ticks do not repeat them.
		interact_pressed = false
		inventory_slot = 0
		interact_target_id = 0
		ability_pressed = false
		source.submit_input(intent)
		source.step()
		prev_snapshot = curr_snapshot
		curr_snapshot = source.snapshot()
	# If we hit the catch-up cap, drop leftover time so the sim does not spiral.
	if steps >= MAX_CATCH_UP_TICKS and _accum >= dt:
		_accum = fmod(_accum, dt)
	alpha = clampf(_accum / dt, 0.0, 1.0)


func render_time_ticks() -> float:
	return float(curr_snapshot.tick - 1) + alpha if curr_snapshot.tick > 0 else alpha


func interpolated_player_tiles() -> SimVec2:
	var x: float = lerpf(prev_snapshot.player_x, curr_snapshot.player_x, alpha)
	var y: float = lerpf(prev_snapshot.player_y, curr_snapshot.player_y, alpha)
	return SimVec2.from_xy(x, y)


func interpolated_player_pixels() -> Vector2:
	return interpolated_player_tiles().to_pixels()


func interpolated_aim() -> float:
	# Shortest-path lerp on the Godot 2D circle (clockwise positive).
	var a: float = prev_snapshot.player_aim
	var b: float = curr_snapshot.player_aim
	var diff: float = fposmod(b - a + PI, TAU) - PI
	return a + diff * alpha
