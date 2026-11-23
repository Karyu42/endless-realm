class_name LocalSim
extends WorldSource
## In-process 20 Hz authority used for the offline slice and a shared
## multi-player world the lobby host can run. Every game rule lives in plain
## RefCounted classes — no Node, SceneTree, Input, or rendering dependencies —
## and is deterministic (tick-based, PCG32 only).
##
## Advance the world with step(), not tick(). tick() is the completed-tick
## getter used by WorldSource and LobbyHost (which calls p.sim.tick() as a
## getter after step()). The host contract named the advance tick(); until
## the host switches, step() stays the advance so existing host CI keeps
## working. apply_input(id, intent) then step() is the multi-player loop.
## Solo play is one player: submit_input(intent) applies to that player.

const READY_EPS: float = 1e-9
## content-v0.1 §2.3: nearest player in aggro range, re-picked every 1 s.
const TARGET_REPICK_TICKS: int = 20
## Entity ids are uint64 on the wire; GDScript int is signed, so they stay
## strictly below 2^63.
const MAX_ENTITY_ID: int = 0x7FFFFFFFFFFFFFFF
## Third mix-seed constant for per-player PCG32 initstate:
## initstate = _mix_seed(instance_seed, player_id, PLAYER_RNG_STREAM), initseq = 1.
const PLAYER_RNG_STREAM: int = 0xA51C11E57EA1

var _config: SimConfig
var _catalog: DataCatalog
var _world_seed: int = 1
var _tick: int = 0
## Default / solo viewer id (player 1 is spawned in _init).
var _player_id: int = 1
var _next_id: int = 2
## Ids ever used for players (allocated or reserved). Only these, or ids the
## allocator has not reached yet, may be passed to add_player / place_player.
var _player_id_set: Dictionary = {1: true}
## [lo, hi) ranges the allocator jumped over when a caller reserved a higher
## id; never issued to entities. One entry per such reservation.
var _skipped_ids: Array[PackedInt64Array] = []
var _players: Dictionary = {} # id -> SimPlayerState
var _sorted_ids: Array[int] = []
var _pending_adds: Dictionary = {} # id -> {character: Variant, x: float, y: float, ...}
var _pending_removes: Dictionary = {} # id -> true
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
var _ground_drops: Array[GroundDrop] = []
var _granted_drop_ids: Dictionary = {} # drop_id -> true
var _instance_m100: int = 100
var _in_portal: bool = false
var _practice_yard: bool = false
## Per-player ability state (id -> PlayerAbilityState). Kept next to
## SimPlayerState so class abilities stay keyed by player id.
var _ability_by_player: Dictionary = {}
## Test / later dungeon walls: tile (tx, ty) -> true is blocking for Slipstep.
var _blocking_tiles: Dictionary = {}


func _init(config: SimConfig = null, start_x: float = 0.0, start_y: float = 0.0, catalog: DataCatalog = null) -> void:
	_config = config if config != null else SimConfig.new()
	_catalog = catalog
	if _catalog != null:
		if _catalog.scaling != null:
			_scaling = _catalog.scaling
		if _catalog.loot != null:
			_loot = _catalog.loot
	# Solo / existing tests: player 1 exists immediately, not queued for the next step.
	var p := _make_player(1, start_x, start_y, null)
	_players[1] = p
	_player_id = 1
	_rebuild_ids()
	_recompute_player_stats(p, true)


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
	for id in _sorted_ids:
		var p: SimPlayerState = _players[id]
		p.rng = PCG32.new(player_rng_initstate(id), 1)
	for id in _pending_adds:
		var rec: Dictionary = _pending_adds[id]
		if rec.has("state"):
			var p: SimPlayerState = rec["state"]
			p.rng = PCG32.new(player_rng_initstate(int(id)), 1)
	var ids: Array = _ability_by_player.keys()
	ids.sort()
	for pid in ids:
		var st: PlayerAbilityState = _ability_by_player[pid]
		st.reseed(_world_seed, int(pid))


func config() -> SimConfig:
	return _config


## initstate for a player's PCG32 stream: SplitMix-style mix of the instance
## seed, the player id, and PLAYER_RNG_STREAM. initseq is always 1.
func player_rng_initstate(player_id: int) -> int:
	return _mix_seed(_world_seed, player_id, PLAYER_RNG_STREAM)


func get_player(id: int) -> SimPlayerState:
	return _players.get(id, null) as SimPlayerState


func player_ids() -> Array[int]:
	return _sorted_ids.duplicate()


func player_count() -> int:
	return _sorted_ids.size()


## Queue a player to join at the start of the next step(). character may be
## null, a class-id String, or a Dictionary {class_id, x, y, hp?}.
func add_player(id: int, character: Variant = null) -> bool:
	if not _player_id_allowed(id):
		return false
	_reserve_id(id)
	_pending_removes.erase(id)
	if _players.has(id) or _pending_adds.has(id):
		if _pending_adds.has(id):
			_pending_adds[id]["character"] = character
		return true
	_pending_adds[id] = {"character": character}
	return true


## Queue a player to leave at the start of the next step(). Their in-flight
## shots are dropped then; enemies re-target on their next re-pick (or sooner
## if the current target is no longer valid).
func remove_player(id: int) -> void:
	_pending_adds.erase(id)
	if _players.has(id):
		_pending_removes[id] = true


## Store the latest intent for this player. Nothing is applied until step().
## The host calls this at most once per player per tick.
func apply_input(id: int, intent: InputIntent) -> void:
	var p: SimPlayerState = _players.get(id, null) as SimPlayerState
	if p == null or intent == null:
		return
	p.intent = _copy_intent(intent)


## Solo / existing WorldSource path: apply to the default player (id 1, or
## the lowest remaining id if 1 is gone).
func submit_input(intent: InputIntent) -> void:
	apply_input(_default_player_id(), intent)


