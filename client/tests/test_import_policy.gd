extends GutTest
## Import refusal uses the two §11.3/§11.5 settings and applies at import, not join.


func test_join_is_never_refused_by_import_policy() -> void:
	assert_eq(ImportPolicy.refuse_reason(false, true, false, false), "")


func test_imports_off_refuses_any_import() -> void:
	assert_eq(
		ImportPolicy.refuse_reason(true, false, false, true),
		ImportPolicy.REJECTED_IMPORTS_OFF
	)
	assert_eq(
		ImportPolicy.refuse_reason(true, true, false, true),
		ImportPolicy.REJECTED_IMPORTS_OFF
	)


func test_offline_off_refuses_only_offline_flagged_imports() -> void:
	assert_eq(
		ImportPolicy.refuse_reason(true, true, true, false),
		ImportPolicy.REJECTED_OFFLINE_OFF
	)
	assert_eq(ImportPolicy.refuse_reason(true, false, true, false), "")


func test_both_allowed_accepts_offline_import() -> void:
	assert_eq(ImportPolicy.refuse_reason(true, true, true, true), "")
