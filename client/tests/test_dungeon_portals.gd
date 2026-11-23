extends GutTest
## Hollowmere Vault practice portal, instance math, and room activation.


func _catalog() -> DataCatalog:
	return DataCatalog.load_default()


func _pid(sim: LocalSim) -> int:
	var ids := sim.player_ids()
	assert_gt(ids.size(), 0, "LocalSim must have a player")
	return ids[0]


func _default_settings() -> LobbySettings:
	# Defaults: m100_min = m100_max = 100, which includes the practice portal.
	return LobbySettings.new()


func _yard() -> LocalSim:
	var catalog := _catalog()
	var sim := LocalSim.new(SimConfig.new(), 16.0, 16.0, catalog)
	sim.set_bounds(0.0, 0.0, 32.0, 32.0)
	sim.set_world_seed(1)
	sim.set_lobby_settings(_default_settings())
	var pid := _pid(sim)
	sim.set_player_class_for(pid, "thornguard")
	sim.set_practice_yard(true)
	sim.spawn_practice_portal("hollowmere_vault")
	return sim


func _enter_intent(seq: int, target_id: int, x: float = 0.0, y: float = 0.0) -> InputIntent:
	return InputIntent.from_raw(seq, x, y, 0.0, false, true, 0, target_id, false)


func test_portal_content_level_and_m100_window() -> void:
	var s := _catalog().scaling
	assert_eq(s.portal_content_level(15, 50), 8, "B=15 M=0.50 -> E=8 (vision §6)")
	assert_eq(s.portal_content_level(10, 100), 10)
	assert_eq(s.instance_base_level(10, 1), 10)
	assert_eq(s.instance_base_level(10, 20), 20)
	assert_true(s.is_valid_m100(50))
	assert_true(s.is_valid_m100(105))
	assert_true(s.is_valid_m100(150))
	assert_false(s.is_valid_m100(45))
	assert_false(s.is_valid_m100(155))
	assert_false(s.is_valid_m100(107))
	assert_true(s.below_join_floor(4, 10), "Lp 4 < 0.5 * E 10")
	assert_false(s.below_join_floor(5, 10))
	assert_false(s.below_join_floor(1, 1), "practice E=1 is enterable at L1")


func test_practice_portal_uses_placeholder_base_and_is_enterable() -> void:
	var sim := _yard()
	var snap := sim.snapshot()
	assert_eq(snap.portals.size(), 1)
	var portal: PortalSnapshot = snap.portals[0]
	assert_eq(portal.kind, PortalSnapshot.KIND_ENTER)
	assert_eq(portal.dungeon_id, "hollowmere_vault")
	assert_eq(portal.m100, 100)
	assert_eq(portal.base_level, 1, "practice_base_level placeholder, not vault 10")
	assert_eq(portal.content_level, 1)
	assert_almost_eq(portal.x, 8.0, 0.0001)
	assert_almost_eq(portal.y, 16.0, 0.0001)
	assert_true(sim.m100_allowed(portal.m100))


func test_interact_out_of_accept_range_does_not_enter() -> void:
	var sim := _yard()
	var portal: PortalSnapshot = sim.snapshot().portals[0]
	# Player starts at (16,16); portal is at (8,16), 8 tiles away > 2.0.
	sim.apply_input(_pid(sim), _enter_intent(1, portal.id))
	sim.step()
	assert_eq(sim.take_pending_transfers().size(), 0)