func submit_player_input(player_id: int, intent: InputIntent) -> void:
	apply_input(player_id, intent)


func _copy_intent(src: InputIntent) -> InputIntent:
	# Copy fields directly so a later ability_pressed on InputIntent is kept.
	# Do not add a second ability field; #42 introduces a single ability_pressed.
	var out := InputIntent.new()
	out.seq = src.seq
	out.move_x = src.move_x
	out.move_y = src.move_y
	out.aim = src.aim
	out.fire_held = src.fire_held
	out.interact_pressed = src.interact_pressed
	out.inventory_slot = src.inventory_slot
	out.interact_target_id = src.interact_target_id
	# Single ability_pressed field (#39 / #42). Do not add a second one.
	out.ability_pressed = src.ability_pressed
	return out


func _clear_oneshots(p: SimPlayerState) -> void:
	p.intent.interact_pressed = false
	p.intent.inventory_slot = 0
	p.intent.interact_target_id = 0
	p.intent.ability_pressed = false


func _default_player_id() -> int:
	if _players.has(_player_id):
		return _player_id
	if not _sorted_ids.is_empty():
		return _sorted_ids[0]
	return 0


func _default_player() -> SimPlayerState:
	return _players.get(_default_player_id(), null) as SimPlayerState


func _make_player(id: int, x: float, y: float, character: Variant) -> SimPlayerState:
	var p := SimPlayerState.new()
	p.id = id
	p.x = x
	p.y = y
	p.prev_x = x
	p.prev_y = y
	p.inventory = PlayerInventory.new(_loot.inventory_slots if _loot != null else 8)
	p.rng = PCG32.new(player_rng_initstate(id), 1)
	p.last_interact_seq = 0
	_ability_of(id)
	_apply_character(p, character)
	return p


func _apply_character(p: SimPlayerState, character: Variant) -> void:
	var class_id: String = p.class_id
	if character == null:
		pass
	elif character is String:
		class_id = String(character)
	elif character is Dictionary:
		var d: Dictionary = character
		if d.has("class_id"):
			class_id = String(d["class_id"])
		elif d.has("class"):
			class_id = String(d["class"])
		if d.has("x"):
			p.x = float(d["x"])
			p.prev_x = p.x
		if d.has("y"):
			p.y = float(d["y"])
			p.prev_y = p.y
		if d.has("hp"):
			p.hp = int(d["hp"])
	_set_player_class_on(p, class_id, not (character is Dictionary and (character as Dictionary).has("hp")))


func _alloc_id() -> int:
	# One id space for players, enemies, projectiles, pattern bullets and
	# bags. Ids are handed out in increasing order and never reused;
	# _reserve_id moves the counter past any id a caller picks itself.
	var id: int = _next_id
	if _next_id < MAX_ENTITY_ID:
		_next_id += 1
	return id


## Reserves an externally chosen id (add_player / place_player) so the
## entity allocator never hands it out again, and remembers it as a player id.
func _reserve_id(id: int) -> void:
	if id >= _next_id and id < MAX_ENTITY_ID:
		if id > _next_id:
			# The allocator never issues the ids it jumps over.
			_skipped_ids.append(PackedInt64Array([_next_id, id]))
		_next_id = id + 1
	_player_id_set[id] = true


## A caller-chosen player id is accepted only if the allocator has never
## handed it to an entity: at or above the counter, jumped over by an
## earlier reservation, or already a player id. Ids of entities that are
## gone are never reused.
func _player_id_allowed(id: int) -> bool:
	if id <= 0 or id >= MAX_ENTITY_ID:
		return false
	if id >= _next_id or _player_id_set.has(id):
		return true
	for r in _skipped_ids:
		if id >= r[0] and id < r[1]:
			return true
	return false


## A fresh player id from the shared entity allocator. Hosts use this so
## player ids can never collide with enemy, projectile or bag ids.
func alloc_player_id() -> int:
	var id := _alloc_id()
	_player_id_set[id] = true
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
	_apply_pending_roster()
	for id in _sorted_ids:
		var p: SimPlayerState = _players[id]
		p.prev_x = p.x
		p.prev_y = p.y
	for e in _enemies:
		e.prev_x = e.x
		e.prev_y = e.y
	# Time index of this tick (first processed tick is 0, now = tick × 0.05).
	# tick() / snapshot.tick stay "completed ticks" (1 after the first step).
	var sim_tick: int = _tick
	# Players are processed in ascending id order, never apply_input order.
	# Ability is applied after movement (Slipstep starts from the post-move
	# position) and before fire (Kindle Pulse's cast lock).
	for id in _sorted_ids:
		var p: SimPlayerState = _players[id]
		p.applied_seq = p.intent.seq
		p.aim = p.intent.aim
		if p.flash_ticks > 0:
			p.flash_ticks -= 1
		_apply_movement(p)
		_apply_ability(id, p.intent, sim_tick)
		_apply_fire(p, sim_tick)
	for e in _enemies:
		if e.flash_ticks > 0:
			e.flash_ticks -= 1
	_step_enemies(sim_tick)
	_apply_combat(sim_tick)
	_tick_ability_clocks()
	# Focus regen is at the end of the tick, after any spend.
	_regen_focus()
	_expire_ground_drops(sim_tick)
	for id in _sorted_ids:
		var p: SimPlayerState = _players[id]
		_apply_interact(p, sim_tick)
		_apply_inventory_hotkey(p)
		_clear_oneshots(p)
	_cull_projectiles(sim_tick)
	_cull_pattern_bullets(sim_tick)
	_cull_enemies()
	_tick += 1


func tick() -> int:
	return _tick


func snapshot() -> WorldSnapshot:
	return world_view(_default_player_id())


