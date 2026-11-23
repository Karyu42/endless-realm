extends GutTest
## Remaining lobby UI: row format, ImportResult copy, invite-only listing,
## and the rejoin-token wrapper the UI uses on add/remove_local_player.


var _ui: LobbyUiSettings
var _host: LobbyHost

const PB := preload("res://src/net/proto/protocol_v1_pb.gd")


func before_each() -> void:
	_ui = LobbyUiSettings.load_default()


func after_each() -> void:
	if _host != null:
		_host.stop()
		_host = null
	GameSession.clear_portal_error()
	GameSession.clear_join_error()
	GameSession.interact_pressed = false
	GameSession.interact_target_id = 0


func test_pack_loads_without_fallbacks() -> void:
	assert_true(_ui.is_valid())
	assert_gt(_ui.min_target_mm, 0.0)
	assert_gt(_ui.assume_dpi, 0)
	assert_false(_ui.text("imports_ok").is_empty())
	assert_false(_ui.text("name_placeholder").is_empty())
	assert_false(_ui.text("imports_allowed_check").is_empty())
	assert_false(_ui.text("lobby_full").is_empty())
	assert_ne(_ui.text("lobby_full"), _ui.error_message(PB.ErrorCode.INSTANCE_FULL))
	assert_gt(_ui.message_max_width_mm, 0.0)


func test_missing_pack_is_invalid() -> void:
	var u := LobbyUiSettings.from_json({})
	assert_push_error("LobbyUiSettings: missing or empty lobby UI pack")
	assert_false(u.is_valid())


func test_import_messages_cover_every_import_result() -> void:
	var codes: PackedInt32Array = ImportResult.all()
	assert_gt(codes.size(), 0)
	for code in codes:
		_assert_import_mapped(code, "all()")
	var script: Script = load("res://src/net/host/import_result.gd")
	var constants: Dictionary = script.get_script_constant_map()
	var seen := 0
	for key in constants.keys():
		var val: Variant = constants[key]
		if typeof(val) != TYPE_INT:
			continue
		seen += 1
		_assert_import_mapped(int(val), "constant map %s" % key)
	assert_gte(seen, codes.size(), "constant map must include every all() code")


func _assert_import_mapped(code: int, source: String) -> void:
	var name: String = ImportResult.name_of(code)
	assert_ne(name, "UNKNOWN", "%s: unnamed code %d" % [source, code])
	assert_true(
		_ui.maps_import(code),
		"data/lobby_ui.json import_messages is missing %s (%s)" % [name, source]
	)
	var msg: String = _ui.import_message(code)
	assert_false(msg.is_empty(), "empty player-facing message for %s (%s)" % [name, source])
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


func _start_host() -> void:
	_host = LobbyHost.new(SimConfig.new())
	_host.port = 0
	assert_eq(_host.start(), OK)


func _wait_ability_ready(id: int) -> void:
	for i in range(2000):
		if _host.sim.ability_cooldown_ticks(id) == 0 				and _host.sim.focus(id) >= float(_host.sim.focus_max(id)):
			return
		_host.run_tick()
	fail_test("ability never became ready")


func _assert_conservative(id: int) -> void:
	var cd_max: int = _host.sim.world_view(id).ability_cooldown_max
	assert_gt(cd_max, 0)
	assert_eq(_host.sim.ability_cooldown_ticks(id), cd_max)
	assert_almost_eq(_host.sim.focus(id), 0.0, 1e-6)


func _cast(id: int, seq: int) -> void:
	var it := InputIntent.from_raw(seq, 0.0, 0.0, 0.0, false)
	it.ability_pressed = true
	_host.submit_local_input(id, it)


func test_local_join_wrapper_spends_the_rejoin_token_once() -> void:
	_start_host()
	var join := LobbyLocalJoin.new()
	var id: int = join.add(_host, null)
	assert_gt(id, 0)
	assert_eq(join.token, "")
	assert_true(join.joined)
	var token: String = join.remove(_host, id)
	assert_ne(token, "")
	assert_eq(join.token, token)
	assert_true(join.left)
	assert_false(join.joined)
	var back: int = join.restore(_host, null)
	assert_eq(back, id, "token must be passed to add_local_player")
	assert_eq(join.token, "", "token is single use")
	assert_true(join.joined)


