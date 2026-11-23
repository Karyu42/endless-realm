extends GutTest
## Packed res://data is what editor and export both load.


func test_packed_data_loads_burrmite() -> void:
	assert_true(FileAccess.file_exists("res://data/enemies.json"), "res://data/enemies.json must be packed")
	assert_true(FileAccess.file_exists("res://data/patterns.json"), "res://data/patterns.json must be packed")
	var catalog := DataCatalog.load_default()
	var enemy := catalog.enemy("burrmite")
	assert_not_null(enemy, "burrmite must load from res://data")
	assert_eq(enemy.pattern_id, "burr_spit")
	assert_eq(enemy.base_hp, 60)
	assert_eq(enemy.aggro_radius, 8.0)
	assert_eq(enemy.deaggro_radius, 12.0, "explicit aggro+4, not the implicit default")
	assert_eq(enemy.deaggro_range(), 12.0)
	var spit := catalog.pattern("burr_spit")
	assert_not_null(spit)
	assert_eq(spit.damage_key, "spit")
	assert_eq(spit.size, "S")
	assert_almost_eq(PatternDef.size_radius(spit.size), 0.15, 0.0)


func test_packed_data_loads_loot_and_scaling() -> void:
	assert_true(FileAccess.file_exists("res://data/loot.json"))
	assert_true(FileAccess.file_exists("res://data/scaling.json"))
	assert_true(FileAccess.file_exists("res://data/classes.json"))
	var catalog := DataCatalog.load_default()
	assert_not_null(catalog.loot)
	assert_eq(catalog.loot.item_chance_pct("normal"), 4)
	assert_eq(catalog.scaling.xp_to_next(10), 308)
	assert_not_null(catalog.class_def("thornguard"))
	assert_eq(catalog.class_def("thornguard").base_hp, 200)


func test_packed_data_has_no_unknown_ids() -> void:
	var catalog := DataCatalog.load_default()
	assert_eq(catalog.unknown_reference_ids().size(), 0)
	assert_eq(catalog.scaling.interact_prompt_range_tiles, 1.5)
	assert_eq(catalog.scaling.interact_accept_range_tiles, 2.0)
	assert_eq(catalog.scaling.practice_yard_content_level, 1)
	assert_eq(catalog.loot.charm_id, "ember_charm")
	assert_eq(catalog.loot.charm_name, "Ember Charm")
	assert_eq(catalog.loot.charm_hp_coef(), 20.0)


func test_unknown_loot_ids_are_reported() -> void:
	var catalog := DataCatalog.load_default()
	catalog.loot.rank_tables["boss"] = "no_such_table"
	var ids := catalog.unknown_reference_ids()
	assert_true("no_such_table" in ids)
	catalog.report_unknown_ids()
	assert_push_error("DataCatalog: unknown id no_such_table")


func test_missing_ability_effect_fields_are_reported() -> void:
	var catalog := DataCatalog.load_default()
	assert_eq(catalog.unknown_reference_ids().size(), 0)
	var raw := {
		"id": "thorn_ward",
		"name": "Thorn Ward",
		"class_id": "thornguard",
		"focus_cost": 40,
		"cooldown_ticks": 160,
		"damage_taken_mult": 0.5,
	}
	catalog.abilities["thorn_ward"] = AbilityDef.from_json(raw)
	var ids := catalog.unknown_reference_ids()
	assert_true("thorn_ward.duration_ticks" in ids)
	catalog.report_unknown_ids()
	assert_push_error("DataCatalog: unknown id thorn_ward.duration_ticks")


func test_missing_slipstep_invuln_is_reported() -> void:
	var catalog := DataCatalog.load_default()
	var raw := {
		"id": "slipstep",
		"name": "Slipstep",
		"class_id": "driftrunner",
		"focus_cost": 30,
		"cooldown_ticks": 60,
		"blink_tiles": 4.0,
	}
	catalog.abilities["slipstep"] = AbilityDef.from_json(raw)
	var ids := catalog.unknown_reference_ids()
	assert_true("slipstep.invuln_ticks" in ids)
	catalog.report_unknown_ids()
	assert_push_error("DataCatalog: unknown id slipstep.invuln_ticks")
