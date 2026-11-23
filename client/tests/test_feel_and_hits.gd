extends GutTest
## Packed feel, damage-number pool, touch-stick math, and LocalSim hit events.


func _pid(sim: LocalSim) -> int:
	var ids := sim.player_ids()
	assert_gt(ids.size(), 0)
	return ids[0]


func test_packed_feel_loads_without_code_defaults() -> void:
	assert_true(FileAccess.file_exists("res://data/feel.json"), "feel.json must be packed")
	var catalog := DataCatalog.load_default()
	assert_not_null(catalog.feel)
	assert_true(catalog.feel.is_valid(), "packed feel must contain every required field")
	assert_eq(catalog.feel.floater_pool_size, 96)
	assert_almost_eq(catalog.feel.touch_deadzone, 0.15, 1e-6)
	assert_almost_eq(catalog.feel.stick_thumb_mm, 14.0, 1e-6)
	assert_almost_eq(catalog.feel.hitstop_seconds, 0.04, 1e-6)
	assert_almost_eq(catalog.feel.floater_player_taken_color.r, 1.0, 1e-6)
	assert_almost_eq(catalog.feel.enemy_outline_px, 2.5, 1e-6)
	assert_almost_eq(catalog.feel.gamepad_aim_halflife_seconds, 0.06, 1e-6)


func test_missing_feel_field_is_invalid_and_logs() -> void:
	var f := FeelSettings.from_json({"hit_flash": {}})
	assert_false(f.is_valid())
	assert_push_error("FeelSettings: missing required group")


func test_stick_deadzone_and_clamp() -> void:
	var center := Vector2(100, 100)
	var radius: float = 50.0
	var inside := StickMath.clamped_offset(Vector2(110, 100), center, radius)
	assert_almost_eq(inside.x, 10.0, 1e-6)
	var far := StickMath.clamped_offset(Vector2(200, 100), center, radius)
	assert_almost_eq(far.length(), 50.0, 1e-6)
	var dead := StickMath.after_deadzone(Vector2(5, 0), radius, 0.15)
	assert_eq(dead, Vector2.ZERO)
	var live := StickMath.after_deadzone(Vector2(20, 0), radius, 0.15)
	assert_almost_eq(live.x, 0.4, 1e-6)
	assert_almost_eq(live.y, 0.0, 1e-6)


func test_stick_radius_is_physical_mm_at_dpi() -> void:
	# 14 mm at 160 DPI on a 1:1 viewport is 14/25.4*160 px.
	var px: float = StickMath.radius_viewport_px(14.0, 160.0, 1080.0, 1080.0)
	assert_almost_eq(px, 14.0 / 25.4 * 160.0, 0.01)
	# A 2x shrink (viewport half the screen) halves viewport pixels.
	var scaled: float = StickMath.radius_viewport_px(14.0, 160.0, 1080.0, 540.0)
	assert_almost_eq(scaled, px * 0.5, 0.01)
	assert_almost_eq(StickMath.radius_viewport_px(14.0, 0.0, 1080.0, 1080.0), 0.0, 0.0)


func test_gamepad_aim_smoothing_is_shortest_path() -> void:
	# Halfway through a 0.1s half-life is a 50% step.
	var mid: float = StickMath.smooth_angle(0.0, 1.0, 0.1, 0.1)
	assert_almost_eq(mid, 0.5, 1e-5)
	# Crossing the -PI/PI seam goes the short way (3 -> pi -> -3), not the long way down.
	var a: float = StickMath.smooth_angle(3.0, -3.0, 0.1, 0.1)
	assert_gt(a, 3.0)
	assert_almost_eq(a, PI, 0.05)
	var long_way: float = 3.0 - 0.5 * ((3.0 - (-3.0)))
	assert_ne(a, long_way)