## Per-viewer snapshot: personal HUD/inventory/bags belong to viewer_id;
## players lists everyone; bags are only that viewer's live drops.
func world_view(player_id: int) -> WorldSnapshot:
	var snap := WorldSnapshot.new()
	snap.tick = _tick
	var viewer: SimPlayerState = _players.get(player_id, null) as SimPlayerState
	if viewer != null:
		snap.player_id = viewer.id
		snap.player_x = viewer.x
		snap.player_y = viewer.y
		snap.player_aim = viewer.aim
		snap.player_hp = viewer.hp
		snap.player_max_hp = _current_max_hp(viewer)
		snap.player_flash_ticks = viewer.flash_ticks
		snap.applied_seq = viewer.applied_seq
		snap.player_level = viewer.level
		snap.xp_tenths = viewer.xp_tenths
		snap.xp_to_next_tenths = _scaling.xp_to_next_tenths(viewer.level)
		snap.pending_glint = viewer.pending_glint
		snap.inventory = viewer.inventory.slots.duplicate()
		snap.equipped_weapon = viewer.inventory.equipped_weapon
		snap.equipped_armor = viewer.inventory.equipped_armor
		snap.equipped_charm = viewer.inventory.equipped_charm
	else:
		snap.player_id = player_id
	var bags: Array[GroundDrop] = []
	for bag in _ground_drops:
		if bag.item != null and bag.item.owner_player_id == player_id and bag.item.state == ItemState.STATE_LIVE:
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
		es.flash_ticks = e.flash_ticks
		enemy_snaps.append(es)
	snap.enemies = enemy_snaps
	var plist: Array[PlayerSnapshot] = []
	for id in _sorted_ids:
		var p: SimPlayerState = _players[id]
		var ps := PlayerSnapshot.new()
		ps.id = p.id
		ps.x = p.x
		ps.y = p.y
		ps.aim = p.aim
		ps.hp = p.hp
		ps.max_hp = _current_max_hp(p)
		ps.flash_ticks = p.flash_ticks
		ps.applied_seq = p.applied_seq
		plist.append(ps)
	snap.players = plist
	if viewer != null:
		var ast := _ability_of(viewer.id)
		snap.player_focus = ast.focus
		snap.player_focus_max = ast.focus_max()
		if ast.ability_def != null:
			snap.ability_id = ast.ability_def.id
			snap.ability_name = ast.ability_def.display_name
			snap.ability_cooldown_max = ast.ability_def.cooldown_ticks
		snap.ability_cooldown_ticks = ast.cooldown_ticks
		snap.ward_ticks = ast.ward_ticks
		snap.invuln_ticks = ast.invuln_ticks
	return snap


func projectile_count() -> int:
	return _projectiles.size()


func pattern_bullet_count() -> int:
	return _pattern_bullets.size()


func enemy_count() -> int:
	return _enemies.size()


func next_ready() -> float:
	var p := _default_player()
	return p.next_ready if p != null else 0.0


## Hook for a later ability lock (Kindle Pulse, PR #19). A blocked tick breaks
## the continuous hold and does not reset next_ready, so there is no catch-up.
func is_fire_blocked() -> bool:
	var p := _default_player()
	if p == null:
		return false
	return p.fire_blocked or _ability_of(p.id).cast_lock_ticks > 0


func set_fire_blocked(blocked: bool) -> void:
	var p := _default_player()
	if p != null:
		p.fire_blocked = blocked


## Tempo × (1 + tempoBonus) is read when a volley is scheduled, so a mid-hold
## rate change keeps the pending next_ready and applies the new cd after it.
func _current_fire_cooldown_s() -> float:
	return _config.fire_cooldown_s()


func _apply_movement(p: SimPlayerState) -> void:
	if p.hp <= 0:
		return
	var mx := p.intent.move_x
	var my := p.intent.move_y
	var move_len := sqrt(mx * mx + my * my)
	if move_len > 1.0:
		mx /= move_len
		my /= move_len
	elif move_len <= SimConstants.MOVE_EPS:
		mx = 0.0
		my = 0.0
	var step_len: float = _config.move_speed_tiles_per_s * SimConstants.TICK_DT
	p.x += mx * step_len
	p.y += my * step_len
	if _has_bounds:
		var r: float = _config.player_radius_tiles
		p.x = clampf(p.x, _bound_min_x + r, _bound_max_x - r)
		p.y = clampf(p.y, _bound_min_y + r, _bound_max_y - r)


func _apply_fire(p: SimPlayerState, sim_tick: int) -> void:
	# content-v0.1.md §1: next_ready is float64 seconds (tick × 0.05), starts at 0.
	# cd = 1 / (Tempo × (1 + tempoBonus)). One volley when fire_held and
	# now ≥ next_ready − 1e-9. A continuous hold schedules the next ready
	# time from the previous ready time (not the landing tick) so a fractional
	# cd stays exact over the long run. A press after a release sets
	# next_ready = now + cd. Release never resets next_ready.
	var now: float = float(sim_tick) * SimConstants.TICK_DT
	if p.hp <= 0 or p.fire_blocked or _ability_of(p.id).cast_lock_ticks > 0:
		p.hold_since_volley = false
		return
	if not p.intent.fire_held:
		p.hold_since_volley = false
		return
	# Rate is read per scheduled shot, not cached for the whole hold.
	var cd: float = _current_fire_cooldown_s()
	if cd <= 0.0:
		return
	if now >= p.next_ready - READY_EPS:
		var continuous: bool = p.hold_since_volley
		_spawn_projectile(p, sim_tick)
		if continuous:
			p.next_ready += cd
		else:
			p.next_ready = now + cd
		p.hold_since_volley = true


