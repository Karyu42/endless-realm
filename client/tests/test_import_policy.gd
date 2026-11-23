extends GutTest
## Host allow/refuse of played_offline imports.


func test_offline_import_allowed_when_host_allows() -> void:
	assert_true(ImportPolicy.allows(true, true))
	var r := Handshake.evaluate(SimConstants.PROTOCOL_VERSION, true, true, 1, 50, 2, 1, 1.0)
	assert_true(r["ok"])


func test_offline_import_refused_when_host_refuses() -> void:
	assert_false(ImportPolicy.allows(true, false))
	var r := Handshake.evaluate(SimConstants.PROTOCOL_VERSION, true, false, 1, 50, 2, 1, 1.0)
	assert_false(r["ok"])
	assert_eq(r["reason"], Handshake.REASON_IMPORT_REFUSED)
	assert_eq(r["reject"]["reason"], Handshake.REASON_IMPORT_REFUSED)


func test_online_character_is_always_allowed() -> void:
	assert_true(ImportPolicy.allows(false, false))
	var r := Handshake.evaluate(SimConstants.PROTOCOL_VERSION, false, false, 1, 50, 2, 1, 1.0)
	assert_true(r["ok"])
