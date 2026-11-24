class_name LocalSim
extends WorldSource
## In-process 20 Hz authority used for the offline slice and a shared
## multi-player world the lobby host can run. Every game rule lives in plain
## RefCounted classes — no Node, SceneTree, Input, or rendering dependencies —
## and is deterministic (tick-based, PCG32 only).
##
## Contract: apply_input(id, intent) then step() to advance. tick() is the
## completed-tick getter, not the advance. Solo play is one player:
## submit_input(intent) applies to that player, then step().

const READY_EPS: float = 1e-9
## content-v0.1 §2.3: nearest player in aggro range, re-picked every 1 s.
const TARGET_REPICK_TICKS: int = 20
## Entity ids are uint64 on the wire; GDScript int is signed, so they stay
## strictly below 2^63.
const MAX_ENTITY_ID: int = 0x7FFFFFFFFFFFFFFF
## Third mix-seed constant for per-player PCG32 initstate:
## initstate = _mix_seed(instance_seed, player_id, PLAYER_RNG_STREAM), initseq = 1.
const PLAYER_RNG_STREAM: int = 0xA51C11E57EA1
## Domain for a dungeon instance seed, so derived_instance_seed is not a bare
## _mix_seed(world, id, tick) like enemy volley seeds. "DNGN".
const DUNGEON_INSTANCE_SEED_DOMAIN: int = 0x444E474E
## Boss aim-target PCG32 domain, distinct from pattern volley seeds. "BAIM".
const BOSS_AIM_SEED_DOMAIN: int = 0x4241494D
## Boss wax-pool placement PCG32 domain, distinct from pattern volley seeds. "BPOL".
const BOSS_POOL_SEED_DOMAIN: int = 0x42504F4C
## vision §3.5 "in range" for Wilds packs and dungeon-room doorway shots, tiles.
const N_PEAK_RANGE_TILES: float = 12.0
## vision §6.1 rule 7: proximity and activity window (30 s at 20 Hz).
const BOSS_PROXIMITY_TILES: float = 12.0
const ACTIVITY_WINDOW_TICKS: int = 600
const NON_IDLE_WINDOW_TICKS: int = ACTIVITY_WINDOW_TICKS
## Aim delta, in degrees, that stamps activity. Wrap-around smallest angle.
const ACTIVITY_AIM_DEG: float = 10.0
## vision §6.1 rule 6a: after an empty-arena reset the boss is untouched for 5 s.
const BOSS_RESET_UNTOUCHED_TICKS: int = 100
const CLASS_CHANGE_REFUSED_LOG := "LocalSim: class change refused outside town"

var _config: SimConfig
var _catalog: DataCatalog
var _world_seed: int = 1
var _tick: int = 0
## Default / solo viewer id (player 1 is spawned in _init).
var _player_id: int = 1
## Next id the allocator will issue. The high-water mark is `_next_id - 1`
## (the last id issued). The allocator never reuses an id and does not
## store an entry per id ever issued.
var _next_id: int = 2
var _players: Dictionary = {} # id -> SimPlayerState
var _sorted_ids: Array[int] = []
var _pending_adds: Dictionary = {} # id -> {character: Variant, x: float, y: float, ...}
var _pending_removes: Dictionary = {} # id -> true
var _projectiles: Array[SimProjectile] = []
## Hits resolved during the tick that just completed. Cleared at the start of step().
var _hits: Array[HitEvent] = []
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
## Host item rules for an instance (true everywhere except where the host
## turns them off): whether loot bags may spawn, and whether items may move
## between a player and the world.
var _loot_bags_allowed: bool = true
var _item_transfers_allowed: bool = true
var _instance_m100: int = 100
var _in_portal: bool = false
var _practice_yard: bool = false
## Overworld / official instances grant persistent rewards. A practice vault
## overwrites this from packed entrance data in configure_dungeon.
var _grants_persistent: bool = true
## Persistent fields at instance entry, used by carry_out() in a practice vault.
var _entry_persistent: Dictionary = {}
## Per-player ability state (id -> PlayerAbilityState). Kept next to
## SimPlayerState so class abilities stay keyed by player id.
var _ability_by_player: Dictionary = {}
## Class ids already logged through DataCatalog.report_unknown_id this sim.
var _logged_unknown_class_ids: Dictionary = {}
## Test / later dungeon walls: tile (tx, ty) -> true is blocking for Slipstep.
var _blocking_tiles: Dictionary = {}
var _portals: Array[PortalSnapshot] = []
var _pending_transfers: Array[PortalTransfer] = []
var _dungeon: DungeonDef = null
## Test hook for vision §3.2 step 1. Real player Ward is not wired yet, so
## mitigation is a no-op (Ward = 0) unless a test sets this.
var _test_armor_ward: float = 0.0
var _instance_base_level: int = 0
var _instance_content_level: int = 0
var _opener_id: int = 0
var _opener_lp: int = 0
var _room_activated: Dictionary = {} # room id -> true
var _exit_spawned: bool = false
var _boss_defeated: bool = false
## Boss-arena n_peak (vision §3.5). 0 means the encounter has not started.
var _boss_n_peak: int = 0
## vision §6.1 rule 6a: sealed from the tick the boss first takes damage.
var _arena_sealed: bool = false
var _boss_untouched_until: int = -1
## Per-room n_peak for non-arena dungeon rooms, keyed by room id.
var _room_n_peak: Dictionary = {}
var _boss_fight_ticks: int = 0
var _boss_fight_sampled_tick: int = -1
var _boss_damage_by: Dictionary = {} # player_id -> damage dealt during the fight
var _boss_near_ticks: Dictionary = {} # player_id -> ticks within 12 tiles
var _boss_ally_heals: Dictionary = {} # player_id -> ally-affecting casts during the fight
var _hazards: Array[HazardState] = []
var _pattern_jobs: Array[PatternJob] = []
var _lobby_settings: LobbySettings = null


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
## The caller guarantees `id` came from this sim's alloc_player_id() (or is
## the pre-spawned player 1). Accepts an id at or below the high-water mark
## that is not currently live. Refuses, and logs, an id above the mark or
## any live player or entity id.
## A fresh add with an unknown or empty class is refused (false): the
## unknown id is logged through DataCatalog, and no player is queued or
## created. Omitting class entirely is allowed and uses the no-class
## default path.
## Explicit HP must come only from host-built character data, never from
## a client-supplied value.
## A same-tick re-add of a still-live player who was queued to leave cancels
## that leave and, if a character Dictionary has x/y, applies the position
## immediately through _set_placed_position.
## Sealed arena placement invariants: a spawn inside a sealed arena is moved
## to a deterministic safe spot outside the doorway. A returning player never
## lands inside a live fight.
func add_player(id: int, character: Variant = null) -> bool:
	var live: SimPlayerState = _players.get(id, null) as SimPlayerState
	if live != null and _pending_removes.has(id):
		# Keep a live player who was queued to leave (same-tick re-add).
		_pending_removes.erase(id)
		_pending_adds.erase(id)
		_apply_character_state(live, character, false)
		return true
	if not _player_id_accept(id):
		return false
	# Refuse before touching pending maps or creating state.
	if _refuse_fresh_class(character):
		return false
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
## `is_new_frame` is kept for API compatibility (the host passes it). Rule 7
## activity no longer depends on it: a replayed held input produces no fire
## rising edge and no aim or position change, so it cannot stamp
## last_activity_tick.
func apply_input(id: int, intent: InputIntent, is_new_frame: bool = true) -> void:
	var p: SimPlayerState = _players.get(id, null) as SimPlayerState
	if p == null or intent == null:
		return
	# A later apply_input in the same tick must not drop a pending one-shot.
	# OR ability_pressed; keep a nonzero interact_target_id (latest nonzero wins).
	var pending_ability: bool = p.intent.ability_pressed
	var pending_target: int = p.intent.interact_target_id
	p.intent = _copy_intent(intent)
	if pending_ability:
		p.intent.ability_pressed = true
	if p.intent.interact_target_id == 0 and pending_target != 0:
		p.intent.interact_target_id = pending_target
	# is_new_frame is accepted and ignored: activity is stamped in step()
	# from aim, actual path, an accepted ability, or a fire rising edge.
	var _is_new_frame: bool = is_new_frame


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
	# Covers add_player({x,y}) and a default spawn; a sealed-arena point is
	# relocated before the player enters the roster.
	_set_placed_position(p, p.x, p.y)
	_seed_activity(p)
	return p


func _apply_character(p: SimPlayerState, character: Variant) -> void:
	_apply_character_state(p, character, true)


## Shared by a fresh add_player, a same-tick cancelled leave, and
## place_player's HP argument. Class and position follow the character
## Dictionary (or a class-id String). HP is sanitized by _apply_placed_hp.
func _apply_character_state(p: SimPlayerState, character: Variant, fresh: bool) -> void:
	if p == null:
		return
	var class_id: String = p.class_id
	var class_set: bool = false
	var has_hp: bool = false
	var requested_hp: int = 0
	if character == null:
		pass
	elif character is String:
		class_id = String(character)
		class_set = true
	elif character is Dictionary:
		var d: Dictionary = character
		if d.has("class_id"):
			class_id = String(d["class_id"])
			class_set = true
		elif d.has("class"):
			class_id = String(d["class"])
			class_set = true
		if d.has("x"):
			p.x = float(d["x"])
			p.prev_x = p.x
		if d.has("y"):
			p.y = float(d["y"])
			p.prev_y = p.y
		if d.has("hp"):
			has_hp = true
			requested_hp = int(d["hp"])
		if d.has("x") or d.has("y"):
			_set_placed_position(p, p.x, p.y)
	# A fresh add treats HP <= 0 as omitted and fills to max, so it never
	# creates a 0-HP player. A cancelled leave and place_player treat
	# HP <= 0 as omitted and keep the current HP.
	var fresh_fill: bool = fresh and (not has_hp or requested_hp <= 0)
	if fresh:
		_set_player_class_on(p, class_id, fresh_fill)
	elif class_set and class_id != p.class_id:
		# Cancelled leave: apply a real class change only in town. In a
		# dungeon instance the current class is kept and a refusal is
		# logged. Keep HP, Focus, cooldown, and the ally-heal support
		# counter. Unknown or empty names leave the current class unchanged.
		if not _refuse_class_change(p, class_id):
			_adopt_player_class(p, class_id)
	if has_hp and not fresh_fill:
		_apply_placed_hp(p, requested_hp, fresh)


## True when a class apply must be skipped: an empty name, or an id that
## is not in a loaded DataCatalog (logged once per name; no fallback).
## With no catalog, the id is accepted so the caller can still store it.
func _reject_class_apply(class_id: String) -> bool:
	if class_id == "":
		return true
	if _catalog == null:
		return false
	if _catalog.class_def(class_id) == null:
		if not _logged_unknown_class_ids.has(class_id):
			_logged_unknown_class_ids[class_id] = true
			DataCatalog.report_unknown_id(class_id)
		return true
	return false


## True when a fresh add_player / _make_player must be refused because the
## caller explicitly set an unknown or empty class. Omitting class is not
## a refusal.
func _refuse_fresh_class(character: Variant) -> bool:
	var class_id := ""
	var class_set := false
	if character is String:
		class_id = String(character)
		class_set = true
	elif character is Dictionary:
		var d: Dictionary = character
		if d.has("class_id"):
			class_id = String(d["class_id"])
			class_set = true
		elif d.has("class"):
			class_id = String(d["class"])
			class_set = true
	if not class_set:
		return false
	return _reject_class_apply(class_id)


