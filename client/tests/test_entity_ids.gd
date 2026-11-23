extends GutTest
## Players and every sim entity share one id allocator.


func _new_sim() -> LocalSim:
	return LocalSim.new(SimConfig.new(), 5.0, 5.0, DataCatalog.load_default())


func _all_live_ids(sim: LocalSim) -> Array[int]:
	var ids: Array[int] = []
	ids.append_array(sim.player_ids())
	for e in sim._enemies:
		ids.append(e.id)
	for shot in sim._projectiles:
		ids.append(shot.id)
	for b in sim._pattern_bullets:
		ids.append(b.id)
	for bag in sim._ground_drops:
		ids.append(bag.id)
	return ids


func test_players_enemies_shots_and_bags_never_share_an_id() -> void:
	var sim := _new_sim()
	var a := sim.alloc_player_id()
	sim.add_player(a, {"x": 6.0, "y": 5.0})
	sim.add_player(2)  # caller-chosen id is reserved too
	var e1 := sim.spawn_enemy("burrmite", 8.0, 5.0)
	var e2 := sim.spawn_enemy("burrmite", 9.0, 5.0)
	sim.step()
	var b := sim.alloc_player_id()
	sim.add_player(b)
	sim.place_ally(sim.alloc_player_id(), 4.0, 4.0, 50, 100)
	var fire := InputIntent.from_raw(1, 0.0, 0.0, 0.0, true)
	for id in sim.player_ids():
		sim.apply_input(id, fire)
	for i in range(10):
		sim.step()
	var drops := 0
	for i in range(40):
		if sim.try_grant_roll_for(e1, i) != null:
			drops += 1
		if sim.try_grant_roll_for(e2, i) != null:
			drops += 1
	assert_gt(drops, 0, "some bags dropped")
	assert_gt(sim.projectile_count(), 0, "some shots in flight")
	var ids := _all_live_ids(sim)
	var seen := {}
	for id in ids:
		assert_false(seen.has(id), "id %d used twice" % id)
		seen[id] = true
	assert_ne(e1, 2, "enemy did not take the reserved player id")
	assert_ne(e2, 2)


func test_add_player_refuses_an_id_held_by_an_entity() -> void:
	var sim := _new_sim()
	var e := sim.spawn_enemy("burrmite", 8.0, 5.0)
	assert_false(sim.add_player(e), "enemy id is not a player id")
	sim.place_player(e, 1.0, 1.0)
	sim.step()
	assert_false(sim.player_ids().has(e))


func test_remove_player_drops_ability_state() -> void:
	var sim := _new_sim()
	var id := sim.alloc_player_id()
	sim.add_player(id, "thornguard")
	sim.step()
	assert_true(sim._ability_by_player.has(id))
	sim.remove_player(id)
	sim.step()
	assert_false(sim._ability_by_player.has(id), "removed with the player")


func test_dead_entity_ids_are_never_reused_for_players() -> void:
	var sim := _new_sim()
	var e := sim.spawn_enemy("burrmite", 8.0, 5.0)
	sim._enemies.clear()  # the enemy is gone
	sim.step()
	assert_false(sim.add_player(e), "a dead entity's id stays retired")
	var next := sim.spawn_enemy("burrmite", 8.0, 5.0)
	assert_gt(next, e, "allocator only moves forward")
	var p := sim.alloc_player_id()
	assert_gt(p, next)
	assert_true(sim.add_player(p))


func test_ids_skipped_by_a_reservation_stay_usable_for_players() -> void:
	var sim := _new_sim()
	sim.place_player(7, 1.0, 1.0)
	sim.place_player(3, 2.0, 2.0)
	assert_eq(sim.player_ids(), [1, 3, 7] as Array[int])
	var e := sim.spawn_enemy("burrmite", 8.0, 5.0)
	assert_gt(e, 7)


func test_allocator_ids_are_never_reused_across_add_remove_cycles() -> void:
	var sim := _new_sim()
	var seen := {}
	var prev: int = 0
	for _i in range(40):
		var pid: int = sim.alloc_player_id()
		assert_false(seen.has(pid), "player id %d reused" % pid)
		assert_gt(pid, prev)
		seen[pid] = true
		prev = pid
		assert_true(sim.add_player(pid, {"x": 5.0, "y": 5.0}))
		sim.step()
		var eid: int = sim.spawn_enemy("burrmite", 8.0, 5.0)
		assert_false(seen.has(eid), "entity id %d reused" % eid)
		assert_gt(eid, prev)
		seen[eid] = true
		prev = eid
		sim.remove_player(pid)
		sim.step()
	var again: int = sim.alloc_player_id()
	assert_false(seen.has(again))
	assert_gt(again, prev)


func test_internal_tracking_stays_bounded_after_many_cycles() -> void:
	var sim := _new_sim()
	var reserved_before: int = sim._player_id_set.size()
	for _i in range(80):
		var eid: int = sim.spawn_enemy("burrmite", 8.0, 5.0)
		assert_gt(eid, 0)
		sim.hurt_enemy(eid, sim.get_enemy(eid).hp, 1)
		sim.step()
	# Entity ids use the high-water mark only; they must not grow the
	# player-reservation set.
	assert_eq(sim._player_id_set.size(), reserved_before)
	for _j in range(80):
		var pid: int = sim.alloc_player_id()
		assert_true(sim.add_player(pid, {"x": 6.0, "y": 5.0}))
		sim.step()
		var e2: int = sim.spawn_enemy("burrmite", 9.0, 5.0)
		if sim.get_enemy(e2) != null:
			sim.hurt_enemy(e2, 10, pid)
		sim.remove_player(pid)
		sim.step()
		assert_false(sim._ability_by_player.has(pid))
		assert_false(sim._boss_damage_by.has(pid))
		assert_false(sim._boss_near_ticks.has(pid))
		assert_false(sim._boss_ally_heals.has(pid))
		for e in sim._enemies:
			assert_false(e.damaged_by.has(pid))
	# Live per-player maps stay on the remaining roster (the built-in player).
	assert_lte(sim._ability_by_player.size(), sim.player_count())
	assert_lte(sim._boss_damage_by.size(), sim.player_count())
	assert_lte(sim._boss_near_ticks.size(), sim.player_count())
	assert_lte(sim._boss_ally_heals.size(), sim.player_count())