func test_entering_opens_a_seeded_dungeon_instance() -> void:
	var yard := _yard()
	var pid := _pid(yard)
	var portal: PortalSnapshot = yard.snapshot().portals[0]
	var p := yard.get_player(pid)
	p.x = 8.5
	p.y = 16.0
	p.prev_x = p.x
	p.prev_y = p.y
	yard.apply_input(pid, _enter_intent(1, portal.id))
	yard.step()
	var transfers := yard.take_pending_transfers()
	assert_eq(transfers.size(), 1)
	var xfer: PortalTransfer = transfers[0]
	assert_eq(xfer.kind, PortalTransfer.KIND_ENTER)
	assert_eq(xfer.dungeon_id, "hollowmere_vault")
	assert_eq(xfer.m100, 100)
	assert_eq(xfer.content_level, 1)
	assert_eq(xfer.player_id, pid)
	assert_eq(xfer.seed, yard.derived_instance_seed(portal.id, 0), "first step is tick 0")
	var again := _yard()
	var pid2 := _pid(again)
	var portal2: PortalSnapshot = again.snapshot().portals[0]
	var p2 := again.get_player(pid2)
	p2.x = 8.5
	p2.y = 16.0
	again.apply_input(pid2, _enter_intent(1, portal2.id))
	again.step()
	var xfer2: PortalTransfer = again.take_pending_transfers()[0]
	assert_eq(xfer2.seed, xfer.seed, "same yard seed, portal, and tick -> same instance seed")
	assert_almost_eq(xfer.arrival_x, 6.0, 0.0001)
	assert_almost_eq(xfer.arrival_y, 6.0, 0.0001)
	assert_false(xfer.grants_persistent, "the practice-yard entrance packs grants_persistent false")

	var catalog := _catalog()
	var def := catalog.dungeon(xfer.dungeon_id)
	var dungeon := LocalSim.new(SimConfig.new(), xfer.arrival_x, xfer.arrival_y, catalog)
	dungeon.set_lobby_settings(_default_settings())
	dungeon.configure_dungeon(
		def, xfer.seed, xfer.m100, xfer.base_level, xfer.content_level,
		xfer.opener_id, xfer.opener_lp, xfer.grants_persistent
	)
	var carry := PlayerCarry.from_sim(yard.get_player(pid), yard.ability_state(pid))
	dungeon.apply_carried_player(carry, xfer.arrival_x, xfer.arrival_y)
	assert_eq(dungeon.instance_content_level(), 1)
	assert_eq(dungeon.instance_base_level(), 1)
	assert_eq(dungeon.dungeon_id(), "hollowmere_vault")
	assert_eq(dungeon.effective_level(), 1)
	var start := dungeon.snapshot()
	assert_almost_eq(start.player_x, 6.0, 0.0001)
	assert_almost_eq(start.player_y, 6.0, 0.0001)
	assert_eq(start.enemies.size(), 0, "antechamber is safe; rooms spawn on entry")
	var placeholders := 0
	for item in start.portals:
		if item.kind == PortalSnapshot.KIND_PLACEHOLDER:
			placeholders += 1
	assert_eq(placeholders, 0, "the Warden is a real spawn, not a placeholder marker")
	assert_false(dungeon.boss_defeated())
	assert_false(dungeon.vault_exit_open())


func test_rooms_activate_on_entry_and_exit_spawns_when_cleared() -> void:
	var catalog := _catalog()
	var def := catalog.dungeon("hollowmere_vault")
	var sim := LocalSim.new(SimConfig.new(), 6.0, 6.0, catalog)
	sim.set_lobby_settings(_default_settings())
	sim.configure_dungeon(def, 42, 100, 1, 1, _pid(sim), 1, def.practice_grants_persistent())
	assert_eq(sim.snapshot().enemies.size(), 0)
	var pid := _pid(sim)
	var p := sim.get_player(pid)
	# Walk into Drip Hall (origin 15,0 size 16x12).
	p.x = 16.0
	p.y = 6.0
	sim.step()
	var after_hall := sim.snapshot()
	assert_eq(after_hall.enemies.size(), 2, "Drip Hall burrmites spawn on entry")
	for e in after_hall.enemies:
		assert_eq(e.content_level, 1)
		assert_eq(e.def_id, "burrmite")
	# Clear them and enter Wick Kennels (origin 34,0).
	sim.defeat_all_enemies()
	p.x = 36.0
	p.y = 6.0
	sim.step()
	var after_kennels := sim.snapshot()
	var ids: PackedStringArray = PackedStringArray()
	for e in after_kennels.enemies:
		ids.append(e.def_id)
	assert_eq(after_kennels.enemies.size(), 2, "Wick Kennels spawns a Driftcap and the Tallow Warden")
	assert_true("driftcap_spore" in ids)
	assert_true("tallow_warden" in ids)
	assert_false(sim.boss_defeated())
	assert_false(sim.vault_exit_open())
	# Clear only the Driftcap: the exit stays closed while the Warden lives.
	for e in after_kennels.enemies:
		if e.def_id == "driftcap_spore":
			var cap: EnemyState = sim.get_enemy(e.id)
			if cap != null:
				cap.invulnerable = false
				sim.hurt_enemy(e.id, cap.hp, pid)
	sim.step()
	assert_false(sim.boss_defeated())
	assert_false(sim.vault_exit_open(), "trash clear does not open the vault exit")
	sim.defeat_all_enemies()
	sim.step()
	var exits := 0
	var exit_id: int = 0
	for item in sim.snapshot().portals:
		if item.kind == PortalSnapshot.KIND_EXIT:
			exits += 1
			exit_id = item.id
			assert_almost_eq(item.x, 44.0, 0.0001)
	assert_eq(exits, 1, "exit portal appears once the Tallow Warden is defeated")
	assert_true(sim.boss_defeated())
	assert_true(sim.vault_exit_open())
	p.x = 44.0
	p.y = 6.0
	sim.apply_input(pid, _enter_intent(1, exit_id))
	sim.step()
	var transfers := sim.take_pending_transfers()
	assert_eq(transfers.size(), 1)
	assert_eq(transfers[0].kind, PortalTransfer.KIND_EXIT)
	assert_eq(transfers[0].player_id, pid)
	assert_almost_eq(transfers[0].arrival_x, 16.0, 0.0001)