## Switch class without refilling HP or resetting ability state. An unknown
## or empty name keeps the current class, cooldown, and Focus.
func _adopt_player_class(p: SimPlayerState, class_id: String) -> void:
	if p == null or class_id == p.class_id:
		return
	if _reject_class_apply(class_id):
		return
	p.class_id = class_id
	p.class_def = _catalog.class_def(class_id) if _catalog != null else null
	var adef: AbilityDef = null
	if p.class_def != null and p.class_def.ability_id != "":
		adef = _catalog.ability(p.class_def.ability_id)
	var st := _ability_of(p.id)
	st.class_def = p.class_def
	st.ability_def = adef
	# Remaining cooldown is kept as-is, even if it is longer than the new
	# ability's max. The HUD clamps its display fraction to 1.
	var max_hp: int = _current_max_hp(p)
	if p.hp > max_hp:
		p.hp = max_hp
	var cap: float = float(st.focus_max())
	if st.focus > cap:
		st.focus = cap


## Character-dict / place_player HP sanitizing. Values below 0 are ignored:
## the current HP is kept, or max HP is used on a fresh add. On a fresh
## add_player, HP <= 0 is also ignored and uses max. On a cancelled leave
## or place_player of an existing player, HP <= 0 keeps the current HP.
## Values above max are capped. A dead player (hp <= 0) is not brought
## back to life.
## Explicit HP must come only from host-built character data, never from
## a client-supplied value.
func _apply_placed_hp(p: SimPlayerState, requested: int, fresh: bool) -> void:
	if p == null:
		return
	var max_hp: int = _current_max_hp(p)
	if requested <= 0:
		if fresh:
			p.hp = max_hp
		return
	if not fresh and p.hp <= 0:
		return
	p.hp = requested if requested <= max_hp else max_hp


func _alloc_id() -> int:
	# One id space for players, enemies, projectiles, pattern bullets and
	# bags. Ids are handed out in increasing order and never reused.
	var id: int = _next_id
	if _next_id < MAX_ENTITY_ID:
		_next_id += 1
	return id


## True when a player or entity with this id is currently in the sim.
func _id_is_live(id: int) -> bool:
	if _players.has(id):
		return true
	for e in _enemies:
		if e.id == id:
			return true
	for shot in _projectiles:
		if shot.id == id:
			return true
	for b in _pattern_bullets:
		if b.id == id:
			return true
	for bag in _ground_drops:
		if bag.id == id:
			return true
	for portal in _portals:
		if portal.id == id:
			return true
	for h in _hazards:
		if h.id == id:
			return true
	return false


## add_player / new place_player: id must be at or below the high-water
## mark and not currently live.
func _player_id_accept(id: int) -> bool:
	if id <= 0 or id >= MAX_ENTITY_ID:
		push_warning("LocalSim: id %d is not a valid player id" % id)
		return false
	if id >= _next_id:
		push_warning("LocalSim: id %d is above the high-water mark" % id)
		return false
	if _id_is_live(id):
		push_warning("LocalSim: id %d is already live" % id)
		return false
	return true


## Raises the entity allocator to `floor` so a host running several sims
## can give each a disjoint id range. Ids below it are never issued here.
func set_id_floor(floor: int) -> bool:
	if floor <= 0 or floor >= MAX_ENTITY_ID:
		return false
	if floor > _next_id:
		_next_id = floor
	return true


## A fresh player id from the shared entity allocator. Hosts use this so
## player ids can never collide with enemy, projectile or bag ids.
func alloc_player_id() -> int:
	return _alloc_id()


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
	e.n_peak = 1
	var kind: String = def.party_scaling if def.party_scaling != "" else "normal"
	e.scaled_max_hp = _scaling.encounter_hp(def.base_hp, e.content_level, e.n_peak, kind)
	e.hp = e.scaled_max_hp
	e.strafe_ticks = def.strafe_switch_ticks
	e.fire_cooldown = 0
	_enemies.append(e)
	return e.id


func step() -> void:
	_hits.clear()
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
		var accepted_ability: bool = _apply_ability(id, p.intent, sim_tick)
		_note_activity(p, accepted_ability, sim_tick)
		_apply_fire(p, sim_tick)
	for e in _enemies:
		if e.flash_ticks > 0:
			e.flash_ticks -= 1
	# vision §3.5 tick order: movement, then sample n_peak and rescale, then attacks.
	_refresh_encounter_scaling()
	_step_enemies(sim_tick)
	_refresh_encounter_scaling()
	_tick_pattern_jobs(sim_tick)
	_tick_hazards(sim_tick)
	_apply_combat(sim_tick)
	_sample_boss_fight_tick(sim_tick)
	_tick_ability_clocks()
	# Focus regen is at the end of the tick, after any spend.
	_regen_focus()
	_expire_ground_drops(sim_tick)
	_activate_rooms()
	_refresh_encounter_scaling()
	for id in _sorted_ids:
		var p: SimPlayerState = _players[id]
		_apply_interact(p, sim_tick)
		_apply_inventory_hotkey(p)
		_clear_oneshots(p)
	_cull_projectiles(sim_tick)
	_cull_pattern_bullets(sim_tick)
	_cull_hazards(sim_tick)
	_cull_pattern_jobs()
	_cull_enemies()
	_maybe_lift_empty_arena(sim_tick)
	_tick_boss_untouched(sim_tick)
	_maybe_spawn_exit()
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
		snap.pending_riftstone = viewer.pending_riftstone
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
		if not e.alive and e.flash_ticks <= 0:
			continue
		var es := EnemySnapshot.new()
		es.id = e.id
		es.def_id = e.def.id if e.def != null else ""
		es.alive = e.alive
		es.x = e.x
		es.y = e.y
		es.aim = e.aim
		es.hp = e.hp
		es.max_hp = e.max_hp()
		es.radius = e.radius()
		es.content_level = e.content_level
		es.flash_ticks = e.flash_ticks
		es.phase_id = e.phase_id()
		es.invulnerable = e.invulnerable
		enemy_snaps.append(es)
	snap.enemies = enemy_snaps
	snap.portals = _portals.duplicate()
	snap.hazards = _hazards.duplicate()
	snap.arena_sealed = _arena_sealed
	snap.seal_tick = _current_seal_tick()
	if _arena_sealed:
		snap.seal_segments = _seal_segments()
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


## Read-only hits from the tick that just completed. Do not mutate or keep past the next step().
func hits() -> Array[HitEvent]:
	return _hits


func _record_hit(kind: int, target_id: int, x: float, y: float, amount: int) -> void:
	var ev := HitEvent.new()
	ev.tick = _tick + 1
	ev.kind = kind
	ev.target_id = target_id
	ev.x = x
	ev.y = y
	ev.amount = amount
	_hits.append(ev)


## Read-only view of in-flight player shots. Do not mutate or keep past a step().
func projectiles() -> Array[SimProjectile]:
	return _projectiles


func projectile_count() -> int:
	return _projectiles.size()


func pattern_bullet_count() -> int:
	return _pattern_bullets.size()


func enemy_count() -> int:
	var n: int = 0
	for e in _enemies:
		if e.alive:
			n += 1
	return n


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
	var step_len: float = _config.move_speed_tiles_per_s * _player_stride_mult(p) * SimConstants.TICK_DT
	# Walking uses the same wall clip as Slipstep (_blink_destination) so
	# dungeon walls and the sealed arena doorway (vision §6.1 rule 6a)
	# actually block movement. X and Y are resolved separately so a diagonal
	# into a wall slides along it instead of stopping on both axes. Slipstep
	# keeps the single-segment clip so a blink cannot slide around a corner
	# or through a diagonal gap.
	if abs(mx) > SimConstants.MOVE_EPS:
		var xdest: PackedFloat64Array = _blink_destination(p.x, p.y, mx, 0.0, step_len)
		p.x = xdest[0]
	if abs(my) > SimConstants.MOVE_EPS:
		var ydest: PackedFloat64Array = _blink_destination(p.x, p.y, 0.0, my, step_len)
		p.y = ydest[1]


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
## HP <= 0 is omitted, same as add_player: a new player starts at max, and
## an existing player's current HP is kept, so this never creates a 0-HP
## player. Explicit HP must come only from host-built character data, never
## from a client-supplied value.
## Sealed arena placement invariants: a point inside a sealed arena is moved
## to a deterministic safe spot outside the doorway. A returning player never
## lands inside a live fight.
func place_player(id: int, x: float, y: float, hp: int = -1) -> void:
	var p: SimPlayerState = _players.get(id, null) as SimPlayerState
	var created: bool = p == null
	if p == null:
		if not _player_id_accept(id):
			return
		_pending_adds.erase(id)
		_pending_removes.erase(id)
		p = _make_player(id, x, y, null)
		_players[id] = p
		_rebuild_ids()
		_recompute_player_stats(p, true)
	else:
		# Keep a live player who was queued to leave (host first-join of
		# built-in player 1, or a same-tick re-add).
		_pending_removes.erase(id)
	_set_placed_position(p, x, y)
	# HP <= 0 is omitted: max on a new player, current HP on an existing one.
	_apply_placed_hp(p, -1 if hp <= 0 else hp, created)


func enemy_target_id(enemy_id: int) -> int:
	var e := _enemy_by_id(enemy_id)
	return e.target_id if e != null else 0


func _player_pos(id: int) -> Vector2:
	var p: SimPlayerState = _players.get(id, null) as SimPlayerState
	if p != null:
		return Vector2(p.x, p.y)
	push_error("LocalSim: unknown player id %s" % id)
	return Vector2.INF


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
	if e.is_boss() and e.def != null and not e.def.phases.is_empty():
		_step_boss(e, sim_tick)
		return
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
			_reset_wilds_encounter(e)
	elif nearest_id != 0 and not leashed:
		e.aggro = true
	# content-v0.1 §2.3: first attack comes fire_interval after aggro (and re-aggro).
	# The target is the nearest living player in aggro range, re-picked every 1 s.
	if e.aggro and not was_aggro:
		e.fire_cooldown = e.def.fire_interval_ticks
		e.target_id = nearest_id
		e.target_repick_tick = sim_tick + TARGET_REPICK_TICKS
		if e.def.sidestep_interval_ticks > 0:
			e.sidestep_cooldown = e.def.sidestep_interval_ticks
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
		var tp: SimPlayerState = _players.get(e.target_id, null) as SimPlayerState
		if tp != null:
			aim_x = tp.x
			aim_y = tp.y
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
	_tick_sidestep(e, sim_tick)
	if _has_bounds:
		var r: float = e.radius()
		e.x = clampf(e.x, _bound_min_x + r, _bound_max_x - r)
		e.y = clampf(e.y, _bound_min_y + r, _bound_max_y - r)


