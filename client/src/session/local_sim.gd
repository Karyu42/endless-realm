class_name LocalSim
extends WorldSource
## In-process 20 Hz authority used for the offline slice. Sim lives in plain
## RefCounted classes, not Nodes.

const READY_EPS: float = 1e-9

var _config: SimConfig
var _tick: int = 0
var _player_id: int = 1
var _next_id: int = 2
var _px: float = 0.0
var _py: float = 0.0
var _aim: float = 0.0
var _applied_seq: int = 0
var _intent: InputIntent = InputIntent.new()
var _next_ready: float = 0.0
var _hold_since_volley: bool = false
var _fire_blocked: bool = false
var _projectiles: Array[SimProjectile] = []
var _has_bounds: bool = false
var _bound_min_x: float = 0.0
var _bound_min_y: float = 0.0
var _bound_max_x: float = 0.0
var _bound_max_y: float = 0.0


func _init(config: SimConfig = null, start_x: float = 0.0, start_y: float = 0.0) -> void:
	_config = config if config != null else SimConfig.new()
	_px = start_x
	_py = start_y


func set_bounds(min_x: float, min_y: float, max_x: float, max_y: float) -> void:
	_has_bounds = true
	_bound_min_x = min_x
	_bound_min_y = min_y
	_bound_max_x = max_x
	_bound_max_y = max_y


func clear_bounds() -> void:
	_has_bounds = false


func config() -> SimConfig:
	return _config


func submit_input(intent: InputIntent) -> void:
	_intent = intent


func step() -> void:
	# Time index of this tick (first processed tick is 0, now = tick × 0.05).
	# tick() / snapshot.tick stay "completed ticks" (1 after the first step).
	var sim_tick: int = _tick
	_applied_seq = _intent.seq
	_aim = _intent.aim
	_apply_movement()
	_apply_fire(sim_tick)
	_cull_projectiles(sim_tick)
	_tick += 1


func tick() -> int:
	return _tick


func snapshot() -> WorldSnapshot:
	var snap := WorldSnapshot.new()
	snap.tick = _tick
	snap.player_id = _player_id
	snap.player_x = _px
	snap.player_y = _py
	snap.player_aim = _aim
	snap.applied_seq = _applied_seq
	snap.projectiles = _projectiles.duplicate()
	return snap


func projectile_count() -> int:
	return _projectiles.size()


func next_ready() -> float:
	return _next_ready


## Hook for a later ability lock (Kindle Pulse, PR #19). A blocked tick breaks
## the continuous hold and does not reset next_ready, so there is no catch-up.
func is_fire_blocked() -> bool:
	return _fire_blocked


func set_fire_blocked(blocked: bool) -> void:
	_fire_blocked = blocked


## Tempo × (1 + tempoBonus) is read when a volley is scheduled, so a mid-hold
## rate change keeps the pending next_ready and applies the new cd after it.
func _current_fire_cooldown_s() -> float:
	return _config.fire_cooldown_s()


func _apply_movement() -> void:
	var mx := _intent.move_x
	var my := _intent.move_y
	var move_len := sqrt(mx * mx + my * my)
	if move_len > 1.0:
		mx /= move_len
		my /= move_len
	elif move_len <= SimConstants.MOVE_EPS:
		mx = 0.0
		my = 0.0
	var step_len: float = _config.move_speed_tiles_per_s * SimConstants.TICK_DT
	_px += mx * step_len
	_py += my * step_len
	if _has_bounds:
		var r: float = _config.player_radius_tiles
		_px = clampf(_px, _bound_min_x + r, _bound_max_x - r)
		_py = clampf(_py, _bound_min_y + r, _bound_max_y - r)


func _apply_fire(sim_tick: int) -> void:
	# content-v0.1.md §1: next_ready is float64 seconds (tick × 0.05), starts at 0.
	# cd = 1 / (Tempo × (1 + tempoBonus)). One volley when fire_held and
	# now ≥ next_ready − 1e-9. A continuous hold schedules the next ready
	# time from the previous ready time (not the landing tick) so a fractional
	# cd stays exact over the long run. A press after a release sets
	# next_ready = now + cd. Release never resets next_ready.
	var now: float = float(sim_tick) * SimConstants.TICK_DT
	if is_fire_blocked():
		_hold_since_volley = false
		return
	if not _intent.fire_held:
		_hold_since_volley = false
		return
	# Rate is read per scheduled shot, not cached for the whole hold.
	var cd: float = _current_fire_cooldown_s()
	if cd <= 0.0:
		return
	if now >= _next_ready - READY_EPS:
		var continuous: bool = _hold_since_volley
		_spawn_projectile(sim_tick)
		if continuous:
			_next_ready += cd
		else:
			_next_ready = now + cd
		_hold_since_volley = true


func _spawn_projectile(sim_tick: int) -> void:
	var dir := SimVec2.from_angle(_aim)
	# If aim is somehow NaN, skip rather than inject a bad shot.
	if is_nan(dir.x) or is_nan(dir.y):
		return
	if dir.length_squared() <= SimConstants.MOVE_EPS:
		dir = SimVec2.from_xy(1.0, 0.0)
	else:
		dir = dir.normalized()
	var shot := SimProjectile.new()
	shot.id = _next_id
	_next_id += 1
	shot.spawn_tick = sim_tick
	shot.origin_x = _px
	shot.origin_y = _py
	shot.dir_x = dir.x
	shot.dir_y = dir.y
	shot.speed = _config.projectile_speed_tiles_per_s
	shot.range_tiles = _config.projectile_range_tiles
	shot.lifetime_ticks = _config.projectile_lifetime_ticks()
	shot.radius_tiles = _config.projectile_radius_tiles
	_projectiles.append(shot)


func _cull_projectiles(sim_tick: int) -> void:
	var live: Array[SimProjectile] = []
	for shot in _projectiles:
		if shot.is_alive_at(sim_tick):
			live.append(shot)
	_projectiles = live
