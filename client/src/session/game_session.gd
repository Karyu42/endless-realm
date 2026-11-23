extends Node

const PB := preload("res://src/net/proto/protocol_v1_pb.gd")
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
## Remembers the host-issued rejoin token when the UI drops a local player.
var local_join: LobbyLocalJoin = LobbyLocalJoin.new()
var _host_bind: String = "0.0.0.0"
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
## Hits from the LocalSim tick that produced curr_snapshot, when the source is a LocalSim.
var last_hits: Array[HitEvent] = []
var last_hit_tick: int = -1
## Packed portal / ErrorReply copy for the local player; empty when none.
var portal_error_text: String = ""
var portal_error_code: int = 0
## Packed Hello-time join refusal copy; empty when none. Not portal copy.
var join_error_text: String = ""
var join_error_code: int = 0
signal join_refused(text: String)

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
	local_join.reset()
	lobby_config = cfg
	var bind := bind_host
	if bind == "*" or bind == "":
		bind = "0.0.0.0"
	_host_bind = bind
	lobby_host = LobbyHost.new(config)
	lobby_host.port = cfg.ws_port
	lobby_host.bind_address = bind
	lobby_host.instance_seed = cfg.instance_seed
	lobby_host.multiplier_m100 = int(round(cfg.display_multiplier * 100.0))
	var settings_err: Error = lobby_host.apply_settings(cfg.host_settings)
	if settings_err != OK:
		lobby_host = null
		start_solo()
		return settings_err
	cfg.host_settings = lobby_host.settings()
	lobby_host.settings_changed.connect(_on_host_settings_changed)
	lobby_host.portal_rejected.connect(_on_host_portal_rejected)
	var err: Error = lobby_host.start()
	if err != OK:
		lobby_host = null
		start_solo()
		return err
	cfg.ws_port = lobby_host.port
	# First join: empty rejoin token (the host starts this player ready).
	var pid: int = local_join.add(lobby_host, null)
	if pid < 0:
		lobby_host.stop()
		lobby_host = null
		start_solo()
		return ERR_CANT_CREATE
	mode = Mode.HOST
	local_player_id = pid
	source = HostWorldSource.new(lobby_host, pid)
	_start_or_stop_beacon()
	_reset_snapshots()
	return OK


func _on_host_settings_changed(s: LobbySettings) -> void:
	if lobby_config != null and s != null:
		lobby_config.host_settings = s.duplicate_settings()


## Apply a copy of LobbySettings through the host API. Returns validate()
## reasons, or a packed apply-failed string, or empty on success.
func apply_lobby_settings(s: LobbySettings, ui: LobbyUiSettings) -> PackedStringArray:
	if s == null:
		return PackedStringArray([ui.text("apply_failed")])
	var reasons: PackedStringArray = s.validate()
	if not reasons.is_empty():
		return reasons
	if lobby_host == null or lobby_host.apply_settings(s) != OK:
		return PackedStringArray([ui.text("apply_failed")])
	return PackedStringArray()


func set_invite_only(on: bool) -> void:
	if lobby_config == null:
		return
	lobby_config.invite_only = on
	_start_or_stop_beacon()


func set_broadcast_join_code(on: bool) -> void:
	if lobby_config == null:
		return
	lobby_config.broadcast_join_code = on


func copy_join_code() -> String:
	var code := current_join_code()
	if code != "":
		DisplayServer.clipboard_set(code)
	return code


func current_join_code() -> String:
	if lobby_host != null:
		return lobby_host.settings().join_code
	if lobby_config != null:
		return lobby_config.host_settings.join_code
	return ""


func drop_local_player() -> String:
	if lobby_host == null:
		return ""
	return local_join.remove(lobby_host, local_player_id)


func restore_local_player(character: Variant = null) -> int:
	if lobby_host == null:
		return -1
	var pid: int = local_join.restore(lobby_host, character)
	if pid >= 0:
		local_player_id = pid
		source = HostWorldSource.new(lobby_host, pid)
		_reset_snapshots()
	return pid


func import_for_local_player(blob: PackedByteArray) -> int:
	if lobby_host == null:
		return ImportResult.REJECTED_UNKNOWN_PLAYER
	return lobby_host.import_character(blob, local_player_id)