func _emit_enemy_pattern(e: EnemyState, sim_tick: int) -> void:
	var pattern_id: String = _pattern_id_for_fire(e)
	if pattern_id == "":
		return
	if _catalog == null:
		return
	var def := _catalog.pattern(pattern_id)
	if def == null:
		return
	_fire_pattern(e, def, sim_tick, e.aim, e.volley_index)
	e.volley_index += 1
	e.fire_cycle += 1


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
				if e.invulnerable:
					# Transition: bullets already in flight continue and deal no damage.
					continue
				var owner: int = shot.owner_id if shot.owner_id != 0 else _default_player_id()
				_hurt_enemy(e, _config.player_projectile_damage, owner, sim_tick)
				shot.consumed = true
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
				# Slipstep i-frames: skip this player and keep checking others
				# instead of stopping at the first overlap.
				if _ability_of(p.id).invuln_ticks > 0:
					continue
				var dmg: int = 0
				var attacker_level: int = 1
				var src := _enemy_by_id(b.source_id)
				if src != null:
					attacker_level = src.content_level
					if src.def != null:
						dmg = src.def.damage_for(b.damage_key)
				if _hurt_player(p, dmg, attacker_level):
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
				# Slipstep i-frames: skip this player and keep checking others
				# instead of stopping at the first overlap.
				if _ability_of(p.id).invuln_ticks > 0:
					continue
				var dmg: int = e.def.contact_damage if e.def != null else 0
				if _hurt_player(p, dmg, e.content_level):
					e.contact_cooldown = _config.contact_cooldown_ticks
				break


func _hurt_player(p: SimPlayerState, amount: int, attacker_level: int = 1) -> bool:
	if p == null or amount <= 0 or p.hp <= 0:
		return false
	var ast := _ability_of(p.id)
	if ast.invuln_ticks > 0:
		return false
	# vision §3.2 order: (1) Ward/armor mitigation, × D; (2) damage-taken
	# multipliers such as Thorn Ward; (3) round half-up and max(1) once at
	# the end. No rounding or minimum between steps.
	var raw: float = _mitigate_incoming(float(amount), attacker_level)
	if ast.ward_ticks > 0 and ast.ability_def != null:
		raw *= ast.ability_def.damage_taken_mult
	amount = maxi(1, SimScaling.round_half_up(raw))
	p.hp -= amount
	if p.hp < 0:
		p.hp = 0
	p.flash_ticks = _config.player_flash_ticks
	_record_hit(HitEvent.KIND_PLAYER_TAKEN, p.id, p.x, p.y, amount)
	return true


## vision §3.2 step 1: raw × 100 / (100 + defenderWard / m(attackerLevel)), then × D.
## Player Ward and D are not wired yet, so this is a no-op (Ward = 0, D = 1)
## unless a test sets _test_armor_ward.
func _mitigate_incoming(raw: float, attacker_level: int) -> float:
	var m_atk: float = _scaling.m(maxi(attacker_level, 1))
	if m_atk <= 0.0:
		m_atk = 1.0
	return raw * 100.0 / (100.0 + _test_armor_ward / m_atk)


## Test hook: pretend the player has this much Ward for incoming mitigation.
func set_test_armor_ward(ward: float) -> void:
	_test_armor_ward = maxf(ward, 0.0)


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
		if e.alive or e.flash_ticks > 0:
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


func set_item_rules(loot_bags_allowed: bool, item_transfers_allowed: bool) -> void:
	_loot_bags_allowed = loot_bags_allowed
	_item_transfers_allowed = item_transfers_allowed


## Removes every ground bag (host use: instances that allow none).
func clear_ground_drops() -> void:
	_ground_drops.clear()


func item_transfers_allowed() -> bool:
	return _item_transfers_allowed


## Read-only view of ground bags. Do not mutate or keep past a step().
func ground_drops() -> Array[GroundDrop]:
	return _ground_drops


## The bag with this entity id, or null. Do not mutate the returned bag.
func bag_by_id(id: int) -> GroundDrop:
	for bag in _ground_drops:
		if bag.id == id:
			return bag
	return null


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
	# An unknown or empty name keeps the current class and ability state.
	# A different class in a dungeon instance is refused; town is unchanged.
	var p: SimPlayerState = _players.get(player_id, null) as SimPlayerState
	if p != null:
		if _refuse_class_change(p, class_id):
			return
		_set_player_class_on(p, class_id, true)
		return
	if _reject_class_apply(class_id):
		return
	var cdef: ClassDef = _catalog.class_def(class_id) if _catalog != null else null
	var adef: AbilityDef = null
	if cdef != null and cdef.ability_id != "":
		adef = _catalog.ability(cdef.ability_id)
	_ability_of(player_id).reset_for_class(cdef, adef)


## True when this sim is a town (Hearth) sim. Class changes apply in place
## only here. A dungeon or practice-vault instance (`configure_dungeon`) is
## not town.
func is_town() -> bool:
	return _dungeon == null


## Whether the host can apply `class_id` in place for this player. A same-class
## rejoin is always allowed. A different class is allowed only in town. The
## host should run linger and then apply_class_change_arrival when this is
## false.
func class_change_allowed(id: int, class_id: String) -> bool:
	if _reject_class_apply(class_id):
		return false
	var p: SimPlayerState = _players.get(id, null) as SimPlayerState
	if p != null and class_id == p.class_id:
		return true
	return is_town()


## After-linger town arrival of a class-changed character (content-v0.1
## class lock). Applies the new class with HP = min(current, new max), 0
## Focus, the ability on full cooldown, no snapshot carry, and no boss
## credit, and seeds a fresh activity stamp. Full max HP is only for a
## fresh spawn with no live or lingering body (add_player).
## TODO(§7.1): pending loot banking is host / persistence side.
func apply_class_change_arrival(id: int, class_id: String) -> bool:
	var p: SimPlayerState = _players.get(id, null) as SimPlayerState
	if p == null:
		return false
	if _reject_class_apply(class_id):
		return false
	var current_hp: int = p.hp
	_set_player_class_on(p, class_id, false)
	var max_hp: int = _current_max_hp(p)
	if current_hp > 0:
		p.hp = mini(current_hp, max_hp)
	else:
		# A dead body is not revived. Full max HP is the fresh-add path.
		p.hp = current_hp
	var st := _ability_of(id)
	st.focus = 0.0
	st.cooldown_ticks = st.ability_def.cooldown_ticks if st.ability_def != null else 0
	_seed_activity(p)
	return true


## True when a different, known class must be kept off this player because
## the sim is not town. Logs one refusal. Same class, unknown ids, and town
## are not refusals here.
func _refuse_class_change(p: SimPlayerState, class_id: String) -> bool:
	if p == null or class_id == p.class_id:
		return false
	if is_town():
		return false
	if _reject_class_apply(class_id):
		return false
	push_error(CLASS_CHANGE_REFUSED_LOG)
	return true


func _set_player_class_on(p: SimPlayerState, class_id: String, fill: bool) -> void:
	if p == null:
		return
	if class_id != "":
		if _reject_class_apply(class_id):
			# Unknown name: keep the current class, cooldown, and Focus.
			return
		p.class_id = class_id
		p.class_def = _catalog.class_def(class_id) if _catalog != null else null
		var adef: AbilityDef = null
		if p.class_def != null and p.class_def.ability_id != "":
			adef = _catalog.ability(p.class_def.ability_id)
		_ability_of(p.id).reset_for_class(p.class_def, adef)
	elif p.class_id != "":
		# Empty name: keep the current class, cooldown, and Focus.
		return
	_recompute_player_stats(p, fill)


func set_instance_multiplier_hundredths(m100: int) -> void:
	_instance_m100 = m100


func set_in_portal(in_portal: bool) -> void:
	_in_portal = in_portal


func set_practice_yard(enabled: bool) -> void:
	_practice_yard = enabled


func is_practice_yard() -> bool:
	return _practice_yard


func set_lobby_settings(settings: LobbySettings) -> void:
	_lobby_settings = settings


## True when m100 is in the packed [50, 150] step-5 window and the lobby range.
func m100_allowed(m100: int) -> bool:
	if not _scaling.is_valid_m100(m100):
		return false
	if _lobby_settings == null:
		return false
	return _lobby_settings.allows_m100(m100)


func add_portal(portal: PortalSnapshot) -> void:
	if portal != null:
		_portals.append(portal)


func defeat_all_enemies() -> void:
	for e in _enemies:
		if e.alive:
			e.invulnerable = false
			_kill_enemy(e, _tick)
	# Test hook: wipe immediately so leftover death flashes don't show up in
	# later room-count assertions. Live combat deaths keep their flash.
	for e in _enemies:
		e.flash_ticks = 0


func instance_content_level() -> int:
	return _instance_content_level


func instance_base_level() -> int:
	return _instance_base_level


func instance_m100() -> int:
	return _instance_m100


func dungeon_id() -> String:
	return _dungeon.id if _dungeon != null else ""


## Read-only view for the host's instance-lifetime code. Does not mutate sim state.
func boss_defeated() -> bool:
	return _boss_defeated


## Read-only view for the host's instance-lifetime code. Does not mutate sim state.
func vault_exit_open() -> bool:
	return _exit_spawned


## Read-only: true from the tick the boss first takes damage until the seal lifts
## (boss death, empty-arena reset, or a new instance). Mutating nothing.
func arena_sealed() -> bool:
	return _arena_sealed


## Read-only copy of boss-dead, vault-exit-open, and arena-sealed. Mutating the
## Dictionary does not change sim state.
func dungeon_state() -> Dictionary:
	return {
		"boss_defeated": _boss_defeated,
		"vault_exit_open": _exit_spawned,
		"arena_sealed": _arena_sealed,
	}


func get_enemy(id: int) -> EnemyState:
	return _enemy_by_id(id)


## Test / tooling hook. Goes through invuln, the seal, phase thresholds and death.
func grants_persistent() -> bool:
	return _grants_persistent


## Character snapshot for leaving this instance. A practice vault carries no
## persistent gains (XP, Glint, Riftstone, or items found here).
func carry_out(player_id: int) -> PlayerCarry:
	var p: SimPlayerState = _players.get(player_id, null) as SimPlayerState
	var carry := PlayerCarry.from_sim(p, _ability_of(player_id))
	if _grants_persistent:
		return carry
	if not _entry_persistent.has(player_id):
		_remember_entry_persistent(p)
	var entry: Dictionary = _entry_persistent.get(player_id, {})
	carry.xp_tenths = int(entry.get("xp_tenths", carry.xp_tenths))
	carry.pending_glint = int(entry.get("pending_glint", carry.pending_glint))
	carry.pending_riftstone = int(entry.get("pending_riftstone", carry.pending_riftstone))
	var kept: Variant = entry.get("inventory", null)
	if kept is PlayerInventory:
		carry.inventory = kept
	return carry


func _remember_entry_persistent(p: SimPlayerState) -> void:
	if p == null:
		return
	_entry_persistent[p.id] = {
		"xp_tenths": p.xp_tenths,
		"pending_glint": p.pending_glint,
		"pending_riftstone": p.pending_riftstone,
		"inventory": _snapshot_inventory(p.inventory),
	}


func _snapshot_inventory(inv: PlayerInventory) -> PlayerInventory:
	if inv == null:
		return null
	var out := PlayerInventory.new(inv.slot_count)
	for i in range(inv.slots.size()):
		if i < out.slots.size():
			out.slots[i] = inv.slots[i]
	out.equipped_weapon = inv.equipped_weapon
	out.equipped_armor = inv.equipped_armor
	out.equipped_charm = inv.equipped_charm
	return out


func boss_n_peak() -> int:
	return _boss_n_peak


func room_n_peak(room_id: String) -> int:
	return int(_room_n_peak.get(room_id, 0))


func boss_aim_seed(entity_id: int, tick: int) -> int:
	return _domain_seed(entity_id, tick, BOSS_AIM_SEED_DOMAIN)


