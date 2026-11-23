extends GutTest
## Remaining lobby UI: row format, ImportResult copy, invite-only listing,
## and the rejoin-token wrapper the UI uses on add/remove_local_player.


var _ui: LobbyUiSettings
var _host: LobbyHost


func before_each() -> void:
	_ui = LobbyUiSettings.load_default()


func after_each() -> void:
	if _host != null:
		_host.stop()
		_host = null


func test_pack_loads_without_fallbacks() -> void:
	assert_true(_ui.is_valid())
	assert_gt(_ui.min_target_mm, 0.0)
	assert_gt(_ui.assume_dpi, 0)
	assert_false(_ui.text("imports_ok").is_empty())


func test_missing_pack_is_invalid() -> void:
	var u := LobbyUiSettings.from_json({})
	assert_push_error("LobbyUiSettings: missing or empty lobby UI pack")
	assert_false(u.is_valid())


func test_import_messages_cover_every_import_result() -> void:
	var codes: PackedInt32Array = ImportResult.all()
	assert_gt(codes.size(), 0)
	for code in codes:
		var name: String = ImportResult.name_of(code)
		assert_ne(name, "UNKNOWN", "all() must not contain an unnamed code")
		assert_true(
			_ui.maps_import(code),
			"data/lobby_ui.json import_messages is missing %s" % name
		)
		var msg: String = _ui.import_message(code)
		assert_false(msg.is_empty(), "empty player-facing message for %s" % name)
		assert_ne(msg, name, "message for %s should be player-facing" % name)


func test_unknown_import_result_is_unmapped() -> void:
	assert_eq(ImportResult.name_of(9999), "UNKNOWN")
	assert_false(_ui.maps_import(9999))
	assert_eq(_ui.import_message(9999), "")


func test_feel_touch_sizes_override_when_present() -> void:
	var packed: Dictionary = DataCatalog._read_json(
		DataCatalog.repo_root().path_join("data/lobby_ui.json")
	)
	var u := LobbyUiSettings.from_json(packed, {"stick_thumb_mm": 20.0, "margin_mm": 9.0})
	assert_true(u.is_valid())
	assert_eq(u.min_target_mm, 20.0)
	assert_eq(u.margin_mm, 9.0)
	var baseline := LobbyUiSettings.from_json(packed, {})
	assert_true(baseline.is_valid())
	assert_eq(baseline.min_target_mm, float(packed["touch"]["min_target_mm"]))


func test_px_from_mm_uses_packed_assume_dpi_when_screen_dpi_is_zero() -> void:
	# Headless CI often reports 0 dpi; the packed assume_dpi is the size source.
	var px: int = _ui.px_from_mm(_ui.min_target_mm)
	assert_gt(px, 0)
	if DisplayServer.screen_get_dpi() <= 0:
		assert_eq(px, int(round(_ui.min_target_mm * float(_ui.assume_dpi) / 25.4)))


func test_row_shows_name_counts_m_range_and_import_flags() -> void:
	var row := LobbyRowFormat.format({
		"name": "Yard",
		"players": 3,
		"max": 50,
		"m100_min": 80,
		"m100_max": 120,
		"imports_allowed": true,
		"offline_allowed": true,
	}, _ui)
	assert_true(row.contains("Yard"), row)
	assert_true(row.contains("3/50"), row)
	assert_true(row.contains("×0.80") and row.contains("×1.20"), row)
	assert_true(row.contains(_ui.text("imports_ok")), row)
	assert_false(row.contains(_ui.text("invite_only")), row)
	assert_false(row.contains("ms"), row)


func test_row_import_flag_variants() -> void:
	assert_eq(
		LobbyRowFormat.imports_label({"imports_allowed": false, "offline_allowed": true}, _ui),
		_ui.text("imports_off")
	)
	assert_eq(
		LobbyRowFormat.imports_label({"imports_allowed": true, "offline_allowed": false}, _ui),
		_ui.text("imports_no_offline")
	)
	assert_eq(
		LobbyRowFormat.imports_label({"imports_allowed": true, "offline_allowed": true}, _ui),
		_ui.text("imports_ok")
	)


