extends Control
## Entry scene: solo, listen-host, join, or a simple LAN lobby browser.
## Headless defaults to --host. Parse flags after `--`.


func _ready() -> void:
	var args := LobbyArgs.parse(OS.get_cmdline_user_args())
	var headless := DisplayServer.get_name() == "headless" or OS.has_feature("headless")
	if args.host or (headless and not args.is_join()):
		_start_host(args)
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
		_start_host(args)
		return
	_show_browser(args)


func _start_host(args: LobbyArgs) -> void:
	var settings := LobbySettings.new()
	settings.lobby_name = args.lobby_name
	settings.ws_port = args.port
	settings.bind_host = args.bind_host
	settings.allow_offline_imports = args.allow_offline_imports
	if args.join_code != "":
		settings.join_code = args.join_code.to_upper()
	if args.max_players > 0:
		settings.max_players = args.max_players
	else:
		settings.max_players = LobbySettings.default_max_for_listen()
	# Placeholder portals so the browser has multipliers to show in dev.
	if settings.open_portals.is_empty():
		settings.open_portals = [1.0] as Array[float]
	var bind := args.bind_host
	var err: Error = GameSession.start_host(settings, bind)
	if err != OK:
		push_warning("Failed to host on port %d (error %d)" % [settings.ws_port, err])


func _show_browser(args: LobbyArgs) -> void:
	var browser: Control = preload("res://src/render/lobby_browser.tscn").instantiate() as Control
	if browser.has_method("setup"):
		browser.setup(args)
	add_child(browser)


func _go_arena() -> void:
	get_tree().change_scene_to_file("res://src/render/arena.tscn")
