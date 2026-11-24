extends GutTest
## LocalSim class lock: class changes apply only in the Hearth, with
## HP = min(current, new max), 0 Focus and full cooldown.


func _catalog() -> DataCatalog:
	return DataCatalog.load_default()


func _new_sim() -> LocalSim:
	return LocalSim.new(SimConfig.new(), 5.0, 5.0, _catalog())


func _hearth() -> LocalSim:
	var sim := _new_sim()
	sim.configure_zone(LocalSim.ZONE_HEARTH)
	return sim


func _vault(sim: LocalSim, opener_id: int) -> void:
	var def: DungeonDef = _catalog().dungeon("hollowmere_vault")
	assert_not_null(def)
	sim.set_lobby_settings(LobbySettings.new())
	sim.configure_dungeon(def, 42, 100, 1, 1, opener_id, 1, def.grants_persistent)


func _full_cooldown(sim: LocalSim, pid: int) -> int:
	return sim.world_view(pid).ability_cooldown_max


func test_class_change_allowed_only_in_the_hearth() -> void:
	var sim := _new_sim()
	var pid: int = sim.alloc_player_id()
	assert_true(sim.add_player(pid, "thornguard"))
	sim.step()
	assert_eq(sim.zone_id(), "")
	assert_false(sim.is_town(), "the Wilds default is not town")
	assert_true(sim.class_change_allowed(pid, "thornguard"))
	assert_false(sim.class_change_allowed(pid, "gleamwright"), "a different class is refused in the Wilds")
	sim.configure_zone(LocalSim.ZONE_HEARTH)
	assert_true(sim.is_town())
	assert_true(sim.class_change_allowed(pid, "gleamwright"))
	_vault(sim, pid)
	assert_false(sim.is_town())
	assert_true(sim.class_change_allowed(pid, "thornguard"), "same-class rejoin is allowed")
	assert_false(sim.class_change_allowed(pid, "gleamwright"), "a different class is refused in a dungeon")
	assert_false(sim.class_change_allowed(pid, "no_such_class"))
	assert_push_error("DataCatalog: unknown id no_such_class")


func test_town_cancelled_leave_still_applies_a_class_change() -> void:
	var sim := _hearth()
	var pid: int = sim.alloc_player_id()
	assert_true(sim.add_player(pid, "thornguard"))
	sim.step()
	sim.get_player(pid).hp = 80
	sim.ability_state(pid).focus = 5.0
	sim.set_ability_cooldown_ticks(pid, 150)
	sim.remove_player(pid)
	assert_true(sim.add_player(pid, "gleamwright"))
	assert_eq(sim.get_player(pid).class_id, "gleamwright")
	assert_eq(sim.get_player(pid).hp, 80, "a class change does not refill HP")
	assert_almost_eq(sim.focus(pid), 0.0, 1e-6)
	assert_eq(sim.ability_cooldown_ticks(pid), _full_cooldown(sim, pid))
	assert_gt(sim.ability_cooldown_ticks(pid), 0)


func test_dungeon_cancelled_leave_keeps_class_on_a_different_class() -> void:
	var sim := _new_sim()
	var pid: int = sim.alloc_player_id()
	assert_true(sim.add_player(pid, "thornguard"))
	sim.step()
	_vault(sim, pid)
	sim.get_player(pid).hp = 80
	sim.ability_state(pid).focus = 5.0
	sim.set_ability_cooldown_ticks(pid, 150)
	sim.remove_player(pid)
	assert_true(sim.add_player(pid, "gleamwright"), "the cancelled leave itself is kept")
	assert_push_error("LocalSim: class change refused outside town")
	assert_eq(sim.get_player(pid).class_id, "thornguard")
	assert_eq(sim.get_player(pid).hp, 80)
	assert_almost_eq(sim.focus(pid), 5.0, 1e-6)
	assert_eq(sim.ability_cooldown_ticks(pid), 150)


func test_wilds_cancelled_leave_keeps_class_on_a_different_class() -> void:
	var sim := _new_sim()
	var pid: int = sim.alloc_player_id()
	assert_true(sim.add_player(pid, "thornguard"))
	sim.step()
	sim.get_player(pid).hp = 80
	sim.ability_state(pid).focus = 5.0
	sim.set_ability_cooldown_ticks(pid, 150)
	sim.remove_player(pid)
	assert_true(sim.add_player(pid, "gleamwright"))
	assert_push_error("LocalSim: class change refused outside town")
	assert_eq(sim.get_player(pid).class_id, "thornguard")
	assert_eq(sim.get_player(pid).hp, 80)
	assert_almost_eq(sim.focus(pid), 5.0, 1e-6)
	assert_eq(sim.ability_cooldown_ticks(pid), 150)


