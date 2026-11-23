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
	sim.configure_dungeon(def, 42, m100, content_level, content_level, pid, content_level, def.grants_persistent)
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
	# Mid-fight HP rise keeps the current fraction (vision §3.5).
	var max8: int = s.encounter_hp(5500, 10, 8, "boss")
	var max9: int = s.encounter_hp(5500, 10, 9, "boss")
	assert_eq(max8, 49844)
	var cur: int = s.keep_hp_fraction((max8 * 60 + 50) / 100, max8, max8)
	assert_eq(cur, 29906, "60% of 49844")
	assert_eq(s.keep_hp_fraction(29906, max8, max9), 31724, "n 8→9 at E=10 keeps the fraction")


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
	# Non-idle input is required for boss-loot eligibility (vision §6.1 rule 7).
	for i in range(16):
		_hold_fire(sim, pid, i + 1)
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


func _hold_fire(sim: LocalSim, pid: int, seq: int) -> void:
	var p := sim.get_player(pid)
	var aim: float = p.aim if p != null else 0.0
	sim.apply_input(pid, InputIntent.from_raw(seq, 0.0, 0.0, aim, true))


func _add_at(sim: LocalSim, x: float, y: float) -> int:
	var id: int = sim.alloc_player_id()
	sim.place_player(id, x, y)
	return id


func test_antechamber_players_do_not_scale_the_warden() -> void:
	var sim := _vault()
	var w := _warden(sim)
	assert_not_null(w)
	assert_eq(sim.boss_n_peak(), 1)
	assert_eq(w.max_hp, 5500)
	# A second living player in the Antechamber is not in the arena.
	var pid2: int = _add_at(sim, 6.0, 6.0)
	assert_gt(pid2, 0)
	sim.step()
	var after := _warden(sim)
	assert_eq(sim.boss_n_peak(), 1, "n_peak counts living characters in the arena only")
	assert_eq(after.max_hp, 5500)
	assert_eq(after.hp, 5500)
	# Entering the arena raises n_peak; it never decreases if they leave.
	var p2 := sim.get_player(pid2)
	p2.x = 36.0
	p2.y = 6.0
	p2.prev_x = p2.x
	p2.prev_y = p2.y
	sim.step()
	var scaled := _warden(sim)
	var expect: int = _catalog().scaling.encounter_hp(5500, 1, 2, "boss")
	assert_eq(sim.boss_n_peak(), 2)
	assert_eq(scaled.max_hp, expect)
	p2.x = 6.0
	p2.y = 6.0
	sim.step()
	assert_eq(sim.boss_n_peak(), 2, "n_peak never decreases during the encounter")
	assert_eq(_warden(sim).max_hp, expect)


func test_far_wilds_players_do_not_scale_a_burrmite() -> void:
	var catalog := _catalog()
	var sim := LocalSim.new(SimConfig.new(), 16.0, 16.0, catalog)
	sim.set_lobby_settings(LobbySettings.new())
	sim.set_practice_yard(true)
	var pid := _pid(sim)
	sim.place_player(pid, 16.0, 16.0)
	var eid: int = sim.spawn_enemy("burrmite", 16.0, 16.5, 1)
	var cl: int = sim.get_enemy(eid).content_level
	var solo: int = catalog.scaling.encounter_hp(60, cl, 1, "normal")
	assert_eq(sim.get_enemy(eid).max_hp(), solo)
	# Four living players well outside the 12-tile pack range.
	for i in range(4):
		_add_at(sim, 40.0 + float(i), 40.0)
	# Aggro the burrmite on the nearby player.
	for _i in range(4):
		sim.step()
	assert_eq(sim.get_enemy(eid).n_peak, 1)
	assert_eq(sim.get_enemy(eid).max_hp(), solo)
	# A second player entering range raises this pack's n_peak only.
	var pid2: int = _add_at(sim, 16.5, 16.0)
	for _j in range(4):
		sim.step()
	var expect: int = catalog.scaling.encounter_hp(60, cl, 2, "normal")
	assert_eq(sim.get_enemy(eid).n_peak, 2)
	assert_eq(sim.get_enemy(eid).max_hp(), expect)
	assert_gt(pid2, 0)