func test_row_invite_only_and_ping_only_when_provided() -> void:
	assert_false(LobbyRowFormat.is_invite_only({"name": "Yard"}))
	assert_true(LobbyRowFormat.is_invite_only({"invite_only": true}))
	assert_true(LobbyRowFormat.is_invite_only({"listed": false}))
	assert_false(LobbyRowFormat.is_invite_only({"listed": true}))
	var invited := LobbyRowFormat.format({
		"name": "Hidden",
		"players": 1,
		"max": 8,
		"m100_min": 100,
		"m100_max": 100,
		"imports_allowed": true,
		"offline_allowed": true,
		"invite_only": true,
		"ping_ms": 24,
	}, _ui)
	assert_true(invited.contains(_ui.text("invite_only")), invited)
	assert_true(invited.contains("24 ms"), invited)


func test_invite_only_config_is_not_broadcast_and_does_not_invent_beacon_fields() -> void:
	var cfg := LobbyConfig.new()
	cfg.invite_only = true
	cfg.broadcast_join_code = true
	cfg.host_settings.lobby_name = "Secret"
	cfg.host_settings.join_code = "AB12CD"
	assert_false(cfg.should_broadcast())
	var payload: Dictionary = cfg.to_beacon(1)
	assert_false(payload.has("invite_only"), "do not invent a beacon field")
	assert_false(payload.has("listed"), "do not invent a beacon field")
	assert_false(payload.has("ping_ms"))
	# The host still knows the code; listing it on the beacon stays opt-in.
	assert_eq(payload["code"], "AB12CD")
	cfg.invite_only = false
	assert_true(cfg.should_broadcast())
	cfg.broadcast_join_code = false
	assert_eq(cfg.to_beacon(1)["code"], "")


func test_args_invite_only_reaches_plan_host() -> void:
	var args := LobbyArgs.parse(PackedStringArray(["--host", "--invite-only"]))
	assert_true(args.invite_only)
	var d: Dictionary = LobbyArgs.plan_host(args, true)
	assert_true(d["ok"])
	assert_true(d["config"].invite_only)


func test_join_by_code_finds_a_lobby_even_if_it_is_marked_invite_only() -> void:
	# Once a beacon can carry listed=false, the browser hides the row but
	# find_by_code must still resolve it.
	var client := LobbyClient.new()
	client.lobbies.append({"name": "Visible", "code": "AAAAAA"})
	client.lobbies.append({"name": "Hidden", "code": "AB12CD", "invite_only": true})
	var info: Dictionary = client.find_by_code("ab12cd")
	assert_eq(String(info.get("name", "")), "Hidden")
	client.free()


func test_validate_reasons_join_for_inline_display() -> void:
	var s := LobbySettings.new()
	s.max_players = 0
	s.m100_min = 45
	var text := " ".join(s.validate())
	assert_true(text.contains("Max players must be between 1 and 50."))
	assert_true(text.contains("Level multipliers must be 0.50 to 1.50 in steps of 0.05."))


func test_local_join_wrapper_spends_the_rejoin_token_once() -> void:
	_host = LobbyHost.new(SimConfig.new())
	_host.port = 0
	assert_eq(_host.start(), OK)
	var join := LobbyLocalJoin.new()
	var id: int = join.add(_host, null)
	assert_gt(id, 0)
	assert_eq(join.token, "")
	var token: String = join.remove(_host, id)
	assert_ne(token, "")
	assert_eq(join.token, token)
	var back: int = join.add(_host, null)
	assert_eq(back, id, "token must be passed to add_local_player")
	assert_eq(join.token, "", "token is single use")
	# A later add without a stored token is a first join, not a replay.
	var other: int = join.add(_host, null)
	assert_gt(other, 0)
	assert_ne(other, id)
