extends GutTest
## content-v0.1 §2.3: nearest living player in aggro range, re-picked every 1 s.


func _issue_through(sim: LocalSim, id: int) -> void:
	while sim._next_id <= id:
		sim.alloc_player_id()


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
	_issue_through(sim, 2)
	sim.place_player(2, 6.0, 0.0)
	var eid: int = sim.spawn_enemy_from_def(_stationary(), 0.0, 0.0)
	sim.step()
	assert_eq(sim.enemy_target_id(eid), 1, "closer player 1 is picked on aggro")
	# Player 2 moves closer; the current target is kept until the 1 s re-pick.
	_issue_through(sim, 2)
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
	_issue_through(sim, 7)
	sim.place_player(7, 4.0, 0.0)
	_issue_through(sim, 3)
	sim.place_player(3, 0.0, 4.0)
	var eid: int = sim.spawn_enemy_from_def(_stationary(), 0.0, 0.0)
	sim.step()
	assert_eq(sim.enemy_target_id(eid), 3)


func test_dead_target_is_replaced_on_the_next_tick() -> void:
	var sim := LocalSim.new(SimConfig.new(), 20.0, 0.0)
	_issue_through(sim, 3)
	sim.place_player(3, 2.0, 0.0)
	_issue_through(sim, 5)
	sim.place_player(5, 3.0, 0.0)
	var eid: int = sim.spawn_enemy_from_def(_stationary(), 0.0, 0.0)
	sim.step()
	assert_eq(sim.enemy_target_id(eid), 3, "nearest living player")
	_issue_through(sim, 3)
	sim.place_player(3, 2.0, 0.0, 0)
	sim.step()
	assert_eq(sim.enemy_target_id(eid), 5, "re-picks the other living player")


func test_no_living_player_in_range_idles_without_host_fallback() -> void:
	# Authority player is far away and must not become the fallback aim.
	var sim := LocalSim.new(SimConfig.new(), 20.0, 0.0)
	_issue_through(sim, 3)
	sim.place_player(3, 2.0, 0.0)
	var def := _stationary()
	def.move_speed = 4.0
	def.wander_speed = 0.0
	var eid: int = sim.spawn_enemy_from_def(def, 0.0, 0.0)
	sim.step()
	assert_eq(sim.enemy_target_id(eid), 3)
	var x_after_aggro: float = sim.snapshot().enemies[0].x
	_issue_through(sim, 3)
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



func test_default_deaggro_radius_is_aggro_plus_four() -> void:
	var d := EnemyDef.from_json({
		"id": "x", "name": "X", "rank": "normal",
		"base": {"hp": 10, "ward": 0, "contact": 0, "damage": {}},
		"move_speed": 0.0, "radius": 0.35, "aggro_radius": 8.0,
		"ai": {"type": "chase_hover"},
	})
	assert_eq(d.deaggro_range(), 12.0)
	assert_false(d.no_leash)
	var sim := LocalSim.new(SimConfig.new(), 5.0, 0.0)
	var def := _stationary(8.0)
	# Default deaggro is 12. Stay aggroed at 10, drop at 13.
	var eid: int = sim.spawn_enemy_from_def(def, 0.0, 0.0)
	sim.step()
	assert_eq(sim.enemy_target_id(eid), 1)
	_issue_through(sim, 1)
	sim.place_player(1, 10.0, 0.0)
	sim.step()
	assert_eq(sim.enemy_target_id(eid), 1, "still inside default deaggro (12)")
	_issue_through(sim, 1)
	sim.place_player(1, 13.0, 0.0)
	sim.step()
	assert_eq(sim.enemy_target_id(eid), 0, "drops when no living player is within deaggro_radius")


func test_explicit_deaggro_radius() -> void:
	var sim := LocalSim.new(SimConfig.new(), 5.0, 0.0)
	var def := _stationary(8.0)
	def.deaggro_radius = 20.0
	var eid: int = sim.spawn_enemy_from_def(def, 0.0, 0.0)
	sim.step()
	assert_eq(sim.enemy_target_id(eid), 1)
	_issue_through(sim, 1)
	sim.place_player(1, 18.0, 0.0)
	sim.step()
	assert_eq(sim.enemy_target_id(eid), 1, "inside explicit deaggro 20")
	_issue_through(sim, 1)
	sim.place_player(1, 21.0, 0.0)
	sim.step()
	assert_eq(sim.enemy_target_id(eid), 0)


func test_leash_triggers_even_if_player_is_inside_deaggro() -> void:
	# deaggro 30, leash 16: walk past 16 from spawn with the player still in range.
	var sim := LocalSim.new(SimConfig.new(), 5.0, 0.0)
	var def := _stationary(8.0)
	def.deaggro_radius = 30.0
	def.leash = 16.0
	def.no_leash = false
	def.move_speed = 8.0
	def.hover_radius = 0.5
	var eid: int = sim.spawn_enemy_from_def(def, 0.0, 0.0)
	sim.step()
	assert_eq(sim.enemy_target_id(eid), 1)
	_issue_through(sim, 1)
	sim.place_player(1, 20.0, 0.0)
	var dropped := false
	for i in range(80):
		sim.step()
		if sim.enemy_target_id(eid) == 0:
			dropped = true
			# The return-to-spawn step runs in the same tick as the drop, so
			# x may already be one move-step back inside 16.
			var e_x: float = sim.snapshot().enemies[0].x
			var step: float = def.move_speed * SimConstants.TICK_DT
			assert_gt(e_x, 16.0 - step - 1e-3, "leash fires around 16 tiles from spawn (x=%s)" % e_x)
			break
	assert_true(dropped, "16-tile leash should drop aggro first")


func test_matron_style_no_leash_uses_deaggro_radius_20() -> void:
	# content-v0.1 §2.3: the Matron doesn't leash while any eligible player is
	# within 20 tiles, so deaggro_radius is 20 (data, not a hardcoded name).
	var sim := LocalSim.new(SimConfig.new(), 5.0, 0.0)
	var def := _stationary(12.0)
	def.deaggro_radius = 20.0
	def.no_leash = true
	def.leash = 16.0
	def.move_speed = 8.0
	def.hover_radius = 0.5
	var eid: int = sim.spawn_enemy_from_def(def, 0.0, 0.0)
	sim.step()
	assert_eq(sim.enemy_target_id(eid), 1)
	_issue_through(sim, 1)
	sim.place_player(1, 18.0, 0.0)
	for i in range(80):
		sim.step()
	assert_eq(sim.enemy_target_id(eid), 1, "still aggroed past the 16-tile leash, player within 20")
	assert_gt(sim.snapshot().enemies[0].x, 16.0)
	# 21 tiles from the enemy, not from spawn (the enemy has walked out).
	_issue_through(sim, 1)
	sim.place_player(1, sim.snapshot().enemies[0].x + 21.0, 0.0)
	sim.step()
	assert_eq(sim.enemy_target_id(eid), 0, "drops when no eligible player is within 20")
