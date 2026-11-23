extends Control
## Entry scene: solo, listen-host, join, or a simple LAN lobby browser.
## Headless does not host unless `--host` is passed, so the CI smoke run
## (no user args) stays a quiet practice-yard boot.
## An invalid `--max-players` / ER_MAX_PLAYERS exits 2 when headless (same
## as host_main) and stays on the browser, with the error shown, when a
## display is attached.


func _ready() -> void:
	var args := LobbyArgs.parse(OS.get_cmdline_user_args())
	var headless := DisplayServer.get_name() == "headless" or OS.has_feature("headless")
	if args.host:
		var decision: Dictionary = LobbyArgs.plan_host(args, headless)
		if not bool(decision["ok"]):
			var err: String = String(decision["error"])
			if headless:
				printerr(err)
				get_tree().quit(int(decision["exit_code"]))
				return
			_show_browser(args, err)
			return
		var cfg: LobbyConfig = decision["config"]
		var start_err: Error = GameSession.start_host(cfg, args.bind_host)
		if start_err != OK:
			var listen_err := "HOST_ERROR listen failed: error %d" % start_err
			if headless:
				printerr(listen_err)
				get_tree().quit(1)
				return
			_show_browser(args, listen_err)
			return
		if not headless:
			_go_arena()
		return
	if args.join_url != "":
		GameSession.start_client(args.join_url, args.played_offline, args.join_code)
		_go_arena()
		return
	if args.join_code != "":
		# Show the browser so a matching LAN beacon can complete the join.
		_show_browser(args)
		return
	if headless:
		# Do not default-host. GameSession already started solo in _ready.
		return
	_show_browser(args)


func _show_browser(args: LobbyArgs, error_text: String = "") -> void:
	var browser: Control = preload("res://src/render/lobby_browser.tscn").instantiate() as Control
	if browser.has_method("setup"):
		browser.setup(args, error_text)
	add_child(browser)


func _go_arena() -> void:
	get_tree().change_scene_to_file("res://src/render/arena.tscn")
