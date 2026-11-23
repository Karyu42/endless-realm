extends GutTest
## Tallow Warden boss: encounter HP, phases, exit gating, and read-only getters.


func _catalog() -> DataCatalog:
	return DataCatalog.load_default()


func _pid(sim: LocalSim) -> int:
	var ids := sim.player_ids()
	assert_gt(ids.size(), 0, "LocalSim must have a player")
	return ids[0]


func _vault(content_level: int = 1, m100: int = 100) -> LocalSim:
	var catalog := _catalog()
	var def := catalog.dungeon("hollowmere_vault")
	var sim := LocalSim.new(SimConfig.new(), 6.0, 6.0, catalog)
	sim.set_lobby_settings(LobbySettings.new())
	var pid := _pid(sim)
	sim.configure_dungeon(def, 42, m100, content_level, content_level, pid, content_level)
	var p := sim.get_player(pid)
	p.x = 36.0
	p.y = 6.0
	p.prev_x = p.x
	p.prev_y = p.y
	# Activate Wick Kennels so the Warden spawns.
	sim.step()
	return sim


func _warden(sim: LocalSim) -> EnemySnapshot:
	for e in sim.snapshot().enemies:
		if e.def_id == "tallow_warden":
			return e
	return null


func test_encounter_hp_matches_content_examples() -> void:
	var s := _catalog().scaling
	assert_eq(s.m100_of_level(10), 145)
	assert_eq(s.s100(1, "boss"), 100)
	assert_eq(s.s100(8, "boss"), 625)
	assert_eq(s.encounter_hp(5500, 1, 1, "boss"), 5500, "E=1 n=1 is base HP")
	assert_eq(s.encounter_hp(5500, 10, 1, "boss"), 7975, "E=10 solo")
	assert_eq(s.encounter_hp(5500, 10, 8, "boss"), 49844, "E=10 n=8 (content-v0.1 §0.3)")
	assert_eq(s.hp_threshold(5500, 0.66), 3630)
	assert_eq(s.hp_threshold(5500, 0.33), 1815)
	assert_eq(s.riftstone_yield(100), 4)
	assert_eq(s.riftstone_yield(150), 9)


func test_getters_are_read_only_and_start_closed() -> void:
	var catalog := _catalog()
	var yard := LocalSim.new(SimConfig.new(), 16.0, 16.0, catalog)
	yard.set_lobby_settings(LobbySettings.new())
	yard.set_practice_yard(true)
	assert_false(yard.boss_defeated())
	assert_false(yard.vault_exit_open())
	var yard_state: Dictionary = yard.dungeon_state()
	assert_eq(yard_state["boss_defeated"], false)
	assert_eq(yard_state["vault_exit_open"], false)
	# Mutating the copy must not write back into the sim.
	yard_state["boss_defeated"] = true
	yard_state["vault_exit_open"] = true
	assert_false(yard.boss_defeated())
	assert_false(yard.vault_exit_open())
	assert_false(yard.dungeon_state()["boss_defeated"])

	var sim := _vault()
	assert_false(sim.boss_defeated(), "the Warden is alive on room entry")
	assert_false(sim.vault_exit_open())
	var state: Dictionary = sim.dungeon_state()
	assert_eq(state["boss_defeated"], false)
	assert_eq(state["vault_exit_open"], false)
	state["boss_defeated"] = true
	state["vault_exit_open"] = true
	assert_false(sim.boss_defeated())
	assert_false(sim.vault_exit_open())
	# Calling the getters does not change sim state.
	var tick := sim.tick()
	assert_false(sim.boss_defeated())
	assert_false(sim.vault_exit_open())
	var _ignored: Dictionary = sim.dungeon_state()
	assert_eq(sim.tick(), tick)


func test_warden_spawns_at_scaled_hp_and_starts_in_p1() -> void:
	var sim := _vault(1, 100)
	var w := _warden(sim)
	assert_not_null(w)
	assert_eq(w.max_hp, 5500)
	assert_eq(w.hp, 5500)
	assert_eq(w.phase_id, "p1")
	assert_false(w.invulnerable)
	assert_almost_eq(w.radius, 1.20, 0.0001)


func test_p1_fires_wickring_and_drip() -> void:
	var sim := _vault()
	for _i in range(33):
		sim.step()
	var rings := 0
	var drips := 0
	for b in sim.snapshot().pattern_bullets:
		if b.pattern_id == "warden_wickring":
			rings += 1
		elif b.pattern_id == "warden_drip":
			drips += 1
	assert_gt(rings, 0, "P1 wickring should have fired by tick 32")
	assert_gt(drips, 0, "P1 drip should have fired by tick 30")