func _spawn_projectile(p: SimPlayerState, sim_tick: int) -> void:
	var dir := SimVec2.from_angle(p.aim)
	# If aim is somehow NaN, skip rather than inject a bad shot.
	if is_nan(dir.x) or is_nan(dir.y):
		return
	if dir.length_squared() <= SimConstants.MOVE_EPS:
		dir = SimVec2.from_xy(1.0, 0.0)
	else:
		dir = dir.normalized()
	var shot := SimProjectile.new()
	shot.id = _alloc_id()
	shot.owner_id = p.id
	shot.spawn_tick = sim_tick
	shot.origin_x = p.x
	shot.origin_y = p.y
	shot.dir_x = dir.x
	shot.dir_y = dir.y
	shot.speed = _config.projectile_speed_tiles_per_s
	shot.range_tiles = _config.projectile_range_tiles
	shot.lifetime_ticks = _config.projectile_lifetime_ticks()
	shot.radius_tiles = _config.projectile_radius_tiles
	_projectiles.append(shot)


## Immediate position / hp write for tests. Creates a player if needed
## (does not wait for the next step, unlike add_player).
func place_player(id: int, x: float, y: float, hp: int = -1) -> void:
	var p: SimPlayerState = _players.get(id, null) as SimPlayerState
	if p == null:
		if not _player_id_allowed(id):
			return
		_reserve_id(id)
		_pending_adds.erase(id)
		_pending_removes.erase(id)
		p = _make_player(id, x, y, null)
		_players[id] = p
		_rebuild_ids()
		_recompute_player_stats(p, true)
	p.x = x
	p.y = y
	if hp >= 0:
		p.hp = hp


func enemy_target_id(enemy_id: int) -> int:
	var e := _enemy_by_id(enemy_id)
	return e.target_id if e != null else 0


func _player_pos(id: int) -> Vector2:
	var p: SimPlayerState = _players.get(id, null) as SimPlayerState
	if p != null:
		return Vector2(p.x, p.y)
	var d: SimPlayerState = _default_player()
	if d != null:
		return Vector2(d.x, d.y)
	return Vector2.ZERO


func _player_hp_of(id: int) -> int:
	var p: SimPlayerState = _players.get(id, null) as SimPlayerState
	return p.hp if p != null else 0


func _player_is_living(id: int) -> bool:
	var p: SimPlayerState = _players.get(id, null) as SimPlayerState
	return p != null and p.hp > 0


func _foreach_living_player_ids() -> Array[int]:
	var ids: Array[int] = []
	for id in _sorted_ids:
		var p: SimPlayerState = _players[id]
		if p.hp > 0:
			ids.append(id)
	return ids


func _nearest_player_in_radius(e: EnemyState, radius: float) -> int:
	var best_id: int = 0
	var best_d2: float = -1.0
	var r2: float = radius * radius
	for pid in _foreach_living_player_ids():
		var pos := _player_pos(pid)
		var dx: float = pos.x - e.x
		var dy: float = pos.y - e.y
		var d2: float = dx * dx + dy * dy
		if d2 > r2:
			continue
		if best_id == 0 or d2 < best_d2 - 1e-12 or (abs(d2 - best_d2) <= 1e-12 and pid < best_id):
			best_id = pid
			best_d2 = d2
	return best_id


func _nearest_player_in_aggro(e: EnemyState) -> int:
	var r: float = e.def.aggro_radius if e.def != null else 0.0
	return _nearest_player_in_radius(e, r)


func _target_is_valid(e: EnemyState) -> bool:
	if e.target_id == 0 or not _player_is_living(e.target_id) or e.def == null:
		return false
	var pos := _player_pos(e.target_id)
	var dx: float = pos.x - e.x
	var dy: float = pos.y - e.y
	var r: float = e.def.deaggro_range()
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
	var anyone_deaggro: int = 0
	if e.def != null:
		anyone_deaggro = _nearest_player_in_radius(e, e.def.deaggro_range())
	var leashed: bool = e.def != null and (not e.def.no_leash) and home_dist > e.def.leash
	var was_aggro: bool = e.aggro
	if e.aggro:
		if leashed or anyone_deaggro == 0:
			# Leashed, or nobody alive in deaggro range: idle and return toward spawn.
			e.aggro = false
			e.target_id = 0
	elif nearest_id != 0 and not leashed:
		e.aggro = true
	# content-v0.1 §2.3: first attack comes fire_interval after aggro (and re-aggro).
	# The target is the nearest living player in aggro range, re-picked every 1 s.
	if e.aggro and not was_aggro:
		e.fire_cooldown = e.def.fire_interval_ticks
		e.target_id = nearest_id
		e.target_repick_tick = sim_tick + TARGET_REPICK_TICKS
	elif e.aggro:
		if (not _target_is_valid(e)) or sim_tick >= e.target_repick_tick:
			e.target_id = nearest_id if nearest_id != 0 else e.target_id
			if not _target_is_valid(e):
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
	elif not rooted and home_dist > SimConstants.MOVE_EPS and (e.def.move_speed > 0.0 or e.def.wander_speed > 0.0):
		# De-aggroed: return toward spawn if this enemy moves.
		speed = e.def.move_speed if e.def.move_speed > 0.0 else e.def.wander_speed
		if home_dist > SimConstants.MOVE_EPS:
			mx = -home_dx / home_dist
			my = -home_dy / home_dist
			e.aim = atan2(my, mx)
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
	_pattern_shots_vs_players(sim_tick)
	_contact_vs_players()


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
				var owner: int = shot.owner_id if shot.owner_id != 0 else _default_player_id()
				e.damaged_by[owner] = true
				e.flash_ticks = _config.player_flash_ticks
				shot.consumed = true
				if e.hp <= 0:
					e.hp = 0
					e.alive = false
					_grant_kill_rewards(e, sim_tick)
				break


