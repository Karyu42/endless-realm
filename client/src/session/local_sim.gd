class_name LocalSim
extends WorldSource
## In-process 20 Hz authority used for the offline slice and, later, a
## player-hosted lobby. Every game rule lives in plain RefCounted classes —
## no Node, SceneTree, Input, or rendering dependencies — and is deterministic
## (tick-based, PCG32 only).

const READY_EPS: float = 1e-9
## content-v0.1 §2.3: nearest player in aggro range, re-picked every 1 s.
const TARGET_REPICK_TICKS: int = 20

var _config: SimConfig
var _catalog: DataCatalog
var _world_seed: int = 1
var _tick: int = 0
var _player_id: int = 1
## Entity ids are uint64 on the wire; GDScript int is signed, so they stay
## strictly below 2^63.
const MAX_ENTITY_ID: int = 0x7FFFFFFFFFFFFFFF
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
var _next_ready: float = 0.0
var _hold_since_volley: bool = false
var _fire_blocked: bool = false
var _projectiles: Array[SimProjectile] = []
var _enemies: Array[EnemyState] = []
var _pattern_bullets: Array[PatternBullet] = []
var _hit_p0: SimVec2 = SimVec2.new()
var _hit_p1: SimVec2 = SimVec2.new()
var _has_bounds: bool = false
var _bound_min_x: float = 0.0
var _bound_min_y: float = 0.0
var _bound_max_x: float = 0.0
var _bound_max_y: float = 0.0
var _scaling: SimScaling = SimScaling.new()
var _loot: LootTables = LootTables.new()
var _class_def: ClassDef = null
var _player_class_id: String = ""
var _player_level: int = 1
var _xp_tenths: int = 0
var _pending_glint: int = 0
var _inventory: PlayerInventory = PlayerInventory.new()
var _ground_drops: Array[GroundDrop] = []
var _granted_drop_ids: Dictionary = {} # drop_id -> true
var _instance_m100: int = 100
var _in_portal: bool = false
var _practice_yard: bool = false
var _last_interact_seq: int = -1
## Extra players for target picking (id -> {x, y, hp}). The authority
## player remains _player_id / _px / _py.
var _other_players: Dictionary = {}


func _init(config: SimConfig = null, start_x: float = 0.0, start_y: float = 0.0, catalog: DataCatalog = null) -> void:
	_config = config if config != null else SimConfig.new()
	_catalog = catalog
	_px = start_x
	_py = start_y
	_prev_px = start_x
	_prev_py = start_y
	_player_hp = _config.player_max_hp
	if _catalog != null:
		if _catalog.scaling != null:
			_scaling = _catalog.scaling
		if _catalog.loot != null:
			_loot = _catalog.loot
			_inventory = PlayerInventory.new(_loot.inventory_slots)
	_recompute_player_stats(true)


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
	if _catalog != null:
		if _catalog.scaling != null:
			_scaling = _catalog.scaling
		if _catalog.loot != null:
			_loot = _catalog.loot


func set_world_seed(seed: int) -> void:
	_world_seed = seed


func config() -> SimConfig:
	return _config


func submit_input(intent: InputIntent) -> void:
	_intent = intent


func _alloc_id() -> int:
	var id: int = _next_id
	if _next_id < MAX_ENTITY_ID:
		_next_id += 1
	return id


func spawn_enemy(def_id: String, x: float, y: float, content_level: int = 1) -> int:
	if _catalog == null:
		push_warning("LocalSim.spawn_enemy: no DataCatalog")
		return 0
	var def := _catalog.enemy(def_id)
	if def == null:
		push_warning("LocalSim.spawn_enemy: unknown id %s" % def_id)
		return 0
	return spawn_enemy_from_def(def, x, y, content_level)


