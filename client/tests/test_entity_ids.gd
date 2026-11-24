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
	assert_ne(e1, a, "enemy did not take the allocated player id")
	assert_ne(e2, a)


func test_add_player_refuses_an_id_held_by_an_entity() -> void:
	var sim := _new_sim()
	var e := sim.spawn_enemy("burrmite", 8.0, 5.0)
	assert_false(sim.add_player(e), "a live entity id is refused")
	assert_push_warning("LocalSim: id %d is already live" % e)
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


func test_allocator_does_not_reuse_dead_entity_ids() -> void:
	var sim := _new_sim()
	var e := sim.spawn_enemy("burrmite", 8.0, 5.0)
	sim._enemies.clear()  # the enemy is gone
	sim.step()
	var next := sim.spawn_enemy("burrmite", 8.0, 5.0)
	assert_gt(next, e, "allocator only moves forward")
	var p := sim.alloc_player_id()
	assert_gt(p, next)
	assert_true(sim.add_player(p))


func test_rejoin_with_an_old_id_works() -> void:
	var sim := _new_sim()
	var pid: int = sim.alloc_player_id()
	assert_true(sim.add_player(pid, {"x": 5.0, "y": 5.0}))
	sim.step()
	assert_true(sim.player_ids().has(pid))
	sim.remove_player(pid)
	sim.step()
	assert_false(sim.player_ids().has(pid))
	assert_true(sim.add_player(pid, {"x": 6.0, "y": 6.0}))
	sim.step()
	assert_true(sim.player_ids().has(pid))
	assert_almost_eq(sim.get_player(pid).x, 6.0, 1e-6)


func test_same_tick_remove_then_add_player_keeps_the_player() -> void:
	# remove_player takes effect at the next step, so a same-tick add_player
	# of that still-live id cancels the leave and applies the new position.
	var sim := _new_sim()
	var pid: int = sim.alloc_player_id()
	assert_true(sim.add_player(pid, {"x": 5.0, "y": 5.0}))
	sim.step()
	assert_true(sim.player_ids().has(pid))
	sim.remove_player(pid)
	assert_true(sim.add_player(pid, {"x": 7.0, "y": 8.0}))
	assert_true(sim.player_ids().has(pid), "the same-tick leave is cancelled")
	assert_almost_eq(sim.get_player(pid).x, 7.0, 1e-6)
	assert_almost_eq(sim.get_player(pid).y, 8.0, 1e-6)
	sim.step()
	assert_true(sim.player_ids().has(pid))
	assert_almost_eq(sim.get_player(pid).x, 7.0, 1e-6)
	assert_almost_eq(sim.get_player(pid).y, 8.0, 1e-6)
	# A live id with no pending leave is still refused.
	assert_false(sim.add_player(pid, {"x": 1.0, "y": 1.0}))
	assert_push_warning("LocalSim: id %d is already live" % pid)
	assert_almost_eq(sim.get_player(pid).x, 7.0, 1e-6)


func test_add_player_refuses_id_above_the_high_water_mark() -> void:
	var sim := _new_sim()
	var above: int = sim._next_id
	assert_false(sim.add_player(above, {"x": 1.0, "y": 1.0}))
	assert_push_warning("LocalSim: id %d is above the high-water mark" % above)
	assert_false(sim.add_player(above + 5, {"x": 1.0, "y": 1.0}))
	sim.step()
	assert_false(sim.player_ids().has(above))
	assert_false(sim.player_ids().has(above + 5))


func test_add_player_refuses_a_live_player_or_entity_id() -> void:
	var sim := _new_sim()
	var live_player: int = sim.player_ids()[0]
	assert_false(sim.add_player(live_player))
	assert_push_warning("LocalSim: id %d is already live" % live_player)
	var pid: int = sim.alloc_player_id()
	assert_true(sim.add_player(pid, {"x": 4.0, "y": 4.0}))
	sim.step()
	assert_false(sim.add_player(pid))
	assert_push_warning("LocalSim: id %d is already live" % pid)
	var e := sim.spawn_enemy("burrmite", 8.0, 5.0)
	assert_false(sim.add_player(e))
	assert_push_warning("LocalSim: id %d is already live" % e)
	sim.place_player(e, 1.0, 1.0)
	sim.step()
	assert_false(sim.player_ids().has(e))


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


func _has_var(obj: Object, name: String) -> bool:
	for item in obj.get_property_list():
		if String(item.name) == name:
			return true
	return false