func test_crossing_66_starts_invuln_transition_and_summons_acolytes() -> void:
	var sim := _vault()
	var pid := _pid(sim)
	var w := _warden(sim)
	# Deal enough to land on the 66% threshold (3630 / 5500).
	sim.hurt_enemy(w.id, w.hp - 3630, pid)
	var mid := sim.get_enemy(w.id)
	assert_eq(mid.hp, 3630)
	assert_eq(mid.phase_id(), "t1")
	assert_true(mid.invulnerable)
	var before: int = mid.hp
	sim.hurt_enemy(w.id, 200, pid)
	assert_eq(sim.get_enemy(w.id).hp, before, "the Warden takes no damage during Melt")
	var acolytes := 0
	for e in sim.snapshot().enemies:
		if e.def_id == "waxen_acolyte":
			acolytes += 1
			assert_eq(e.max_hp, 150, "adds use normal-enemy scaling at n=1 E=1")
	assert_eq(acolytes, 4, "Melt spawns 4 Waxen Acolytes in the corners")
	# Adds drop no loot: kill one and confirm no bag / glint from it.
	var glint_before: int = sim.snapshot().pending_glint
	for e in sim.snapshot().enemies:
		if e.def_id == "waxen_acolyte":
			sim.hurt_enemy(e.id, e.hp, pid)
			break
	sim.step()
	assert_eq(sim.snapshot().pending_glint, glint_before)
	# 2.0 s transition (40 ticks) then P2.
	for _i in range(40):
		sim.step()
	var after := sim.get_enemy(w.id)
	assert_eq(after.phase_id(), "p2")
	assert_false(after.invulnerable)


func test_death_opens_exit_grants_loot_and_clears_bullets() -> void:
	var sim := _vault()
	var pid := _pid(sim)
	var w := _warden(sim)
	# Fire a few ticks so bullets exist, then kill the Warden.
	for _i in range(16):
		sim.step()
	assert_gt(sim.snapshot().pattern_bullets.size(), 0)
	sim.hurt_enemy(w.id, w.hp, pid)
	sim.step()
	assert_true(sim.boss_defeated())
	assert_true(sim.vault_exit_open())
	assert_eq(sim.dungeon_state()["boss_defeated"], true)
	assert_eq(sim.dungeon_state()["vault_exit_open"], true)
	assert_eq(sim.snapshot().pattern_bullets.size(), 0, "death clears live enemy bullets")
	assert_eq(sim.snapshot().hazards.size(), 0)
	var exits := 0
	for item in sim.snapshot().portals:
		if item.kind == PortalSnapshot.KIND_EXIT:
			exits += 1
	assert_eq(exits, 1)
	# Boss loot: 2 guaranteed rolls at M=100, glint ×30, riftstone 4, XP ×50.
	assert_eq(sim.snapshot().ground_drops.size(), 2)
	assert_eq(sim.snapshot().pending_glint, 30, "ceil(m(1)) × 30")
	assert_eq(sim.snapshot().pending_riftstone, 4)
	assert_gt(sim.snapshot().xp_tenths, 0)
	# Acolytes from a mid-fight kill-from-full skip t1, so no adds required here.


func test_p2_and_p3_thresholds() -> void:
	var sim := _vault()
	var pid := _pid(sim)
	var w := _warden(sim)
	sim.hurt_enemy(w.id, w.hp - 3630, pid)
	for _i in range(40):
		sim.step()
	assert_eq(sim.get_enemy(w.id).phase_id(), "p2")
	# P2 loop: pools at the start, spiral in the first 80 ticks.
	var saw_spiral := false
	var saw_pool := false
	for _i in range(8):
		sim.step()
		for b in sim.snapshot().pattern_bullets:
			if b.pattern_id == "warden_spiral":
				saw_spiral = true
		if sim.snapshot().hazards.size() > 0:
			saw_pool = true
	assert_true(saw_spiral, "P2 should start the 4-arm spiral")
	assert_true(saw_pool, "P2 should place wax pools at loop start")
	sim.hurt_enemy(w.id, sim.get_enemy(w.id).hp - 1815, pid)
	assert_eq(sim.get_enemy(w.id).phase_id(), "t2")
	assert_true(sim.get_enemy(w.id).invulnerable)
	for _i in range(60):
		sim.step()
	var p3 := sim.get_enemy(w.id)
	assert_eq(p3.phase_id(), "p3")
	assert_false(p3.invulnerable)
	# Anchored near the kennels center (40, 6).
	assert_almost_eq(p3.x, 40.0, 0.15)
	assert_almost_eq(p3.y, 6.0, 0.15)
	for _i in range(6):
		sim.step()
	var spirals := 0
	var gaps := 0
	for b in sim.snapshot().pattern_bullets:
		if b.pattern_id.begins_with("warden_twinspiral"):
			spirals += 1
		elif b.pattern_id == "warden_gapring":
			gaps += 1
	assert_gt(spirals, 0, "P3 twin spirals should be running")
	assert_gt(gaps, 0, "P3 gap ring fires on phase enter (tick 0 of P3)")