func test_add_while_joined_is_refused() -> void:
	_start_host()
	var join := LobbyLocalJoin.new()
	var id: int = join.add(_host, null)
	assert_gt(id, 0)
	assert_eq(join.add(_host, null), -1)
	assert_eq(_host.players.size(), 1)


func test_restore_without_a_prior_drop_is_refused() -> void:
	_start_host()
	var join := LobbyLocalJoin.new()
	assert_eq(join.restore(_host, null), -1)
	var id: int = join.add(_host, null)
	assert_gt(id, 0)
	assert_eq(join.restore(_host, null), -1)
	assert_eq(_host.players.size(), 1)
	assert_true(join.joined)


func test_second_leave_is_a_noop_and_keeps_the_token() -> void:
	_start_host()
	var join := LobbyLocalJoin.new()
	var id: int = join.add(_host, null)
	var token: String = join.remove(_host, id)
	assert_ne(token, "")
	assert_eq(join.remove(_host, id), token)
	assert_eq(join.token, token)
	assert_true(join.left)
	assert_false(join.joined)


func test_later_tokenless_add_is_conservative() -> void:
	_start_host()
	var join := LobbyLocalJoin.new()
	var first: int = join.add(_host, null)
	_host.run_tick()
	_assert_ready_or_first(first)
	join.remove(_host, first)
	join.token = ""
	var later: int = join.add(_host, null)
	assert_gt(later, 0)
	assert_ne(later, first)
	_host.run_tick()
	_assert_conservative(later)


func _assert_ready_or_first(id: int) -> void:
	assert_eq(_host.sim.ability_cooldown_ticks(id), 0)
	assert_almost_eq(_host.sim.focus(id), float(_host.sim.focus_max(id)), 1e-6)


func test_drop_restore_drop_drop_restore_keeps_ability_state() -> void:
	_start_host()
	var join := LobbyLocalJoin.new()
	var id: int = join.add(_host, null)
	_host.run_tick()
	_wait_ability_ready(id)
	_cast(id, 1)
	_host.run_tick()
	var cd: int = _host.sim.ability_cooldown_ticks(id)
	var focus: float = _host.sim.focus(id)
	assert_gt(cd, 0)
	assert_lt(focus, float(_host.sim.focus_max(id)))
	var token: String = join.remove(_host, id)
	assert_ne(token, "")
	assert_eq(join.restore(_host, null), id)
	assert_eq(_host.sim.ability_cooldown_ticks(id), cd)
	assert_almost_eq(_host.sim.focus(id), focus, 1e-6)
	var kept: String = join.remove(_host, id)
	assert_ne(kept, "")
	assert_eq(join.remove(_host, id), kept)
	assert_eq(join.token, kept)
	assert_eq(join.restore(_host, null), id)
	assert_eq(_host.sim.ability_cooldown_ticks(id), cd)
	assert_almost_eq(_host.sim.focus(id), focus, 1e-6)



func test_error_messages_cover_each_portal_code() -> void:
	var codes: PackedInt32Array = ErrorCodes.packed()
	assert_eq(codes.size(), 3)
	assert_true(codes.has(PB.ErrorCode.MULTIPLIER_NOT_ALLOWED))
	assert_true(codes.has(PB.ErrorCode.INSTANCE_FULL))
	assert_true(codes.has(PB.ErrorCode.INSTANCE_NOT_FOUND))
	for code in codes:
		var name: String = ErrorCodes.name_of(code)
		assert_ne(name, "UNKNOWN", "unnamed ErrorCode %d" % code)
		assert_true(
			_ui.maps_error(code),
			"data/lobby_ui.json error_messages is missing %s" % name
		)
		var msg: String = _ui.error_message(code)
		assert_false(msg.is_empty(), "empty player-facing message for %s" % name)
		assert_ne(msg, name, "message for %s should be player-facing" % name)
		assert_false(msg.contains(name), "message for %s should be original copy" % name)