func test_internal_tracking_stays_bounded_after_many_cycles() -> void:
	var sim := _new_sim()
	assert_false(_has_var(sim, "_player_id_set"), "no per-id-ever set")
	assert_false(_has_var(sim, "_skipped_ids"))
	for _i in range(80):
		var eid: int = sim.spawn_enemy("burrmite", 8.0, 5.0)
		assert_gt(eid, 0)
		sim.hurt_enemy(eid, sim.get_enemy(eid).hp, 1)
		sim.step()
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
		for e in sim._enemies:
			assert_false(e.damaged_by.has(pid))
	assert_lte(sim._ability_by_player.size(), sim.player_count())

	# Boss maps fill during a fight, stay through a mid-fight leave, and
	# clear when the fight ends.
	var catalog := DataCatalog.load_default()
	var def := catalog.dungeon("hollowmere_vault")
	var vault := LocalSim.new(SimConfig.new(), 6.0, 6.0, catalog)
	vault.set_lobby_settings(LobbySettings.new())
	var vpid: int = vault.player_ids()[0]
	vault.configure_dungeon(def, 42, 100, 1, 1, vpid, 1, def.grants_persistent)
	var vp := vault.get_player(vpid)
	vp.x = 36.0
	vp.y = 6.0
	vp.prev_x = vp.x
	vp.prev_y = vp.y
	# A partner stays in the arena so a mid-fight leave does not reset it.
	var partner: int = vault.alloc_player_id()
	assert_true(vault.add_player(partner, {"x": 36.0, "y": 6.5}))
	vault.step()
	var warden: EnemyState = null
	for e in vault._enemies:
		if e.def != null and e.def.id == "tallow_warden":
			warden = e
			break
	assert_not_null(warden)
	vault.hurt_enemy(warden.id, 200, vpid)
	vault.step()
	assert_gt(int(vault._boss_damage_by.get(vpid, 0)), 0)
	assert_gt(int(vault._boss_near_ticks.get(vpid, 0)), 0)
	vault.remove_player(vpid)
	vault.step()
	var stay := vault.get_player(partner)
	if stay != null:
		stay.hp = maxi(stay.hp, 200)
	assert_gt(int(vault._boss_damage_by.get(vpid, 0)), 0, "mid-fight leave keeps credit")
	assert_gt(int(vault._boss_near_ticks.get(vpid, 0)), 0)
	assert_true(vault.add_player(vpid, {"x": 36.0, "y": 6.0}))
	vault.step()
	vp = vault.get_player(vpid)
	vp.x = 36.0
	vp.y = 6.0
	vault.hurt_enemy(warden.id, vault.get_enemy(warden.id).hp, vpid)
	vault.step()
	assert_true(vault.boss_defeated())
	assert_eq(vault._boss_damage_by.size(), 0, "fight-end clears credit maps")
	assert_eq(vault._boss_near_ticks.size(), 0)
	assert_eq(vault._boss_ally_heals.size(), 0)


func test_character_dict_hp_is_sanitized() -> void:
	# Character-dict / place_player HP sanitizing: ignore values below 0,
	# cap at max (200), and do not revive a dead player. Covers a fresh
	# add_player, place_player, and a same-tick cancelled leave.
	var sim := _new_sim()

	# Fresh add_player takes effect at the start of the next step.
	var fresh_neg: int = sim.alloc_player_id()
	assert_true(sim.add_player(fresh_neg, {"x": 3.0, "y": 3.0, "hp": -5}))
	sim.step()
	assert_eq(sim.get_player(fresh_neg).hp, 200, "fresh add ignores HP below 0 and uses max")

	var fresh_zero: int = sim.alloc_player_id()
	assert_true(sim.add_player(fresh_zero, {"x": 3.0, "y": 3.0, "hp": 0}))
	sim.step()
	assert_eq(sim.get_player(fresh_zero).hp, 200, "fresh add ignores HP <= 0 and uses max")

	var fresh_over: int = sim.alloc_player_id()
	assert_true(sim.add_player(fresh_over, {"x": 3.0, "y": 3.0, "hp": 99999}))
	sim.step()
	assert_eq(sim.get_player(fresh_over).hp, 200)

	# place_player of a current occupant.
	var placed: int = sim.alloc_player_id()
	assert_true(sim.add_player(placed, {"x": 3.0, "y": 3.0}))
	sim.step()
	sim.get_player(placed).hp = 120
	sim.place_player(placed, 3.0, 3.0, -5)
	assert_eq(sim.get_player(placed).hp, 120, "place_player ignores HP below 0")
	sim.place_player(placed, 3.0, 3.0, 99999)
	assert_eq(sim.get_player(placed).hp, 200)
	sim.place_player(placed, 3.0, 3.0, 0)
	assert_eq(sim.get_player(placed).hp, 0)
	sim.place_player(placed, 3.0, 3.0, 80)
	assert_eq(sim.get_player(placed).hp, 0, "place_player does not revive a dead player")

	# place_player creating a new player.
	var new_neg: int = sim.alloc_player_id()
	sim.place_player(new_neg, 3.0, 3.0, -5)
	assert_eq(sim.get_player(new_neg).hp, 200)
	var new_zero: int = sim.alloc_player_id()
	sim.place_player(new_zero, 3.0, 3.0, 0)
	assert_eq(sim.get_player(new_zero).hp, 0)
	var new_over: int = sim.alloc_player_id()
	sim.place_player(new_over, 3.0, 3.0, 99999)
	assert_eq(sim.get_player(new_over).hp, 200)

	# Same-tick cancelled leave.
	var readd: int = sim.alloc_player_id()
	assert_true(sim.add_player(readd, {"x": 3.0, "y": 3.0}))
	sim.step()
	sim.get_player(readd).hp = 120
	sim.remove_player(readd)
	assert_true(sim.add_player(readd, {"hp": -5}))
	assert_eq(sim.get_player(readd).hp, 120, "cancelled leave ignores HP below 0")
	sim.remove_player(readd)
	assert_true(sim.add_player(readd, {"hp": 99999}))
	assert_eq(sim.get_player(readd).hp, 200)
	sim.remove_player(readd)
	assert_true(sim.add_player(readd, {"hp": 0}))
	assert_eq(sim.get_player(readd).hp, 0)
	sim.remove_player(readd)
	assert_true(sim.add_player(readd, {"hp": 80}))
	assert_eq(sim.get_player(readd).hp, 0, "cancelled leave does not revive a dead player")