func boss_pool_seed(entity_id: int, tick: int) -> int:
	return _domain_seed(entity_id, tick, BOSS_POOL_SEED_DOMAIN)


func pattern_volley_seed(entity_id: int, tick: int, volley_index: int) -> int:
	return _mix_seed(_world_seed, entity_id, tick + volley_index)


func live_pattern_ids() -> PackedStringArray:
	var ids := PackedStringArray()
	var seen: Dictionary = {}
	for b in _pattern_bullets:
		if b.pattern_id != "" and not seen.has(b.pattern_id):
			ids.append(b.pattern_id)
			seen[b.pattern_id] = true
	for job in _pattern_jobs:
		if job.live and job.def != null and job.def.id != "" and not seen.has(job.def.id):
			ids.append(job.def.id)
			seen[job.def.id] = true
	return ids


func hurt_enemy(enemy_id: int, amount: int, attacker_id: int = 0) -> void:
	var e: EnemyState = _enemy_by_id(enemy_id)
	if e != null:
		_hurt_enemy(e, amount, attacker_id, _tick)


func take_pending_transfers() -> Array[PortalTransfer]:
	var out: Array[PortalTransfer] = _pending_transfers.duplicate()
	_pending_transfers.clear()
	return out


## Read-only copy of the live portal roster for host admission lifetimes.
func portals() -> Array[PortalSnapshot]:
	return _portals.duplicate()


func portal_by_id(id: int) -> PortalSnapshot:
	for portal in _portals:
		if portal.id == id:
			return portal
	return null


func derived_instance_seed(portal_id: int, enter_tick: int) -> int:
	return _mix_seed(
		_mix_seed(_world_seed, portal_id, enter_tick),
		0,
		DUNGEON_INSTANCE_SEED_DOMAIN
	)


func _domain_seed(entity_id: int, tick: int, domain: int) -> int:
	return _mix_seed(_mix_seed(_world_seed, entity_id, tick), 0, domain)


## Place the packed practice-yard entrance (found-portal rules, M locked at creation).
func spawn_practice_portal(dungeon_id: String) -> int:
	if _catalog == null:
		return 0
	var def: DungeonDef = _catalog.dungeon(dungeon_id)
	if def == null or def.practice_yard_portal.is_empty():
		return 0
	var src: Dictionary = def.practice_yard_portal
	var portal := PortalSnapshot.new()
	portal.id = _alloc_id()
	portal.x = float(src["x"])
	portal.y = float(src["y"])
	portal.radius = float(src["radius"])
	portal.kind = PortalSnapshot.KIND_ENTER
	portal.dungeon_id = def.id
	portal.dungeon_name = def.name
	portal.m100 = int(src["m100"])
	var practice_base: int = int(src["practice_base_level"])
	portal.base_level = practice_base
	portal.content_level = _scaling.portal_content_level(practice_base, portal.m100)
	portal.persistent = bool(src.get("persistent", false))
	if not src.has("grants_persistent"):
		push_error("DataCatalog: unknown id %s.practice_yard_portal.grants_persistent" % def.id)
		return 0
	portal.grants_persistent = bool(src["grants_persistent"])
	_portals.append(portal)
	return portal.id


## Turn this sim into a dungeon instance. Call on a fresh LocalSim.
func configure_dungeon(
	def: DungeonDef,
	seed: int,
	m100: int,
	base_level: int,
	content_level: int,
	opener_id: int,
	opener_lp: int,
	grants_persistent: bool
) -> void:
	_dungeon = def
	_practice_yard = false
	_grants_persistent = grants_persistent
	_entry_persistent.clear()
	_in_portal = true
	_instance_m100 = m100
	_instance_base_level = base_level
	_instance_content_level = content_level
	_opener_id = opener_id
	_opener_lp = opener_lp
	_room_activated.clear()
	_exit_spawned = false
	_boss_defeated = false
	_boss_n_peak = 0
	_arena_sealed = false
	_boss_untouched_until = -1
	_room_n_peak.clear()
	_reset_boss_fight_trackers()
	_portals.clear()
	_enemies.clear()
	_projectiles.clear()
	_pattern_bullets.clear()
	_hazards.clear()
	_pattern_jobs.clear()
	_ground_drops.clear()
	_granted_drop_ids.clear()
	_blocking_tiles.clear()
	set_world_seed(seed)
	if def != null:
		var r := def.bounds_rect()
		set_bounds(r.position.x, r.position.y, r.position.x + r.size.x, r.position.y + r.size.y)
		_build_dungeon_walls(def)
		_spawn_boss_placeholders(def)
	for id in _sorted_ids:
		_remember_entry_persistent(_players[id])
		_seed_activity(_players[id])


## Copy a character into this instance at (x, y) after a portal transfer.
## Sealed arena placement invariants: a restore into a sealed arena lands at
## a deterministic safe spot outside the doorway. A returning player never
## lands inside a live fight.
func apply_carried_player(carry: PlayerCarry, x: float, y: float) -> void:
	if carry == null:
		return
	var p: SimPlayerState = _players.get(carry.player_id, null) as SimPlayerState
	if p == null:
		return
	if carry.class_id != "":
		_set_player_class_on(p, carry.class_id, false)
	p.level = carry.level
	p.xp_tenths = carry.xp_tenths
	p.pending_glint = carry.pending_glint
	p.pending_riftstone = carry.pending_riftstone
	p.aim = carry.aim
	_set_placed_position(p, x, y)
	p.last_interact_seq = carry.last_interact_seq
	if carry.inventory != null:
		p.inventory = carry.inventory
	_recompute_player_stats(p, false)
	p.hp = clampi(carry.hp, 0, _current_max_hp(p))
	if carry.ability != null:
		var st := _ability_of(p.id)
		st.class_def = carry.ability.class_def
		st.ability_def = carry.ability.ability_def
		st.focus = carry.ability.focus
		st.cooldown_ticks = carry.ability.cooldown_ticks
		st.cast_lock_ticks = carry.ability.cast_lock_ticks
		st.ward_ticks = carry.ability.ward_ticks
		st.invuln_ticks = carry.ability.invuln_ticks
		st.last_ability_seq = carry.ability.last_ability_seq
		st.ally_ability_heals = carry.ability.ally_ability_heals
		st.reseed(_world_seed, p.id)
	_remember_entry_persistent(p)
	_seed_activity(p)


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
	# Practice yard and the Wilds use Lp (vision §3.2a). Inside a portal,
	# Le = min(Lp, E + sync_plus) (vision §6.1).
	if p == null:
		return 1
	return _scaling.effective_level(p.level, _instance_content_level, _in_portal)


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


func _is_eligible(e: EnemyState, player_id: int, px: float, py: float, sim_tick: int = 0) -> bool:
	if e.is_boss() and _reward_rank(e) == "boss":
		return _is_boss_eligible(e, player_id, sim_tick)
	if e.damaged_by.has(player_id):
		return true
	var dx: float = px - e.x
	var dy: float = py - e.y
	return dx * dx + dy * dy <= _loot.eligibility_range_tiles * _loot.eligibility_range_tiles


func _grant_kill_rewards(e: EnemyState, sim_tick: int) -> void:
	if e.rewards_granted:
		return
	e.rewards_granted = true
	# Practice vault: packed grants_persistent is false — no XP, currency,
	# gear rolls, loot bags, or found portals, for trash or the Warden.
	if not _grants_persistent:
		return
	if not e.drops_loot:
		return
	var rank: String = _reward_rank(e)
	for id in _sorted_ids:
		var p: SimPlayerState = _players[id]
		if not _is_eligible(e, p.id, p.x, p.y, sim_tick):
			continue
		var le: int = _player_le(p)
		var xp: int = _scaling.credited_kill_tenths(e.content_level, le, rank)
		_grant_xp_tenths_to(p, xp)
		p.pending_glint += _loot.glint_for_kill(e.content_level, rank, _scaling)
		if rank == "boss":
			p.pending_riftstone += _scaling.riftstone_yield(_instance_m100)
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
	if item == null or not _loot_bags_allowed:
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
	return bag_by_id(id)


func ability_state(player_id: int) -> PlayerAbilityState:
	return _ability_of(player_id)


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


## Focus regen per second for this player (class rate, as used each tick).
func focus_regen_per_s(player_id: int) -> float:
	return _ability_of(player_id).focus_regen()


func focus_max(player_id: int) -> int:
	return _ability_of(player_id).focus_max()


func ability_cooldown_ticks(player_id: int) -> int:
	return _ability_of(player_id).cooldown_ticks


func set_ability_cooldown_ticks(player_id: int, ticks: int) -> void:
	_ability_of(player_id).cooldown_ticks = maxi(0, ticks)


func set_invuln_ticks(player_id: int, ticks: int) -> void:
	_ability_of(player_id).invuln_ticks = maxi(0, ticks)


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


func _apply_ability(player_id: int, intent: InputIntent, _sim_tick: int) -> bool:
	if intent == null or not intent.ability_pressed:
		return false
	# seq 0 is never applied (host-api rejects it; game_session skips 0 on wrap).
	if intent.seq == 0:
		return false
	var st := _ability_of(player_id)
	if intent.seq == st.last_ability_seq:
		return false
	st.last_ability_seq = intent.seq
	if st.ability_def == null:
		return false
	var caster: SimPlayerState = _players.get(player_id, null) as SimPlayerState
	if caster != null and caster.hp <= 0:
		return false
	if st.cooldown_ticks > 0:
		return false
	if st.focus + 1e-9 < float(st.ability_def.focus_cost):
		return false
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
	return true


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
		if _boss_fight_active() and not _boss_defeated:
			var n: int = int(_boss_ally_heals.get(player_id, 0))
			_boss_ally_heals[player_id] = n + 1


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
	t_end = _clip_arena_seal_t(sx, sy, ex, ey, t_end)
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


func _clip_arena_seal_t(sx: float, sy: float, ex: float, ey: float, t_end: float) -> float:
	# While sealed, nobody may cross the arena bounds (vision §6.1 rule 6a).
	if not _arena_sealed or _dungeon == null or t_end <= 0.0:
		return t_end
	var room: Dictionary = _arena_room()
	if room.is_empty():
		return t_end
	var start_in: bool = _dungeon.room_contains(room, sx, sy)
	var dest_in: bool = _dungeon.room_contains(room, sx + (ex - sx) * t_end, sy + (ey - sy) * t_end)
	if dest_in == start_in:
		return t_end
	var lo: float = 0.0
	var hi: float = t_end
	for _i in range(40):
		var mid: float = (lo + hi) * 0.5
		var mx: float = sx + (ex - sx) * mid
		var my: float = sy + (ey - sy) * mid
		if _dungeon.room_contains(room, mx, my) == start_in:
			lo = mid
		else:
			hi = mid
	return maxf(0.0, lo)


func _current_seal_tick() -> int:
	if not _arena_sealed:
		return -1
	for e in _enemies:
		if e.is_boss() and e.seal_tick >= 0:
			return e.seal_tick
	return -1


func arena_seal_segments() -> Array[Dictionary]:
	# Read-only copy of the sealed doorway segments, in tiles.
	return _seal_segments() if _arena_sealed else []


func _seal_segments() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var room: Dictionary = _arena_room()
	if room.is_empty() or _dungeon == null:
		return out
	var arena := _dict_rect(room)
	if arena.size.x <= 0.0 or arena.size.y <= 0.0:
		return out
	var others: Array = []
	for other in _dungeon.rooms:
		if String(other.get("id", "")) == String(room.get("id", "")):
			continue
		others.append(other)
	for corridor in _dungeon.corridors:
		others.append(corridor)
	for other in others:
		var edge: Dictionary = _shared_edge(arena, _dict_rect(other))
		if not edge.is_empty():
			out.append(edge)
	return out