func test_boss_loot_follows_rule_7() -> void:
	var sim := _vault()
	var pid := _pid(sim)
	var w := _warden(sim)
	# A nearby fighter who damages the Warden but stays idle is not eligible.
	for _i in range(8):
		sim.step()
	sim.hurt_enemy(w.id, 200, pid)
	sim.hurt_enemy(w.id, sim.get_enemy(w.id).hp, pid)
	sim.step()
	assert_true(sim.boss_defeated())
	assert_eq(sim.snapshot().pending_glint, 0, "damage without recent non-idle input is not enough")
	assert_eq(sim.snapshot().pending_riftstone, 0)
	assert_eq(sim.snapshot().ground_drops.size(), 0)

	# A second run: contribution plus recent non-idle input qualifies.
	var sim2 := _vault()
	var pid_a: int = _pid(sim2)
	var w2 := _warden(sim2)
	# A player who only arrives in loot range at the kill, with no contribution,
	# is not eligible under vision §6.1 rule 7.
	var pid_b: int = _add_at(sim2, 6.0, 6.0)
	# Open the fight with a real hit so fight ticks accrue before B arrives.
	_hold_fire(sim2, pid_a, 1)
	sim2.step()
	sim2.hurt_enemy(w2.id, 200, pid_a)
	for i in range(16):
		_hold_fire(sim2, pid_a, i + 2)
		sim2.step()
	# Move B next to the Warden only at the end, and give them input too.
	var pb := sim2.get_player(pid_b)
	pb.x = 42.0
	pb.y = 6.5
	_hold_fire(sim2, pid_b, 30)
	sim2.step()
	_hold_fire(sim2, pid_a, 31)
	# Use current HP: B's arena entry can raise n_peak mid-fight.
	sim2.hurt_enemy(w2.id, sim2.get_enemy(w2.id).hp, pid_a)
	sim2.step()
	assert_eq(sim2.get_player(pid_a).pending_glint, 30)
	assert_eq(sim2.get_player(pid_a).pending_riftstone, 4)
	assert_eq(sim2.get_player(pid_b).pending_glint, 0, "loot-range presence alone does not qualify")
	assert_eq(sim2.get_player(pid_b).pending_riftstone, 0)
	assert_eq(sim2.snapshot().ground_drops.size(), 2)


func test_boss_seeds_use_their_own_domains() -> void:
	var sim := _vault()
	var w := _warden(sim)
	var tick: int = 20
	var aim: int = sim.boss_aim_seed(w.id, tick)
	var pool: int = sim.boss_pool_seed(w.id, tick)
	var volley: int = sim.pattern_volley_seed(w.id, tick, 0)
	var collide_aim: int = sim.pattern_volley_seed(w.id, tick, 7919)
	var collide_pool: int = sim.pattern_volley_seed(w.id, tick, 4243)
	assert_ne(aim, collide_aim, "aim seed is not mix(world, id, tick+7919)")
	assert_ne(pool, collide_pool, "pool seed is not mix(world, id, tick+4243)")
	assert_ne(aim, pool)
	assert_ne(aim, volley)
	assert_ne(pool, volley)


func test_one_hit_crossing_both_thresholds_latches_t1_then_t2() -> void:
	var sim := _vault()
	var pid := _pid(sim)
	var w := _warden(sim)
	# Drop below the 33% mark in one P1 hit: Melt (t1) starts, not P2.
	sim.hurt_enemy(w.id, w.hp - 1815, pid)
	assert_eq(sim.get_enemy(w.id).hp, 1815)
	assert_eq(sim.get_enemy(w.id).phase_id(), "t1")
	assert_true(sim.get_enemy(w.id).invulnerable)
	# After Melt, P2 is entered and immediately latches Congeal (t2).
	for _i in range(40):
		sim.step()
	assert_eq(sim.get_enemy(w.id).phase_id(), "t2")
	assert_true(sim.get_enemy(w.id).invulnerable)
	# Congeal (t2) holds for 60 ticks, then P3.
	for _j in range(60):
		sim.step()
	assert_eq(sim.get_enemy(w.id).phase_id(), "p3")
	assert_false(sim.get_enemy(w.id).invulnerable)


