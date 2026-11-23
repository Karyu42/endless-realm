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
var _fire_acc: float = 0.0
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


func fire_accumulator() -> float:
	return _fire_acc / float(SimConstants.TICK_HZ)


func _apply_movement() -> void:
	var mx := _intent.move_x
	var my := _intent.move_y
	var len := sqrt(mx * mx + my * my)
	if len > 1.0:
		mx /= len
		my /= len
	elif len <= SimConstants.MOVE_EPS:
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
	# Content-spec timing: add Tempo each tick, fire each time the sum reaches
	# TICK_HZ (equivalent to adding Tempo/TICK_HZ and firing at 1, but this
	# stays exact for the designed rates 2.0 / 2.5 / 3.5). On release, cap at
	# one stored shot so a tap cannot bank extras.
	var hz: float = float(SimConstants.TICK_HZ)
	if _intent.fire_held:
		var tempo: float = _config.fire_rate_shots_per_s * (1.0 + _config.tempo_bonus)
		_fire_acc += tempo
		while _fire_acc >= hz:
			_fire_acc -= hz
			_spawn_projectile()
	else:
		_fire_acc = minf(_fire_acc, hz)


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
