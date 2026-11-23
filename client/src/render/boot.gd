extends Control
## Entry scene: solo, listen-host, join, or a simple LAN lobby browser.
## Headless does not host unless `--host` is passed, so the CI smoke run
## (no user args) stays a quiet practice-yard boot.


func _ready() -> void:
	var args := LobbyArgs.parse(OS.get_cmdline_user_args())
	var headless := DisplayServer.get_name() == "headless" or OS.has_feature("headless")
	if args.host:
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
		# Do not default-host. GameSession already started solo in _ready.
		return
	_show_browser(args)


func _start_host(args: LobbyArgs) -> void:
	var settings := LobbySettings.new()
	settings.lobby_name = args.lobby_name
	settings.ws_port = args.port
	settings.bind_host = args.bind_host
	settings.allow_imports = args.allow_imports
	settings.allow_offline_imports = args.allow_offline_imports
	settings.broadcast_join_code = args.broadcast_join_code
	if args.join_code != "":
		settings.join_code = args.join_code.to_upper()
	if args.max_players_raw != "":
		if not settings.try_set_max_players(args.max_players_raw):
			push_warning("Max players must be an integer from 1 to 50, got %s" % args.max_players_raw)
			return
	if settings.open_portals.is_empty():
		settings.open_portals = [1.0] as Array[float]
	var err: Error = GameSession.start_host(settings, args.bind_host)
	if err != OK:
		push_warning("Failed to host on port %d (error %d)" % [settings.ws_port, err])


func _show_browser(args: LobbyArgs) -> void:
	var browser: Control = preload("res://src/render/lobby_browser.tscn").instantiate() as Control
	if browser.has_method("setup"):
		browser.setup(args)
	add_child(browser)


func _go_arena() -> void:
	get_tree().change_scene_to_file("res://src/render/arena.tscn")
