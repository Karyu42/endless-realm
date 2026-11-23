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
	var sim := LocalSim.new(SimConfig.new(), 4.0, 0.0)
	sim.place_player(3, 0.0, 4.0)
	var eid: int = sim.spawn_enemy_from_def(_stationary(), 0.0, 0.0)
	sim.step()
	assert_eq(sim.enemy_target_id(eid), 1)


func test_out_of_range_player_is_not_targeted() -> void:
	var sim := LocalSim.new(SimConfig.new(), 10.0, 0.0)
	var eid: int = sim.spawn_enemy_from_def(_stationary(8.0), 0.0, 0.0)
	sim.step()
	assert_eq(sim.enemy_target_id(eid), 0)
