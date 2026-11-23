extends GutTest
## Swept hits, Burrmite damage / death, and pattern shots hitting the player.


func _catalog() -> DataCatalog:
	return DataCatalog.load_default()


func _cfg() -> SimConfig:
	var cfg := SimConfig.new()
	cfg.move_speed_tiles_per_s = 0.0
	cfg.fire_rate_shots_per_s = 20.0
	cfg.projectile_speed_tiles_per_s = 14.0
	cfg.projectile_range_tiles = 20.0
	cfg.projectile_lifetime_ticks_override = 40
	cfg.player_projectile_damage = 10
	cfg.player_max_hp = 200
	cfg.player_flash_ticks = 4
	cfg.contact_cooldown_ticks = 10
	return cfg


func test_swept_hit_catches_tunneling() -> void:
	# A size-S bullet travelling 2 tiles in one tick through a 0.30-radius player.
	assert_true(SweepHit.moving_circles(0, 0, 2, 0, 0.15, 1, 0, 1, 0, 0.30))
	assert_false(SweepHit.moving_circles(0, 0, 2, 0, 0.15, 1, 3, 1, 3, 0.30))


func test_stationary_overlap_is_a_hit() -> void:
	assert_true(SweepHit.moving_circles(0, 0, 0, 0, 0.30, 0.2, 0, 0.2, 0, 0.30))


func test_player_shots_damage_and_despawn_burrmite() -> void:
	var def := _catalog().enemy("burrmite")
	assert_not_null(def)
	def.move_speed = 0.0
	def.wander_speed = 0.0
	def.pattern_id = ""
	def.contact_damage = 0
	def.aggro_radius = 20.0
	var sim := LocalSim.new(_cfg(), 0.0, 0.0, _catalog())
	var id := sim.spawn_enemy_from_def(def, 2.0, 0.0)
	assert_gt(id, 0)
	assert_eq(sim.enemy_count(), 1)
	# Six shots of 10 damage; fire-on-press at 20/s starts on tick 0.
	var death_tick: int = -1
	for i in range(20):
		sim.submit_input(InputIntent.from_raw(i + 1, 0.0, 0.0, 0.0, true))
		sim.step()
		if sim.enemy_count() == 0:
			death_tick = i
			break
	assert_eq(sim.enemy_count(), 0, "Burrmite should have despawned on death")
	# First shot (tick 0) reaches the Burrmite on tick 3; the sixth hits on tick 8.
	assert_eq(death_tick, 8)
	assert_eq(sim.tick(), 9)


func test_existing_movement_is_unchanged_without_an_enemy() -> void:
	var cfg := _cfg()
	cfg.move_speed_tiles_per_s = 4.5
	cfg.fire_rate_shots_per_s = 0.0
	var sim := LocalSim.new(cfg, 0.0, 0.0, _catalog())
	for i in range(SimConstants.TICK_HZ):
		sim.submit_input(InputIntent.from_raw(i + 1, 1.0, 0.0, 0.0, false))
		sim.step()
	assert_eq(sim.enemy_count(), 0)
	assert_almost_eq(sim.snapshot().player_x, 4.5, 1e-12)
	assert_eq(sim.snapshot().player_hp, 200)


func test_pattern_shot_damages_player_and_flashes() -> void:
	var cfg := _cfg()
	# Keep the Burrmite still so the aimed spit cannot miss.
	var def := _catalog().enemy("burrmite")
	assert_not_null(def)
	def.move_speed = 0.0
	def.wander_speed = 0.0
	def.contact_damage = 0
	def.aggro_radius = 20.0
	def.hover_radius = 20.0
	var sim := LocalSim.new(cfg, 0.0, 0.0, _catalog())
	sim.spawn_enemy_from_def(def, 3.0, 0.0)
	var start_hp := sim.snapshot().player_hp
	# First spit is 30 ticks after aggro (§2.3), not on the aggro tick.
	# Speed 6 tiles/s = 0.3 tiles/tick; radii 0.15 + 0.30, so the swept hit lands on tick 39.
	var saw_flash := false
	var hit_tick: int = -1
	for i in range(50):
		sim.submit_input(InputIntent.from_raw(i + 1, 0.0, 0.0, 0.0, false))
		sim.step()
		var snap := sim.snapshot()
		if snap.player_flash_ticks > 0:
			saw_flash = true
		if snap.player_hp < start_hp:
			hit_tick = i
			assert_eq(snap.player_hp, start_hp - 10)
			assert_gt(snap.player_flash_ticks, 0)
			assert_true(saw_flash)
			break
	assert_eq(hit_tick, 39, "burr_spit should first hit on tick 39")


func test_contact_damage_applies_with_cooldown() -> void:
	var def := _catalog().enemy("burrmite")
	assert_not_null(def)
	def.move_speed = 0.0
	def.wander_speed = 0.0
	def.pattern_id = ""
	def.contact_damage = 8
	def.aggro_radius = 20.0
	var sim := LocalSim.new(_cfg(), 0.0, 0.0, _catalog())
	# Overlap at the origin.
	sim.spawn_enemy_from_def(def, 0.2, 0.0)
	sim.submit_input(InputIntent.from_raw(1, 0.0, 0.0, 0.0, false))
	sim.step()
	var hp := sim.snapshot().player_hp
	assert_eq(hp, 192)
	# Next tick should not apply contact again (cooldown 10).
	sim.submit_input(InputIntent.from_raw(2, 0.0, 0.0, 0.0, false))
	sim.step()
	assert_eq(sim.snapshot().player_hp, 192)
	# After the cooldown, another tick of overlap should hit again.
	for i in range(9):
		sim.submit_input(InputIntent.from_raw(3 + i, 0.0, 0.0, 0.0, false))
		sim.step()
	assert_eq(sim.snapshot().player_hp, 184)



func test_burr_spit_fires_thirty_ticks_after_aggro() -> void:
	# content-v0.1 §2.3: first attack comes 1.5 s (30 ticks) after aggro, then every 30.
	var def := _catalog().enemy("burrmite")
	assert_not_null(def)
	def.move_speed = 0.0
	def.wander_speed = 0.0
	def.contact_damage = 0
	def.aggro_radius = 20.0
	def.hover_radius = 20.0
	var sim := LocalSim.new(_cfg(), 0.0, 0.0, _catalog())
	sim.set_world_seed(1)
	sim.spawn_enemy_from_def(def, 5.0, 0.0)
	var emits: Array[int] = []
	for i in range(91):
		sim.submit_input(InputIntent.from_raw(i + 1, 0.0, 0.0, 0.0, false))
		sim.step()
		for b in sim.snapshot().pattern_bullets:
			if b.spawn_tick not in emits:
				emits.append(b.spawn_tick)
	assert_eq(emits, [30, 60, 90])