func test_join_floor_rejects_underleveled_entry() -> void:
	var catalog := _catalog()
	var sim := LocalSim.new(SimConfig.new(), 16.0, 16.0, catalog)
	sim.set_world_seed(1)
	sim.set_lobby_settings(_default_settings())
	var pid := _pid(sim)
	# A crafted official-base portal at E=10; L1 is below the join floor.
	var portal := PortalSnapshot.new()
	portal.id = 99
	portal.x = 16.0
	portal.y = 16.0
	portal.radius = 0.75
	portal.kind = PortalSnapshot.KIND_ENTER
	portal.dungeon_id = "hollowmere_vault"
	portal.m100 = 100
	portal.base_level = 10
	portal.content_level = 10
	sim.add_portal(portal)
	sim.apply_input(pid, _enter_intent(1, 99))
	sim.step()
	assert_eq(sim.take_pending_transfers().size(), 0, "Lp 1 < 0.5 * E 10 is rejected")


func test_lobby_settings_reject_an_m100_outside_the_lobby_range() -> void:
	var catalog := _catalog()
	var sim := LocalSim.new(SimConfig.new(), 16.0, 16.0, catalog)
	sim.set_world_seed(1)
	var settings := LobbySettings.new()
	settings.m100_min = 100
	settings.m100_max = 100
	sim.set_lobby_settings(settings)
	var pid := _pid(sim)
	# 50 is valid on the vision window (50–150, step 5) but not in this lobby.
	var portal := PortalSnapshot.new()
	portal.id = 99
	portal.x = 16.0
	portal.y = 16.0
	portal.radius = 0.75
	portal.kind = PortalSnapshot.KIND_ENTER
	portal.dungeon_id = "hollowmere_vault"
	portal.m100 = 50
	portal.base_level = 1
	portal.content_level = 1
	sim.add_portal(portal)
	assert_true(catalog.scaling.is_valid_m100(50), "50 is in the packed window")
	assert_false(sim.m100_allowed(50), "but the lobby is locked to 1.00")
	sim.apply_input(pid, _enter_intent(1, 99))
	sim.step()
	assert_eq(sim.take_pending_transfers().size(), 0)
	# 107 fails the packed step-5 rule even if the lobby range is wide.
	var wide := LobbySettings.new()
	wide.m100_min = 50
	wide.m100_max = 150
	sim.set_lobby_settings(wide)
	assert_false(sim.m100_allowed(107))
	assert_true(sim.m100_allowed(50))
	assert_true(sim.m100_allowed(150))
	assert_false(sim.m100_allowed(155))


func test_level_sync_down_inside_a_portal() -> void:
	var catalog := _catalog()
	var def := catalog.dungeon("hollowmere_vault")
	var sim := LocalSim.new(SimConfig.new(), 6.0, 6.0, catalog)
	sim.set_lobby_settings(_default_settings())
	var pid := _pid(sim)
	sim.configure_dungeon(def, 7, 100, 10, 10, pid, 20, def.grants_persistent)
	var p := sim.get_player(pid)
	p.level = 20
	assert_eq(sim.effective_level(), 15, "Le = min(20, 10+5)")


func test_unknown_dungeon_enemy_id_is_logged() -> void:
	var catalog := DataCatalog.load_default()
	var vault: DungeonDef = catalog.dungeon("hollowmere_vault")
	var room: Dictionary = vault.rooms[1]
	var spawns: Array = room["spawns"]
	var original: Array = spawns.duplicate(true)
	spawns.append({"enemy_id": "no_such_enemy", "x": 0.0, "y": 0.0})
	var ids := catalog.unknown_reference_ids()
	assert_true("no_such_enemy" in ids)
	catalog.report_unknown_ids()
	assert_push_error("DataCatalog: unknown id no_such_enemy")
	room["spawns"] = original

func test_derived_instance_seed_uses_the_dungeon_domain() -> void:
	var sim := _yard()
	var portal_id: int = 7
	var enter_tick: int = 3
	var bare: int = sim._mix_seed(1, portal_id, enter_tick)
	var want: int = sim._mix_seed(bare, 0, LocalSim.DUNGEON_INSTANCE_SEED_DOMAIN)
	assert_eq(sim.derived_instance_seed(portal_id, enter_tick), want)
	assert_ne(sim.derived_instance_seed(portal_id, enter_tick), bare, "not a bare world,id,tick mix")