func test_unknown_error_code_is_logged_and_unmapped() -> void:
	assert_eq(ErrorCodes.name_of(9999), "UNKNOWN")
	assert_false(_ui.maps_error(9999))
	assert_eq(_ui.error_message(9999), "")
	assert_eq(ErrorCodes.catalog_id(9999), "ErrorCode.9999")
	var text: String = GameSession.apply_portal_error(9999)
	assert_push_error("DataCatalog: unknown id ErrorCode.9999")
	assert_eq(text, "")
	assert_eq(GameSession.portal_error_text, "")


func test_apply_portal_error_shows_packed_copy_not_the_host_reason() -> void:
	for code in ErrorCodes.packed():
		GameSession.interact_pressed = true
		GameSession.interact_target_id = 77
		var text: String = GameSession.apply_portal_error(code)
		assert_eq(text, _ui.error_message(code))
		assert_eq(GameSession.portal_error_text, _ui.error_message(code))
		assert_eq(GameSession.portal_error_code, code)
		assert_false(GameSession.interact_pressed, "interact is cleared so the player can retry")
		assert_eq(GameSession.interact_target_id, 0)
		GameSession.clear_portal_error()


func test_portal_rejected_for_the_local_player_applies_the_message() -> void:
	var pid: int = GameSession.local_player_id
	GameSession.interact_pressed = true
	GameSession.interact_target_id = 12
	GameSession._on_host_portal_rejected(pid, PB.ErrorCode.INSTANCE_NOT_FOUND, "portal entrance is closed")
	assert_eq(GameSession.portal_error_text, _ui.error_message(PB.ErrorCode.INSTANCE_NOT_FOUND))
	assert_false(GameSession.portal_error_text.contains("portal entrance is closed"))
	assert_false(GameSession.interact_pressed)
	assert_eq(GameSession.interact_target_id, 0)
	# A rejection for someone else does not overwrite the local player's message.
	GameSession._on_host_portal_rejected(pid + 99, PB.ErrorCode.INSTANCE_FULL, "ignored")
	assert_eq(GameSession.portal_error_text, _ui.error_message(PB.ErrorCode.INSTANCE_NOT_FOUND))


func _welcome(client: LobbyClient, pid: int = 7) -> void:
	var msg = PB.ServerMessage.new()
	msg.new_welcome().set_player_id(pid)
	client._on_packet(msg.to_bytes())


func test_lobby_client_error_reply_emits_each_code_and_is_not_a_join_reject() -> void:
	for code in ErrorCodes.packed():
		var client := LobbyClient.new()
		var got_code: Array = [-1]
		var join_code: Array = [-1]
		var rejected: Array = [false]
		client.error_received.connect(func(c: int, _reason: String) -> void:
			got_code[0] = c
		)
		client.join_error_received.connect(func(c: int, _reason: String) -> void:
			join_code[0] = c
		)
		client.rejected.connect(func(_reason: String) -> void:
			rejected[0] = true
		)
		_welcome(client)
		var msg = PB.ServerMessage.new()
		var err = msg.new_error()
		err.set_code(code)
		err.set_reason("host reason must not become a join reject")
		client._on_packet(msg.to_bytes())
		assert_eq(got_code[0], code)
		assert_eq(join_code[0], -1, "mid-session ErrorReply must not emit join_error_received")
		assert_eq(client.last_error_code, code)
		assert_false(rejected[0], "ErrorReply must not emit rejected")
		client.free()