func spawn_enemy_from_def(def: EnemyDef, x: float, y: float, content_level: int = 1) -> int:
	if def == null:
		return 0
	var e := EnemyState.new()
	e.id = _alloc_id()
	e.def = def
	e.x = x
	e.y = y
	e.prev_x = x
	e.prev_y = y
	e.home_x = x
	e.home_y = y
	e.content_level = _scaling.practice_yard_content_level if _practice_yard else maxi(1, content_level)
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
	# Time index of this tick (first processed tick is 0, now = tick × 0.05).
	# tick() / snapshot.tick stay "completed ticks" (1 after the first step).
	var sim_tick: int = _tick
	_applied_seq = _intent.seq
	_aim = _intent.aim
	if _player_flash_ticks > 0:
		_player_flash_ticks -= 1
	_apply_movement()
	_apply_fire(sim_tick)
	_step_enemies(sim_tick)
	_apply_combat(sim_tick)
	_expire_ground_drops(sim_tick)
	_apply_interact(sim_tick)
	_apply_inventory_hotkey()
	_cull_projectiles(sim_tick)
	_cull_pattern_bullets(sim_tick)
	_cull_enemies()
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
	snap.player_hp = _player_hp
	snap.player_max_hp = player_max_hp()
	snap.player_flash_ticks = _player_flash_ticks
	snap.applied_seq = _applied_seq
	snap.player_level = _player_level
	snap.xp_tenths = _xp_tenths
	snap.xp_to_next_tenths = _scaling.xp_to_next_tenths(_player_level)
	snap.pending_glint = _pending_glint
	snap.inventory = _inventory.slots.duplicate()
	snap.equipped_weapon = _inventory.equipped_weapon
	snap.equipped_armor = _inventory.equipped_armor
	snap.equipped_charm = _inventory.equipped_charm
	var bags: Array[GroundDrop] = []
	for bag in _ground_drops:
		if bag.item != null and bag.item.owner_player_id == _player_id and bag.item.state == ItemState.STATE_LIVE:
			bags.append(bag)
	snap.ground_drops = bags
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
		es.content_level = e.content_level
		enemy_snaps.append(es)
	snap.enemies = enemy_snaps
	return snap


func projectile_count() -> int:
	return _projectiles.size()


func pattern_bullet_count() -> int:
	return _pattern_bullets.size()


func enemy_count() -> int:
	return _enemies.size()


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
	shot.id = _alloc_id()
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



func place_player(id: int, x: float, y: float, hp: int = -1) -> void:
	if id == _player_id:
		_px = x
		_py = y
		if hp >= 0:
			_player_hp = hp
		return
	var entry: Dictionary = _other_players.get(id, {"x": 0.0, "y": 0.0, "hp": _config.player_max_hp})
	entry["x"] = x
	entry["y"] = y
	if hp >= 0:
		entry["hp"] = hp
	_other_players[id] = entry


func enemy_target_id(enemy_id: int) -> int:
	var e := _enemy_by_id(enemy_id)
	return e.target_id if e != null else 0


func _player_pos(id: int) -> Vector2:
	if id == _player_id:
		return Vector2(_px, _py)
	var entry: Variant = _other_players.get(id, null)
	if entry is Dictionary:
		return Vector2(float(entry["x"]), float(entry["y"]))
	return Vector2(_px, _py)


func _player_hp_of(id: int) -> int:
	if id == _player_id:
		return _player_hp
	var entry: Variant = _other_players.get(id, null)
	if entry is Dictionary:
		return int(entry["hp"])
	return 0


func _player_is_living(id: int) -> bool:
	if id == _player_id:
		return _player_hp > 0
	if not _other_players.has(id):
		return false
	return int(_other_players[id]["hp"]) > 0


func _foreach_living_player_ids() -> Array[int]:
	var ids: Array[int] = []
	if _player_hp > 0:
		ids.append(_player_id)
	var other_ids: Array = _other_players.keys()
	other_ids.sort()
	for id in other_ids:
		if int(_other_players[id]["hp"]) > 0:
			ids.append(int(id))
	return ids