func test_dungeon_set_player_class_is_refused() -> void:
	var sim := _new_sim()
	var pid: int = sim.alloc_player_id()
	assert_true(sim.add_player(pid, "thornguard"))
	sim.step()
	_vault(sim, pid)
	sim.set_player_class_for(pid, "gleamwright")
	assert_push_error("LocalSim: class change refused outside town")
	assert_eq(sim.get_player(pid).class_id, "thornguard")


func test_same_class_cancelled_leave_in_a_dungeon_keeps_state() -> void:
	var sim := _new_sim()
	var pid: int = sim.alloc_player_id()
	assert_true(sim.add_player(pid, "thornguard"))
	sim.step()
	_vault(sim, pid)
	sim.get_player(pid).hp = 120
	sim.ability_state(pid).focus = 7.0
	sim.set_ability_cooldown_ticks(pid, 40)
	sim.remove_player(pid)
	assert_true(sim.add_player(pid, "thornguard"))
	assert_eq(sim.get_player(pid).class_id, "thornguard")
	assert_eq(sim.get_player(pid).hp, 120)
	assert_almost_eq(sim.focus(pid), 7.0, 1e-6)
	assert_eq(sim.ability_cooldown_ticks(pid), 40)


func test_same_class_is_a_noop_in_a_dungeon_and_in_the_wilds() -> void:
	for in_dungeon in [false, true]:
		var sim := _new_sim()
		var pid: int = sim.alloc_player_id()
		assert_true(sim.add_player(pid, "thornguard"))
		sim.step()
		if in_dungeon:
			_vault(sim, pid)
		sim.get_player(pid).hp = 90
		sim.ability_state(pid).focus = 8.0
		sim.set_ability_cooldown_ticks(pid, 55)
		sim.set_player_class_for(pid, "thornguard")
		assert_eq(sim.get_player(pid).class_id, "thornguard")
		assert_eq(sim.get_player(pid).hp, 90)
		assert_almost_eq(sim.focus(pid), 8.0, 1e-6)
		assert_eq(sim.ability_cooldown_ticks(pid), 55)
		sim.remove_player(pid)
		assert_true(sim.add_player(pid, "thornguard"))
		assert_eq(sim.get_player(pid).hp, 90)
		assert_almost_eq(sim.focus(pid), 8.0, 1e-6)
		assert_eq(sim.ability_cooldown_ticks(pid), 55)


func test_same_class_rejoin_in_a_dungeon_restores_a_snapshot() -> void:
	# #52 / #56: a same-class in-instance rejoin restores the leave snapshot
	# (Focus and remaining cooldown, adjusted by the host). LocalSim still
	# accepts the re-add and the host-applied restore.
	var sim := _new_sim()
	var pid: int = sim.alloc_player_id()
	assert_true(sim.add_player(pid, "thornguard"))
	sim.step()
	_vault(sim, pid)
	sim.get_player(pid).hp = 90
	sim.ability_state(pid).focus = 12.0
	sim.set_ability_cooldown_ticks(pid, 80)
	var saved_hp: int = sim.get_player(pid).hp
	var saved_focus: float = sim.focus(pid)
	var saved_cd: int = sim.ability_cooldown_ticks(pid)
	sim.remove_player(pid)
	sim.step()
	assert_eq(sim.get_player(pid), null)
	assert_true(sim.add_player(pid, {"class_id": "thornguard", "hp": saved_hp, "x": 6.0, "y": 6.0}))
	sim.step()
	assert_eq(sim.get_player(pid).class_id, "thornguard")
	assert_eq(sim.get_player(pid).hp, saved_hp)
	# The host writes the snapshot after the re-add, as #52 does.
	sim.ability_state(pid).focus = saved_focus
	sim.set_ability_cooldown_ticks(pid, saved_cd)
	assert_almost_eq(sim.focus(pid), 12.0, 1e-6)
	assert_eq(sim.ability_cooldown_ticks(pid), 80)


