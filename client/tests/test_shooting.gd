extends GutTest
## Fire-on-press timing from content-v0.1.md §1 (float64 next_ready, not an
## integer-tick cooldown). Class Tempo values are from vision §2.


func _cfg(tempo: float) -> SimConfig:
	var cfg := SimConfig.new()
	cfg.move_speed_tiles_per_s = 0.0
	cfg.fire_rate_shots_per_s = tempo
	cfg.tempo_bonus = 0.0
	cfg.projectile_speed_tiles_per_s = 14.0
	cfg.projectile_range_tiles = 7.0
	cfg.projectile_lifetime_ticks_override = 0
	return cfg


## Thornguard: Tempo 2.0, cd = 0.5 s.
func _thornguard() -> SimConfig:
	return _cfg(2.0)


## Driftrunner: Tempo 3.5, cd = 1/3.5 s ≈ 0.2857 s.
func _driftrunner() -> SimConfig:
	return _cfg(3.5)


func _hold_fire(sim: LocalSim, ticks: int, aim: float = 0.0) -> void:
	for i in range(ticks):
		sim.submit_input(InputIntent.from_raw(i + 1, 0.0, 0.0, aim, true))
		sim.step()


func _spawn_ticks(sim: LocalSim) -> Array:
	var ticks: Array = []
	for shot in sim.snapshot().projectiles:
		ticks.append(shot.spawn_tick)
	return ticks


func test_lifetime_ticks_matches_range_over_speed() -> void:
	# ceil(7 / 14 * 20) = 10 (Gleamwright Lumen Rod range/speed).
	assert_eq(_cfg(2.5).projectile_lifetime_ticks(), 10)


func test_fire_cooldown_seconds_match_class_tempo() -> void:
	assert_almost_eq(_thornguard().fire_cooldown_s(), 0.5, 1e-12)
	assert_almost_eq(_driftrunner().fire_cooldown_s(), 1.0 / 3.5, 1e-12)
	assert_almost_eq(_cfg(2.5).fire_cooldown_s(), 0.4, 1e-12)


func test_first_shot_fires_on_the_press_tick() -> void:
	var sim := LocalSim.new(_thornguard(), 0.0, 0.0)
	sim.submit_input(InputIntent.from_raw(1, 0.0, 0.0, 0.0, true))
	sim.step()
	assert_eq(sim.tick(), 1)
	assert_eq(sim.projectile_count(), 1)
	assert_eq(sim.snapshot().projectiles[0].spawn_tick, 0)
	assert_almost_eq(sim.next_ready(), 0.5, 1e-12)


func test_thornguard_hold_from_tick_zero() -> void:
	# content-v0.1 golden: Thornguard (2.0/s) fires on ticks 0, 10, 20 ….
	var cfg := _thornguard()
	cfg.projectile_range_tiles = 100.0
	cfg.projectile_lifetime_ticks_override = 100
	var sim := LocalSim.new(cfg, 0.0, 0.0)
	_hold_fire(sim, 21)
	assert_eq(sim.projectile_count(), 3)
	assert_eq(_spawn_ticks(sim), [0, 10, 20])


func test_driftrunner_hold_from_tick_zero() -> void:
	# content-v0.1 golden: Driftrunner (3.5/s) fires on 0, 6, 12, 18, 23, 29.
	# Scheduling from the previous ready time (not the landing tick) is what
	# produces tick 23 instead of 24.
	var cfg := _driftrunner()
	cfg.projectile_range_tiles = 100.0
	cfg.projectile_lifetime_ticks_override = 100
	var sim := LocalSim.new(cfg, 0.0, 0.0)
	_hold_fire(sim, 30)
	assert_eq(sim.projectile_count(), 6)
	assert_eq(_spawn_ticks(sim), [0, 6, 12, 18, 23, 29])


func test_thornguard_repress_mid_cooldown_waits_until_ten() -> void:
	# Press tick 0, release tick 1, press again tick 3 → volleys at 0 and 10.
	var cfg := _thornguard()
	cfg.projectile_range_tiles = 100.0
	cfg.projectile_lifetime_ticks_override = 100
	var sim := LocalSim.new(cfg, 0.0, 0.0)
	sim.submit_input(InputIntent.from_raw(1, 0.0, 0.0, 0.0, true))
	sim.step()
	assert_eq(_spawn_ticks(sim), [0])
	# Release on tick 1, remain released on tick 2, re-press from tick 3.
	sim.submit_input(InputIntent.from_raw(2, 0.0, 0.0, 0.0, false))
	sim.step()
	sim.submit_input(InputIntent.from_raw(3, 0.0, 0.0, 0.0, false))
	sim.step()
	for i in range(7):
		sim.submit_input(InputIntent.from_raw(4 + i, 0.0, 0.0, 0.0, true))
		sim.step()
	assert_eq(sim.tick(), 10)
	assert_eq(_spawn_ticks(sim), [0], "still on cooldown at tick 9")
	sim.submit_input(InputIntent.from_raw(11, 0.0, 0.0, 0.0, true))
	sim.step()
	assert_eq(sim.tick(), 11)
	assert_eq(_spawn_ticks(sim), [0, 10])


func test_fast_tapping_never_exceeds_the_hold_rate() -> void:
	# Tapping every other tick fires no faster than holding (0, 10).
	var cfg := _thornguard()
	cfg.projectile_range_tiles = 100.0
	cfg.projectile_lifetime_ticks_override = 100
	var sim := LocalSim.new(cfg, 0.0, 0.0)
	for i in range(SimConstants.TICK_HZ):
		var held := (i % 2) == 0
		sim.submit_input(InputIntent.from_raw(i + 1, 0.0, 0.0, 0.0, held))
		sim.step()
	assert_eq(sim.projectile_count(), 2)
	assert_eq(_spawn_ticks(sim), [0, 10])


