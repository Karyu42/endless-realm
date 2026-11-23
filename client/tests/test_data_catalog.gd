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