func test_apply_class_change_arrival_is_conservative_and_clears_credit() -> void:
	var sim := _hearth()
	var pid: int = sim.alloc_player_id()
	assert_true(sim.add_player(pid, "thornguard"))
	sim.step()
	sim.get_player(pid).hp = 180
	sim.ability_state(pid).focus = 20.0
	sim.set_ability_cooldown_ticks(pid, 10)
	sim._boss_damage_by[pid] = 200
	sim._boss_near_ticks[pid] = 30
	sim._boss_ally_heals[pid] = 4
	sim.get_player(pid).last_activity_tick = 0
	assert_true(sim.apply_class_change_arrival(pid, "gleamwright"))
	assert_eq(sim.get_player(pid).class_id, "gleamwright")
	assert_eq(sim.get_player(pid).hp, 140, "HP is min(current, new max)")
	assert_almost_eq(sim.focus(pid), 0.0, 1e-6)
	assert_eq(sim.ability_cooldown_ticks(pid), _full_cooldown(sim, pid))
	assert_gt(sim.ability_cooldown_ticks(pid), 0)
	assert_false(sim._boss_damage_by.has(pid))
	assert_false(sim._boss_near_ticks.has(pid))
	assert_false(sim._boss_ally_heals.has(pid))
	assert_eq(sim.get_player(pid).last_activity_tick, sim._tick)
	# A later different class in town still uses the in-place path.
	sim.remove_player(pid)
	assert_true(sim.add_player(pid, "thornguard"))
	assert_eq(sim.get_player(pid).class_id, "thornguard")
	assert_eq(sim.get_player(pid).hp, 140, "cancelled-leave town change does not refill")
	assert_almost_eq(sim.focus(pid), 0.0, 1e-6)
	assert_eq(sim.ability_cooldown_ticks(pid), _full_cooldown(sim, pid))


func test_apply_class_change_arrival_is_refused_outside_town() -> void:
	var wilds := _new_sim()
	var pid: int = wilds.alloc_player_id()
	assert_true(wilds.add_player(pid, "thornguard"))
	wilds.step()
	wilds.get_player(pid).hp = 80
	wilds.ability_state(pid).focus = 9.0
	assert_false(wilds.apply_class_change_arrival(pid, "gleamwright"))
	assert_eq(wilds.get_player(pid).class_id, "thornguard")
	assert_eq(wilds.get_player(pid).hp, 80)
	assert_almost_eq(wilds.focus(pid), 9.0, 1e-6)
	_vault(wilds, pid)
	assert_false(wilds.apply_class_change_arrival(pid, "gleamwright"))
	assert_eq(wilds.get_player(pid).class_id, "thornguard")
	assert_eq(wilds.get_player(pid).hp, 80)


func test_town_class_swap_never_raises_hp() -> void:
	var sim := _hearth()
	var pid: int = sim.alloc_player_id()
	assert_true(sim.add_player(pid, "thornguard"))
	sim.step()
	sim.get_player(pid).hp = 180
	sim.set_player_class_for(pid, "gleamwright")
	assert_eq(sim.get_player(pid).class_id, "gleamwright")
	assert_eq(sim.get_player(pid).hp, 140, "capped at the new class max")
	assert_almost_eq(sim.focus(pid), 0.0, 1e-6)
	assert_eq(sim.ability_cooldown_ticks(pid), _full_cooldown(sim, pid))
	sim.set_player_class_for(pid, "thornguard")
	assert_eq(sim.get_player(pid).class_id, "thornguard")
	assert_eq(sim.get_player(pid).hp, 140, "swapping back does not raise HP")
	assert_almost_eq(sim.focus(pid), 0.0, 1e-6)
	assert_eq(sim.ability_cooldown_ticks(pid), _full_cooldown(sim, pid))
	# A later swap at a lower HP stays at that HP.
	sim.get_player(pid).hp = 80
	sim.set_player_class_for(pid, "gleamwright")
	assert_eq(sim.get_player(pid).hp, 80)
	sim.set_player_class_for(pid, "thornguard")
	assert_eq(sim.get_player(pid).hp, 80)


func test_repeated_refusals_log_once_per_player_and_class() -> void:
	var sim := _new_sim()
	var pid: int = sim.alloc_player_id()
	assert_true(sim.add_player(pid, "thornguard"))
	sim.step()
	for i in range(20):
		sim.set_player_class_for(pid, "gleamwright")
	assert_eq(sim.get_player(pid).class_id, "thornguard")
	assert_push_error("LocalSim: class change refused outside town")
	assert_push_error_count(1)


func test_fresh_add_still_fills_max_hp() -> void:
	var sim := _new_sim()
	var pid: int = sim.alloc_player_id()
	assert_true(sim.add_player(pid, "gleamwright"))
	sim.step()
	assert_eq(sim.get_player(pid).hp, 140, "a fresh spawn with no prior body starts at max HP")
	assert_false(sim.apply_class_change_arrival(99999, "thornguard"), "not town")
	sim.configure_zone(LocalSim.ZONE_HEARTH)
	assert_false(sim.apply_class_change_arrival(99999, "thornguard"), "no such player")