func _dict_rect(d: Dictionary) -> Rect2:
	var origin: Variant = d.get("origin", [])
	var size: Variant = d.get("size", [])
	if not (origin is Array) or not (size is Array):
		return Rect2()
	if (origin as Array).size() < 2 or (size as Array).size() < 2:
		return Rect2()
	return Rect2(float(origin[0]), float(origin[1]), float(size[0]), float(size[1]))


func _shared_edge(a: Rect2, b: Rect2) -> Dictionary:
	# Shared vertical or horizontal edge between two axis-aligned rooms.
	var lo: float
	var hi: float
	if is_equal_approx(a.position.x, b.position.x + b.size.x) or is_equal_approx(a.position.x + a.size.x, b.position.x):
		var x: float = a.position.x if is_equal_approx(a.position.x, b.position.x + b.size.x) else a.position.x + a.size.x
		lo = maxf(a.position.y, b.position.y)
		hi = minf(a.position.y + a.size.y, b.position.y + b.size.y)
		if hi - lo > 0.05:
			return {"x0": x, "y0": lo, "x1": x, "y1": hi}
	if is_equal_approx(a.position.y, b.position.y + b.size.y) or is_equal_approx(a.position.y + a.size.y, b.position.y):
		var y: float = a.position.y if is_equal_approx(a.position.y, b.position.y + b.size.y) else a.position.y + a.size.y
		lo = maxf(a.position.x, b.position.x)
		hi = minf(a.position.x + a.size.x, b.position.x + b.size.x)
		if hi - lo > 0.05:
			return {"x0": lo, "y0": y, "x1": hi, "y1": y}
	return {}


func _set_arena_sealed(sealed: bool) -> void:
	_arena_sealed = sealed


## Write a placement or position restore. If the arena is sealed and (x, y)
## is inside it, the player is relocated to a deterministic safe spot just
## outside the doorway. A returning player never lands inside a live fight.
func _set_placed_position(p: SimPlayerState, x: float, y: float) -> void:
	if p == null:
		return
	var dest: PackedFloat64Array = _placement_xy(x, y)
	p.x = dest[0]
	p.y = dest[1]
	p.prev_x = p.x
	p.prev_y = p.y


func _placement_xy(x: float, y: float) -> PackedFloat64Array:
	if not _should_relocate_sealed_placement(x, y):
		return PackedFloat64Array([x, y])
	return _sealed_arena_outside_door_xy()


func _should_relocate_sealed_placement(x: float, y: float) -> bool:
	if not _arena_sealed or _dungeon == null:
		return false
	var room: Dictionary = _arena_room()
	if room.is_empty():
		return false
	return _dungeon.room_contains(room, x, y)


## Deterministic safe spot just outside the sealed arena door. Prefers the
## midpoint of the first doorway segment (sorted), stepped outward from the
## arena center by at least the player radius. Used by place_player,
## add_player with {x,y}, and apply_carried_player.
func _sealed_arena_outside_door_xy() -> PackedFloat64Array:
	var room: Dictionary = _arena_room()
	var arena := _dict_rect(room)
	var standoff: float = 0.5
	if _config != null:
		standoff = maxf(_config.player_radius_tiles, 0.5)
	var acx: float = arena.position.x + arena.size.x * 0.5
	var acy: float = arena.position.y + arena.size.y * 0.5
	var sx: float = arena.position.x - standoff
	var sy: float = acy
	var seg: Dictionary = _primary_seal_segment()
	if not seg.is_empty():
		var mx: float = (float(seg["x0"]) + float(seg["x1"])) * 0.5
		var my: float = (float(seg["y0"]) + float(seg["y1"])) * 0.5
		var nx: float = 0.0
		var ny: float = 0.0
		if is_equal_approx(float(seg["x0"]), float(seg["x1"])):
			nx = -1.0 if acx > mx else 1.0
		else:
			ny = -1.0 if acy > my else 1.0
		sx = mx + nx * standoff
		sy = my + ny * standoff
	# If the first estimate is still inside, keep pushing away from the center.
	if _dungeon != null and not room.is_empty():
		var guard: int = 0
		while _dungeon.room_contains(room, sx, sy) and guard < 8:
			sx += -standoff if sx <= acx else standoff
			sy += -standoff if sy <= acy else standoff
			guard += 1
	return PackedFloat64Array([sx, sy])


func _primary_seal_segment() -> Dictionary:
	var segs: Array[Dictionary] = _seal_segments()
	if segs.is_empty():
		return {}
	segs.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if float(a["x0"]) != float(b["x0"]):
			return float(a["x0"]) < float(b["x0"])
		if float(a["y0"]) != float(b["y0"]):
			return float(a["y0"]) < float(b["y0"])
		if float(a["x1"]) != float(b["x1"]):
			return float(a["x1"]) < float(b["x1"])
		return float(a["y1"]) < float(b["y1"])
	)
	return segs[0]


func _apply_interact(p: SimPlayerState, sim_tick: int) -> void:
	# InputFrame.interact_target_id: 0 means none. A nonzero value is a
	# press on this seq, applied at most once per seq via Seq.seq_is_next
	# (same rule as HostInteractValidator). Unknown ids, bags the player
	# may not use, portals that fail the join floor, and targets beyond
	# SimScaling.in_accept_range are dropped silently, with no ErrorReply.
	var target_id: int = p.intent.interact_target_id

	if target_id == 0:
		return
	if not Seq.seq_is_next(p.intent.seq, p.last_interact_seq):
		return
	p.last_interact_seq = p.intent.seq
	var bag := _bag_by_id(target_id)
	if bag != null and not _item_transfers_allowed:
		return
	if _live_own_bag(p, bag):
		if not _scaling.in_accept_range(_bag_distance(p, bag)):
			return
		if p.inventory.is_full():
			return
		if p.inventory.add(bag.item):
			_ground_drops.erase(bag)
		return
	_try_portal_enter(p, target_id, sim_tick)


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
				for e in _enemies:
					e.damaged_by.erase(pid)
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
			var character: Variant = rec.get("character", null)
			if _refuse_fresh_class(character):
				continue
			var p := _make_player(pid, 0.0, 0.0, character)
			_players[pid] = p
			changed = true
		_pending_adds.clear()
	if changed:
		_rebuild_ids()
		if not _players.has(_player_id):
			_player_id = _sorted_ids[0] if not _sorted_ids.is_empty() else 0


func _try_portal_enter(p: SimPlayerState, target_id: int, sim_tick: int) -> void:
	var portal := portal_by_id(target_id)
	if portal == null or not portal.is_interactable():
		return
	var dist: float = SimConstants.interact_distance(p.x, p.y, portal.x, portal.y)
	if not _scaling.in_accept_range(dist):
		return
	if portal.kind == PortalSnapshot.KIND_ENTER:
		if not m100_allowed(portal.m100):
			return
		if _scaling.below_join_floor(p.level, portal.content_level):
			return
		var def: DungeonDef = null
		if _catalog != null:
			def = _catalog.dungeon(portal.dungeon_id)
		if def == null:
			return
		var arrival := def.arrival_point()
		var xfer := PortalTransfer.new()
		xfer.kind = PortalTransfer.KIND_ENTER
		xfer.player_id = p.id
		xfer.portal_id = portal.id
		xfer.dungeon_id = portal.dungeon_id
		xfer.seed = derived_instance_seed(portal.id, sim_tick)
		xfer.m100 = portal.m100
		xfer.base_level = portal.base_level
		xfer.content_level = portal.content_level
		xfer.opener_id = p.id
		xfer.opener_lp = p.level
		xfer.arrival_x = arrival.x
		xfer.arrival_y = arrival.y
		xfer.grants_persistent = portal.grants_persistent
		_pending_transfers.append(xfer)
		return
	if portal.kind == PortalSnapshot.KIND_EXIT:
		var xfer := PortalTransfer.new()
		xfer.kind = PortalTransfer.KIND_EXIT
		xfer.player_id = p.id
		xfer.portal_id = portal.id
		xfer.dungeon_id = portal.dungeon_id
		xfer.arrival_x = 16.0
		xfer.arrival_y = 16.0
		_pending_transfers.append(xfer)


func _activate_rooms() -> void:
	if _dungeon == null:
		return
	for room in _dungeon.rooms:
		var rid: String = String(room.get("id", ""))
		if rid == "" or _room_activated.has(rid):
			continue
		var entered: bool = false
		for id in _sorted_ids:
			var p: SimPlayerState = _players[id]
			if p.hp > 0 and _dungeon.room_contains(room, p.x, p.y):
				entered = true
				break
		if not entered:
			continue
		_room_activated[rid] = true
		var spawns: Variant = room.get("spawns", [])
		if not (spawns is Array):
			continue
		for spawn in spawns:
			if not (spawn is Dictionary):
				continue
			var eid: String = String(spawn.get("enemy_id", ""))
			if eid == "":
				continue
			var sid: int = spawn_enemy(eid, float(spawn["x"]), float(spawn["y"]), _instance_content_level)
			var spawned: EnemyState = _enemy_by_id(sid)
			if spawned != null:
				spawned.room_id = rid


func _maybe_spawn_exit() -> void:
	# The vault exit opens when the Tallow Warden is defeated (content-v0.1 §3.4).
	if _dungeon == null or _exit_spawned:
		return
	if _dungeon_has_boss() and not _boss_defeated:
		return
	for e in _enemies:
		if e.alive and e.is_boss():
			return
	for room in _dungeon.rooms:
		if not room.has("exit_portal"):
			continue
		var src: Variant = room["exit_portal"]
		if not (src is Dictionary):
			continue
		var portal := PortalSnapshot.new()
		portal.id = _alloc_id()
		portal.x = float(src["x"])
		portal.y = float(src["y"])
		portal.radius = float(src["radius"])
		portal.kind = PortalSnapshot.KIND_EXIT
		portal.dungeon_id = _dungeon.id
		portal.dungeon_name = _dungeon.name
		portal.m100 = _instance_m100
		portal.base_level = _instance_base_level
		portal.content_level = _instance_content_level
		_portals.append(portal)
		_exit_spawned = true
		return


func _spawn_boss_placeholders(def: DungeonDef) -> void:
	for room in def.rooms:
		if not room.has("boss_placeholder"):
			continue
		var src: Variant = room["boss_placeholder"]
		if not (src is Dictionary):
			continue
		var mark := PortalSnapshot.new()
		mark.id = _alloc_id()
		mark.x = float(src["x"])
		mark.y = float(src["y"])
		mark.radius = 0.6
		mark.kind = PortalSnapshot.KIND_PLACEHOLDER
		mark.dungeon_id = def.id
		mark.dungeon_name = def.name
		mark.marker_id = String(src.get("id", ""))
		mark.marker_name = String(src.get("name", ""))
		_portals.append(mark)


func _build_dungeon_walls(def: DungeonDef) -> void:
	var r := def.bounds_rect()
	var min_tx: int = int(floor(r.position.x))
	var min_ty: int = int(floor(r.position.y))
	var max_tx: int = int(ceil(r.position.x + r.size.x))
	var max_ty: int = int(ceil(r.position.y + r.size.y))
	for ty in range(min_ty, max_ty):
		for tx in range(min_tx, max_tx):
			var cx: float = float(tx) + 0.5
			var cy: float = float(ty) + 0.5
			if not _dungeon_walkable(def, cx, cy):
				_blocking_tiles[Vector2i(tx, ty)] = true