func test_boss_rewards_are_not_granted_twice() -> void:
	var sim := _vault()
	var pid := _pid(sim)
	var w := _warden(sim)
	for i in range(4):
		_hold_fire(sim, pid, i + 1)
		sim.step()
	sim.hurt_enemy(w.id, w.hp, pid)
	assert_eq(sim.snapshot().pending_glint, 30)
	assert_eq(sim.snapshot().pending_riftstone, 4)
	assert_eq(sim.snapshot().ground_drops.size(), 2)
	var xp: int = sim.snapshot().xp_tenths
	# A second grant attempt (re-kill hook / extra step) must not add rewards.
	# Don't defeat_all here: Wick Kennels also has a Driftcap whose trash loot
	# would change the pending totals.
	sim.hurt_enemy(w.id, 1, pid)
	sim.step()
	assert_eq(sim.snapshot().pending_glint, 30)
	assert_eq(sim.snapshot().pending_riftstone, 4)
	assert_eq(sim.snapshot().ground_drops.size(), 2)
	assert_eq(sim.snapshot().xp_tenths, xp)


func test_player_carry_round_trips_pending_riftstone() -> void:
	var catalog := _catalog()
	var src := LocalSim.new(SimConfig.new(), 16.0, 16.0, catalog)
	src.set_lobby_settings(LobbySettings.new())
	var pid := _pid(src)
	var p := src.get_player(pid)
	p.pending_riftstone = 7
	p.pending_glint = 11
	p.xp_tenths = 40
	var carry := PlayerCarry.from_sim(p, src.ability_state(pid))
	assert_eq(carry.pending_riftstone, 7)
	var dst := LocalSim.new(SimConfig.new(), 6.0, 6.0, catalog)
	dst.set_lobby_settings(LobbySettings.new())
	if dst.get_player(pid) == null:
		assert_true(dst.add_player(pid, {"x": 6.0, "y": 6.0}))
		dst.step()
	dst.apply_carried_player(carry, 6.0, 6.0)
	var out := dst.get_player(pid)
	assert_eq(out.pending_riftstone, 7)
	assert_eq(out.pending_glint, 11)
	assert_eq(out.xp_tenths, 40)
	var carry2 := PlayerCarry.from_sim(out, dst.ability_state(pid))
	assert_eq(carry2.pending_riftstone, 7)


func test_acolytes_die_with_the_warden_no_rewards_and_death_flash() -> void:
	var sim := _vault()
	var pid := _pid(sim)
	var w := _warden(sim)
	sim.hurt_enemy(w.id, w.hp - 3630, pid)
	for _i in range(40):
		sim.step()
	assert_eq(sim.get_enemy(w.id).phase_id(), "p2")
	var acolyte_ids: Array[int] = []
	for e in sim.snapshot().enemies:
		if e.def_id == "waxen_acolyte":
			acolyte_ids.append(e.id)
	assert_eq(acolyte_ids.size(), 4)
	for i in range(4):
		_hold_fire(sim, pid, i + 1)
		sim.step()
	sim.hurt_enemy(w.id, sim.get_enemy(w.id).hp, pid)
	var living := 0
	var flashing := 0
	for e in sim.snapshot().enemies:
		if e.def_id != "waxen_acolyte":
			continue
		if e.alive:
			living += 1
		else:
			flashing += 1
			assert_gt(e.flash_ticks, 0, "adds play the normal death flash, they do not silently despawn")
	assert_eq(living, 0, "every living Waxen Acolyte dies on the Warden's death tick")
	assert_eq(flashing, 4)
	# Boss rewards only: no acolyte loot or XP (drops_loot is off).
	assert_eq(sim.snapshot().pending_glint, 30)
	assert_eq(sim.snapshot().pending_riftstone, 4)
	assert_eq(sim.snapshot().ground_drops.size(), 2)


func test_acolyte_third_cycle_fires_aim_and_sidesteps() -> void:
	var catalog := _catalog()
	var sim := LocalSim.new(SimConfig.new(), 8.0, 8.0, catalog)
	sim.set_lobby_settings(LobbySettings.new())
	sim.set_practice_yard(true)
	var pid := _pid(sim)
	sim.place_player(pid, 8.0, 8.0)
	var eid: int = sim.spawn_enemy("waxen_acolyte", 8.0, 10.0, 1)
	var saw_cross := 0
	var saw_aim := 0
	var saw_sidestep := false
	for _i in range(200):
		sim.step()
		var pids := sim.live_pattern_ids()
		if "acolyte_cross" in pids:
			saw_cross += 1
		if "acolyte_aim" in pids:
			saw_aim += 1
		for b in sim.snapshot().pattern_bullets:
			if b.pattern_id == "acolyte_aim":
				saw_aim += 1
		var st: EnemyState = sim.get_enemy(eid)
		if st != null and st.sidestep_left > 0:
			saw_sidestep = true
	var st_end: EnemyState = sim.get_enemy(eid)
	assert_not_null(st_end)
	assert_gte(st_end.fire_cycle, 3, "three fire cycles should have completed")
	assert_gt(saw_cross, 0, "the first cycles fire acolyte_cross")
	assert_gt(saw_aim, 0, "every third cycle fires acolyte_aim")
	assert_true(saw_sidestep, "the Acolyte starts a sidestep on its 60-tick timer")


