extends GutTest
## LocalSim class lock: class changes apply in town; a dungeon instance
## refuses them. After-linger town arrival uses conservative ability state.


func _catalog() -> DataCatalog:
	return DataCatalog.load_default()


func _new_sim() -> LocalSim:
	return LocalSim.new(SimConfig.new(), 5.0, 5.0, _catalog())


func _vault(sim: LocalSim, opener_id: int) -> void:
	var def: DungeonDef = _catalog().dungeon("hollowmere_vault")
	assert_not_null(def)
	sim.set_lobby_settings(LobbySettings.new())
	sim.configure_dungeon(def, 42, 100, 1, 1, opener_id, 1, def.grants_persistent)


func test_class_change_allowed_in_town_and_in_a_dungeon() -> void:
	var sim := _new_sim()
	var pid: int = sim.alloc_player_id()
	assert_true(sim.add_player(pid, "thornguard"))
	sim.step()
	assert_true(sim.is_town())
	assert_true(sim.class_change_allowed(pid, "thornguard"))
	assert_true(sim.class_change_allowed(pid, "gleamwright"))
	_vault(sim, pid)
	assert_false(sim.is_town())
	assert_true(sim.class_change_allowed(pid, "thornguard"), "same-class rejoin is allowed")
	assert_false(sim.class_change_allowed(pid, "gleamwright"), "a different class is not applied in a dungeon")
	assert_false(sim.class_change_allowed(pid, "no_such_class"))
	assert_push_error("DataCatalog: unknown id no_such_class")


func test_town_cancelled_leave_still_applies_a_class_change() -> void:
	var sim := _new_sim()
	var pid: int = sim.alloc_player_id()
	assert_true(sim.add_player(pid, "thornguard"))
	sim.step()
	sim.get_player(pid).hp = 80
	sim.ability_state(pid).focus = 5.0
	sim.set_ability_cooldown_ticks(pid, 150)
	sim.remove_player(pid)
	assert_true(sim.add_player(pid, "gleamwright"))
	assert_eq(sim.get_player(pid).class_id, "gleamwright")
	assert_eq(sim.get_player(pid).hp, 80, "town class change does not refill HP")
	assert_almost_eq(sim.focus(pid), 5.0, 1e-6)
	assert_eq(sim.ability_cooldown_ticks(pid), 150)


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
	var sim := _new_sim()
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
	assert_eq(sim.ability_cooldown_ticks(pid), sim.world_view(pid).ability_cooldown_max)
	assert_gt(sim.ability_cooldown_ticks(pid), 0)
	assert_false(sim._boss_damage_by.has(pid))
	assert_false(sim._boss_near_ticks.has(pid))
	assert_false(sim._boss_ally_heals.has(pid))
	assert_eq(sim.get_player(pid).last_activity_tick, sim._tick)
	# A later different class in town still uses the in-place path, not arrival.
	sim.remove_player(pid)
	assert_true(sim.add_player(pid, "thornguard"))
	assert_eq(sim.get_player(pid).class_id, "thornguard")
	assert_eq(sim.get_player(pid).hp, 140, "cancelled-leave town change does not refill")


func test_fresh_add_still_fills_max_hp() -> void:
	var sim := _new_sim()
	var pid: int = sim.alloc_player_id()
	assert_true(sim.add_player(pid, "gleamwright"))
	sim.step()
	assert_eq(sim.get_player(pid).hp, 140, "a fresh spawn with no prior body starts at max HP")
	assert_false(sim.apply_class_change_arrival(99999, "thornguard"))
