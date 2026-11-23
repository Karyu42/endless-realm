class_name LocalSim
extends WorldSource
## In-process 20 Hz authority used for the offline slice and, later, a
## player-hosted lobby. Every game rule lives in plain RefCounted classes —
## no Node, SceneTree, Input, or rendering dependencies — and is deterministic
## (tick-based, PCG32 only).

var _config: SimConfig
var _catalog: DataCatalog
var _world_seed: int = 1
var _tick: int = 0
var _player_id: int = 1
var _next_id: int = 2
var _px: float = 0.0
var _py: float = 0.0
var _prev_px: float = 0.0
var _prev_py: float = 0.0
var _aim: float = 0.0
var _player_hp: int = 200
var _player_flash_ticks: int = 0
var _applied_seq: int = 0
var _intent: InputIntent = InputIntent.new()
var _fire_acc: float = 0.0
var _projectiles: Array[SimProjectile] = []
var _enemies: Array[EnemyState] = []
var _pattern_bullets: Array[PatternBullet] = []
var _has_bounds: bool = false
var _bound_min_x: float = 0.0
var _bound_min_y: float = 0.0
var _bound_max_x: float = 0.0
var _bound_max_y: float = 0.0


func _init(config: SimConfig = null, start_x: float = 0.0, start_y: float = 0.0, catalog: DataCatalog = null) -> void:
	_config = config if config != null else SimConfig.new()
	_catalog = catalog
	_px = start_x
	_py = start_y
	_prev_px = start_x
	_prev_py = start_y
	_player_hp = _config.player_max_hp


func set_bounds(min_x: float, min_y: float, max_x: float, max_y: float) -> void:
	_has_bounds = true
	_bound_min_x = min_x
	_bound_min_y = min_y
	_bound_max_x = max_x
	_bound_max_y = max_y


func clear_bounds() -> void:
	_has_bounds = false


func set_catalog(catalog: DataCatalog) -> void:
	_catalog = catalog


func set_world_seed(seed: int) -> void:
	_world_seed = seed


func config() -> SimConfig:
	return _config


func submit_input(intent: InputIntent) -> void:
	_intent = intent


func spawn_enemy(def_id: String, x: float, y: float) -> int:
	if _catalog == null:
		push_warning("LocalSim.spawn_enemy: no DataCatalog")
		return 0
	var def := _catalog.enemy(def_id)
	if def == null:
		push_warning("LocalSim.spawn_enemy: unknown id %s" % def_id)
		return 0
	return spawn_enemy_from_def(def, x, y)


func spawn_enemy_from_def(def: EnemyDef, x: float, y: float) -> int:
	if def == null:
		return 0
	var e := EnemyState.new()
	e.id = _next_id
	_next_id += 1
	e.def = def
	e.x = x
	e.y = y
	e.prev_x = x
	e.prev_y = y
	e.home_x = x
	e.home_y = y
	e.hp = def.base_hp
	e.strafe_ticks = def.strafe_switch_ticks
	e.fire_cooldown = 0
	_enemies.append(e)
	return e.id


func step() -> void:
	_prev_px = _px
	_prev_py = _py
	for e in _enemies:
		e.prev_x = e.x
		e.prev_y = e.y
	_tick += 1
	_applied_seq = _intent.seq
	_aim = _intent.aim
	if _player_flash_ticks > 0:
		_player_flash_ticks -= 1
	_apply_movement()
	_apply_fire()
	_step_enemies()
	_apply_combat()
	_cull_projectiles()
	_cull_pattern_bullets()
	_cull_enemies()


func tick() -> int:
	return _tick


func snapshot() -> WorldSnapshot:
	var snap := WorldSnapshot.new()
	snap.tick = _tick
	snap.player_id = _player_id
	snap.player_x = _px
	snap.player_y = _py
	snap.player_aim = _aim
	snap.player_hp = _player_hp
	snap.player_max_hp = _config.player_max_hp
	snap.player_flash_ticks = _player_flash_ticks
	snap.applied_seq = _applied_seq
	snap.projectiles = _projectiles.duplicate()
	snap.pattern_bullets = _pattern_bullets.duplicate()
	var enemy_snaps: Array[EnemySnapshot] = []
	for e in _enemies:
		if not e.alive:
			continue
		var es := EnemySnapshot.new()
		es.id = e.id
		es.def_id = e.def.id if e.def != null else ""
		es.x = e.x
		es.y = e.y
		es.aim = e.aim
		es.hp = e.hp
		es.max_hp = e.max_hp()
		es.radius = e.radius()
		enemy_snaps.append(es)
	snap.enemies = enemy_snaps
	return snap


func projectile_count() -> int:
	return _projectiles.size()


func pattern_bullet_count() -> int:
	return _pattern_bullets.size()


func enemy_count() -> int:
	return _enemies.size()


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


func _step_enemies() -> void:
	for e in _enemies:
		if not e.alive:
			continue
		_step_one_enemy(e)