func _practice_vault() -> LocalSim:
	var catalog := _catalog()
	var def := catalog.dungeon("hollowmere_vault")
	var sim := LocalSim.new(SimConfig.new(), 6.0, 6.0, catalog)
	sim.set_lobby_settings(LobbySettings.new())
	var pid := _pid(sim)
	var base: int = int(def.practice_yard_portal["practice_base_level"])
	sim.configure_dungeon(def, 42, 100, base, base, pid, base, def.practice_grants_persistent())
	var p := sim.get_player(pid)
	p.x = 36.0
	p.y = 6.0
	p.prev_x = p.x
	p.prev_y = p.y
	sim.step()
	return sim


func test_packed_grants_persistent_flags() -> void:
	var def := _catalog().dungeon("hollowmere_vault")
	assert_true(def.grants_persistent, "official vault runs grant persistent rewards")
	assert_false(def.practice_grants_persistent(), "the yard entrance does not")
	assert_true(def.practice_yard_portal.has("grants_persistent"))


func test_practice_warden_grants_nothing_and_carry_out_is_unchanged() -> void:
	var sim := _practice_vault()
	assert_false(sim.grants_persistent())
	var pid := _pid(sim)
	var p := sim.get_player(pid)
	var entry := PlayerCarry.from_sim(p, sim.ability_state(pid))
	entry.xp_tenths = 123
	entry.pending_glint = 8
	entry.pending_riftstone = 2
	var token := ItemState.new()
	token.drop_id = "practice-token"
	token.display_base = "Practice Token"
	token.tier = 1
	assert_true(entry.inventory.add(token))
	sim.apply_carried_player(entry, p.x, p.y)
	# Trash and the Warden both grant nothing that persists.
	var drift_id: int = 0
	for e in sim.snapshot().enemies:
		if e.def_id == "driftcap_spore":
			drift_id = e.id
			break
	if drift_id != 0:
		var cap: EnemyState = sim.get_enemy(drift_id)
		if cap != null:
			sim.hurt_enemy(drift_id, cap.hp, pid)
	var w := _warden(sim)
	assert_not_null(w)
	for i in range(4):
		_hold_fire(sim, pid, i + 1)
		sim.step()
	sim.hurt_enemy(w.id, sim.get_enemy(w.id).hp, pid)
	sim.step()
	assert_true(sim.boss_defeated())
	assert_true(sim.vault_exit_open())
	var after := sim.get_player(pid)
	assert_eq(after.xp_tenths, 123)
	assert_eq(after.pending_glint, 8)
	assert_eq(after.pending_riftstone, 2)
	assert_eq(sim.snapshot().ground_drops.size(), 0, "no loot bags in a practice vault")
	var out := sim.carry_out(pid)
	assert_eq(out.xp_tenths, 123)
	assert_eq(out.pending_glint, 8)
	assert_eq(out.pending_riftstone, 2)
	assert_eq(out.inventory.slots[0].drop_id, "practice-token")
	var extra := 0
	for item in out.inventory.slots:
		if item != null:
			extra += 1
	assert_eq(extra, 1, "no gear or item rolls leave a practice vault")


func test_non_practice_vault_still_grants_per_rule_7() -> void:
	var sim := _vault()
	assert_true(sim.grants_persistent())
	var pid := _pid(sim)
	var w := _warden(sim)
	for i in range(4):
		_hold_fire(sim, pid, i + 1)
		sim.step()
	sim.hurt_enemy(w.id, w.hp, pid)
	sim.step()
	assert_true(sim.boss_defeated())
	assert_eq(sim.snapshot().pending_glint, 30)
	assert_eq(sim.snapshot().pending_riftstone, 4)
	assert_eq(sim.snapshot().ground_drops.size(), 2)
	assert_gt(sim.snapshot().xp_tenths, 0)
	var out := sim.carry_out(pid)
	assert_eq(out.pending_glint, 30)
	assert_eq(out.pending_riftstone, 4)
	assert_gt(out.xp_tenths, 0)