func _dungeon_walkable(def: DungeonDef, x: float, y: float) -> bool:
	for room in def.rooms:
		if def.room_contains(room, x, y):
			return true
	for corridor in def.corridors:
		if def.room_contains(corridor, x, y):
			return true
	return false


func _rebuild_ids() -> void:
	_sorted_ids.clear()
	var keys: Array = _players.keys()
	keys.sort()
	for id in keys:
		_sorted_ids.append(int(id))


func _refresh_encounter_scaling() -> void:
	if _dungeon != null:
		if not _boss_defeated:
			_refresh_boss_n_peak()
		_refresh_room_n_peaks()
	else:
		_refresh_wilds_n_peaks()


func _refresh_boss_n_peak() -> void:
	if _boss_defeated:
		return
	var n: int = _count_living_in_arena()
	if _boss_n_peak <= 0:
		if n <= 0:
			return
		_boss_n_peak = n
	elif n > _boss_n_peak and not _arena_sealed:
		# Once the arena is sealed, n_peak cannot grow until the seal lifts
		# (vision §6.1 rule 6a).
		_boss_n_peak = n
	for e in _enemies:
		if not e.alive or e.def == null:
			continue
		if e.is_boss() or e.summoned:
			_apply_n_peak(e, _boss_n_peak)


func _refresh_room_n_peaks() -> void:
	if _dungeon == null:
		return
	for room in _dungeon.rooms:
		var rid: String = String(room.get("id", ""))
		if rid == "" or not _room_activated.has(rid):
			continue
		var n: int = _count_living_for_room(room)
		if not _room_n_peak.has(rid):
			_room_n_peak[rid] = n if n > 0 else 1
		elif n > int(_room_n_peak[rid]):
			_room_n_peak[rid] = n
		var peak: int = int(_room_n_peak[rid])
		for e in _enemies:
			if e.alive and e.room_id == rid and not e.is_boss() and not e.summoned:
				_apply_n_peak(e, peak)


func _refresh_wilds_n_peaks() -> void:
	for e in _enemies:
		if not e.alive or e.def == null or e.is_boss() or not e.aggro:
			continue
		var n: int = _count_living_near(e.x, e.y, N_PEAK_RANGE_TILES)
		if n > e.n_peak:
			_apply_n_peak(e, n)


func _apply_n_peak(e: EnemyState, n: int) -> void:
	if e == null or not e.alive or e.def == null:
		return
	n = maxi(n, 1)
	var kind: String = e.def.party_scaling if e.def.party_scaling != "" else "normal"
	var new_max: int = _scaling.encounter_hp(e.def.base_hp, e.content_level, n, kind)
	var old_max: int = e.max_hp()
	e.n_peak = n
	if new_max == old_max or old_max <= 0:
		e.scaled_max_hp = new_max
		return
	if e.hp > 0:
		e.hp = _scaling.keep_hp_fraction(e.hp, old_max, new_max)
	e.scaled_max_hp = new_max


func _arena_room() -> Dictionary:
	if _dungeon == null:
		return {}
	for e in _enemies:
		if e.is_boss():
			var room: Dictionary = _room_containing(e.x, e.y)
			if not room.is_empty():
				return room
	for room in _dungeon.rooms:
		var spawns: Variant = room.get("spawns", [])
		if not (spawns is Array):
			continue
		for spawn in spawns:
			if not (spawn is Dictionary):
				continue
			if String(spawn.get("enemy_id", "")) == "tallow_warden":
				return room
	return {}


func _count_living_in_arena() -> int:
	var room: Dictionary = _arena_room()
	if room.is_empty() or _dungeon == null:
		return 0
	var n: int = 0
	for id in _sorted_ids:
		var p: SimPlayerState = _players[id]
		if p.hp > 0 and _dungeon.room_contains(room, p.x, p.y):
			n += 1
	return n


func _count_living_for_room(room: Dictionary) -> int:
	if _dungeon == null or room.is_empty():
		return 0
	var rid: String = String(room.get("id", ""))
	var n: int = 0
	for id in _sorted_ids:
		var p: SimPlayerState = _players[id]
		if p.hp <= 0:
			continue
		if _dungeon.room_contains(room, p.x, p.y):
			n += 1
			continue
		var near: bool = false
		for e in _enemies:
			if not e.alive or e.room_id != rid or e.is_boss() or e.summoned:
				continue
			var dx: float = p.x - e.x
			var dy: float = p.y - e.y
			if dx * dx + dy * dy <= N_PEAK_RANGE_TILES * N_PEAK_RANGE_TILES:
				near = true
				break
		if near:
			n += 1
	return n


func _count_living_near(x: float, y: float, radius: float) -> int:
	var n: int = 0
	var r2: float = radius * radius
	for id in _sorted_ids:
		var p: SimPlayerState = _players[id]
		if p.hp <= 0:
			continue
		var dx: float = p.x - x
		var dy: float = p.y - y
		if dx * dx + dy * dy <= r2:
			n += 1
	return n


func _reset_wilds_encounter(e: EnemyState) -> void:
	if _dungeon != null or e == null or e.def == null:
		return
	_apply_n_peak(e, 1)
	e.hp = e.scaled_max_hp


func _reset_boss_fight_trackers() -> void:
	_boss_fight_ticks = 0
	_boss_fight_sampled_tick = -1
	_boss_damage_by.clear()
	_boss_near_ticks.clear()
	_boss_ally_heals.clear()


func _boss_fight_active() -> bool:
	if _boss_defeated:
		return false
	for e in _enemies:
		if e.is_boss() and e.seal_tick >= 0:
			return true
	return false


func _living_boss() -> EnemyState:
	for e in _enemies:
		if e.is_boss() and e.alive:
			return e
	return null


func _begin_boss_fight(_e: EnemyState, sim_tick: int) -> void:
	# The physical seal only exists in a dungeon boss arena (vision §6.1 rule 6a).
	if not _arena_room().is_empty():
		_set_arena_sealed(true)
	_sample_boss_fight_tick(sim_tick)


func _maybe_lift_empty_arena(sim_tick: int) -> void:
	# The seal lifts when no living player is left in the arena; the boss then
	# resets (vision §6.1 rule 6a). Full restore details also live on #61.
	if not _arena_sealed or _boss_defeated or _dungeon == null:
		return
	if _arena_room().is_empty():
		return
	if _count_living_in_arena() > 0:
		return
	_set_arena_sealed(false)
	_reset_abandoned_boss_fight(sim_tick)


func _reset_abandoned_boss_fight(sim_tick: int) -> void:
	_boss_n_peak = 0
	_reset_boss_fight_trackers()
	_boss_untouched_until = sim_tick + BOSS_RESET_UNTOUCHED_TICKS
	_pattern_bullets.clear()
	_hazards.clear()
	for e in _enemies:
		if e.is_boss():
			_cancel_jobs_from(e.id)
			e.seal_tick = -1
			e.damaged_by.clear()
			e.rewards_granted = false
			e.alive = true
			_apply_n_peak(e, 1)
			e.hp = e.scaled_max_hp
			if e.def != null and e.def.phases.size() > 0:
				_enter_boss_phase(e, 0)
			e.invulnerable = true
		elif e.summoned:
			e.drops_loot = false
			e.invulnerable = false
			e.alive = false
			e.hp = 0
			e.flash_ticks = 0
			_cancel_jobs_from(e.id)


func _tick_boss_untouched(sim_tick: int) -> void:
	if _boss_untouched_until < 0:
		return
	if sim_tick < _boss_untouched_until:
		var boss: EnemyState = _living_boss()
		if boss != null:
			boss.invulnerable = true
		return
	_boss_untouched_until = -1
	var boss: EnemyState = _living_boss()
	if boss == null:
		return
	var phase: Dictionary = boss.current_phase()
	if bool(phase.get("invulnerable", false)):
		return
	boss.invulnerable = false


func _sample_boss_fight_tick(sim_tick: int) -> void:
	if _boss_defeated or not _boss_fight_active():
		return
	if _boss_fight_sampled_tick == sim_tick:
		return
	_boss_fight_sampled_tick = sim_tick
	_boss_fight_ticks += 1
	var boss: EnemyState = _living_boss()
	if boss == null:
		return
	var r2: float = BOSS_PROXIMITY_TILES * BOSS_PROXIMITY_TILES
	for id in _sorted_ids:
		var p: SimPlayerState = _players[id]
		if p.hp <= 0:
			continue
		var dx: float = p.x - boss.x
		var dy: float = p.y - boss.y
		if dx * dx + dy * dy <= r2:
			_boss_near_ticks[id] = int(_boss_near_ticks.get(id, 0)) + 1


func _is_boss_eligible(e: EnemyState, player_id: int, sim_tick: int) -> bool:
	var contributed: bool = false
	var dmg: int = int(_boss_damage_by.get(player_id, 0))
	# (a) dealt at least 2% of the boss's max HP at kill time.
	if e.max_hp() > 0 and dmg * 100 >= e.max_hp() * 2:
		contributed = true
	# (b) used an ability that affected an ally at least twice during the fight.
	if int(_boss_ally_heals.get(player_id, 0)) >= 2:
		contributed = true
	# (c) were within 12 tiles of the boss for at least half the fight's ticks.
	var near: int = int(_boss_near_ticks.get(player_id, 0))
	if _boss_fight_ticks > 0 and near * 2 >= _boss_fight_ticks:
		contributed = true
	if not contributed:
		return false
	var p: SimPlayerState = _players.get(player_id, null) as SimPlayerState
	if p == null or p.hp <= 0:
		return false
	# Inclusive window: last_activity_tick >= kill_tick - 600.
	return p.last_activity_tick >= sim_tick - ACTIVITY_WINDOW_TICKS


## Seed the rule 7 activity stamp on sim join or instance entry. The stamp
## itself is never unset. The aim reference is the player's current aim, and
## the accumulated path starts at 0. A cancelled leave does not seed, so
## fight bookkeeping for that id is left in place.
func _seed_activity(p: SimPlayerState) -> void:
	if p == null:
		return
	p.last_activity_tick = _tick
	p.activity_aim_ref = p.aim
	p.activity_path = 0.0
	p.activity_fire_held = false
	# Fresh entry starts with no prior fight contribution for this id.
	_boss_damage_by.erase(p.id)
	_boss_near_ticks.erase(p.id)
	_boss_ally_heals.erase(p.id)


func _stamp_activity(p: SimPlayerState, sim_tick: int) -> void:
	p.last_activity_tick = sim_tick
	p.activity_aim_ref = p.aim
	p.activity_path = 0.0


## Smallest aim delta in degrees, with wrap-around: min(|a-b|, 360-|a-b|).
func _aim_delta_degrees(from_rad: float, to_rad: float) -> float:
	return absf(rad_to_deg(angle_difference(from_rad, to_rad)))


