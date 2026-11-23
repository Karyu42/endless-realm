extends GutTest
## Driftcap Spore: rooted, timer spore_ring, no contact, alternating start angle.


func _catalog() -> DataCatalog:
	return DataCatalog.load_default()


func _sim_at(x: float, y: float) -> LocalSim:
	var cfg := SimConfig.new()
	cfg.move_speed_tiles_per_s = 0.0
	cfg.fire_rate_shots_per_s = 0.0
	cfg.player_max_hp = 200
	cfg.contact_cooldown_ticks = 10
	var sim := LocalSim.new(cfg, x, y, _catalog())
	sim.set_world_seed(1)
	return sim


func test_packed_driftcap_stats_match_content_spec() -> void:
	var e := _catalog().enemy("driftcap_spore")
	assert_not_null(e)
	assert_true(e.is_rooted())
	assert_eq(e.base_hp, 90)
	assert_almost_eq(e.base_ward, 2.0, 0.0)
	assert_eq(e.contact_damage, 0)
	assert_eq(e.damage_for("ring"), 12)
	assert_almost_eq(e.move_speed, 0.0, 0.0)
	assert_almost_eq(e.radius, 0.50, 0.0)
	assert_almost_eq(e.aggro_radius, 8.0, 0.0)
	assert_eq(e.pattern_id, "spore_ring")
	assert_eq(e.fire_interval_ticks, 40)
	var p := _catalog().pattern("spore_ring")
	assert_not_null(p)
	assert_eq(p.type, "ring")
	assert_eq(p.count, 8)
	assert_eq(p.aim, "fixed")
	assert_eq(p.size, "M")
	assert_almost_eq(p.speed, 4.0, 0.0)
	assert_almost_eq(p.range_tiles, 5.0, 0.0)
	assert_eq(p.trigger, "timer")
	assert_eq(p.interval_ticks, 40)
	assert_eq(p.angle_offset_cycle_deg.size(), 2)
	assert_almost_eq(p.angle_offset_cycle_deg[0], 0.0, 0.0)
	assert_almost_eq(p.angle_offset_cycle_deg[1], 22.5, 0.0)
	assert_eq(PatternDef.lifetime_ticks(5.0, 4.0), 25)
	assert_almost_eq(PatternDef.size_radius("M"), 0.25, 0.0)


func test_driftcap_stays_rooted_and_fires_first_ring_after_two_seconds() -> void:
	# Player at (0,0), spore at (3,0): inside the 8-tile aggro, first fire after 40 ticks.
	var sim := _sim_at(0.0, 0.0)
	var id := sim.spawn_enemy("driftcap_spore", 3.0, 0.0)
	assert_gt(id, 0)
	var start_x: float = 3.0
	var start_y: float = 0.0
	for _i in range(40):
		sim.step()
		assert_eq(sim.snapshot().pattern_bullets.size(), 0, "first ring waits 40 ticks after aggro")
	assert_almost_eq(sim.snapshot().enemies[0].x, start_x, 1e-12)
	assert_almost_eq(sim.snapshot().enemies[0].y, start_y, 1e-12)
	sim.step()
	var bullets: Array = sim.snapshot().pattern_bullets
	assert_eq(bullets.size(), 8)
	# Volley 0: 45° apart, start 0° (fixed, not aimed at the player).
	var angles: Array[float] = []
	for b in bullets:
		assert_eq(b.pattern_id, "spore_ring")
		assert_almost_eq(b.radius_tiles, 0.25, 0.0)
		angles.append(b.angle_rad)
	angles.sort()
	for i in range(8):
		assert_almost_eq(angles[i], deg_to_rad(float(i) * 45.0), 1e-9)
	# Still rooted after the volley.
	assert_almost_eq(sim.snapshot().enemies[0].x, start_x, 1e-12)
	assert_almost_eq(sim.snapshot().enemies[0].y, start_y, 1e-12)


func test_second_spore_ring_fills_the_gaps() -> void:
	var sim := _sim_at(0.0, 0.0)
	sim.spawn_enemy("driftcap_spore", 3.0, 0.0)
	for _i in range(81):
		sim.step()
	# First ring expires after 25 ticks; the second is live at tick 81 (fired on 80).
	var bullets: Array = sim.snapshot().pattern_bullets
	assert_eq(bullets.size(), 8)
	var angles: Array[float] = []
	for b in bullets:
		angles.append(b.angle_rad)
	angles.sort()
	for i in range(8):
		assert_almost_eq(angles[i], deg_to_rad(22.5 + float(i) * 45.0), 1e-9)


func test_driftcap_contact_deals_no_damage() -> void:
	var sim := _sim_at(0.0, 0.0)
	sim.spawn_enemy("driftcap_spore", 0.2, 0.0)
	var hp: int = sim.snapshot().player_hp
	for _i in range(20):
		sim.step()
	assert_eq(sim.snapshot().player_hp, hp)
	assert_eq(sim.snapshot().enemies[0].x, 0.2)
	assert_eq(sim.snapshot().enemies[0].y, 0.0)


func test_missing_rooted_interval_is_reported() -> void:
	var catalog := _catalog()
	assert_eq(catalog.unknown_reference_ids().size(), 0)
	var raw := {
		"id": "driftcap_spore",
		"name": "Driftcap Spore",
		"rank": "normal",
		"base": {"hp": 90, "ward": 2, "contact": 0, "damage": {"ring": 12}},
		"move_speed": 0,
		"radius": 0.50,
		"aggro_radius": 8.0,
		"ai": {"type": "rooted", "pattern": "spore_ring"},
	}
	catalog.enemies["driftcap_spore"] = EnemyDef.from_json(raw)
	var ids := catalog.unknown_reference_ids()
	assert_true("driftcap_spore.ai.fire_interval_ticks" in ids)
	catalog.report_unknown_ids()
	assert_push_error("DataCatalog: unknown id driftcap_spore.ai.fire_interval_ticks")
