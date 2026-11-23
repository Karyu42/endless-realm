extends GutTest
## Golden closed-form pattern positions shared with server/internal/sim.

const EPS := 1e-9


func test_burr_spit_lifetime_is_twenty() -> void:
	assert_eq(PatternDef.lifetime_ticks(6.0, 6.0), 20)


func test_size_radii() -> void:
	assert_almost_eq(PatternDef.size_radius("S"), 0.15, 0.0)
	assert_almost_eq(PatternDef.size_radius("M"), 0.25, 0.0)
	assert_almost_eq(PatternDef.size_radius("L"), 0.40, 0.0)


func test_pattern_fixtures() -> void:
	var catalog := DataCatalog.load_default()
	assert_gt(catalog.patterns.size(), 0, "data/patterns.json did not load")
	var dir := DataCatalog.repo_root().path_join("fixtures/patterns")
	var files := DirAccess.get_files_at(dir)
	assert_gt(files.size(), 0, "no pattern fixtures")
	for fname in files:
		if not fname.ends_with(".json"):
			continue
		var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(dir.path_join(fname)))
		assert_true(parsed is Dictionary, fname)
		for c in parsed["cases"]:
			_assert_case(catalog, String(c.get("name", fname)), c)


func _assert_case(catalog: DataCatalog, name: String, c: Dictionary) -> void:
	var def := catalog.pattern(String(c["pattern_id"]))
	assert_not_null(def, "%s: unknown pattern" % name)
	var seed := int(c["seed"])
	var spawn_tick := int(c["spawn_tick"])
	var origin: Array = c["origin"]
	var aim := float(c["aim_rad"])
	var volley := int(c.get("volley_index", 0))
	var bullets := def.emit(seed, float(origin[0]), float(origin[1]), aim, volley)
	for b in bullets:
		b.spawn_tick = spawn_tick
	var expected: Dictionary = c["expected"]
	for tick_v in c["ticks"]:
		var tick := int(tick_v)
		var want: Array = expected[str(tick)]
		var got: Array[PatternBullet] = []
		for b in bullets:
			if b.is_alive_at(tick):
				got.append(b)
		assert_eq(got.size(), want.size(), "%s tick %d count" % [name, tick])
		for i in range(want.size()):
			var w: Dictionary = want[i]
			if w.has("index"):
				assert_eq(got[i].index, int(w["index"]), "%s tick %d index" % [name, tick])
			var pos := got[i].position_at_time(float(tick))
			assert_almost_eq(pos.x, float(w["x"]), EPS, "%s tick %d x" % [name, tick])
			assert_almost_eq(pos.y, float(w["y"]), EPS, "%s tick %d y" % [name, tick])
