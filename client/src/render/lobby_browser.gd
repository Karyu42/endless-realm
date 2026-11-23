extends Control
## Lists LAN beacons and starts solo, host, or a join by code / IP:port.

var args: LobbyArgs
var _client: LobbyClient
var _pending_code: String = ""
var _setup_error: String = ""
var _ui: LobbyUiSettings
var _join_client: LobbyClient


func setup(p_args: LobbyArgs, error_text: String = "") -> void:
	args = p_args
	_setup_error = error_text
	if args != null and args.join_code != "":
		_pending_code = args.join_code
		var join_edit: LineEdit = %JoinCodeEdit
		join_edit.text = args.join_code


func _ready() -> void:
	_ui = LobbyUiSettings.load_default()
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
	broadcast_check.button_pressed = args.broadcast_join_code if args != null else false
	broadcast_check.text = _ui.text("broadcast_code")
	var invite_check: CheckBox = %InviteOnlyCheck
	invite_check.button_pressed = args.invite_only if args != null else false
	invite_check.text = _ui.text("invite_only_check")
	invite_check.toggled.connect(_on_invite_toggled)
	var offline_check: CheckBox = %PlayedOfflineCheck
	offline_check.button_pressed = args.played_offline if args != null else false
	_client = LobbyClient.new()
	add_child(_client)
	_client.lobbies_changed.connect(_refresh_list)
	_client.start_discovery()
	%SoloButton.pressed.connect(_on_solo)
	%HostButton.pressed.connect(_on_host)
	%JoinSelectedButton.pressed.connect(_on_join_selected)
	%JoinCodeButton.pressed.connect(_on_join_code)
	%JoinIpButton.pressed.connect(_on_join_ip)
	for n in [%NameEdit, %MaxPlayersEdit, %M100MinEdit, %M100MaxEdit, %HostCodeEdit]:
		(n as LineEdit).text_changed.connect(func(_t: String) -> void: _refresh_validate())
	for n in [%AllowImportsCheck, %AllowOfflineImportsCheck, %BroadcastJoinCodeCheck, %InviteOnlyCheck]:
		(n as CheckBox).toggled.connect(func(_on: bool) -> void: _refresh_validate())
	# stack.md: Android is join-only in v0.1 (desktop / --headless hosts).
	if OS.has_feature("android"):
		for n in [
			%HostTitle, %NameEdit, %MaxPlayersEdit, %M100MinEdit, %M100MaxEdit, %HostCodeEdit,
			%AllowImportsCheck, %AllowOfflineImportsCheck, %BroadcastJoinCodeCheck, %InviteOnlyCheck,
			%HostButton, %ValidateLabel
		]:
			n.visible = false
	_apply_touch_layout()
	_on_invite_toggled(invite_check.button_pressed)
	_refresh_list()
	_refresh_validate()
	if GameSession.join_error_text != "":
		%StatusLabel.text = GameSession.take_join_error()
	elif _setup_error != "":
		%StatusLabel.text = _setup_error
	if _pending_code != "":
		# Wait a couple of beacons for a matching LAN host.
		get_tree().create_timer(1.5).timeout.connect(_try_pending_code)


func _apply_touch_layout() -> void:
	if _ui == null or not _ui.is_valid():
		return
	var margin: MarginContainer = $Margin
	var pad: int = _ui.margin_px()
	margin.add_theme_constant_override("margin_left", pad)
	margin.add_theme_constant_override("margin_top", pad)
	margin.add_theme_constant_override("margin_right", pad)
	margin.add_theme_constant_override("margin_bottom", pad)
	var min_h: int = _ui.min_target_px()
	var font: int = _ui.font_size
	var status_font: int = _ui.status_font_size
	var row_h: int = _ui.row_min_px()
	var narrow: bool = OS.has_feature("android")
	var vp := get_viewport_rect().size
	if vp.x > 0.0 and vp.x < float(_ui.stack_narrow_px):
		narrow = true
	var cols: BoxContainer = $Margin/Cols
	for prop in cols.get_property_list():
		if String(prop.get("name", "")) == "vertical":
			cols.set("vertical", narrow)
			break
	%LobbyList.custom_minimum_size = Vector2(0, maxf(180.0, float(row_h * 6)))
	%LobbyList.add_theme_font_size_override("font_size", font)
	%StatusLabel.add_theme_font_size_override("font_size", status_font)
	%ValidateLabel.add_theme_font_size_override("font_size", status_font)
	for n in [
		%SoloButton, %HostButton, %JoinSelectedButton, %JoinCodeButton, %JoinIpButton,
		%NameEdit, %MaxPlayersEdit, %M100MinEdit, %M100MaxEdit, %HostCodeEdit,
		%JoinCodeEdit, %JoinIpEdit, %AllowImportsCheck, %AllowOfflineImportsCheck,
		%BroadcastJoinCodeCheck, %InviteOnlyCheck, %PlayedOfflineCheck
	]:
		n.custom_minimum_size = Vector2(0, min_h)
		if n is BaseButton or n is LineEdit or n is Label:
			n.add_theme_font_size_override("font_size", font)

	if _ui != null and _ui.is_valid():
		_ui.apply_message_label(%StatusLabel, get_viewport_rect().size.x)