func _pattern_shots_vs_players(sim_tick: int) -> void:
	for b in _pattern_bullets:
		if not b.is_alive_at(sim_tick):
			continue
		b.write_position_at_time(float(sim_tick - 1) if sim_tick > 0 else 0.0, _hit_p0)
		b.write_position_at_time(float(sim_tick), _hit_p1)
		for id in _sorted_ids:
			var p: SimPlayerState = _players[id]
			if p.hp <= 0:
				continue
			if SweepHit.moving_circles(
				_hit_p0.x, _hit_p0.y, _hit_p1.x, _hit_p1.y, b.radius_tiles,
				p.prev_x, p.prev_y, p.x, p.y, _config.player_radius_tiles
			):
				var dmg: int = 0
				var src := _enemy_by_id(b.source_id)
				if src != null and src.def != null:
					dmg = src.def.damage_for(b.damage_key)
				if _hurt_player(p, dmg):
					b.consumed = true
				break


func _contact_vs_players() -> void:
	for e in _enemies:
		if not e.alive or e.contact_cooldown > 0:
			continue
		for id in _sorted_ids:
			var p: SimPlayerState = _players[id]
			if p.hp <= 0:
				continue
			if SweepHit.moving_circles(
				p.prev_x, p.prev_y, p.x, p.y, _config.player_radius_tiles,
				e.prev_x, e.prev_y, e.x, e.y, e.radius()
			):
				if _hurt_player(p, e.def.contact_damage if e.def != null else 0):
					e.contact_cooldown = _config.contact_cooldown_ticks
				break


func _hurt_player(p: SimPlayerState, amount: int) -> bool:
	if p == null or amount <= 0 or p.hp <= 0:
		return false
	var ast := _ability_of(p.id)
	if ast.invuln_ticks > 0:
		return false
	if ast.ward_ticks > 0 and ast.ability_def != null:
		# vision §2: the cut multiplies final damage after mitigation and D.
		# Incoming amounts are still raw until those land in _hurt_player.
		# The vision §3.2 "minimum of 1" applies after mitigation, which is
		# not in this hook yet, so a product that rounds to 0 stays 0.
		amount = SimScaling.round_half_up(float(amount) * ast.ability_def.damage_taken_mult)
	p.hp -= amount
	if p.hp < 0:
		p.hp = 0
	p.flash_ticks = _config.player_flash_ticks
	return true


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
	var p := _default_player()
	return p.inventory if p != null else PlayerInventory.new()


func player_level() -> int:
	var p := _default_player()
	return p.level if p != null else 1


func xp_tenths() -> int:
	var p := _default_player()
	return p.xp_tenths if p != null else 0


func pending_glint() -> int:
	var p := _default_player()
	return p.pending_glint if p != null else 0


func ground_drop_count() -> int:
	var n: int = 0
	for bag in _ground_drops:
		if bag.item != null and bag.item.state == ItemState.STATE_LIVE:
			n += 1
	return n


func set_player_class(class_id: String) -> void:
	set_player_class_for(_default_player_id(), class_id)


func set_player_class_for(player_id: int, class_id: String) -> void:
	# Ability state is created even if the player is not in _players yet
	# (place_ally / mid-_make_player). SimPlayerState is updated when present.
	var p: SimPlayerState = _players.get(player_id, null) as SimPlayerState
	if p != null:
		_set_player_class_on(p, class_id, true)
		return
	var st := _ability_of(player_id)
	var cdef: ClassDef = null
	var adef: AbilityDef = null
	if _catalog != null and class_id != "":
		cdef = _catalog.class_def(class_id)
		if cdef != null and cdef.ability_id != "":
			adef = _catalog.ability(cdef.ability_id)
	st.reset_for_class(cdef, adef)


func _set_player_class_on(p: SimPlayerState, class_id: String, fill: bool) -> void:
	if p == null:
		return
	p.class_id = class_id
	p.class_def = null
	var adef: AbilityDef = null
	if _catalog != null and class_id != "":
		p.class_def = _catalog.class_def(class_id)
		if p.class_def != null and p.class_def.ability_id != "":
			adef = _catalog.ability(p.class_def.ability_id)
	var st := _ability_of(p.id)
	st.reset_for_class(p.class_def, adef)
	_recompute_player_stats(p, fill)


func set_instance_multiplier_hundredths(m100: int) -> void:
	_instance_m100 = m100


func set_in_portal(in_portal: bool) -> void:
	_in_portal = in_portal


func set_practice_yard(enabled: bool) -> void:
	_practice_yard = enabled


func is_practice_yard() -> bool:
	return _practice_yard


func player_max_hp() -> int:
	var p := _default_player()
	return _current_max_hp(p) if p != null else 0


func effective_level() -> int:
	var p := _default_player()
	return _player_le(p) if p != null else 1


func grant_xp_tenths(amount: int) -> int:
	var p := _default_player()
	if p == null:
		return 0
	return _grant_xp_tenths_to(p, amount)


func _grant_xp_tenths_to(p: SimPlayerState, amount: int) -> int:
	## Apply a raw tenths grant and resolve any number of level-ups. Returns levels gained.
	if amount <= 0:
		return 0
	var old_max: int = _current_max_hp(p)
	p.xp_tenths += amount
	var gained: int = 0
	var guard: int = 0
	while guard < 100000:
		var need: int = _scaling.xp_to_next_tenths(p.level)
		if p.xp_tenths < need:
			break
		p.xp_tenths -= need
		p.level += 1
		gained += 1
		guard += 1
	if gained > 0:
		_apply_max_hp_delta(p, old_max)
	return gained


func has_granted_drop(drop_id: String) -> bool:
	return _granted_drop_ids.has(drop_id)


func try_grant_roll_for(enemy_id: int, drop_index: int, looter_class: String = "") -> ItemState:
	var e := _enemy_by_id(enemy_id)
	if e == null:
		return null
	var p := _default_player()
	if p == null:
		return null
	var cid: String = looter_class if looter_class != "" else (p.class_id if p.class_id != "" else "thornguard")
	return _try_grant_roll(e, p.id, drop_index, cid, _tick)


func _base_hp(p: SimPlayerState) -> int:
	if p.class_def != null:
		return p.class_def.base_hp
	return _config.player_max_hp