func _nearest_player_in_aggro(e: EnemyState) -> int:
	var best_id: int = 0
	var best_d2: float = -1.0
	for pid in _foreach_living_player_ids():
		var pos := _player_pos(pid)
		var dx: float = pos.x - e.x
		var dy: float = pos.y - e.y
		var d2: float = dx * dx + dy * dy
		var r: float = e.def.aggro_radius if e.def != null else 0.0
		if d2 > r * r:
			continue
		if best_id == 0 or d2 < best_d2 - 1e-12 or (abs(d2 - best_d2) <= 1e-12 and pid < best_id):
			best_id = pid
			best_d2 = d2
	return best_id


func _target_is_valid(e: EnemyState) -> bool:
	if e.target_id == 0 or not _player_is_living(e.target_id) or e.def == null:
		return false
	var pos := _player_pos(e.target_id)
	var dx: float = pos.x - e.x
	var dy: float = pos.y - e.y
	var r: float = e.def.aggro_radius
	return dx * dx + dy * dy <= r * r


func _step_enemies(sim_tick: int) -> void:
	for e in _enemies:
		if not e.alive:
			continue
		_step_one_enemy(e, sim_tick)


func _step_one_enemy(e: EnemyState, sim_tick: int) -> void:
	var home_dx: float = e.x - e.home_x
	var home_dy: float = e.y - e.home_y
	var home_dist: float = sqrt(home_dx * home_dx + home_dy * home_dy)
	var nearest_id: int = _nearest_player_in_aggro(e)
	var was_aggro: bool = e.aggro
	if e.aggro:
		if home_dist > e.def.leash or nearest_id == 0:
			# Leashed, or nobody alive in aggro range: idle. Do not aim
			# at the authority player when that player is far or dead.
			e.aggro = false
			e.target_id = 0
	elif nearest_id != 0 and home_dist <= e.def.leash:
		e.aggro = true
	# content-v0.1 §2.3: first attack comes fire_interval after aggro (and re-aggro).
	# The target is the nearest living player in aggro range, re-picked every 1 s.
	if e.aggro and not was_aggro:
		e.fire_cooldown = e.def.fire_interval_ticks
		e.target_id = nearest_id
		e.target_repick_tick = sim_tick + TARGET_REPICK_TICKS
	elif e.aggro:
		if (not _target_is_valid(e)) or sim_tick >= e.target_repick_tick:
			e.target_id = nearest_id
			e.target_repick_tick = sim_tick + TARGET_REPICK_TICKS
	# Aim only at the current target. Never fall back to the host player.
	var aim_x: float = e.x
	var aim_y: float = e.y
	if e.target_id != 0:
		var tpos := _player_pos(e.target_id)
		aim_x = tpos.x
		aim_y = tpos.y
	var dx: float = aim_x - e.x
	var dy: float = aim_y - e.y
	var dist: float = sqrt(dx * dx + dy * dy)
	if e.contact_cooldown > 0:
		e.contact_cooldown -= 1
	var mx: float = 0.0
	var my: float = 0.0
	var rooted: bool = e.def.is_rooted()
	var speed: float = 0.0 if rooted else e.def.wander_speed
	if e.aggro:
		if not rooted:
			speed = e.def.move_speed
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
		if dist > SimConstants.MOVE_EPS:
			e.aim = atan2(dy, dx)
		# No packed interval means no fallback rate: do not fire.
		if e.def.fire_interval_ticks > 0 and e.fire_cooldown <= 0:
			_emit_enemy_pattern(e, sim_tick)
			e.fire_cooldown = e.def.fire_interval_ticks
	elif not rooted:
		e.wander_ticks -= 1
		if e.wander_ticks <= 0:
			var rng := PCG32.new(_mix_seed(_world_seed, e.id, sim_tick), 1)
			e.wander_angle = (float(rng.uint32()) / 4294967296.0) * TAU
			e.wander_ticks = e.def.strafe_switch_ticks
		mx = cos(e.wander_angle)
		my = sin(e.wander_angle)
	if e.fire_cooldown > 0:
		e.fire_cooldown -= 1
	var step: float = speed * SimConstants.TICK_DT
	e.x += mx * step
	e.y += my * step
	if _has_bounds:
		var r: float = e.radius()
		e.x = clampf(e.x, _bound_min_x + r, _bound_max_x - r)
		e.y = clampf(e.y, _bound_min_y + r, _bound_max_y - r)