func _start_or_stop_beacon() -> void:
	if lobby_config == null or not lobby_config.should_broadcast() or lobby_host == null or mode != Mode.HOST:
		if beacon != null:
			beacon.stop()
			beacon = null
		return
	if beacon == null:
		beacon = LobbyBeaconBroadcaster.new()
		if beacon.start(lobby_config, _host_bind) != OK:
			# Discovery is optional; the host still listens on WebSocket.
			beacon = null


func start_client(url: String, offline: bool = false, join_code: String = "") -> Error:
	clear_join_error()
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
	lobby_client.error_received.connect(_on_client_portal_error)
	lobby_client.join_error_received.connect(_on_client_join_error)
	mode = Mode.CLIENT
	source = ClientWorldSource.new(lobby_client)
	_reset_snapshots()
	return OK


func _on_client_welcomed(pid: int) -> void:
	local_player_id = pid


func _on_host_portal_rejected(player_id: int, code: int, _reason: String) -> void:
	if player_id != local_player_id:
		return
	apply_portal_error(code)


func _on_client_portal_error(code: int, _reason: String) -> void:
	apply_portal_error(code)


func _on_client_join_error(code: int, _reason: String) -> void:
	apply_join_error(code)
	if mode == Mode.CLIENT and (lobby_client == null or lobby_client.player_id == 0):
		call_deferred("_abandon_failed_join")


func _abandon_failed_join() -> void:
	if mode != Mode.CLIENT:
		return
	if lobby_client != null and lobby_client.player_id != 0:
		return
	start_solo()


## Hello-time join refusal. INSTANCE_FULL uses packed lobby_full copy, not the
## portal "area is full" sentence. Join-floor UNSPECIFIED is left alone.
func apply_join_error(code: int) -> String:
	var ui := LobbyUiSettings.load_default()
	var text := ""
	if code == PB.ErrorCode.INSTANCE_FULL:
		text = ui.text("lobby_full")
		if text == "":
			DataCatalog.report_unknown_id("lobby_ui.strings.lobby_full")
	elif code != PB.ErrorCode.ERROR_CODE_UNSPECIFIED:
		DataCatalog.report_unknown_id(ErrorCodes.catalog_id(code))
	join_error_text = text
	join_error_code = code
	if text != "":
		join_refused.emit(text)
	return text


func take_join_error() -> String:
	var text: String = join_error_text
	clear_join_error()
	return text


func clear_join_error() -> void:
	join_error_text = ""
	join_error_code = 0


## Show packed copy for this ErrorCode and unlock interact so the player can retry.
## Unknown codes are logged through DataCatalog and do not use a silent fallback.
func apply_portal_error(code: int) -> String:
	var ui := LobbyUiSettings.load_default()
	if ui.maps_error(code):
		portal_error_text = ui.error_message(code)
	else:
		DataCatalog.report_unknown_id(ErrorCodes.catalog_id(code))
		portal_error_text = ""
	portal_error_code = code
	interact_pressed = false
	interact_target_id = 0
	return portal_error_text


func clear_portal_error() -> void:
	portal_error_text = ""
	portal_error_code = 0


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
	sim.set_lobby_settings(LobbySettings.new())
	var yard_e: int = 1
	if catalog != null and catalog.scaling != null:
		yard_e = catalog.scaling.practice_yard_content_level
	sim.spawn_enemy("burrmite", 24.0, 10.0, yard_e)
	sim.spawn_enemy("driftcap_spore", 24.0, 20.0, yard_e)
	sim.spawn_practice_portal("hollowmere_vault")
	return sim


func _reset_snapshots() -> void:
	_accum = 0.0
	_seq = 0
	curr_snapshot = source.snapshot() if source != null else WorldSnapshot.new()
	prev_snapshot = curr_snapshot.duplicate_snapshot()


func _teardown_net() -> void:
	clear_portal_error()
	if beacon != null:
		beacon.stop()
		beacon = null
	if lobby_host != null:
		if lobby_host.settings_changed.is_connected(_on_host_settings_changed):
			lobby_host.settings_changed.disconnect(_on_host_settings_changed)
		if lobby_host.portal_rejected.is_connected(_on_host_portal_rejected):
			lobby_host.portal_rejected.disconnect(_on_host_portal_rejected)
		lobby_host.stop()
		lobby_host = null
	local_join.reset()
	if lobby_client != null:
		lobby_client.stop()
		lobby_client.queue_free()
		lobby_client = null


