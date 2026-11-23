extends GutTest
## Official PCG-XSH-RR 64/32 known vectors from fixtures/pcg32/known.json.


func test_known_vectors_match_fixtures() -> void:
	var path := DataCatalog.repo_root().path_join("fixtures/pcg32/known.json")
	assert_true(FileAccess.file_exists(path), "missing %s" % path)
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	assert_true(parsed is Dictionary)
	var cases: Variant = parsed["cases"]
	assert_true(cases is Array)
	assert_gt((cases as Array).size(), 0)
	for c in cases:
		var initstate := int(c["initstate"])
		var initseq := int(c["initseq"])
		var rng := PCG32.new(initstate, initseq)
		var values: Array = c["values"]
		for i in range(values.size()):
			var got: int = rng.uint32()
			var want: int = int(values[i])
			assert_eq(got, want, "init(%s,%s) [%d]" % [c["initstate"], c["initseq"], i])