func test_damage_number_pool_reuses_slots_and_caps() -> void:
	var pool := DamageNumberPool.new()
	pool.configure(4)
	assert_eq(pool.capacity(), 4)
	assert_eq(pool.active_count(), 0)
	for i in range(4):
		assert_gte(pool.spawn(i + 1, DamageNumberPool.KIND_DEALT, 0.0, 0.0, 0.0), 0)
	assert_eq(pool.active_count(), 4)
	# Over cap recycles the oldest instead of growing.
	var recycled: int = pool.spawn(99, DamageNumberPool.KIND_PLAYER_TAKEN, 5.0, 5.0, 0.0)
	assert_gte(recycled, 0)
	assert_eq(pool.active_count(), 4)
	assert_eq(pool.slot_at(recycled).amount, 99)
	assert_eq(pool.slot_at(recycled).kind, DamageNumberPool.KIND_PLAYER_TAKEN)
	pool.advance(0.8, 0.7, 28.0)
	assert_eq(pool.active_count(), 0, "expired numbers return to the pool")
	var again: int = pool.spawn(3, DamageNumberPool.KIND_HEAL, 0.0, 0.0, 10.0)
	assert_gte(again, 0)
	assert_eq(pool.active_count(), 1)


func test_local_sim_hit_list_is_per_tick_and_read_only() -> void:
	var catalog := DataCatalog.load_default()
	var cfg := SimConfig.new()
	cfg.player_projectile_damage = 10
	var sim := LocalSim.new(cfg, 8.0, 8.0, catalog)
	sim.set_world_seed(1)
	var pid: int = _pid(sim)
	sim.set_player_class_for(pid, "thornguard")
	assert_eq(sim.hits().size(), 0)

	var def := EnemyDef.new()
	def.aggro_radius = 0.0
	def.leash = 1.0
	def.move_speed = 0.0
	def.wander_speed = 0.0
	def.contact_damage = 8
	def.base_hp = 60
	def.radius = 0.35
	def.pattern_id = ""
	var eid: int = sim.spawn_enemy_from_def(def, 8.0, 8.0)
	sim.step()
	var hits: Array[HitEvent] = sim.hits()
	assert_gte(hits.size(), 1, "contact should publish a player-taken hit")
	var found_taken: bool = false
	for ev in hits:
		if ev.kind == HitEvent.KIND_PLAYER_TAKEN and ev.target_id == pid:
			found_taken = true
			assert_eq(ev.amount, 8)
			assert_eq(ev.tick, sim.tick())
	assert_true(found_taken)
	# Same array (read-only: do not mutate).
	assert_eq(hits, sim.hits())

	# Move the enemy away so the next step is clean, then land a player shot.
	var e: EnemyState = sim._enemies[0]
	e.x = 10.0
	e.y = 8.0
	e.prev_x = 10.0
	e.prev_y = 8.0
	# Wait out contact cooldown, then fire along +X at the enemy.
	for _i in range(cfg.contact_cooldown_ticks + 1):
		e.x = 10.0
		e.y = 8.0
		sim.step()
	assert_eq(sim.hits().size(), 0, "the list is the completed tick only")
	var p: SimPlayerState = sim.get_player(pid)
	p.x = 8.0
	p.y = 8.0
	p.prev_x = 8.0
	p.prev_y = 8.0
	var intent := InputIntent.from_raw(1, 0.0, 0.0, 0.0, true, false, 0, 0, false)
	sim.apply_input(pid, intent)
	var saw_dealt: bool = false
	for _j in range(20):
		sim.apply_input(pid, intent)
		sim.step()
		for ev in sim.hits():
			if ev.kind == HitEvent.KIND_DEALT and ev.target_id == eid:
				saw_dealt = true
				assert_eq(ev.amount, 10)
				assert_eq(ev.tick, sim.tick())
				break
		if saw_dealt:
			break
	assert_true(saw_dealt, "a player shot should publish a dealt hit")
	# Silence unused if spawn id is 0 (would fail earlier).
	assert_gt(eid, 0)
