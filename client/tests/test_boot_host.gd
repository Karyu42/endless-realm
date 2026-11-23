extends GutTest
## Boot/listen-host max-players policy: headless exits 2, display stays on
## the browser, and --max-players wins over ER_MAX_PLAYERS.


func after_each() -> void:
	OS.unset_environment(LobbyArgs.ENV_MAX_PLAYERS)


func test_headless_invalid_flag_exits_2() -> void:
	var args := LobbyArgs.parse(PackedStringArray(["--host", "--max-players=99"]))
	var d: Dictionary = LobbyArgs.plan_host(args, true)
	assert_false(d["ok"])
	assert_eq(d["exit_code"], 2)
	assert_false(d["stay_on_browser"])
	assert_true(String(d["error"]).contains("99"))


func test_headless_invalid_space_flag_exits_2() -> void:
	var args := LobbyArgs.parse(PackedStringArray(["--host", "--max-players", "0"]))
	var d: Dictionary = LobbyArgs.plan_host(args, true)
	assert_false(d["ok"])
	assert_eq(d["exit_code"], 2)


func test_display_invalid_flag_stays_on_browser() -> void:
	var args := LobbyArgs.parse(PackedStringArray(["--host", "--max-players=99"]))
	var d: Dictionary = LobbyArgs.plan_host(args, false)
	assert_false(d["ok"])
	assert_eq(d["exit_code"], 0)
	assert_true(d["stay_on_browser"])
	assert_true(String(d["error"]).contains("99"))


func test_er_max_players_is_honoured_when_flag_is_absent() -> void:
	OS.set_environment(LobbyArgs.ENV_MAX_PLAYERS, "8")
	var args := LobbyArgs.parse(PackedStringArray(["--host"]))
	assert_eq(args.max_players_raw, "8")
	assert_eq(args.max_players_source, LobbyArgs.ENV_MAX_PLAYERS)
	var d: Dictionary = LobbyArgs.plan_host(args, true)
	assert_true(d["ok"])
	assert_eq(d["exit_code"], 0)
	assert_eq(d["config"].host_settings.max_players, 8)


func test_invalid_env_without_flag_exits_2_headless_and_stays_on_display() -> void:
	OS.set_environment(LobbyArgs.ENV_MAX_PLAYERS, "99")
	var args := LobbyArgs.parse(PackedStringArray(["--host"]))
	var headless: Dictionary = LobbyArgs.plan_host(args, true)
	assert_false(headless["ok"])
	assert_eq(headless["exit_code"], 2)
	var display: Dictionary = LobbyArgs.plan_host(args, false)
	assert_false(display["ok"])
	assert_true(display["stay_on_browser"])
	assert_eq(display["exit_code"], 0)


func test_flag_wins_over_er_max_players() -> void:
	OS.set_environment(LobbyArgs.ENV_MAX_PLAYERS, "8")
	var args := LobbyArgs.parse(PackedStringArray(["--host", "--max-players=20"]))
	assert_eq(args.max_players_raw, "20")
	assert_eq(args.max_players_source, "--max-players")
	var d: Dictionary = LobbyArgs.plan_host(args, true)
	assert_true(d["ok"])
	assert_eq(d["config"].host_settings.max_players, 20)


func test_flag_wins_when_env_is_invalid() -> void:
	OS.set_environment(LobbyArgs.ENV_MAX_PLAYERS, "99")
	var args := LobbyArgs.parse(PackedStringArray(["--host", "--max-players=20"]))
	var d: Dictionary = LobbyArgs.plan_host(args, true)
	assert_true(d["ok"], "valid flag must win over an invalid env")
	assert_eq(d["config"].host_settings.max_players, 20)


func test_valid_flag_defaults_and_blank_env_start() -> void:
	var args := LobbyArgs.parse(PackedStringArray(["--host"]))
	var d: Dictionary = LobbyArgs.plan_host(args, true)
	assert_true(d["ok"])
	assert_eq(d["config"].host_settings.max_players, LobbyHost.DEFAULT_MAX_PLAYERS)


func test_headless_process_exits_2_on_max_players_99() -> void:
	# Same entry as a packaged boot: main scene, --host --max-players=99.
	var argv := PackedStringArray([
		"--headless", "--path", ProjectSettings.globalize_path("res://"),
		"--quit-after", "8", "--", "--host", "--bind=127.0.0.1", "--max-players=99",
	])
	var out: Array = []
	var code: int = OS.execute(OS.get_executable_path(), argv, out, true)
	assert_eq(code, 2, "boot --headless --host --max-players=99 should exit 2")


func test_beacon_player_count_never_reports_51_of_50() -> void:
	# player_count already includes the listen host (add_local_player).
	assert_eq(LobbyConfig.beacon_player_count(1, 50), 1)
	assert_eq(LobbyConfig.beacon_player_count(50, 50), 50)
	assert_eq(LobbyConfig.beacon_player_count(51, 50), 50)