func _base_ward(p: SimPlayerState) -> float:
	if p.class_def != null:
		return p.class_def.base_ward
	return 0.0


func _gear_hp(p: SimPlayerState) -> int:
	var hp: int = 0
	var armor: ItemState = p.inventory.equipped_armor
	if armor != null:
		hp += SimScaling.round_half_up(_loot.armor_hp_coef * _scaling.g(armor.tier))
	var charm: ItemState = p.inventory.equipped_charm
	if charm != null and charm.charm_line == "hp":
		hp += SimScaling.round_half_up(_loot.charm_hp_coef() * _scaling.g(charm.tier))
	return hp


func _current_max_hp(p: SimPlayerState) -> int:
	if p.max_hp_override >= 0:
		return p.max_hp_override
	return _scaling.scaled_hp(_base_hp(p), _player_le(p), _gear_hp(p))


func _player_le(p: SimPlayerState) -> int:
	# Practice yard and the Wilds use Lp (vision §3.2a). Portals sync down later.
	if not _in_portal:
		return p.level
	# Without an instance E, treat as Wilds; set_in_portal is for later portal instances.
	return p.level


func _apply_max_hp_delta(p: SimPlayerState, old_max: int) -> void:
	var new_max: int = _current_max_hp(p)
	var delta: int = new_max - old_max
	if delta != 0:
		p.hp += delta
	if p.hp > new_max:
		p.hp = new_max
	if p.hp < 0:
		p.hp = 0


func apply_class_motion() -> void:
	# Copies stride and tempo from the current class onto SimConfig. Callers
	# that already set custom fire rates (tests) should not use this.
	var p := _default_player()
	if p != null and p.class_def != null:
		_config.move_speed_tiles_per_s = p.class_def.stride
		_config.fire_rate_shots_per_s = p.class_def.tempo


func _recompute_player_stats(p: SimPlayerState, fill: bool) -> void:
	# fill: spawn or class change, reset to full.
	if fill and p != null:
		p.hp = _current_max_hp(p)
		var st := _ability_of(p.id)
		st.focus = float(st.focus_max())
		st.cooldown_ticks = 0
		st.cast_lock_ticks = 0
		st.ward_ticks = 0
		st.invuln_ticks = 0


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
	for id in _sorted_ids:
		var p: SimPlayerState = _players[id]
		if not _is_eligible(e, p.id, p.x, p.y):
			continue
		var le: int = _player_le(p)
		var xp: int = _scaling.credited_kill_tenths(e.content_level, le, rank)
		_grant_xp_tenths_to(p, xp)
		p.pending_glint += _loot.glint_for_kill(e.content_level, rank, _scaling)
		var rolls: int = _loot.roll_count(rank, _instance_m100)
		var looter_class: String = p.class_id if p.class_id != "" else "thornguard"
		for i in range(rolls):
			_try_grant_roll(e, p.id, i, looter_class, sim_tick)


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


func _bag_distance(p: SimPlayerState, bag: GroundDrop) -> float:
	return SimConstants.interact_distance(p.x, p.y, bag.x, bag.y)


func _live_own_bag(p: SimPlayerState, bag: GroundDrop) -> bool:
	return bag != null and bag.item != null and bag.item.state == ItemState.STATE_LIVE and bag.item.owner_player_id == p.id


func _bag_by_id(id: int) -> GroundDrop:
	for bag in _ground_drops:
		if bag.id == id:
			return bag
	return null


func _ability_of(player_id: int) -> PlayerAbilityState:
	if not _ability_by_player.has(player_id):
		var st := PlayerAbilityState.new()
		st.reseed(_world_seed, player_id)
		_ability_by_player[player_id] = st
	return _ability_by_player[player_id] as PlayerAbilityState


func focus(player_id: int) -> float:
	return _ability_of(player_id).focus


func set_focus(player_id: int, value: float) -> void:
	var st := _ability_of(player_id)
	st.focus = clampf(value, 0.0, float(st.focus_max()))


func focus_max(player_id: int) -> int:
	return _ability_of(player_id).focus_max()


func ability_cooldown_ticks(player_id: int) -> int:
	return _ability_of(player_id).cooldown_ticks


func set_ability_cooldown_ticks(player_id: int, ticks: int) -> void:
	_ability_of(player_id).cooldown_ticks = maxi(0, ticks)


func ward_ticks(player_id: int) -> int:
	return _ability_of(player_id).ward_ticks


func invuln_ticks(player_id: int) -> int:
	return _ability_of(player_id).invuln_ticks


func ally_ability_heals(player_id: int) -> int:
	return _ability_of(player_id).ally_ability_heals


## Next value from this player's ability PCG32 stream (instance seed + id).
func ability_rng_uint32(player_id: int) -> int:
	return _ability_of(player_id).rng_uint32()


func place_ally(id: int, x: float, y: float, hp: int, max_hp: int) -> void:
	# Test hook: allies are full sim players so Kindle Pulse and targeting
	# share one roster.
	place_player(id, x, y, hp)
	var p: SimPlayerState = _players.get(id, null) as SimPlayerState
	if p == null:
		return
	if max_hp >= 0:
		p.max_hp_override = max_hp
		p.hp = mini(max_hp, hp) if hp >= 0 else mini(max_hp, p.hp)
	_ability_of(id)


func ally_hp(id: int) -> int:
	var p: SimPlayerState = _players.get(id, null) as SimPlayerState
	return p.hp if p != null else 0


func set_blocking_tile(tx: int, ty: int, blocked: bool = true) -> void:
	var key := Vector2i(tx, ty)
	if blocked:
		_blocking_tiles[key] = true
	else:
		_blocking_tiles.erase(key)


func _regen_focus() -> void:
	var ids: Array = _ability_by_player.keys()
	ids.sort()
	for pid in ids:
		var st: PlayerAbilityState = _ability_by_player[pid]
		st.regen(SimConstants.TICK_DT)