func _emit_enemy_pattern(e: EnemyState, sim_tick: int) -> void:
	if e.def.pattern_id == "":
		return
	if _catalog == null:
		return
	var def := _catalog.pattern(e.def.pattern_id)
	if def == null:
		return
	var seed: int = _mix_seed(_world_seed, e.id, sim_tick + e.volley_index)
	var bullets := def.emit(seed, e.x, e.y, e.aim, e.volley_index)
	for b in bullets:
		b.id = _alloc_id()
		b.spawn_tick = sim_tick
		b.source_id = e.id
		_pattern_bullets.append(b)
	e.volley_index += 1


func _mix_seed(a: int, b: int, c: int) -> int:
	# SplitMix-style mix; wraps at 2^64 the same way on a later headless host.
	# Constants are the signed form of 0x9E3779B97F4A7C15, 0xBF58476D1CE4E5B9,
	# and 0x94D049BB133111EB (Godot rejects those hex literals as > int64 max).
	return a * -7046029254386353131 + b * -4658895280553007687 + c * -7723592293110705685


func _apply_combat(sim_tick: int) -> void:
	_player_shots_vs_enemies(sim_tick)
	_pattern_shots_vs_player(sim_tick)
	_contact_vs_player()


func _player_shots_vs_enemies(sim_tick: int) -> void:
	for shot in _projectiles:
		if not shot.is_alive_at(sim_tick):
			continue
		shot.write_position_at_time(float(sim_tick - 1) if sim_tick > 0 else 0.0, _hit_p0)
		shot.write_position_at_time(float(sim_tick), _hit_p1)
		for e in _enemies:
			if not e.alive:
				continue
			if SweepHit.moving_circles(
				_hit_p0.x, _hit_p0.y, _hit_p1.x, _hit_p1.y, shot.radius_tiles,
				e.prev_x, e.prev_y, e.x, e.y, e.radius()
			):
				e.hp -= _config.player_projectile_damage
				e.damaged_by[_player_id] = true
				shot.consumed = true
				if e.hp <= 0:
					e.hp = 0
					e.alive = false
					_grant_kill_rewards(e, sim_tick)
				break