func test_aim_zero_travels_positive_x() -> void:
	var sim := LocalSim.new(_thornguard(), 0.0, 0.0)
	_hold_fire(sim, 1, 0.0)
	assert_eq(sim.projectile_count(), 1)
	var shot: SimProjectile = sim.snapshot().projectiles[0]
	assert_almost_eq(shot.dir_x, 1.0, 1e-12)
	assert_almost_eq(shot.dir_y, 0.0, 1e-12)
	var pos := shot.position_at_time(float(shot.spawn_tick))
	assert_almost_eq(pos.x, 0.0, 1e-12)
	assert_almost_eq(pos.y, 0.0, 1e-12)
	pos = shot.position_at_time(float(shot.spawn_tick + 5))
	assert_almost_eq(pos.x, 14.0 * 5.0 * SimConstants.TICK_DT, 1e-12)
	assert_almost_eq(pos.y, 0.0, 1e-12)


func test_aim_half_pi_travels_positive_y() -> void:
	var sim := LocalSim.new(_thornguard(), 1.0, 2.0)
	_hold_fire(sim, 1, PI / 2.0)
	var shot: SimProjectile = sim.snapshot().projectiles[0]
	assert_almost_eq(shot.dir_x, 0.0, 1e-12)
	assert_almost_eq(shot.dir_y, 1.0, 1e-12)
	var pos := shot.position_at_time(float(shot.spawn_tick + 4))
	assert_almost_eq(pos.x, 1.0, 1e-12)
	assert_almost_eq(pos.y, 2.0 + 14.0 * 4.0 * SimConstants.TICK_DT, 1e-12)


func test_projectile_despawns_after_lifetime() -> void:
	var sim := LocalSim.new(_thornguard(), 0.0, 0.0)
	_hold_fire(sim, 1)
	assert_eq(sim.projectile_count(), 1)
	var spawn_tick := sim.snapshot().projectiles[0].spawn_tick
	assert_eq(spawn_tick, 0)
	# Lifetime 10: still alive while processing spawn + 9, gone at spawn + 10.
	for i in range(9):
		sim.submit_input(InputIntent.from_raw(20 + i, 0.0, 0.0, 0.0, false))
		sim.step()
	assert_eq(sim.tick(), 10)
	assert_eq(sim.projectile_count(), 1)
	sim.submit_input(InputIntent.from_raw(30, 0.0, 0.0, 0.0, false))
	sim.step()
	assert_eq(sim.tick(), 11)
	assert_eq(sim.projectile_count(), 0)


func test_projectile_despawns_at_range_before_lifetime() -> void:
	var cfg := _thornguard()
	cfg.projectile_speed_tiles_per_s = 20.0
	cfg.projectile_range_tiles = 2.0
	cfg.projectile_lifetime_ticks_override = 20
	# 20 tiles/s * 0.05 s = 1 tile/tick, so range 2 is hit at elapsed 2.
	var sim := LocalSim.new(cfg, 0.0, 0.0)
	_hold_fire(sim, 1)
	assert_eq(sim.projectile_count(), 1)
	sim.submit_input(InputIntent.from_raw(11, 0.0, 0.0, 0.0, false))
	sim.step()
	assert_eq(sim.projectile_count(), 1, "elapsed 1, distance 1 < 2")
	sim.submit_input(InputIntent.from_raw(12, 0.0, 0.0, 0.0, false))
	sim.step()
	assert_eq(sim.projectile_count(), 0, "elapsed 2, distance 2 is not below range")


## Gleamwright: Tempo 2.5, cd = 0.4 s.
func _gleamwright() -> SimConfig:
	return _cfg(2.5)


func test_gleamwright_cast_lock_has_no_catch_up() -> void:
	# content-v0.1 §1 / #19: a 5-tick Kindle Pulse lock on tick 14 breaks the
	# hold with no catch-up. After the block, the next volley is a fresh
	# press that still respects leftover cooldown: 0, 8, 19, 27, 35.
	var cfg := _gleamwright()
	cfg.projectile_range_tiles = 100.0
	cfg.projectile_lifetime_ticks_override = 100
	var sim := LocalSim.new(cfg, 0.0, 0.0)
	for i in range(36):
		# Lock occupies ticks 14–18 inclusive (0.25 s = 5 ticks).
		sim.set_fire_blocked(i >= 14 and i <= 18)
		sim.submit_input(InputIntent.from_raw(i + 1, 0.0, 0.0, 0.0, true))
		sim.step()
	assert_eq(_spawn_ticks(sim), [0, 8, 19, 27, 35])


func test_rate_change_mid_hold_applies_from_the_next_shot() -> void:
	# A pending next_ready is kept; the new cooldown is applied after the
	# next volley. Thornguard 2.0 fires on 0 then would fire on 10; changing
	# to 4.0/s (cd 0.25 s) on tick 5 still fires at 10, then 15, 20, 25.
	var cfg := _thornguard()
	cfg.projectile_range_tiles = 100.0
	cfg.projectile_lifetime_ticks_override = 100
	var sim := LocalSim.new(cfg, 0.0, 0.0)
	for i in range(26):
		if i == 5:
			sim.config().fire_rate_shots_per_s = 4.0
		sim.submit_input(InputIntent.from_raw(i + 1, 0.0, 0.0, 0.0, true))
		sim.step()
	assert_eq(_spawn_ticks(sim), [0, 10, 15, 20, 25])