func test_player_xp_focus_cooldown_and_inventory_carry_into_and_out_of_the_vault() -> void:
	var yard := _yard()
	var pid := _pid(yard)
	yard.grant_xp_tenths(123)
	yard.set_focus(pid, 40.0)
	yard.set_ability_cooldown_ticks(pid, 80)
	var item := ItemState.new()
	item.drop_id = "carry-token"
	item.display_base = "Carry Token"
	item.tier = 1
	assert_true(yard.get_player(pid).inventory.add(item))
	var start_xp: int = yard.get_player(pid).xp_tenths
	assert_eq(start_xp, 123)
	var portal: PortalSnapshot = yard.snapshot().portals[0]
	var yp := yard.get_player(pid)
	yp.x = 8.5
	yp.y = 16.0
	yp.prev_x = yp.x
	yp.prev_y = yp.y
	yard.apply_input(pid, _enter_intent(1, portal.id))
	yard.step()
	var xfer: PortalTransfer = yard.take_pending_transfers()[0]
	var catalog := _catalog()
	var def := catalog.dungeon(xfer.dungeon_id)
	var dungeon := LocalSim.new(SimConfig.new(), xfer.arrival_x, xfer.arrival_y, catalog)
	dungeon.set_lobby_settings(_default_settings())
	dungeon.configure_dungeon(
		def, xfer.seed, xfer.m100, xfer.base_level, xfer.content_level,
		xfer.opener_id, xfer.opener_lp, xfer.grants_persistent
	)
	if dungeon.get_player(pid) == null:
		assert_true(dungeon.add_player(pid, {"x": xfer.arrival_x, "y": xfer.arrival_y}))
		dungeon.step()
	# Snapshot after the enter tick: Focus regen and cooldown clock already ran.
	var into := PlayerCarry.from_sim(yard.get_player(pid), yard.ability_state(pid))
	dungeon.apply_carried_player(into, xfer.arrival_x, xfer.arrival_y)
	var dp := dungeon.get_player(pid)
	assert_eq(dp.xp_tenths, into.xp_tenths)
	assert_eq(into.xp_tenths, 123)
	assert_almost_eq(dungeon.focus(pid), into.ability.focus, 1e-6)
	assert_eq(dungeon.ability_cooldown_ticks(pid), into.ability.cooldown_ticks)
	assert_eq(dp.inventory.slots[0].drop_id, "carry-token")

	var back := PlayerCarry.from_sim(dp, dungeon.ability_state(pid))
	var yard2 := _yard()
	if yard2.get_player(pid) == null:
		assert_true(yard2.add_player(pid, {"x": 16.0, "y": 16.0}))
		yard2.step()
	yard2.apply_carried_player(back, 16.0, 16.0)
	var yp2 := yard2.get_player(pid)
	assert_eq(yp2.xp_tenths, back.xp_tenths)
	assert_eq(back.xp_tenths, 123)
	assert_almost_eq(yard2.focus(pid), back.ability.focus, 1e-6)
	assert_eq(yard2.ability_cooldown_ticks(pid), back.ability.cooldown_ticks)
	assert_eq(yp2.inventory.slots[0].drop_id, "carry-token")


func test_reentering_mid_clear_starts_uncleared() -> void:
	var catalog := _catalog()
	var def := catalog.dungeon("hollowmere_vault")
	var sim := LocalSim.new(SimConfig.new(), 6.0, 6.0, catalog)
	sim.set_lobby_settings(_default_settings())
	var pid := _pid(sim)
	sim.configure_dungeon(def, 42, 100, 1, 1, pid, 1, def.practice_grants_persistent())
	var p := sim.get_player(pid)
	p.x = 16.0
	p.y = 6.0
	sim.step()
	assert_eq(sim.snapshot().enemies.size(), 2, "Drip Hall is activated")
	sim.defeat_all_enemies()
	# Mid-clear: hall is empty, kennels not entered, no exit yet.
	var exits := 0
	for item in sim.snapshot().portals:
		if item.kind == PortalSnapshot.KIND_EXIT:
			exits += 1
	assert_eq(exits, 0)
	# A re-enter builds a fresh instance; rooms and the exit reset.
	var again := LocalSim.new(SimConfig.new(), 6.0, 6.0, catalog)
	again.set_lobby_settings(_default_settings())
	if again.get_player(pid) == null:
		assert_true(again.add_player(pid, {"x": 6.0, "y": 6.0}))
		again.step()
	again.configure_dungeon(def, 42, 100, 1, 1, pid, 1, def.practice_grants_persistent())
	assert_eq(again.snapshot().enemies.size(), 0, "antechamber starts empty")
	exits = 0
	for item in again.snapshot().portals:
		if item.kind == PortalSnapshot.KIND_EXIT:
			exits += 1
	assert_eq(exits, 0, "exit is not already open")
	var p2 := again.get_player(pid)
	p2.x = 16.0
	p2.y = 6.0
	again.step()
	assert_eq(again.snapshot().enemies.size(), 2, "Drip Hall spawns a fresh pair")
