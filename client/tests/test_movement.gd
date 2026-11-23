extends GutTest
## Movement and diagonal normalization on LocalSim (20 Hz, float64).


func _config(speed: float = 4.5) -> SimConfig:
	var cfg := SimConfig.new()
	cfg.move_speed_tiles_per_s = speed
	cfg.fire_rate_shots_per_s = 0.0
	return cfg


func _run(sim: LocalSim, ticks: int, raw_x: float, raw_y: float) -> WorldSnapshot:
	for i in range(ticks):
		sim.submit_input(InputIntent.from_raw(i + 1, raw_x, raw_y, 0.0, false))
		sim.step()
	return sim.snapshot()


func test_tick_starts_at_zero() -> void:
	var sim := LocalSim.new(_config(), 0.0, 0.0)
	assert_eq(sim.tick(), 0)
	assert_almost_eq(sim.snapshot().player_x, 0.0, 1e-12)
	assert_almost_eq(sim.snapshot().player_y, 0.0, 1e-12)


func test_no_input_stays_put() -> void:
	var sim := LocalSim.new(_config(), 3.0, 4.0)
	var snap := _run(sim, 20, 0.0, 0.0)
	assert_eq(snap.tick, 20)
	assert_almost_eq(snap.player_x, 3.0, 1e-12)
	assert_almost_eq(snap.player_y, 4.0, 1e-12)


func test_axis_move_matches_stride_times_time() -> void:
	# 4.5 tiles/s * 1.0 s = 4.5 tiles due +X.
	var sim := LocalSim.new(_config(4.5), 0.0, 0.0)
	var snap := _run(sim, SimConstants.TICK_HZ, 1.0, 0.0)
	assert_almost_eq(snap.player_x, 4.5, 1e-12)
	assert_almost_eq(snap.player_y, 0.0, 1e-12)


func test_up_is_negative_y() -> void:
	var sim := LocalSim.new(_config(4.5), 0.0, 0.0)
	var snap := _run(sim, SimConstants.TICK_HZ, 0.0, -1.0)
	assert_almost_eq(snap.player_x, 0.0, 1e-12)
	assert_almost_eq(snap.player_y, -4.5, 1e-12)


func test_diagonal_is_normalized() -> void:
	# Raw (1, 1) must not be faster than axis-aligned movement.
	var sim := LocalSim.new(_config(4.5), 0.0, 0.0)
	var snap := _run(sim, SimConstants.TICK_HZ, 1.0, 1.0)
	var expected: float = 4.5 / sqrt(2.0)
	assert_almost_eq(snap.player_x, expected, 1e-12)
	assert_almost_eq(snap.player_y, expected, 1e-12)
	var dist := sqrt(snap.player_x * snap.player_x + snap.player_y * snap.player_y)
	assert_almost_eq(dist, 4.5, 1e-12)


func test_eight_directions_share_the_same_speed() -> void:
	var dirs: Array = [
		[1.0, 0.0], [-1.0, 0.0], [0.0, 1.0], [0.0, -1.0],
		[1.0, 1.0], [1.0, -1.0], [-1.0, 1.0], [-1.0, -1.0],
	]
	for d in dirs:
		var sim := LocalSim.new(_config(6.0), 0.0, 0.0)
		var snap := _run(sim, SimConstants.TICK_HZ, d[0], d[1])
		var dist := sqrt(snap.player_x * snap.player_x + snap.player_y * snap.player_y)
		assert_almost_eq(dist, 6.0, 1e-12, "dir %s" % [d])


func test_short_analog_tilt_is_not_normalized_up() -> void:
	var sim := LocalSim.new(_config(4.0), 0.0, 0.0)
	var snap := _run(sim, SimConstants.TICK_HZ, 0.5, 0.0)
	assert_almost_eq(snap.player_x, 2.0, 1e-12)
	assert_almost_eq(snap.player_y, 0.0, 1e-12)
