extends GutTest
## content-v0.1 §2.3: nearest living player in aggro range, re-picked every 1 s.


func _stationary(aggro: float = 8.0) -> EnemyDef:
	var def := EnemyDef.new()
	def.aggro_radius = aggro
	def.leash = 16.0
	def.move_speed = 0.0
	def.wander_speed = 0.0
	def.hover_radius = 3.0
	def.strafe_switch_ticks = 40
	def.fire_interval_ticks = 1000
	def.pattern_id = ""
	def.base_hp = 60
	def.radius = 0.35
	return def


func test_picks_nearest_player_and_repicks_after_one_second() -> void:
	var sim := LocalSim.new(SimConfig.new(), 5.0, 0.0)
	sim.place_player(2, 6.0, 0.0)
	var eid: int = sim.spawn_enemy_from_def(_stationary(), 0.0, 0.0)
	sim.step()
	assert_eq(sim.enemy_target_id(eid), 1, "closer player 1 is picked on aggro")
	# Player 2 moves closer; the current target is kept until the 1 s re-pick.
	sim.place_player(2, 2.0, 0.0)
	for i in range(19):
		sim.step()
		assert_eq(sim.enemy_target_id(eid), 1, "held through tick %d" % (i + 1))
	sim.step()
	assert_eq(sim.enemy_target_id(eid), 2, "re-picked at 20 ticks (1 s)")


func test_equal_distance_picks_the_lower_id() -> void:
	# Tie between two non-authority ids so the result does not depend on
	# the authority player being checked first. Id 1 is out of range.
	var sim := LocalSim.new(SimConfig.new(), 20.0, 0.0)
	sim.place_player(7, 4.0, 0.0)
	sim.place_player(3, 0.0, 4.0)
	var eid: int = sim.spawn_enemy_from_def(_stationary(), 0.0, 0.0)
	sim.step()
	assert_eq(sim.enemy_target_id(eid), 3)


func test_dead_target_is_replaced_on_the_next_tick() -> void:
	var sim := LocalSim.new(SimConfig.new(), 20.0, 0.0)
	sim.place_player(3, 2.0, 0.0)
	sim.place_player(5, 3.0, 0.0)
	var eid: int = sim.spawn_enemy_from_def(_stationary(), 0.0, 0.0)
	sim.step()
	assert_eq(sim.enemy_target_id(eid), 3, "nearest living player")
	sim.place_player(3, 2.0, 0.0, 0)
	sim.step()
	assert_eq(sim.enemy_target_id(eid), 5, "re-picks the other living player")


func test_no_living_player_in_range_idles_without_host_fallback() -> void:
	# Authority player is far away and must not become the fallback aim.
	var sim := LocalSim.new(SimConfig.new(), 20.0, 0.0)
	sim.place_player(3, 2.0, 0.0)
	var def := _stationary()
	def.move_speed = 4.0
	def.wander_speed = 0.0
	var eid: int = sim.spawn_enemy_from_def(def, 0.0, 0.0)
	sim.step()
	assert_eq(sim.enemy_target_id(eid), 3)
	var x_after_aggro: float = sim.snapshot().enemies[0].x
	sim.place_player(3, 2.0, 0.0, 0)
	sim.step()
	assert_eq(sim.enemy_target_id(eid), 0, "idle when nobody is alive in range")
	var snap := sim.snapshot()
	assert_true(
		snap.enemies[0].x <= x_after_aggro + 1e-12,
		"must not walk toward the far host at x=20 (x=%s after %s)" % [snap.enemies[0].x, x_after_aggro]
	)


func test_out_of_range_player_is_not_targeted() -> void:
	var sim := LocalSim.new(SimConfig.new(), 10.0, 0.0)
	var eid: int = sim.spawn_enemy_from_def(_stationary(), 0.0, 0.0)
	sim.step()
	assert_eq(sim.enemy_target_id(eid), 0)
