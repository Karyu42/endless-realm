extends GutTest
## Tick stepping, input seq application, and the WorldSource swap shape.


func test_each_step_advances_tick_by_one() -> void:
	var sim := LocalSim.new(SimConfig.new(), 0.0, 0.0)
	assert_eq(sim.tick(), 0)
	for i in range(7):
		sim.submit_input(InputIntent.from_raw(i + 1, 0.0, 0.0, 0.0, false))
		sim.step()
		assert_eq(sim.tick(), i + 1)
	assert_eq(sim.snapshot().tick, 7)
	assert_eq(sim.snapshot().applied_seq, 7)


func test_snapshot_is_a_copy_of_projectile_list() -> void:
	var cfg := SimConfig.new()
	cfg.fire_rate_shots_per_s = 20.0
	cfg.projectile_speed_tiles_per_s = 14.0
	cfg.projectile_range_tiles = 7.0
	var sim := LocalSim.new(cfg, 0.0, 0.0)
	sim.submit_input(InputIntent.from_raw(1, 0.0, 0.0, 0.0, true))
	sim.step()
	var snap := sim.snapshot()
	assert_eq(snap.projectiles.size(), 1)
	# Later ticks must not mutate the list already handed to the renderer.
	for i in range(sim.snapshot().projectiles[0].lifetime_ticks + 2):
		sim.submit_input(InputIntent.from_raw(i + 2, 0.0, 0.0, 0.0, false))
		sim.step()
	assert_eq(snap.projectiles.size(), 1)
	assert_eq(sim.projectile_count(), 0)


func test_net_client_stub_does_not_simulate() -> void:
	var net := NetClient.new()
	net.submit_input(InputIntent.from_raw(3, 1.0, 0.0, 0.5, true))
	net.step()
	assert_eq(net.tick(), 0)
	assert_eq(net.snapshot().tick, 0)
	assert_eq(net.last_intent.seq, 3)
	assert_true(net.last_intent.fire_held)


func test_constants_match_the_stack() -> void:
	assert_eq(SimConstants.TICK_HZ, 20)
	assert_almost_eq(SimConstants.TICK_DT, 0.05, 1e-15)
	assert_almost_eq(SimConstants.TILE_PX, 16.0, 0.0)
	assert_eq(SimConstants.PROTOCOL_VERSION, 1)