## Stamp last_activity_tick when this tick has a qualifying event. Held fire,
## a wall push, interact, a sub-10° aim change, and a refused ability do not.
func _note_activity(p: SimPlayerState, accepted_ability: bool, sim_tick: int) -> void:
	var fire_edge: bool = (not p.activity_fire_held) and p.intent.fire_held
	p.activity_fire_held = p.intent.fire_held
	# Dead characters do not stamp, including aim, fire edges, movement, and
	# abilities. fire_held is still tracked so a hold across death does not
	# become a rising edge later.
	if p.hp <= 0:
		return
	var dx: float = p.x - p.prev_x
	var dy: float = p.y - p.prev_y
	p.activity_path += sqrt(dx * dx + dy * dy)
	if accepted_ability or fire_edge or p.activity_path >= 1.0:
		_stamp_activity(p, sim_tick)
		return
	# 1e-6 degrees covers float error on an exact 10° wrap, such as 359° to 9°.
	if _aim_delta_degrees(p.activity_aim_ref, p.aim) >= ACTIVITY_AIM_DEG - 1e-6:
		_stamp_activity(p, sim_tick)


func _pattern_id_for_fire(e: EnemyState) -> String:
	if e.def == null:
		return ""
	if e.def.alt_pattern_id != "" and e.def.alt_every_cycles > 0:
		if (e.fire_cycle + 1) % e.def.alt_every_cycles == 0:
			return e.def.alt_pattern_id
	return e.def.pattern_id


func _tick_sidestep(e: EnemyState, _sim_tick: int) -> void:
	if e.def == null or e.def.sidestep_tiles <= 0.0 or e.def.sidestep_interval_ticks <= 0:
		return
	if not e.aggro:
		return
	if e.sidestep_left > 0:
		e.x += e.sidestep_dx
		e.y += e.sidestep_dy
		e.sidestep_left -= 1
		return
	if e.sidestep_cooldown > 0:
		e.sidestep_cooldown -= 1
	if e.sidestep_cooldown > 0:
		return
	var dur: int = maxi(e.def.sidestep_duration_ticks, 1)
	var px: float = -sin(e.aim)
	var py: float = cos(e.aim)
	if (e.fire_cycle % 2) == 1:
		px = -px
		py = -py
	var plen: float = sqrt(px * px + py * py)
	if plen <= READY_EPS:
		px = 1.0
		py = 0.0
		plen = 1.0
	px /= plen
	py /= plen
	e.sidestep_dx = px * e.def.sidestep_tiles / float(dur)
	e.sidestep_dy = py * e.def.sidestep_tiles / float(dur)
	e.sidestep_left = dur
	e.sidestep_cooldown = e.def.sidestep_interval_ticks
	e.x += e.sidestep_dx
	e.y += e.sidestep_dy
	e.sidestep_left -= 1


func _player_stride_mult(p: SimPlayerState) -> float:
	var slow: float = 0.0
	for h in _hazards:
		if h.is_active(_tick) and h.contains(p.x, p.y) and h.slow_pct > slow:
			slow = h.slow_pct
	if slow <= 0.0:
		return 1.0
	return maxf(0.0, 1.0 - slow / 100.0)


func _hurt_enemy(e: EnemyState, amount: int, attacker_id: int, sim_tick: int) -> void:
	if e == null or not e.alive or amount <= 0:
		return
	if e.invulnerable:
		return
	if e.is_boss() and e.seal_tick < 0:
		e.seal_tick = sim_tick
		_begin_boss_fight(e, sim_tick)
	var dealt: int = mini(amount, e.hp)
	e.hp -= amount
	if attacker_id != 0:
		e.damaged_by[attacker_id] = true
		if e.is_boss() and dealt > 0:
			var acc: int = int(_boss_damage_by.get(attacker_id, 0))
			_boss_damage_by[attacker_id] = acc + dealt
	e.flash_ticks = _config.player_flash_ticks
	if dealt > 0:
		_record_hit(HitEvent.KIND_DEALT, e.id, e.x, e.y, dealt)
	if e.hp <= 0:
		_kill_enemy(e, sim_tick)
		return
	_maybe_boss_transition(e)


func _kill_enemy(e: EnemyState, sim_tick: int) -> void:
	if e == null:
		return
	if not e.alive and e.rewards_granted:
		return
	e.hp = 0
	e.alive = false
	e.invulnerable = false
	if e.flash_ticks <= 0:
		e.flash_ticks = _config.player_flash_ticks
	if e.is_boss() and not _boss_defeated:
		_on_boss_defeated(e, sim_tick)
	_grant_kill_rewards(e, sim_tick)
	if e.is_boss():
		_reset_boss_fight_trackers()


func _on_boss_defeated(e: EnemyState, sim_tick: int) -> void:
	_boss_defeated = true
	_boss_n_peak = 0
	_set_arena_sealed(false)
	_boss_untouched_until = -1
	_pattern_bullets.clear()
	_hazards.clear()
	_cancel_jobs_from(e.id)
	# Living Waxen Acolytes die on the same tick, with no loot or XP, and
	# play the normal death flash (content-v0.1, Design).
	for other in _enemies:
		if other.alive and other.summoned:
			other.invulnerable = false
			other.drops_loot = false
			_kill_enemy(other, sim_tick)


func _maybe_boss_transition(e: EnemyState) -> void:
	if not e.is_boss() or e.def == null:
		return
	var phase: Dictionary = e.current_phase()
	if phase.is_empty() or bool(phase.get("transition", false)):
		return
	if not phase.has("hp_above"):
		return
	var threshold: int = _scaling.hp_threshold(e.max_hp(), float(phase["hp_above"]))
	if e.hp > threshold:
		return
	if e.phase_index + 1 >= e.def.phases.size():
		return
	_enter_boss_phase(e, e.phase_index + 1)


func _enter_boss_phase(e: EnemyState, index: int) -> void:
	_cancel_jobs_from(e.id)
	e.phase_index = index
	e.phase_age = 0
	e.loop_once_fired.clear()
	var phase: Dictionary = e.current_phase()
	e.invulnerable = bool(phase.get("invulnerable", false))
	_run_phase_enter(e, phase)
	# A hit can cross more than one threshold: after a transition ends (or a
	# combat phase is entered), latch immediately if HP is already at or below
	# the new phase's threshold (content-v0.1 §3.4).
	if not bool(phase.get("transition", false)):
		_maybe_boss_transition(e)


func _run_phase_enter(e: EnemyState, phase: Dictionary) -> void:
	var actions: Variant = phase.get("on_enter", [])
	if not (actions is Array):
		return
	for action in actions:
		if not (action is Dictionary):
			continue
		var summon_id: String = String(action.get("summon", ""))
		if summon_id == "":
			continue
		var at: String = String(action.get("at", ""))
		var count: int = int(action.get("count", 0))
		var loot: bool = bool(action.get("loot", true))
		if at == "corners":
			_summon_at_corners(e, summon_id, count, loot)


func _summon_at_corners(boss: EnemyState, enemy_id: String, count: int, loot: bool) -> void:
	var room: Dictionary = _room_containing(boss.x, boss.y)
	if room.is_empty():
		return
	var origin: Variant = room.get("origin", [0.0, 0.0])
	var size: Variant = room.get("size", [0.0, 0.0])
	if not (origin is Array) or not (size is Array) or origin.size() < 2 or size.size() < 2:
		return
	var ox: float = float(origin[0])
	var oy: float = float(origin[1])
	var sx: float = float(size[0])
	var sy: float = float(size[1])
	var inset: float = 1.5
	var corners: Array[Vector2] = [
		Vector2(ox + inset, oy + inset),
		Vector2(ox + sx - inset, oy + inset),
		Vector2(ox + inset, oy + sy - inset),
		Vector2(ox + sx - inset, oy + sy - inset),
	]
	var n: int = mini(count, corners.size())
	for i in range(n):
		var sid: int = spawn_enemy(enemy_id, corners[i].x, corners[i].y, boss.content_level)
		var add: EnemyState = _enemy_by_id(sid)
		if add == null:
			continue
		add.drops_loot = loot
		add.summoned = true
		add.room_id = boss.room_id
		_apply_n_peak(add, maxi(_boss_n_peak, 1))
		add.hp = add.scaled_max_hp


func _step_boss(e: EnemyState, sim_tick: int) -> void:
	if e.contact_cooldown > 0:
		e.contact_cooldown -= 1
	var phase: Dictionary = e.current_phase()
	if phase.is_empty():
		return
	if e.phase_age == 0 and e.phase_index == 0 and not bool(phase.get("transition", false)):
		# First tick of P1: no special on_enter, but loops fire at age 0.
		pass
	_move_boss(e, phase)
	_tick_boss_loops(e, phase, sim_tick)
	if bool(phase.get("transition", false)):
		var hold: int = int(phase.get("ticks", 0))
		e.phase_age += 1
		if e.phase_age >= hold and e.phase_index + 1 < e.def.phases.size():
			_enter_boss_phase(e, e.phase_index + 1)
		return
	e.phase_age += 1


func _move_boss(e: EnemyState, phase: Dictionary) -> void:
	var speed: float = float(phase.get("move_speed", e.def.move_speed if e.def != null else 0.0))
	var move: String = String(phase.get("move", ""))
	if bool(phase.get("transition", false)) and String(phase.get("move_to", "")) == "center":
		move = "anchor_center"
		if speed <= 0.0 and e.def != null:
			speed = e.def.move_speed
	var center := _arena_center(e)
	var dx: float = center.x - e.x
	var dy: float = center.y - e.y
	var dist: float = sqrt(dx * dx + dy * dy)
	var mx: float = 0.0
	var my: float = 0.0
	if move == "anchor_center":
		if dist > SimConstants.MOVE_EPS and speed > 0.0:
			mx = dx / dist
			my = dy / dist
		elif dist <= SimConstants.MOVE_EPS:
			e.x = center.x
			e.y = center.y
			speed = 0.0
	elif move == "drift_center":
		if dist > 2.0 and dist > SimConstants.MOVE_EPS:
			mx = dx / dist
			my = dy / dist
		elif dist > SimConstants.MOVE_EPS:
			mx = -dy / dist
			my = dx / dist
	if speed > 0.0 and (mx != 0.0 or my != 0.0):
		var step: float = speed * SimConstants.TICK_DT
		e.x += mx * step
		e.y += my * step
	if dist > SimConstants.MOVE_EPS:
		e.aim = atan2(dy, dx)


func _tick_boss_loops(e: EnemyState, phase: Dictionary, sim_tick: int) -> void:
	var loops: Variant = phase.get("loops", [])
	if not (loops is Array):
		return
	var loop_len: int = int(phase.get("loop_ticks", 0))
	var clock: int = e.phase_age
	if loop_len > 0:
		clock = e.phase_age % loop_len
		if clock == 0 and e.phase_age > 0:
			e.loop_once_fired.clear()
	for loop in loops:
		if not (loop is Dictionary):
			continue
		if not _loop_is_due(e, loop, clock, phase, sim_tick):
			continue
		var pid: String = String(loop.get("pattern", ""))
		if pid == "" or _catalog == null:
			continue
		var def: PatternDef = _catalog.pattern(pid)
		if def == null:
			continue
		var key: String = pid
		if bool(loop.get("once_per_loop", false)) or bool(loop.get("at_loop_start", false)):
			if e.loop_once_fired.has(key):
				continue
			e.loop_once_fired[key] = true
		if def.type == "spiral" or def.type == "burst":
			if _has_live_job(e.id, def.id):
				continue
		var aim: float = _boss_aim(e, def, sim_tick)
		_fire_pattern(e, def, sim_tick, aim, e.volley_index)
		e.volley_index += 1