func _pattern_shots_vs_player(sim_tick: int) -> void:
	if _player_hp <= 0:
		return
	for b in _pattern_bullets:
		if not b.is_alive_at(sim_tick):
			continue
		b.write_position_at_time(float(sim_tick - 1) if sim_tick > 0 else 0.0, _hit_p0)
		b.write_position_at_time(float(sim_tick), _hit_p1)
		if SweepHit.moving_circles(
			_hit_p0.x, _hit_p0.y, _hit_p1.x, _hit_p1.y, b.radius_tiles,
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


func _cull_projectiles(sim_tick: int) -> void:
	var write: int = 0
	for shot in _projectiles:
		if shot.is_alive_at(sim_tick):
			_projectiles[write] = shot
			write += 1
	_projectiles.resize(write)


func _cull_pattern_bullets(sim_tick: int) -> void:
	var write: int = 0
	for b in _pattern_bullets:
		if b.is_alive_at(sim_tick):
			_pattern_bullets[write] = b
			write += 1
	_pattern_bullets.resize(write)


func _cull_enemies() -> void:
	var write: int = 0
	for e in _enemies:
		if e.alive:
			_enemies[write] = e
			write += 1
	_enemies.resize(write)


func scaling() -> SimScaling:
	return _scaling


func loot_tables() -> LootTables:
	return _loot


func inventory() -> PlayerInventory:
	return _inventory


func player_level() -> int:
	return _player_level


func xp_tenths() -> int:
	return _xp_tenths


func pending_glint() -> int:
	return _pending_glint


func ground_drop_count() -> int:
	var n: int = 0
	for bag in _ground_drops:
		if bag.item != null and bag.item.state == ItemState.STATE_LIVE:
			n += 1
	return n


func set_player_class(class_id: String) -> void:
	_player_class_id = class_id
	_class_def = null
	if _catalog != null and class_id != "":
		_class_def = _catalog.class_def(class_id)
	_recompute_player_stats(true)


func set_instance_multiplier_hundredths(m100: int) -> void:
	_instance_m100 = m100


func set_in_portal(in_portal: bool) -> void:
	_in_portal = in_portal


func set_practice_yard(enabled: bool) -> void:
	_practice_yard = enabled


func is_practice_yard() -> bool:
	return _practice_yard


func player_max_hp() -> int:
	return _current_max_hp()


func effective_level() -> int:
	return _player_le()


func grant_xp_tenths(amount: int) -> int:
	## Apply a raw tenths grant and resolve any number of level-ups. Returns levels gained.
	if amount <= 0:
		return 0
	var old_max: int = _current_max_hp()
	_xp_tenths += amount
	var gained: int = 0
	var guard: int = 0
	while guard < 100000:
		var need: int = _scaling.xp_to_next_tenths(_player_level)
		if _xp_tenths < need:
			break
		_xp_tenths -= need
		_player_level += 1
		gained += 1
		guard += 1
	if gained > 0:
		_apply_max_hp_delta(old_max)
	return gained


func has_granted_drop(drop_id: String) -> bool:
	return _granted_drop_ids.has(drop_id)


func try_grant_roll_for(enemy_id: int, drop_index: int, looter_class: String = "") -> ItemState:
	var e := _enemy_by_id(enemy_id)
	if e == null:
		return null
	var cid: String = looter_class if looter_class != "" else (_player_class_id if _player_class_id != "" else "thornguard")
	return _try_grant_roll(e, _player_id, drop_index, cid, _tick)


func _base_hp() -> int:
	if _class_def != null:
		return _class_def.base_hp
	return _config.player_max_hp


func _base_ward() -> float:
	if _class_def != null:
		return _class_def.base_ward
	return 0.0


func _gear_hp() -> int:
	var hp: int = 0
	var armor: ItemState = _inventory.equipped_armor
	if armor != null:
		hp += SimScaling.round_half_up(_loot.armor_hp_coef * _scaling.g(armor.tier))
	var charm: ItemState = _inventory.equipped_charm
	if charm != null and charm.charm_line == "hp":
		hp += SimScaling.round_half_up(_loot.charm_hp_coef() * _scaling.g(charm.tier))
	return hp


func _current_max_hp() -> int:
	return _scaling.scaled_hp(_base_hp(), _player_le(), _gear_hp())


func _player_le() -> int:
	# Practice yard and the Wilds use Lp (vision §3.2a). Portals sync down later.
	if not _in_portal:
		return _player_level
	# Without an instance E, treat as Wilds; set_in_portal is for later portal instances.
	return _player_level


func _apply_max_hp_delta(old_max: int) -> void:
	var new_max: int = _current_max_hp()
	var delta: int = new_max - old_max
	if delta != 0:
		_player_hp += delta
	if _player_hp > new_max:
		_player_hp = new_max
	if _player_hp < 0:
		_player_hp = 0


func _recompute_player_stats(fill: bool) -> void:
	# fill: spawn or class change, reset to full.
	if fill:
		_player_hp = _current_max_hp()


func _is_eligible(e: EnemyState, player_id: int, px: float, py: float) -> bool:
	if e.damaged_by.has(player_id):
		return true
	var dx: float = px - e.x
	var dy: float = py - e.y
	return dx * dx + dy * dy <= _loot.eligibility_range_tiles * _loot.eligibility_range_tiles


func _grant_kill_rewards(e: EnemyState, sim_tick: int) -> void:
	if e.rewards_granted:
		return
	e.rewards_granted = true
	var rank: String = _reward_rank(e)
	var elig: bool = _is_eligible(e, _player_id, _px, _py)
	if not elig:
		return
	var le: int = _player_le()
	var xp: int = _scaling.credited_kill_tenths(e.content_level, le, rank)
	grant_xp_tenths(xp)
	_pending_glint += _loot.glint_for_kill(e.content_level, rank, _scaling)
	var rolls: int = _loot.roll_count(rank, _instance_m100)
	var looter_class: String = _player_class_id if _player_class_id != "" else "thornguard"
	for i in range(rolls):
		_try_grant_roll(e, _player_id, i, looter_class, sim_tick)


func _try_grant_roll(e: EnemyState, looter_id: int, drop_index: int, looter_class: String, sim_tick: int) -> ItemState:
	var did: String = LootTables.drop_id(_world_seed, e.id, looter_id, drop_index)
	if _granted_drop_ids.has(did):
		return null
	var rank: String = _reward_rank(e)
	var item: ItemState = _loot.roll_item(
		_world_seed, e.id, looter_id, drop_index, e.content_level, rank, looter_class, _scaling
	)
	# A miss still consumes the id so a retry cannot reroll the chance.
	_granted_drop_ids[did] = true
	if item == null:
		return null
	item.drop_id = did
	var bag := GroundDrop.new()
	bag.id = _alloc_id()
	bag.item = item
	bag.x = e.x
	bag.y = e.y
	bag.spawn_tick = sim_tick
	bag.t_star = _scaling.t_star(e.content_level)
	_ground_drops.append(bag)
	return item


func _expire_ground_drops(sim_tick: int) -> void:
	var write: int = 0
	for bag in _ground_drops:
		if bag.item != null and bag.item.state == ItemState.STATE_LIVE and bag.expired_at(sim_tick, _loot.ground_expiry_ticks):
			bag.item.state = ItemState.STATE_TOMBSTONED
			bag.item.tombstone_reason = "EXPIRED"
		if bag.item != null and bag.item.state == ItemState.STATE_LIVE:
			_ground_drops[write] = bag
			write += 1
	_ground_drops.resize(write)


func _reward_rank(e: EnemyState) -> String:
	# The practice yard is a tutorial space: every kill is a normal E=1 reward.
	if _practice_yard:
		return "normal"
	return e.def.rank if e.def != null else "normal"


func _bag_distance(bag: GroundDrop) -> float:
	return SimConstants.interact_distance(_px, _py, bag.x, bag.y)


func _live_own_bag(bag: GroundDrop) -> bool:
	return bag != null and bag.item != null and bag.item.state == ItemState.STATE_LIVE and bag.item.owner_player_id == _player_id


func _bag_by_id(id: int) -> GroundDrop:
	for bag in _ground_drops:
		if bag.id == id:
			return bag
	return null


func _apply_interact(_sim_tick: int) -> void:
	# Mirror upcoming proto InputFrame.interact_target_id: 0 means none. A
	# nonzero value is a press on this seq, applied at most once per seq.
	# Unknown ids, bags the player may not use, and targets beyond the accept
	# range are dropped silently, with no error.
	var target_id: int = _intent.interact_target_id
	if target_id == 0:
		return
	if _intent.seq == _last_interact_seq:
		return
	_last_interact_seq = _intent.seq
	var bag := _bag_by_id(target_id)
	if not _live_own_bag(bag):
		return
	if not _scaling.in_accept_range(_bag_distance(bag)):
		return
	if _inventory.is_full():
		return
	if _inventory.add(bag.item):
		_ground_drops.erase(bag)


func _apply_inventory_hotkey() -> void:
	var slot: int = _intent.inventory_slot
	if slot < 1 or slot > _inventory.slot_count:
		return
	var old_max: int = _current_max_hp()
	if _inventory.equip_from_slot(slot - 1):
		_apply_max_hp_delta(old_max)