func _step_one_enemy(e: EnemyState) -> void:
	var dx: float = _px - e.x
	var dy: float = _py - e.y
	var dist: float = sqrt(dx * dx + dy * dy)
	var home_dx: float = e.x - e.home_x
	var home_dy: float = e.y - e.home_y
	var home_dist: float = sqrt(home_dx * home_dx + home_dy * home_dy)
	if e.aggro:
		if home_dist > e.def.leash:
			e.aggro = false
	elif dist <= e.def.aggro_radius and home_dist <= e.def.leash:
		e.aggro = true
	if e.contact_cooldown > 0:
		e.contact_cooldown -= 1
	if e.fire_cooldown > 0:
		e.fire_cooldown -= 1
	var mx: float = 0.0
	var my: float = 0.0
	var speed: float = e.def.wander_speed
	if e.aggro:
		speed = e.def.move_speed
		if dist > SimConstants.MOVE_EPS:
			e.aim = atan2(dy, dx)
		if dist > e.def.hover_radius and dist > SimConstants.MOVE_EPS:
			mx = dx / dist
			my = dy / dist
		else:
			e.strafe_ticks -= 1
			if e.strafe_ticks <= 0:
				e.strafe_sign *= -1.0
				e.strafe_ticks = e.def.strafe_switch_ticks
			if dist > SimConstants.MOVE_EPS:
				mx = (-dy / dist) * e.strafe_sign
				my = (dx / dist) * e.strafe_sign
		if e.fire_cooldown <= 0:
			_emit_enemy_pattern(e)
			e.fire_cooldown = e.def.fire_interval_ticks
	else:
		e.wander_ticks -= 1
		if e.wander_ticks <= 0:
			var rng := PCG32.new(_mix_seed(_world_seed, e.id, _tick), 1)
			e.wander_angle = (float(rng.uint32()) / 4294967296.0) * TAU
			e.wander_ticks = e.def.strafe_switch_ticks
		mx = cos(e.wander_angle)
		my = sin(e.wander_angle)
	var step: float = speed * SimConstants.TICK_DT
	e.x += mx * step
	e.y += my * step
	if _has_bounds:
		var r: float = e.radius()
		e.x = clampf(e.x, _bound_min_x + r, _bound_max_x - r)
		e.y = clampf(e.y, _bound_min_y + r, _bound_max_y - r)


func _emit_enemy_pattern(e: EnemyState) -> void:
	if e.def.pattern_id == "":
		return
	if _catalog == null:
		return
	var def := _catalog.pattern(e.def.pattern_id)
	if def == null:
		return
	var seed: int = _mix_seed(_world_seed, e.id, _tick + e.volley_index)
	var bullets := def.emit(seed, e.x, e.y, e.aim, e.volley_index)
	for b in bullets:
		b.id = _next_id
		_next_id += 1
		b.spawn_tick = _tick
		b.source_id = e.id
		_pattern_bullets.append(b)
	e.volley_index += 1


func _mix_seed(a: int, b: int, c: int) -> int:
	# SplitMix-style mix; wraps at 2^64 the same way on a later headless host.
	# Constants are the signed form of 0x9E3779B97F4A7C15, 0xBF58476D1CE4E5B9,
	# and 0x94D049BB133111EB (Godot rejects those hex literals as > int64 max).
	return a * -7046029254386353131 + b * -4658895280553007687 + c * -7723592293110705685


func _apply_combat() -> void:
	_player_shots_vs_enemies()
	_pattern_shots_vs_player()
	_contact_vs_player()


func _player_shots_vs_enemies() -> void:
	for shot in _projectiles:
		if not shot.is_alive_at(_tick):
			continue
		var p0 := shot.position_at_time(float(_tick - 1))
		var p1 := shot.position_at_time(float(_tick))
		for e in _enemies:
			if not e.alive:
				continue
			if SweepHit.moving_circles(
				p0.x, p0.y, p1.x, p1.y, shot.radius_tiles,
				e.prev_x, e.prev_y, e.x, e.y, e.radius()
			):
				e.hp -= _config.player_projectile_damage
				shot.consumed = true
				if e.hp <= 0:
					e.hp = 0
					e.alive = false
				break


func _pattern_shots_vs_player() -> void:
	if _player_hp <= 0:
		return
	for b in _pattern_bullets:
		if not b.is_alive_at(_tick):
			continue
		var p0 := b.position_at_time(float(_tick - 1))
		var p1 := b.position_at_time(float(_tick))
		if SweepHit.moving_circles(
			p0.x, p0.y, p1.x, p1.y, b.radius_tiles,
			_prev_px, _prev_py, _px, _py, _config.player_radius_tiles
		):
			var dmg: int = 0
			var src := _enemy_by_id(b.source_id)
			if src != null and src.def != null:
				dmg = src.def.damage_for(b.damage_key)
			_hurt_player(dmg)
			b.consumed = true
			if _player_hp <= 0:
				return


func _contact_vs_player() -> void:
	if _player_hp <= 0:
		return
	for e in _enemies:
		if not e.alive or e.contact_cooldown > 0:
			continue
		if SweepHit.moving_circles(
			_prev_px, _prev_py, _px, _py, _config.player_radius_tiles,
			e.prev_x, e.prev_y, e.x, e.y, e.radius()
		):
			_hurt_player(e.def.contact_damage if e.def != null else 0)
			e.contact_cooldown = _config.contact_cooldown_ticks
			if _player_hp <= 0:
				return


func _hurt_player(amount: int) -> void:
	if amount <= 0 or _player_hp <= 0:
		return
	_player_hp -= amount
	if _player_hp < 0:
		_player_hp = 0
	_player_flash_ticks = _config.player_flash_ticks


func _enemy_by_id(id: int) -> EnemyState:
	for e in _enemies:
		if e.id == id:
			return e
	return null


func _cull_projectiles() -> void:
	var live: Array[SimProjectile] = []
	for shot in _projectiles:
		if shot.is_alive_at(_tick):
			live.append(shot)
	_projectiles = live


func _cull_pattern_bullets() -> void:
	var live: Array[PatternBullet] = []
	for b in _pattern_bullets:
		if b.is_alive_at(_tick):
			live.append(b)
	_pattern_bullets = live


func _cull_enemies() -> void:
	var live: Array[EnemyState] = []
	for e in _enemies:
		if e.alive:
			live.append(e)
	_enemies = live