func _process(delta: float) -> void:
	if source == null:
		return
	if mode == Mode.HOST and lobby_host != null:
		_process_host(delta)
		return
	if lobby_host != null:
		lobby_host.service()
	var dt: float = SimConstants.TICK_DT
	_accum += delta
	var steps: int = 0
	while _accum >= dt and steps < MAX_CATCH_UP_TICKS:
		_accum -= dt
		steps += 1
		# uint32 wrap; seq 0 is always rejected by the host, so skip it.
		_seq = Seq.next(_seq)
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
		_apply_solo_transfers()
		prev_snapshot = curr_snapshot
		curr_snapshot = source.snapshot()
		_capture_hits()
	# If we hit the catch-up cap, drop leftover time so the sim does not spiral.
	if steps >= MAX_CATCH_UP_TICKS and _accum >= dt:
		_accum = fmod(_accum, dt)
	alpha = clampf(_accum / dt, 0.0, 1.0)


func _process_host(delta: float) -> void:
	# Submit before service() so this frame's input is in the due host tick.
	# uint32 wrap; seq 0 is always rejected by the host, so skip it.
	_seq = Seq.next(_seq)
	var intent := InputIntent.from_raw(
		_seq, move_x, move_y, aim, fire_held, interact_pressed, inventory_slot, interact_target_id,
		ability_pressed
	)
	interact_pressed = false
	inventory_slot = 0
	interact_target_id = 0
	ability_pressed = false
	source.submit_input(intent)
	lobby_host.service()
	if beacon != null:
		beacon.player_count = LobbyConfig.beacon_player_count(
			lobby_host.players.size(), lobby_host.max_players)
		beacon.poll(delta)
	var view: WorldSnapshot = source.snapshot()
	if view != null and view.tick != curr_snapshot.tick:
		prev_snapshot = curr_snapshot
		curr_snapshot = view
		_capture_hits()
	var due: int = lobby_host.next_deadline_usec()
	var now: int = lobby_host.clock.call() if lobby_host.clock.is_valid() else Time.get_ticks_usec()
	alpha = clampf(1.0 - float(due - now) / float(LobbyHost.PERIOD_USEC), 0.0, 1.0)


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


func _capture_hits() -> void:
	last_hits.clear()
	last_hit_tick = curr_snapshot.tick if curr_snapshot != null else -1
	var sim := source as LocalSim
	if sim == null:
		return
	for ev in sim.hits():
		last_hits.append(ev)


func feel() -> FeelSettings:
	if catalog != null and catalog.feel != null and catalog.feel.is_valid():
		return catalog.feel
	return null


func _apply_solo_transfers() -> void:
	var sim := source as LocalSim
	if sim == null:
		return
	var transfers := sim.take_pending_transfers()
	if transfers.is_empty():
		return
	# Solo play has one local player; take the first transfer this tick.
	_switch_solo_instance(sim, transfers[0])


func _switch_solo_instance(old: LocalSim, xfer: PortalTransfer) -> void:
	var player := old.get_player(xfer.player_id)
	if player == null:
		return
	var carry := old.carry_out(xfer.player_id)
	var next: LocalSim
	if xfer.kind == PortalTransfer.KIND_ENTER:
		next = _new_dungeon_sim(xfer)
	else:
		next = _new_sim()
	next.apply_carried_player(carry, xfer.arrival_x, xfer.arrival_y)
	source = next


func _new_dungeon_sim(xfer: PortalTransfer) -> LocalSim:
	if catalog == null:
		catalog = DataCatalog.load_default()
	var def: DungeonDef = catalog.dungeon(xfer.dungeon_id)
	var sim := LocalSim.new(config, xfer.arrival_x, xfer.arrival_y, catalog)
	if def != null:
		sim.configure_dungeon(
			def, xfer.seed, xfer.m100, xfer.base_level, xfer.content_level,
			xfer.opener_id, xfer.opener_lp, xfer.grants_persistent
		)
	return sim