func test_fresh_add_player_with_non_positive_hp_uses_max() -> void:
	# A fresh add_player never creates a 0-HP player: HP <= 0 is ignored
	# and the player starts at max.
	var sim := _new_sim()
	var zero: int = sim.alloc_player_id()
	assert_true(sim.add_player(zero, {"x": 3.0, "y": 3.0, "hp": 0}))
	sim.step()
	assert_eq(sim.get_player(zero).hp, 200)
	var neg: int = sim.alloc_player_id()
	assert_true(sim.add_player(neg, {"x": 3.0, "y": 3.0, "hp": -5}))
	sim.step()
	assert_eq(sim.get_player(neg).hp, 200)


func test_cancelled_leave_applies_class_without_resetting_state() -> void:
	# A cancelled leave applies class only when it actually changes, and
	# never refills HP or resets ability state. A fresh add still fills.
	var sim := _new_sim()

	var fresh: int = sim.alloc_player_id()
	assert_true(sim.add_player(fresh, "gleamwright"))
	sim.step()
	assert_eq(sim.get_player(fresh).class_id, "gleamwright")
	assert_eq(sim.get_player(fresh).hp, 140)

	var fresh_dict: int = sim.alloc_player_id()
	assert_true(sim.add_player(fresh_dict, {"class_id": "gleamwright", "x": 4.0, "y": 4.0}))
	sim.step()
	assert_eq(sim.get_player(fresh_dict).class_id, "gleamwright")
	assert_eq(sim.get_player(fresh_dict).hp, 140)

	var changed: int = sim.alloc_player_id()
	assert_true(sim.add_player(changed, {"x": 5.0, "y": 5.0}))
	sim.step()
	sim.get_player(changed).hp = 80
	sim.remove_player(changed)
	assert_true(sim.add_player(changed, "gleamwright"))
	assert_eq(sim.get_player(changed).class_id, "gleamwright")
	assert_eq(sim.get_player(changed).hp, 80, "a class change on cancelled leave does not refill HP")

	var kept: int = sim.alloc_player_id()
	assert_true(sim.add_player(kept, {"x": 5.0, "y": 5.0}))
	sim.step()
	sim.get_player(kept).hp = 80
	sim.remove_player(kept)
	assert_true(sim.add_player(kept, {"class_id": "gleamwright", "hp": 50}))
	assert_eq(sim.get_player(kept).class_id, "gleamwright")
	assert_eq(sim.get_player(kept).hp, 50)

	var capped: int = sim.alloc_player_id()
	assert_true(sim.add_player(capped, {"x": 5.0, "y": 5.0}))
	sim.step()
	sim.remove_player(capped)
	assert_true(sim.add_player(capped, {"class": "gleamwright", "hp": 99999}))
	assert_eq(sim.get_player(capped).class_id, "gleamwright")
	assert_eq(sim.get_player(capped).hp, 140, "HP is capped at the new class max")


func test_cancelled_leave_with_a_class_does_not_revive_a_dead_player() -> void:
	var sim := _new_sim()
	var pid: int = sim.alloc_player_id()
	assert_true(sim.add_player(pid, {"x": 5.0, "y": 5.0}))
	sim.step()
	sim.get_player(pid).hp = 0
	sim.remove_player(pid)
	assert_true(sim.add_player(pid, "gleamwright"))
	assert_eq(sim.get_player(pid).class_id, "gleamwright")
	assert_eq(sim.get_player(pid).hp, 0, "a dead player re-added with a class stays dead")


func test_cancelled_leave_with_the_same_class_keeps_ability_state() -> void:
	var sim := _new_sim()
	var pid: int = sim.alloc_player_id()
	assert_true(sim.add_player(pid, "thornguard"))
	sim.step()
	var st := sim.ability_state(pid)
	st.cooldown_ticks = 150
	st.focus = 5.0
	st.ally_ability_heals = 3
	sim.get_player(pid).hp = 120
	sim.remove_player(pid)
	assert_true(sim.add_player(pid, "thornguard"))
	assert_eq(sim.get_player(pid).class_id, "thornguard")
	assert_eq(sim.get_player(pid).hp, 120)
	assert_eq(sim.ability_cooldown_ticks(pid), 150)
	assert_almost_eq(sim.focus(pid), 5.0, 1e-6)
	assert_eq(sim.ally_ability_heals(pid), 3)
