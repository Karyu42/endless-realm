extends Node
## Autoload. Owns a WorldSource, steps it at 20 Hz, and exposes snapshots for
## render interpolation. Gameplay nodes emit input and read state only.
## Solo play and a later player-hosted lobby both run LocalSim (plain
## RefCounted game rules). This node is the session wrapper, not the sim.

var config: SimConfig
var catalog: DataCatalog
var source: WorldSource
var prev_snapshot: WorldSnapshot = WorldSnapshot.new()
var curr_snapshot: WorldSnapshot = WorldSnapshot.new()
var alpha: float = 0.0

## Latest raw input, written by the arena / virtual sticks each display frame.
var move_x: float = 0.0
var move_y: float = 0.0
var aim: float = 0.0
var fire_held: bool = false
var interact_pressed: bool = false
var inventory_slot: int = 0
## Snapshot id of the interactable the client auto-selected (0 = none).
var interact_target_id: int = 0

var _accum: float = 0.0
var _seq: int = 0
const MAX_CATCH_UP_TICKS: int = 5


func _ready() -> void:
	config = load("res://resources/sim_config.tres") as SimConfig
	if config == null:
		config = SimConfig.new()
	catalog = DataCatalog.load_default()
	var sim := LocalSim.new(config, 16.0, 16.0, catalog)
	sim.set_bounds(0.0, 0.0, 32.0, 32.0)
	sim.set_world_seed(1)
	sim.set_player_class("thornguard")
	# Practice yard: every enemy is fixed at the data E (killXP(1), Glint 1, T* = 0).
	sim.set_practice_yard(true)
	sim.spawn_enemy("burrmite", 24.0, 10.0, catalog.scaling.practice_yard_content_level)
	source = sim
	curr_snapshot = source.snapshot()
	prev_snapshot = curr_snapshot.duplicate_snapshot()


func _process(delta: float) -> void:
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
			_seq, move_x, move_y, aim, fire_held, interact_pressed, inventory_slot, interact_target_id
		)
		# Consume one-shot actions so catch-up ticks do not repeat them.
		interact_pressed = false
		inventory_slot = 0
		interact_target_id = 0
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