func test_lobby_client_join_reject_still_emits_rejected() -> void:
	var client := LobbyClient.new()
	var rejected: Array = [false]
	var errors: Array = [0]
	client.rejected.connect(func(reason: String) -> void:
		rejected[0] = true
		assert_eq(reason, "full lobby")
	)
	client.error_received.connect(func(_c: int, _r: String) -> void:
		errors[0] += 1
	)
	client.join_error_received.connect(func(_c: int, _r: String) -> void:
		errors[0] += 1
	)
	var msg = PB.ServerMessage.new()
	msg.new_reject().set_reason("full lobby")
	client._on_packet(msg.to_bytes())
	assert_true(rejected[0])
	assert_eq(errors[0], 0)
	client.free()

func test_hello_time_instance_full_uses_lobby_full_not_portal_copy() -> void:
	var client := LobbyClient.new()
	var portal_codes: Array = []
	var join_codes: Array = []
	var rejected: Array = [false]
	client.error_received.connect(func(c: int, _reason: String) -> void:
		portal_codes.append(c)
	)
	client.join_error_received.connect(func(c: int, _reason: String) -> void:
		join_codes.append(c)
	)
	client.rejected.connect(func(_reason: String) -> void:
		rejected[0] = true
	)
	assert_eq(client.player_id, 0)
	var msg = PB.ServerMessage.new()
	var err = msg.new_error()
	err.set_code(PB.ErrorCode.INSTANCE_FULL)
	err.set_reason("lobby is full")
	client._on_packet(msg.to_bytes())
	assert_eq(join_codes, [PB.ErrorCode.INSTANCE_FULL])
	assert_eq(portal_codes, [])
	assert_false(rejected[0])
	var text: String = GameSession.apply_join_error(PB.ErrorCode.INSTANCE_FULL)
	assert_eq(text, _ui.text("lobby_full"))
	assert_eq(GameSession.join_error_text, _ui.text("lobby_full"))
	assert_ne(text, _ui.error_message(PB.ErrorCode.INSTANCE_FULL))
	assert_eq(GameSession.portal_error_text, "")
	assert_false(text.contains("area is full"))
	client.free()


func test_mid_session_instance_full_still_uses_portal_copy() -> void:
	var client := LobbyClient.new()
	_welcome(client)
	GameSession._on_client_portal_error(PB.ErrorCode.INSTANCE_FULL, "lobby is full")
	assert_eq(GameSession.portal_error_text, _ui.error_message(PB.ErrorCode.INSTANCE_FULL))
	assert_eq(GameSession.join_error_text, "")
	assert_ne(GameSession.portal_error_text, _ui.text("lobby_full"))
	client.free()


func test_hello_time_unspecified_is_left_alone() -> void:
	var text: String = GameSession.apply_join_error(PB.ErrorCode.ERROR_CODE_UNSPECIFIED)
	assert_eq(text, "")
	assert_eq(GameSession.join_error_text, "")
	assert_eq(GameSession.portal_error_text, "")


func test_message_label_wraps_on_a_narrow_android_width() -> void:
	var viewport_w := 360.0
	var w: int = _ui.message_max_width_px(viewport_w)
	assert_gt(w, 0)
	assert_lte(w, int(viewport_w))
	assert_lte(w, _ui.px_from_mm(_ui.message_max_width_mm))
	var label := Label.new()
	label.add_theme_font_size_override("font_size", 18)
	add_child_autofree(label)
	assert_eq(_ui.apply_message_label(label, viewport_w), w)
	assert_eq(label.autowrap_mode, TextServer.AUTOWRAP_WORD_SMART)
	assert_eq(int(label.custom_minimum_size.x), w)
	label.text = "%s  ·  E to enter Hollowmere Vault  ·  E1  ×1.00" % _ui.error_message(PB.ErrorCode.INSTANCE_FULL)
	await get_tree().process_frame
	var wrapped: Vector2 = label.get_minimum_size()
	assert_lte(wrapped.x, float(w) + 1.0)
	var one := Label.new()
	one.add_theme_font_size_override("font_size", 18)
	one.text = "A"
	add_child_autofree(one)
	await get_tree().process_frame
	assert_gt(wrapped.y, one.get_minimum_size().y, "long prompt must wrap to more than one line")

