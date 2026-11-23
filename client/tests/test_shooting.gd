extends GutTest
## Per-weapon fire cooldown: instant first shot, steady cadence, no tap-burst.


func _cfg() -> SimConfig:
	var cfg := SimConfig.new()
	cfg.move_speed_tiles_per_s = 0.0
	cfg.fire_rate_shots_per_s = 2.0
	cfg.projectile_speed_tiles_per_s = 14.0
	cfg.projectile_range_tiles = 7.0
	cfg.projectile_lifetime_ticks_override = 0
	return cfg


func _hold_fire(sim: LocalSim, ticks: int, aim: float = 0.0) -> void:
	for i in range(ticks):
		sim.submit_input(InputIntent.from_raw(i + 1, 0.0, 0.0, aim, true))
		sim.step()


func test_lifetime_ticks_matches_range_over_speed() -> void:
	# ceil(7 / 14 * 20) = 10
	assert_eq(_cfg().projectile_lifetime_ticks(), 10)


func test_fire_interval_is_ten_ticks_at_two_per_second() -> void:
	assert_eq(_cfg().fire_interval_ticks(), 10)


func test_first_shot_fires_on_the_press_tick() -> void:
	var sim := LocalSim.new(_cfg(), 0.0, 0.0)
	sim.submit_input(InputIntent.from_raw(1, 0.0, 0.0, 0.0, true))
	sim.step()
	assert_eq(sim.tick(), 1)
	assert_eq(sim.projectile_count(), 1)
	assert_eq(sim.snapshot().projectiles[0].spawn_tick, 1)
	assert_eq(sim.fire_cooldown(), 10)


func test_held_fire_keeps_a_ten_tick_cadence() -> void:
	# Keep volleys alive so the count is not reduced by despawn.
	var cfg := _cfg()
	cfg.projectile_range_tiles = 100.0
	cfg.projectile_lifetime_ticks_override = 100
	var sim := LocalSim.new(cfg, 0.0, 0.0)
	_hold_fire(sim, 21)
	assert_eq(sim.projectile_count(), 3)
	var shots := sim.snapshot().projectiles
	assert_eq(shots[0].spawn_tick, 1)
	assert_eq(shots[1].spawn_tick, 11)
	assert_eq(shots[2].spawn_tick, 21)


func test_repress_mid_cooldown_does_not_fire_early() -> void:
	var cfg := _cfg()
	cfg.projectile_range_tiles = 100.0
	cfg.projectile_lifetime_ticks_override = 100
	var sim := LocalSim.new(cfg, 0.0, 0.0)
	# Tick 1: first shot. Release for a few ticks, then re-press before tick 11.
	sim.submit_input(InputIntent.from_raw(1, 0.0, 0.0, 0.0, true))
	sim.step()
	assert_eq(sim.projectile_count(), 1)
	for i in range(4):
		sim.submit_input(InputIntent.from_raw(2 + i, 0.0, 0.0, 0.0, false))
		sim.step()
	for i in range(5):
		sim.submit_input(InputIntent.from_raw(6 + i, 0.0, 0.0, 0.0, true))
		sim.step()
	assert_eq(sim.tick(), 10)
	assert_eq(sim.projectile_count(), 1, "still on cooldown")
	sim.submit_input(InputIntent.from_raw(11, 0.0, 0.0, 0.0, true))
	sim.step()
	assert_eq(sim.tick(), 11)
	assert_eq(sim.projectile_count(), 2)
	assert_eq(sim.snapshot().projectiles[1].spawn_tick, 11)


func test_fast_tapping_never_exceeds_the_fire_rate() -> void:
	var cfg := _cfg()
	cfg.projectile_range_tiles = 100.0
	cfg.projectile_lifetime_ticks_override = 100
	var sim := LocalSim.new(cfg, 0.0, 0.0)
	# Alternate press / release every tick for one second.
	for i in range(SimConstants.TICK_HZ):
		var held := (i % 2) == 0
		sim.submit_input(InputIntent.from_raw(i + 1, 0.0, 0.0, 0.0, held))
		sim.step()
	assert_eq(sim.projectile_count(), 2)
	var shots := sim.snapshot().projectiles
	assert_eq(shots[0].spawn_tick, 1)
	assert_eq(shots[1].spawn_tick, 11)


func test_aim_zero_travels_positive_x() -> void:
	var sim := LocalSim.new(_cfg(), 0.0, 0.0)
	_hold_fire(sim, 1, 0.0)
	assert_eq(sim.projectile_count(), 1)
	var shot: SimProjectile = sim.snapshot().projectiles[0]
	assert_almost_eq(shot.dir_x, 1.0, 1e-12)
	assert_almost_eq(shot.dir_y, 0.0, 1e-12)
	var pos := shot.position_at_time(float(sim.tick()))
	# Fired on tick 1, elapsed 0 on the fire tick.
	assert_almost_eq(pos.x, 0.0, 1e-12)
	assert_almost_eq(pos.y, 0.0, 1e-12)
	# One second later would be 14 tiles, but range/lifetime cap at 7 over 10 ticks.
	pos = shot.position_at_time(float(shot.spawn_tick + 5))
	assert_almost_eq(pos.x, 14.0 * 5.0 * SimConstants.TICK_DT, 1e-12)
	assert_almost_eq(pos.y, 0.0, 1e-12)


func test_aim_half_pi_travels_positive_y() -> void:
	var sim := LocalSim.new(_cfg(), 1.0, 2.0)
	_hold_fire(sim, 1, PI / 2.0)
	var shot: SimProjectile = sim.snapshot().projectiles[0]
	assert_almost_eq(shot.dir_x, 0.0, 1e-12)
	assert_almost_eq(shot.dir_y, 1.0, 1e-12)
	var pos := shot.position_at_time(float(shot.spawn_tick + 4))
	assert_almost_eq(pos.x, 1.0, 1e-12)
	assert_almost_eq(pos.y, 2.0 + 14.0 * 4.0 * SimConstants.TICK_DT, 1e-12)


func test_projectile_despawns_after_lifetime() -> void:
	var sim := LocalSim.new(_cfg(), 0.0, 0.0)
	_hold_fire(sim, 1)
	assert_eq(sim.projectile_count(), 1)
	var spawn_tick := sim.snapshot().projectiles[0].spawn_tick
	assert_eq(spawn_tick, 1)
	# Lifetime 10: still alive at spawn + 9, gone at spawn + 10.
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
	var cfg := _cfg()
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