func _tick_ability_clocks() -> void:
	var ids: Array = _ability_by_player.keys()
	ids.sort()
	for pid in ids:
		var st: PlayerAbilityState = _ability_by_player[pid]
		st.tick_clocks()


func _apply_ability(player_id: int, intent: InputIntent, _sim_tick: int) -> void:
	if intent == null or not intent.ability_pressed:
		return
	# seq 0 is never applied (host-api rejects it; game_session skips 0 on wrap).
	if intent.seq == 0:
		return
	var st := _ability_of(player_id)
	if intent.seq == st.last_ability_seq:
		return
	st.last_ability_seq = intent.seq
	if st.ability_def == null:
		return
	var caster: SimPlayerState = _players.get(player_id, null) as SimPlayerState
	if caster != null and caster.hp <= 0:
		return
	if st.cooldown_ticks > 0:
		return
	if st.focus + 1e-9 < float(st.ability_def.focus_cost):
		return
	st.focus -= float(st.ability_def.focus_cost)
	st.cooldown_ticks = st.ability_def.cooldown_ticks
	var aid: String = st.ability_def.id
	if aid == "thorn_ward":
		# Recast refreshes the duration and does not stack (vision §2).
		st.ward_ticks = st.ability_def.duration_ticks
	elif aid == "kindle_pulse":
		st.cast_lock_ticks = st.ability_def.cast_lock_ticks
		_apply_kindle_pulse(player_id, st)
	elif aid == "slipstep":
		_apply_slipstep(player_id, st)
		st.invuln_ticks = st.ability_def.invuln_ticks


func _apply_kindle_pulse(player_id: int, st: PlayerAbilityState) -> void:
	var healed_ally: bool = false
	var caster: SimPlayerState = _players.get(player_id, null) as SimPlayerState
	var origin := Vector2(caster.x, caster.y) if caster != null else Vector2.ZERO
	if caster != null:
		_heal_target(player_id, origin.x, origin.y, _current_max_hp(caster), true, st)
	var radius: float = st.ability_def.heal_radius_tiles if st.ability_def != null else 0.0
	for id in _sorted_ids:
		if int(id) == player_id:
			continue
		var other: SimPlayerState = _players[id]
		if other.hp <= 0:
			continue
		var dx0: float = other.x - origin.x
		var dy0: float = other.y - origin.y
		if dx0 * dx0 + dy0 * dy0 > radius * radius:
			continue
		var before: int = other.hp
		_heal_target(int(id), other.x, other.y, _current_max_hp(other), false, st)
		if ally_hp(int(id)) > before:
			healed_ally = true
	if healed_ally:
		st.ally_ability_heals += 1


func _heal_target(id: int, _x: float, _y: float, max_hp: int, is_self: bool, st: PlayerAbilityState) -> void:
	if st.ability_def == null or max_hp <= 0:
		return
	var raw: float = st.ability_def.heal_max_hp_frac * float(max_hp)
	var heal: int = SimScaling.round_half_up(raw)
	if heal <= 0:
		return
	var p: SimPlayerState = _players.get(id, null) as SimPlayerState
	if p == null:
		return
	p.hp = mini(_current_max_hp(p), p.hp + heal)


func _apply_slipstep(player_id: int, st: PlayerAbilityState) -> void:
	var dist: float = st.ability_def.blink_tiles if st.ability_def != null else 0.0
	if dist <= 0.0:
		return
	var p: SimPlayerState = _players.get(player_id, null) as SimPlayerState
	if p == null:
		return
	var mx: float = p.intent.move_x
	var my: float = p.intent.move_y
	var move_len: float = sqrt(mx * mx + my * my)
	var dx: float
	var dy: float
	if move_len > SimConstants.MOVE_EPS:
		dx = mx / move_len
		dy = my / move_len
	else:
		dx = cos(p.aim)
		dy = sin(p.aim)
	var dest := _blink_destination(p.x, p.y, dx, dy, dist)
	p.x = dest[0]
	p.y = dest[1]
	# Teleport: do not sweep contact or bullets along the path.
	p.prev_x = p.x
	p.prev_y = p.y


func _blink_destination(sx: float, sy: float, dx: float, dy: float, dist: float) -> PackedFloat64Array:
	# PackedFloat64Array, not Vector2: Godot's Vector2 is float32 and would
	# coarsen the sim's float64 positions.
	var ex: float = sx + dx * dist
	var ey: float = sy + dy * dist
	var t_end: float = 1.0
	if _has_bounds:
		var r: float = _config.player_radius_tiles
		t_end = _clip_segment_t(sx, ex, _bound_min_x + r, _bound_max_x - r, t_end)
		t_end = _clip_segment_t(sy, ey, _bound_min_y + r, _bound_max_y - r, t_end)
	t_end = _clip_blocked_tiles_t(sx, sy, ex, ey, t_end)
	return PackedFloat64Array([sx + (ex - sx) * t_end, sy + (ey - sy) * t_end])


func _clip_segment_t(start: float, dest: float, lo: float, hi: float, t_end: float) -> float:
	var span: float = dest - start
	if abs(span) <= SimConstants.MOVE_EPS:
		return t_end
	if dest > hi:
		t_end = minf(t_end, (hi - start) / span)
	elif dest < lo:
		t_end = minf(t_end, (lo - start) / span)
	return maxf(0.0, t_end)


