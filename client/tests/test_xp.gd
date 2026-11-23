extends GutTest
## Vision §3.4 XP curve: tenths, the published table, multi-level-up, high levels.


func _scaling() -> SimScaling:
	return DataCatalog.load_default().scaling


func test_xp_table_matches_vision() -> void:
	var s := _scaling()
	# Level L -> [m, killXP, xpToNext, total XP to reach L]
	var table := {
		1: [1.00, 10.0, 120, 0],
		10: [1.45, 14.5, 308, 1811],
		20: [1.95, 19.5, 564, 5997],
		50: [3.45, 34.5, 1642, 37427],
		100: [5.95, 59.5, 4358, 181591],
		500: [25.95, 259.5, 57473, 10830199],
		1000: [50.95, 509.5, 186302, 69097226],
	}
	for L in table.keys():
		var row: Array = table[L]
		assert_almost_eq(s.m(L), float(row[0]), 1e-12, "m(%d)" % L)
		assert_eq(s.kill_xp_tenths(L), int(round(float(row[1]) * 10.0)), "killXP(%d) tenths" % L)
		assert_eq(s.xp_to_next(L), int(row[2]), "xpToNext(%d)" % L)
		assert_eq(s.total_xp_to_reach(L), int(row[3]), "total XP to L%d" % L)


func test_on_level_kill_acceptance() -> void:
	var s := _scaling()
	# An on-level normal kill at L10 credits exactly 14.5 XP; a boss kill 725.0.
	assert_eq(s.credited_kill_tenths(10, 10, "normal"), 145)
	assert_eq(s.credited_kill_tenths(10, 10, "boss"), 7250)


func test_under_level_cap_and_over_level_penalty() -> void:
	var s := _scaling()
	# Under-level: credited as killXP(min(E, Le+10)). Le=25, E=40 -> killXP(35).
	assert_eq(s.credited_kill_tenths(40, 25, "normal"), s.kill_xp_tenths(35))
	# Over-level penalty at Le - E = 5: 1 - 0.05*5 = 0.75.
	# On-level killXP(10) is 145 tenths; at Le=15, E=10: 145 * 0.75 = 108.75 -> 109.
	assert_eq(s.credited_kill_tenths(10, 15, "normal"), 109)


func test_multi_level_up_from_one_grant() -> void:
	var catalog := DataCatalog.load_default()
	var cfg := SimConfig.new()
	cfg.fire_rate_shots_per_s = 0.0
	var sim := LocalSim.new(cfg, 0.0, 0.0, catalog)
	sim.set_player_class("thornguard")
	assert_eq(sim.player_level(), 1)
	# Total XP to reach L10 is 1,811; plus 5.0 leftover.
	var tenths: int = catalog.scaling.total_xp_to_reach(10) * 10 + 50
	var gained: int = sim.grant_xp_tenths(tenths)
	assert_eq(gained, 9)
	assert_eq(sim.player_level(), 10)
	assert_eq(sim.xp_tenths(), 50)
	# Thornguard 200 × m(10)=1.45 → 290, half-up integer hundredths.
	assert_eq(sim.snapshot().player_max_hp, 290)
	assert_eq(sim.snapshot().player_hp, 290)


func test_high_level_curve_does_not_overflow() -> void:
	var s := _scaling()
	var xp1000: int = s.xp_to_next(1000)
	var tot1000: int = s.total_xp_to_reach(1000)
	assert_eq(xp1000, 186302)
	assert_eq(tot1000, 69097226)
	# Past the 2^31 whole-XP crossing (~L 3,545). Values must stay positive
	# and inside signed int64.
	var xp4000: int = s.xp_to_next(4000)
	var tot4000: int = s.total_xp_to_reach(4000)
	assert_gt(xp4000, 0)
	assert_gt(tot4000, tot1000)
	assert_lt(tot4000, 9223372036854775807)
	assert_lt(xp4000 * 10, 9223372036854775807)
