extends Control
## Lists LAN beacons and starts solo, host, or a join by code / IP:port.

var args: LobbyArgs
var _client: LobbyClient
var _pending_code: String = ""
var _setup_error: String = ""


func setup(p_args: LobbyArgs, error_text: String = "") -> void:
	args = p_args
	_setup_error = error_text
	if args != null and args.join_code != "":
		_pending_code = args.join_code
		var join_edit: LineEdit = %JoinCodeEdit
		join_edit.text = args.join_code


func _ready() -> void:
	if args == null:
		args = LobbyArgs.new()
	var max_edit: LineEdit = %MaxPlayersEdit
	max_edit.text = str(LobbyHost.DEFAULT_MAX_PLAYERS)
	var m_min: LineEdit = %M100MinEdit
	m_min.text = str(LobbySettings.BASE_M100)
	var m_max: LineEdit = %M100MaxEdit
	m_max.text = str(LobbySettings.BASE_M100)
	var allow_check: CheckBox = %AllowImportsCheck
	allow_check.button_pressed = true
	var offline_imports: CheckBox = %AllowOfflineImportsCheck
	offline_imports.button_pressed = true
	var broadcast_check: CheckBox = %BroadcastJoinCodeCheck
	broadcast_check.button_pressed = false
	var offline_check: CheckBox = %PlayedOfflineCheck
	offline_check.button_pressed = false
	_client = LobbyClient.new()
	add_child(_client)
	_client.lobbies_changed.connect(_refresh_list)
	_client.start_discovery()
	%SoloButton.pressed.connect(_on_solo)
	%HostButton.pressed.connect(_on_host)
	%JoinSelectedButton.pressed.connect(_on_join_selected)
	%JoinCodeButton.pressed.connect(_on_join_code)
	%JoinIpButton.pressed.connect(_on_join_ip)
	# stack.md: Android is join-only in v0.1 (desktop / --headless hosts).
	if OS.has_feature("android"):
		for n in [
			%HostTitle, %NameEdit, %MaxPlayersEdit, %M100MinEdit, %M100MaxEdit, %HostCodeEdit,
			%AllowImportsCheck, %AllowOfflineImportsCheck, %BroadcastJoinCodeCheck, %HostButton
		]:
			n.visible = false
	_refresh_list()
	if _setup_error != "":
		%StatusLabel.text = _setup_error
	if _pending_code != "":
		# Wait a couple of beacons for a matching LAN host.
		get_tree().create_timer(1.5).timeout.connect(_try_pending_code)


func _refresh_list() -> void:
	var list: ItemList = %LobbyList
	list.clear()
	for lobby in _client.lobbies:
		list.add_item(_format_lobby(lobby))
	if _setup_error == "":
		%StatusLabel.text = "%d lobby(s) on LAN" % _client.lobbies.size()


func _format_lobby(info: Dictionary) -> String:
	var preview: Array = info.get("preview", info.get("portals", []))
	var chips: PackedStringArray = _fmt_mults(preview)
	var more: int = int(info.get("more", 0))
	if more > 0:
		chips.append("+%d more" % more)
	var portals := ", ".join(chips)
	var code := String(info.get("code", ""))
	var code_bit := ("code %s  " % code) if code != "" else ""
	return "%s  %d/%d  %sportals [%s]  %s:%d" % [
		String(info.get("name", "?")),
		int(info.get("players", 0)),
		int(info.get("max", 0)),
		code_bit,
		portals,
		String(info.get("ip", "")),
		int(info.get("port", 0)),
	]


func _fmt_mults(values: Array) -> PackedStringArray:
	var out: PackedStringArray = []
	for v in values:
		out.append("%.2f" % float(v))
	return out


func _on_solo() -> void:
	GameSession.start_solo()
	_go_arena()