func _clip_blocked_tiles_t(sx: float, sy: float, ex: float, ey: float, t_end: float) -> float:
	# Grid walk (DDA) along tile boundaries so a path that only clips a
	# blocked tile's corner still stops at the last free point.
	if t_end <= 0.0:
		return 0.0
	if _tile_is_blocked(int(floor(sx)), int(floor(sy))):
		return 0.0
	var dx: float = ex - sx
	var dy: float = ey - sy
	if abs(dx) <= SimConstants.MOVE_EPS and abs(dy) <= SimConstants.MOVE_EPS:
		return t_end
	var tx: int = int(floor(sx))
	var ty: int = int(floor(sy))
	var step_x: int = 0
	if dx > SimConstants.MOVE_EPS:
		step_x = 1
	elif dx < -SimConstants.MOVE_EPS:
		step_x = -1
	var step_y: int = 0
	if dy > SimConstants.MOVE_EPS:
		step_y = 1
	elif dy < -SimConstants.MOVE_EPS:
		step_y = -1
	var t_max_x: float = INF
	var t_delta_x: float = INF
	if step_x != 0:
		var next_x: float = float(tx + (1 if step_x > 0 else 0))
		t_max_x = (next_x - sx) / dx
		t_delta_x = float(step_x) / dx
		if t_max_x < 0.0:
			t_max_x = 0.0
	var t_max_y: float = INF
	var t_delta_y: float = INF
	if step_y != 0:
		var next_y: float = float(ty + (1 if step_y > 0 else 0))
		t_max_y = (next_y - sy) / dy
		t_delta_y = float(step_y) / dy
		if t_max_y < 0.0:
			t_max_y = 0.0
	while true:
		var cross_x: bool = step_x != 0 and t_max_x <= t_max_y + SimConstants.MOVE_EPS
		var cross_y: bool = step_y != 0 and t_max_y <= t_max_x + SimConstants.MOVE_EPS
		if step_x == 0:
			cross_x = false
		if step_y == 0:
			cross_y = false
		if not cross_x and not cross_y:
			return t_end
		var t_hit: float = t_max_x if cross_x else t_max_y
		if cross_x and cross_y:
			t_hit = t_max_x
		if t_hit > t_end + SimConstants.MOVE_EPS:
			return t_end
		var ntx: int = tx + (step_x if cross_x else 0)
		var nty: int = ty + (step_y if cross_y else 0)
		# An exact-corner crossing is blocked if either side tile is solid,
		# so the path cannot slip through a diagonal gap.
		var side_blocked: bool = false
		if cross_x and cross_y:
			side_blocked = _tile_is_blocked(tx + step_x, ty) or _tile_is_blocked(tx, ty + step_y)
		if side_blocked or _tile_is_blocked(ntx, nty):
			# Stay on the free side of the boundary (floor(11.0) is tile 11).
			return maxf(0.0, minf(t_end, t_hit) - SimConstants.MOVE_EPS)
		tx = ntx
		ty = nty
		if cross_x:
			t_max_x += t_delta_x
		if cross_y:
			t_max_y += t_delta_y
	return t_end


func _tile_is_blocked(tx: int, ty: int) -> bool:
	if _blocking_tiles.has(Vector2i(tx, ty)):
		return true
	if not _has_bounds:
		return false
	if tx < int(floor(_bound_min_x)) or ty < int(floor(_bound_min_y)):
		return true
	if tx >= int(ceil(_bound_max_x)) or ty >= int(ceil(_bound_max_y)):
		return true
	return false


func _apply_interact(p: SimPlayerState, _sim_tick: int) -> void:
	# InputFrame.interact_target_id: 0 means none. A nonzero value is a
	# press on this seq, applied at most once per seq via Seq.seq_is_next
	# (same rule as HostInteractValidator). Unknown ids, bags the player
	# may not use, and targets beyond SimScaling.in_accept_range are
	# dropped silently, with no ErrorReply.
	var target_id: int = p.intent.interact_target_id

	if target_id == 0:
		return
	if not Seq.seq_is_next(p.intent.seq, p.last_interact_seq):
		return
	p.last_interact_seq = p.intent.seq
	var bag := _bag_by_id(target_id)
	if not _live_own_bag(p, bag):
		return
	if not _scaling.in_accept_range(_bag_distance(p, bag)):
		return
	if p.inventory.is_full():
		return
	if p.inventory.add(bag.item):
		_ground_drops.erase(bag)


func _apply_inventory_hotkey(p: SimPlayerState) -> void:
	var slot: int = p.intent.inventory_slot
	if slot < 1 or slot > p.inventory.slot_count:
		return
	var old_max: int = _current_max_hp(p)
	if p.inventory.equip_from_slot(slot - 1):
		_apply_max_hp_delta(p, old_max)


func _apply_pending_roster() -> void:
	var changed: bool = false
	if not _pending_removes.is_empty():
		var drop_ids: Array = _pending_removes.keys()
		drop_ids.sort()
		for id in drop_ids:
			var pid: int = int(id)
			if _players.has(pid):
				_players.erase(pid)
				# Ability state goes with the player; a host that wants it
				# back on rejoin saves it first (focus / cooldown getters).
				_ability_by_player.erase(pid)
				changed = true
		_pending_removes.clear()
		# Drop that player's in-flight shots.
		var write: int = 0
		for shot in _projectiles:
			if shot.owner_id != 0 and not _players.has(shot.owner_id):
				continue
			_projectiles[write] = shot
			write += 1
		_projectiles.resize(write)
	if not _pending_adds.is_empty():
		var add_ids: Array = _pending_adds.keys()
		add_ids.sort()
		for id in add_ids:
			var pid: int = int(id)
			if _players.has(pid):
				continue
			var rec: Dictionary = _pending_adds[pid]
			var p := _make_player(pid, 0.0, 0.0, rec.get("character", null))
			_players[pid] = p
			changed = true
		_pending_adds.clear()
	if changed:
		_rebuild_ids()
		if not _players.has(_player_id):
			_player_id = _sorted_ids[0] if not _sorted_ids.is_empty() else 0


func _rebuild_ids() -> void:
	_sorted_ids.clear()
	var keys: Array = _players.keys()
	keys.sort()
	for id in keys:
		_sorted_ids.append(int(id))