func _on_invite_toggled(on: bool) -> void:
	%BroadcastJoinCodeCheck.visible = not on and not OS.has_feature("android")
	_refresh_validate()


func _draft_host_settings() -> LobbySettings:
	var hs := LobbySettings.new()
	var name_edit: LineEdit = %NameEdit
	hs.lobby_name = name_edit.text.strip_edges()
	if hs.lobby_name == "":
		hs.lobby_name = "Practice Lobby"
	var host_max: LineEdit = %MaxPlayersEdit
	var parsed_max: int = LobbyHost.parse_max_players(host_max.text)
	hs.max_players = parsed_max if parsed_max >= 0 else 0
	hs.m100_min = _parse_m100(%M100MinEdit.text)
	hs.m100_max = _parse_m100(%M100MaxEdit.text)
	hs.imports_allowed = (%AllowImportsCheck as CheckBox).button_pressed
	hs.offline_allowed = (%AllowOfflineImportsCheck as CheckBox).button_pressed
	hs.join_code = (%HostCodeEdit as LineEdit).text.strip_edges().to_upper()
	return hs


func _refresh_validate() -> void:
	if not %ValidateLabel.visible:
		return
	var reasons: PackedStringArray = _draft_host_settings().validate()
	%ValidateLabel.text = " ".join(reasons)


func _refresh_list() -> void:
	var list: ItemList = %LobbyList
	list.clear()
	for lobby in _client.lobbies:
		if LobbyRowFormat.is_invite_only(lobby):
			continue
		list.add_item(LobbyRowFormat.format(lobby, _ui))
	if _setup_error == "":
		%StatusLabel.text = "%d lobby(s) on LAN" % _visible_lobby_count()


func _visible_lobby_count() -> int:
	var n: int = 0
	for lobby in _client.lobbies:
		if not LobbyRowFormat.is_invite_only(lobby):
			n += 1
	return n


func _visible_lobby_at(index: int) -> Dictionary:
	var i: int = 0
	for lobby in _client.lobbies:
		if LobbyRowFormat.is_invite_only(lobby):
			continue
		if i == index:
			return lobby
		i += 1
	return {}


func _on_solo() -> void:
	GameSession.start_solo()
	_go_arena()


func _on_host() -> void:
	var cfg := LobbyConfig.new()
	cfg.host_settings = _draft_host_settings()
	cfg.invite_only = (%InviteOnlyCheck as CheckBox).button_pressed
	cfg.broadcast_join_code = (not cfg.invite_only) and (%BroadcastJoinCodeCheck as CheckBox).button_pressed
	var reasons: PackedStringArray = cfg.host_settings.validate()
	if not reasons.is_empty():
		%ValidateLabel.text = " ".join(reasons)
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
	if selected.is_empty():
		%StatusLabel.text = _ui.text("select_lobby")
		return
	var info := _visible_lobby_at(selected[0])
	if info.is_empty():
		%StatusLabel.text = _ui.text("select_lobby")
		return
	_join_info(info)


func _on_join_code() -> void:
	var join_edit: LineEdit = %JoinCodeEdit
	var code: String = join_edit.text.strip_edges()
	if code == "":
		%StatusLabel.text = _ui.text("enter_join_code")
		return
	var info := _client.find_by_code(code)
	if info.is_empty():
		%StatusLabel.text = _ui.text("code_not_found")
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
		%StatusLabel.text = _ui.text("enter_host_port")
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
	_await_join()


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
	_await_join()



func _await_join() -> void:
	_disconnect_join_signals()
	var lc: LobbyClient = GameSession.lobby_client
	if lc == null:
		return
	_join_client = lc
	lc.welcomed.connect(_on_join_welcomed)
	lc.join_error_received.connect(_on_join_refused)


func _disconnect_join_signals() -> void:
	if _join_client != null and is_instance_valid(_join_client):
		if _join_client.welcomed.is_connected(_on_join_welcomed):
			_join_client.welcomed.disconnect(_on_join_welcomed)
		if _join_client.join_error_received.is_connected(_on_join_refused):
			_join_client.join_error_received.disconnect(_on_join_refused)
	_join_client = null


func _on_join_welcomed(_pid: int) -> void:
	_disconnect_join_signals()
	_go_arena()


func _on_join_refused(_code: int, _reason: String) -> void:
	_disconnect_join_signals()
	var text: String = GameSession.join_error_text
	if text != "":
		%StatusLabel.text = text


func _go_arena() -> void:
	get_tree().change_scene_to_file("res://src/render/arena.tscn")


func _parse_m100(text: String) -> int:
	var trimmed: String = text.strip_edges()
	if trimmed.is_empty() or not trimmed.is_valid_int():
		return 0
	return trimmed.to_int()