func _loop_is_due(e: EnemyState, loop: Dictionary, clock: int, phase: Dictionary, sim_tick: int) -> bool:
	if bool(loop.get("at_loop_start", false)):
		return clock == 0
	var window_start: int = int(loop.get("window_start_ticks", 0)) if loop.has("window_start_ticks") else 0
	var has_end: bool = loop.has("window_end_ticks")
	var window_end: int = int(loop.get("window_end_ticks", 0))
	if loop.has("window_start_ticks") or has_end:
		if clock < window_start:
			return false
		if has_end and clock >= window_end:
			return false
		if bool(loop.get("once_per_loop", false)):
			return clock == window_start
	var every: int = int(loop.get("every_ticks", 0))
	if every <= 0 and _catalog != null:
		var def: PatternDef = _catalog.pattern(String(loop.get("pattern", "")))
		if def != null:
			if def.emit_interval_ticks > 0:
				every = def.emit_interval_ticks
			elif def.interval_ticks > 0:
				every = def.interval_ticks
	if every <= 0:
		# Windowed one-shot (burst) already handled above; nothing periodic.
		return bool(loop.get("once_per_loop", false)) and clock == window_start
	every = _boss_scaled_interval(e, phase, every, sim_tick)
	var offset: int = int(loop.get("offset_ticks", 0))
	if clock < offset:
		return false
	return (clock - offset) % every == 0


func _boss_scaled_interval(e: EnemyState, phase: Dictionary, every: int, sim_tick: int) -> int:
	var raw: Variant = phase.get("enrage", null)
	if not (raw is Dictionary):
		return every
	var enrage: Dictionary = raw
	var after: int = int(enrage.get("after_ticks", 0))
	var mult: float = float(enrage.get("interval_mult", 1.0))
	if e.seal_tick < 0 or after <= 0 or (sim_tick - e.seal_tick) < after:
		return every
	return maxi(1, SimScaling.round_half_up(float(every) * mult))


func _boss_aim(e: EnemyState, def: PatternDef, sim_tick: int) -> float:
	if def != null and def.aim == "fixed":
		return e.aim
	var tid: int = _pick_boss_aim_target(e, sim_tick)
	if tid == 0:
		return e.aim
	var p: SimPlayerState = _players.get(tid, null) as SimPlayerState
	if p == null:
		return e.aim
	var dx: float = p.x - e.x
	var dy: float = p.y - e.y
	if dx * dx + dy * dy <= SimConstants.MOVE_EPS * SimConstants.MOVE_EPS:
		return e.aim
	e.aim = atan2(dy, dx)
	return e.aim


func _pick_boss_aim_target(e: EnemyState, sim_tick: int) -> int:
	var ids: Array[int] = _living_players_in_arena(e)
	if ids.is_empty():
		return 0
	if ids.size() == 1:
		e.last_aim_target_id = ids[0]
		e.same_target_streak = 1
		return ids[0]
	var candidates: Array[int] = []
	for id in ids:
		if e.same_target_streak >= 2 and id == e.last_aim_target_id:
			continue
		candidates.append(id)
	if candidates.is_empty():
		candidates = ids
	var rng := PCG32.new(_domain_seed(e.id, sim_tick, BOSS_AIM_SEED_DOMAIN), 1)
	var pick: int = candidates[int(rng.uint32() % (candidates.size() as int))]
	if pick == e.last_aim_target_id:
		e.same_target_streak += 1
	else:
		e.last_aim_target_id = pick
		e.same_target_streak = 1
	return pick


func _living_players_in_arena(e: EnemyState) -> Array[int]:
	var room: Dictionary = _room_containing(e.x, e.y)
	var out: Array[int] = []
	for id in _sorted_ids:
		var p: SimPlayerState = _players[id]
		if p.hp <= 0:
			continue
		if room.is_empty() or (_dungeon != null and _dungeon.room_contains(room, p.x, p.y)):
			out.append(id)
	return out


func _room_containing(x: float, y: float) -> Dictionary:
	if _dungeon == null:
		return {}
	for room in _dungeon.rooms:
		if _dungeon.room_contains(room, x, y):
			return room
	return {}


func _arena_center(e: EnemyState) -> Vector2:
	var room: Dictionary = _room_containing(e.x, e.y)
	if room.is_empty():
		return Vector2(e.home_x, e.home_y)
	var origin: Variant = room.get("origin", [e.home_x, e.home_y])
	var size: Variant = room.get("size", [0.0, 0.0])
	if not (origin is Array) or not (size is Array) or origin.size() < 2 or size.size() < 2:
		return Vector2(e.home_x, e.home_y)
	return Vector2(float(origin[0]) + float(size[0]) * 0.5, float(origin[1]) + float(size[1]) * 0.5)


func _fire_pattern(e: EnemyState, def: PatternDef, sim_tick: int, aim: float, volley: int) -> void:
	if def == null:
		return
	if def.type == "hazard":
		_spawn_hazards(e, def, sim_tick)
		return
	if def.type == "burst":
		_start_burst_job(e, def, sim_tick, aim)
		return
	if def.type == "spiral":
		_start_spiral_job(e, def, sim_tick, aim, volley)
		return
	_emit_pattern_now(e, def, sim_tick, aim, volley)


func _emit_pattern_now(e: EnemyState, def: PatternDef, sim_tick: int, aim: float, volley: int) -> void:
	var seed: int = _mix_seed(_world_seed, e.id, sim_tick + volley)
	var bullets := def.emit(seed, e.x, e.y, aim, volley)
	for b in bullets:
		b.id = _alloc_id()
		b.spawn_tick = sim_tick
		b.source_id = e.id
		_pattern_bullets.append(b)


func _start_burst_job(e: EnemyState, def: PatternDef, sim_tick: int, aim: float) -> void:
	var job := PatternJob.new()
	job.source_id = e.id
	job.def = def
	job.start_tick = sim_tick
	job.next_emit_tick = sim_tick
	job.emit_index = 0
	job.repeats_left = def.repeats if def.repeats > 0 else 1
	job.reaim = def.reaim
	job.aim = aim
	job.interval = def.interval_ticks if def.interval_ticks > 0 else 1
	job.live = true
	_pattern_jobs.append(job)
	_emit_job(job, e, sim_tick)


func _start_spiral_job(e: EnemyState, def: PatternDef, sim_tick: int, aim: float, _volley: int) -> void:
	# A spiral already in flight for this source is left running
	# (phase changes cancel jobs first).
	var job := PatternJob.new()
	job.source_id = e.id
	job.def = def
	job.start_tick = sim_tick
	job.next_emit_tick = sim_tick
	job.emit_index = 0
	job.repeats_left = -1
	job.reaim = def.aim != "fixed"
	job.aim = aim
	job.interval = def.emit_interval_ticks if def.emit_interval_ticks > 0 else 1
	if def.duration_ticks > 0:
		job.end_tick = sim_tick + def.duration_ticks
	job.live = true
	_pattern_jobs.append(job)
	_emit_job(job, e, sim_tick)


func _tick_pattern_jobs(sim_tick: int) -> void:
	for job in _pattern_jobs:
		if not job.live:
			continue
		if job.end_tick >= 0 and sim_tick >= job.end_tick:
			job.live = false
			continue
		if sim_tick < job.next_emit_tick:
			continue
		var src: EnemyState = _enemy_by_id(job.source_id)
		if src == null or not src.alive:
			job.live = false
			continue
		_emit_job(job, src, sim_tick)


func _emit_job(job: PatternJob, e: EnemyState, sim_tick: int) -> void:
	var aim: float = job.aim
	if job.reaim:
		aim = _boss_aim(e, job.def, sim_tick) if e.is_boss() else e.aim
		job.aim = aim
	if job.def.type == "burst":
		# Parent emit applies per-repeat angle offset to the child volley.
		var seed: int = _mix_seed(_world_seed, e.id, sim_tick + job.emit_index)
		var bullets := job.def.emit(seed, e.x, e.y, aim, job.emit_index)
		for b in bullets:
			b.id = _alloc_id()
			b.spawn_tick = sim_tick
			b.source_id = e.id
			_pattern_bullets.append(b)
	else:
		_emit_pattern_now(e, job.def, sim_tick, aim, job.emit_index)
	job.emit_index += 1
	if job.repeats_left > 0:
		job.repeats_left -= 1
		if job.repeats_left <= 0:
			job.live = false
			return
	job.next_emit_tick = sim_tick + job.interval


func _has_live_job(source_id: int, pattern_id: String) -> bool:
	for job in _pattern_jobs:
		if job.live and job.source_id == source_id and job.def != null and job.def.id == pattern_id:
			return true
	return false


func _cancel_jobs_from(source_id: int) -> void:
	for job in _pattern_jobs:
		if job.source_id == source_id:
			job.live = false


func _cull_pattern_jobs() -> void:
	var write: int = 0
	for job in _pattern_jobs:
		if job.live:
			_pattern_jobs[write] = job
			write += 1
	_pattern_jobs.resize(write)


func _spawn_hazards(e: EnemyState, def: PatternDef, sim_tick: int) -> void:
	var ids: Array[int] = _living_players_in_arena(e)
	if ids.is_empty():
		return
	var cap: int = def.max_targets if def.max_targets > 0 else ids.size()
	var rng := PCG32.new(_domain_seed(e.id, sim_tick, BOSS_POOL_SEED_DOMAIN), 1)
	var picked: Array[int] = []
	var pool: Array[int] = ids.duplicate()
	while picked.size() < cap and not pool.is_empty():
		var i: int = int(rng.uint32() % (pool.size() as int))
		picked.append(pool[i])
		pool.remove_at(i)
	for pid in picked:
		var p: SimPlayerState = _players.get(pid, null) as SimPlayerState
		if p == null:
			continue
		var h := HazardState.new()
		h.id = _alloc_id()
		h.x = p.x
		h.y = p.y
		h.radius = def.radius
		h.telegraph_ticks = def.telegraph_ticks
		h.duration_ticks = def.duration_ticks
		h.tick_interval_ticks = def.tick_interval_ticks if def.tick_interval_ticks > 0 else 1
		h.slow_pct = def.slow_pct
		h.damage_key = def.damage_key
		h.source_id = e.id
		h.spawn_tick = sim_tick
		_hazards.append(h)


func _tick_hazards(sim_tick: int) -> void:
	for h in _hazards:
		if not h.should_damage(sim_tick):
			continue
		var src: EnemyState = _enemy_by_id(h.source_id)
		var amount: int = 0
		var attacker_level: int = 1
		if src != null and src.def != null:
			amount = src.def.damage_for(h.damage_key)
			attacker_level = src.content_level
		for id in _sorted_ids:
			var p: SimPlayerState = _players[id]
			if p.hp <= 0:
				continue
			if h.contains(p.x, p.y):
				_hurt_player(p, amount, attacker_level)


func _cull_hazards(sim_tick: int) -> void:
	var write: int = 0
	for h in _hazards:
		if not h.expired(sim_tick):
			_hazards[write] = h
			write += 1
	_hazards.resize(write)


func _dungeon_has_boss() -> bool:
	if _dungeon == null or _catalog == null:
		return false
	for room in _dungeon.rooms:
		var spawns: Variant = room.get("spawns", [])
		if not (spawns is Array):
			continue
		for spawn in spawns:
			if not (spawn is Dictionary):
				continue
			var def: EnemyDef = _catalog.enemy(String(spawn.get("enemy_id", "")))
			if def != null and def.is_boss():
				return true
	return false
