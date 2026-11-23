extends GutTest
## Fire-rate accumulator, aim convention, and projectile lifetime / range.


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


func test_no_shot_until_accumulator_reaches_one() -> void:
	# Tempo 2.0 / 20 Hz = 0.1 per tick. First shot on tick 10.
	var sim := LocalSim.new(_cfg(), 0.0, 0.0)
	_hold_fire(sim, 9)
	assert_eq(sim.projectile_count(), 0)
	sim.submit_input(InputIntent.from_raw(10, 0.0, 0.0, 0.0, true))
	sim.step()
	assert_eq(sim.projectile_count(), 1)
	assert_eq(sim.tick(), 10)


func test_fire_rate_two_shots_per_second() -> void:
	# Keep both volleys alive so the count is not reduced by despawn.
	var cfg := _cfg()
	cfg.projectile_range_tiles = 100.0
	cfg.projectile_lifetime_ticks_override = 100
	var sim := LocalSim.new(cfg, 0.0, 0.0)
	_hold_fire(sim, SimConstants.TICK_HZ)
	assert_eq(sim.projectile_count(), 2)
	var shots := sim.snapshot().projectiles
	assert_eq(shots[0].spawn_tick, 10)
	assert_eq(shots[1].spawn_tick, 20)


func test_release_does_not_bank_extra_shots() -> void:
	var sim := LocalSim.new(_cfg(), 0.0, 0.0)
	# 9 ticks held (acc = 0.9), then release, then 10 more held -> only one shot.
	for i in range(9):
		sim.submit_input(InputIntent.from_raw(i + 1, 0.0, 0.0, 0.0, true))
		sim.step()
	sim.submit_input(InputIntent.from_raw(10, 0.0, 0.0, 0.0, false))
	sim.step()
	assert_eq(sim.projectile_count(), 0)
	for i in range(10):
		sim.submit_input(InputIntent.from_raw(11 + i, 0.0, 0.0, 0.0, true))
		sim.step()
	assert_eq(sim.projectile_count(), 1)


func test_aim_zero_travels_positive_x() -> void:
	var sim := LocalSim.new(_cfg(), 0.0, 0.0)
	_hold_fire(sim, 10, 0.0)
	assert_eq(sim.projectile_count(), 1)
	var shot: SimProjectile = sim.snapshot().projectiles[0]
	assert_almost_eq(shot.dir_x, 1.0, 1e-12)
	assert_almost_eq(shot.dir_y, 0.0, 1e-12)
	var pos := shot.position_at_time(float(sim.tick()))
	# Fired on tick 10, elapsed 0 on the fire tick.
	assert_almost_eq(pos.x, 0.0, 1e-12)
	assert_almost_eq(pos.y, 0.0, 1e-12)
	# One second later would be 14 tiles, but range/lifetime cap at 7 over 10 ticks.
	pos = shot.position_at_time(float(shot.spawn_tick + 5))
	assert_almost_eq(pos.x, 14.0 * 5.0 * SimConstants.TICK_DT, 1e-12)
	assert_almost_eq(pos.y, 0.0, 1e-12)


func test_aim_half_pi_travels_positive_y() -> void:
	var sim := LocalSim.new(_cfg(), 1.0, 2.0)
	_hold_fire(sim, 10, PI / 2.0)
	var shot: SimProjectile = sim.snapshot().projectiles[0]
	assert_almost_eq(shot.dir_x, 0.0, 1e-12)
	assert_almost_eq(shot.dir_y, 1.0, 1e-12)
	var pos := shot.position_at_time(float(shot.spawn_tick + 4))
	assert_almost_eq(pos.x, 1.0, 1e-12)
	assert_almost_eq(pos.y, 2.0 + 14.0 * 4.0 * SimConstants.TICK_DT, 1e-12)


func test_projectile_despawns_after_lifetime() -> void:
	var sim := LocalSim.new(_cfg(), 0.0, 0.0)
	_hold_fire(sim, 10)
	assert_eq(sim.projectile_count(), 1)
	var spawn_tick := sim.snapshot().projectiles[0].spawn_tick
	assert_eq(spawn_tick, 10)
	# Lifetime 10: still alive at spawn + 9, gone at spawn + 10.
	for i in range(9):
		sim.submit_input(InputIntent.from_raw(20 + i, 0.0, 0.0, 0.0, false))
		sim.step()
	assert_eq(sim.tick(), 19)
	assert_eq(sim.projectile_count(), 1)
	sim.submit_input(InputIntent.from_raw(30, 0.0, 0.0, 0.0, false))
	sim.step()
	assert_eq(sim.tick(), 20)
	assert_eq(sim.projectile_count(), 0)


func test_projectile_despawns_at_range_before_lifetime() -> void:
	var cfg := _cfg()
	cfg.projectile_speed_tiles_per_s = 20.0
	cfg.projectile_range_tiles = 2.0
	cfg.projectile_lifetime_ticks_override = 20
	# 20 tiles/s * 0.05 s = 1 tile/tick, so range 2 is hit at elapsed 2.
	var sim := LocalSim.new(cfg, 0.0, 0.0)
	# Fire once (tempo 2.0 -> tick 10).
	_hold_fire(sim, 10)
	assert_eq(sim.projectile_count(), 1)
	sim.submit_input(InputIntent.from_raw(11, 0.0, 0.0, 0.0, false))
	sim.step()
	assert_eq(sim.projectile_count(), 1, "elapsed 1, distance 1 < 2")
	sim.submit_input(InputIntent.from_raw(12, 0.0, 0.0, 0.0, false))
	sim.step()
	assert_eq(sim.projectile_count(), 0, "elapsed 2, distance 2 is not below range")
