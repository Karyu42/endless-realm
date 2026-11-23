class_name LocalSim
extends WorldSource
## In-process 20 Hz authority used for the offline slice. Sim lives in plain
## RefCounted classes, not Nodes.

var _config: SimConfig
var _tick: int = 0
var _player_id: int = 1
var _next_id: int = 2
var _px: float = 0.0
var _py: float = 0.0
var _aim: float = 0.0
var _applied_seq: int = 0
var _intent: InputIntent = InputIntent.new()
var _fire_cooldown: int = 0
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
	_tick += 1
	_applied_seq = _intent.seq
	_aim = _intent.aim
	_apply_movement()
	_apply_fire()
	_cull_projectiles()


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


func fire_cooldown() -> int:
	return _fire_cooldown


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


func _apply_fire() -> void:
	# First shot on the tick fire is pressed if the weapon is off cooldown.
	# Cooldown is ceil(TICK_HZ / (Tempo * (1 + bonus))) ticks, counted from
	# that shot (10 ticks at 2/s and 20 Hz). It keeps running after release,
	# so tapping cannot beat the fire rate. Applies to every weapon.
	if _fire_cooldown > 0:
		_fire_cooldown -= 1
	if not _intent.fire_held:
		return
	var interval: int = _config.fire_interval_ticks()
	if interval <= 0:
		return
	if _fire_cooldown == 0:
		_spawn_projectile()
		_fire_cooldown = interval


func _spawn_projectile() -> void:
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
	shot.spawn_tick = _tick
	shot.origin_x = _px
	shot.origin_y = _py
	shot.dir_x = dir.x
	shot.dir_y = dir.y
	shot.speed = _config.projectile_speed_tiles_per_s
	shot.range_tiles = _config.projectile_range_tiles
	shot.lifetime_ticks = _config.projectile_lifetime_ticks()
	shot.radius_tiles = _config.projectile_radius_tiles
	_projectiles.append(shot)


func _cull_projectiles() -> void:
	var live: Array[SimProjectile] = []
	for shot in _projectiles:
		if shot.is_alive_at(_tick):
			live.append(shot)
	_projectiles = live