func _on_host() -> void:
	var cfg := LobbyConfig.new()
	var hs = cfg.host_settings
	var name_edit: LineEdit = %NameEdit
	hs.lobby_name = name_edit.text.strip_edges()
	if hs.lobby_name == "":
		hs.lobby_name = "Practice Lobby"
	var host_max: LineEdit = %MaxPlayersEdit
	var parsed_max: int = LobbyHost.parse_max_players(host_max.text)
	hs.max_players = parsed_max if parsed_max >= 0 else 0
	hs.m100_min = _parse_m100(%M100MinEdit.text)
	hs.m100_max = _parse_m100(%M100MaxEdit.text)
	var host_imports: CheckBox = %AllowImportsCheck
	hs.imports_allowed = host_imports.button_pressed
	var host_offline: CheckBox = %AllowOfflineImportsCheck
	hs.offline_allowed = host_offline.button_pressed
	var broadcast: CheckBox = %BroadcastJoinCodeCheck
	cfg.broadcast_join_code = broadcast.button_pressed
	var host_code_edit: LineEdit = %HostCodeEdit
	hs.join_code = host_code_edit.text.strip_edges().to_upper()
	# Show LobbySettings.validate() strings as-is, including name and join-code checks.
	var reasons: PackedStringArray = hs.validate()
	if not reasons.is_empty():
		%StatusLabel.text = " ".join(reasons)
		return
	cfg.open_portals = [1.0] as Array[float]
	var err: Error = GameSession.start_host(cfg, "*")
	if err != OK:
		%StatusLabel.text = "Could not host (error %d). Is the port in use?" % err
		return
	_go_arena()


func _on_join_selected() -> void:
	var list: ItemList = %LobbyList
	var selected: PackedInt32Array = list.get_selected_items()
	if selected.is_empty() or selected[0] >= _client.lobbies.size():
		%StatusLabel.text = "Select a lobby first."
		return
	_join_info(_client.lobbies[selected[0]])


func _on_join_code() -> void:
	var join_edit: LineEdit = %JoinCodeEdit
	var code: String = join_edit.text.strip_edges()
	if code == "":
		%StatusLabel.text = "Enter a join code."
		return
	var info := _client.find_by_code(code)
	if info.is_empty():
		%StatusLabel.text = "No LAN lobby with that code yet. Keep the browser open."
		return
	_join_info(info)


func _try_pending_code() -> void:
	if _pending_code == "":
		return
	var info := _client.find_by_code(_pending_code)
	if not info.is_empty():
		_join_info(info)


func _on_join_ip() -> void:
	var ip_edit: LineEdit = %JoinIpEdit
	var raw: String = ip_edit.text.strip_edges()
	if raw == "":
		%StatusLabel.text = "Enter host:port."
		return
	var host: String = raw
	var port: int = LobbyBeacon.DEFAULT_WS_PORT
	if raw.contains(":"):
		var parts: PackedStringArray = raw.split(":")
		host = parts[0]
		port = int(parts[1])
	var url := "ws://%s:%d/ws" % [host, port]
	var played_offline: CheckBox = %PlayedOfflineCheck
	var err: Error = GameSession.start_client(url, played_offline.button_pressed, "")
	if err != OK:
		%StatusLabel.text = "Could not reach %s" % url
		return
	_go_arena()


func _join_info(info: Dictionary) -> void:
	var ip := String(info.get("ip", "127.0.0.1"))
	var port: int = int(info.get("port", LobbyBeacon.DEFAULT_WS_PORT))
	var path := String(info.get("path", "/ws"))
	if not path.begins_with("/"):
		path = "/" + path
	var url := "ws://%s:%d%s" % [ip, port, path]
	var played_offline: CheckBox = %PlayedOfflineCheck
	var err: Error = GameSession.start_client(
		url,
		played_offline.button_pressed,
		String(info.get("code", ""))
	)
	if err != OK:
		%StatusLabel.text = "Could not join %s" % url
		return
	_go_arena()


func _go_arena() -> void:
	get_tree().change_scene_to_file("res://src/render/arena.tscn")


func _parse_m100(text: String) -> int:
	var trimmed: String = text.strip_edges()
	if trimmed.is_empty() or not trimmed.is_valid_int():
		return 0
	return trimmed.to_int()

