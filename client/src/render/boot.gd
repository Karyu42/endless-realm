extends Control
## Entry scene: solo, listen-host, join, or a simple LAN lobby browser.
## Headless does not host unless `--host` is passed, so the CI smoke run
## (no user args) stays a quiet practice-yard boot.
## An invalid `--max-players` / ER_MAX_PLAYERS exits 2 when headless (same
## as host_main) and stays on the browser, with the error shown, when a
## display is attached.

var _args: LobbyArgs
var _headless: bool = false


func _ready() -> void:
	_args = LobbyArgs.parse(OS.get_cmdline_user_args())
	_headless = DisplayServer.get_name() == "headless" or OS.has_feature("headless")
	if _args.host:
		var decision: Dictionary = LobbyArgs.plan_host(_args, _headless)
		if not bool(decision["ok"]):
			var err: String = String(decision["error"])
			if _headless:
				printerr(err)
				get_tree().quit(int(decision["exit_code"]))
				return
			_show_browser(_args, err)
			return
		var cfg: LobbyConfig = decision["config"]
		var start_err: Error = GameSession.start_host(cfg, _args.bind_host)
		if start_err != OK:
			var listen_err := "HOST_ERROR listen failed: error %d" % start_err
			if _headless:
				printerr(listen_err)
				get_tree().quit(1)
				return
			_show_browser(_args, listen_err)
			return
		if not _headless:
			_go_arena()
		return
	if _args.join_url != "":
		var join_err: Error = GameSession.start_client(_args.join_url, _args.played_offline, _args.join_code)
		if join_err != OK:
			if _headless:
				printerr("Could not reach %s" % _args.join_url)
				get_tree().quit(1)
				return
			_show_browser(_args, "Could not reach %s" % _args.join_url)
			return
		var lc: LobbyClient = GameSession.lobby_client
		if lc == null:
			return
		lc.welcomed.connect(_on_join_welcomed)
		lc.join_error_received.connect(_on_join_refused)
		return
	if _args.join_code != "":
		# Show the browser so a matching LAN beacon can complete the join.
		_show_browser(_args)
		return
	if _headless:
		# Do not default-host. GameSession already started solo in _ready.
		return
	_show_browser(_args)


func _on_join_welcomed(_pid: int) -> void:
	_go_arena()


func _on_join_refused(_code: int, _reason: String) -> void:
	var text: String = GameSession.join_error_text
	if _headless:
		printerr(text)
		get_tree().quit(1)
		return
	_show_browser(_args, text)


func _show_browser(args: LobbyArgs, error_text: String = "") -> void:
	var browser: Control = preload("res://src/render/lobby_browser.tscn").instantiate() as Control
	if browser.has_method("setup"):
		browser.setup(args, error_text)
	add_child(browser)


func _go_arena() -> void:
	get_tree().change_scene_to_file("res://src/render/arena.tscn")
