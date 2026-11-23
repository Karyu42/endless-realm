extends Control
## Listen-host overlay: join code (copyable), invite-only listing, live
## LobbySettings via apply_settings() / settings_changed, and import results.

var _ui: LobbyUiSettings
var _bound_host: LobbyHost
var _code_label: Label
var _copy_btn: Button
var _invite_check: CheckBox
var _broadcast_check: CheckBox
var _settings_btn: Button
var _settings_box: VBoxContainer
var _name_edit: LineEdit
var _max_edit: LineEdit
var _mmin_edit: LineEdit
var _mmax_edit: LineEdit
var _imports_check: CheckBox
var _offline_check: CheckBox
var _apply_btn: Button
var _validate: Label
var _status: Label
var _import_btn: Button
var _file_dialog: FileDialog
var _settings_open: bool = false


func _ready() -> void:
	_ui = LobbyUiSettings.load_default()
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	_build()
	_apply_touch_layout()
	visible = false


func _process(_delta: float) -> void:
	var host: LobbyHost = GameSession.lobby_host if GameSession.mode == GameSession.Mode.HOST else null
	if host != _bound_host:
		_rebind(host)
	visible = host != null
	mouse_filter = Control.MOUSE_FILTER_STOP if visible else Control.MOUSE_FILTER_IGNORE


func _rebind(host: LobbyHost) -> void:
	if _bound_host != null and _bound_host.settings_changed.is_connected(_on_settings_changed):
		_bound_host.settings_changed.disconnect(_on_settings_changed)
	_bound_host = host
	if host != null:
		if not host.settings_changed.is_connected(_on_settings_changed):
			host.settings_changed.connect(_on_settings_changed)
		_on_settings_changed(host.settings())
		_invite_check.set_block_signals(true)
		_broadcast_check.set_block_signals(true)
		_invite_check.button_pressed = GameSession.lobby_config != null and GameSession.lobby_config.invite_only
		_broadcast_check.button_pressed = GameSession.lobby_config != null and GameSession.lobby_config.broadcast_join_code
		_invite_check.set_block_signals(false)
		_broadcast_check.set_block_signals(false)
		_sync_broadcast_visible()


func _on_settings_changed(s: LobbySettings) -> void:
	if s == null:
		return
	_code_label.text = _ui.text("join_code_label") % s.join_code
	_name_edit.text = s.lobby_name
	_max_edit.text = str(s.max_players)
	_mmin_edit.text = str(s.m100_min)
	_mmax_edit.text = str(s.m100_max)
	_imports_check.button_pressed = s.imports_allowed
	_offline_check.button_pressed = s.offline_allowed
	_refresh_validate()


func _build() -> void:
	var pad: int = _ui.margin_px() if _ui != null and _ui.is_valid() else 8
	var panel := PanelContainer.new()
	panel.mouse_filter = Control.MOUSE_FILTER_STOP
	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", pad)
	margin.add_theme_constant_override("margin_top", pad)
	margin.add_theme_constant_override("margin_right", pad)
	margin.add_theme_constant_override("margin_bottom", pad)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 6)
	var title := Label.new()
	title.text = _ui.text("lobby_panel_title")
	col.add_child(title)
	_code_label = Label.new()
	_code_label.text = _ui.text("join_code_missing")
	_code_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	col.add_child(_code_label)
	_copy_btn = Button.new()
	_copy_btn.text = _ui.text("copy_code")
	_copy_btn.pressed.connect(_on_copy)
	col.add_child(_copy_btn)
	_invite_check = CheckBox.new()
	_invite_check.text = _ui.text("invite_only_check")
	_invite_check.toggled.connect(_on_invite_toggled)
	col.add_child(_invite_check)
	_broadcast_check = CheckBox.new()
	_broadcast_check.text = _ui.text("broadcast_code")
	_broadcast_check.toggled.connect(_on_broadcast_toggled)
	col.add_child(_broadcast_check)
	_settings_btn = Button.new()
	_settings_btn.text = _ui.text("open_settings")
	_settings_btn.pressed.connect(_toggle_settings)
	col.add_child(_settings_btn)
	_settings_box = VBoxContainer.new()
	_settings_box.visible = false
	_settings_box.add_theme_constant_override("separation", 6)
	_name_edit = LineEdit.new()
	_name_edit.placeholder_text = "Lobby name"
	_max_edit = LineEdit.new()
	_max_edit.placeholder_text = "Max players (1–50)"
	_mmin_edit = LineEdit.new()
	_mmin_edit.placeholder_text = "Min M (m100)"
	_mmax_edit = LineEdit.new()
	_mmax_edit.placeholder_text = "Max M (m100)"
	_imports_check = CheckBox.new()
	_imports_check.text = "Imports allowed"
	_offline_check = CheckBox.new()
	_offline_check.text = "Offline-flagged imports allowed"
	_apply_btn = Button.new()
	_apply_btn.text = _ui.text("apply_settings")
	_apply_btn.pressed.connect(_on_apply)
	_validate = Label.new()
	_validate.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_import_btn = Button.new()
	_import_btn.text = _ui.text("import_character")
	_import_btn.pressed.connect(_on_import_pressed)
	for n in [_name_edit, _max_edit, _mmin_edit, _mmax_edit]:
		n.text_changed.connect(func(_t: String) -> void: _refresh_validate())
		_settings_box.add_child(n)
	_settings_box.add_child(_imports_check)
	_settings_box.add_child(_offline_check)
	_settings_box.add_child(_apply_btn)
	_settings_box.add_child(_validate)
	_settings_box.add_child(_import_btn)
	col.add_child(_settings_box)
	_status = Label.new()
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	col.add_child(_status)
	margin.add_child(col)
	panel.add_child(margin)
	add_child(panel)
	_file_dialog = FileDialog.new()
	_file_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	_file_dialog.access = FileDialog.ACCESS_FILESYSTEM
	_file_dialog.title = _ui.text("import_pick_title")
	_file_dialog.file_selected.connect(_on_import_file)
	add_child(_file_dialog)
	custom_minimum_size = Vector2(280, 0)
	offset_left = -300
	offset_top = 8
	offset_right = -8
	offset_bottom = 8
	grow_horizontal = Control.GROW_DIRECTION_BEGIN


func _apply_touch_layout() -> void:
	if _ui == null or not _ui.is_valid():
		return
	var min_h: int = _ui.min_target_px()
	var font: int = _ui.font_size
	for n in [
		_copy_btn, _invite_check, _broadcast_check, _settings_btn, _apply_btn, _import_btn,
		_name_edit, _max_edit, _mmin_edit, _mmax_edit, _imports_check, _offline_check,
		_code_label, _validate, _status
	]:
		if n == null:
			continue
		n.custom_minimum_size = Vector2(0, min_h)
		n.add_theme_font_size_override("font_size", font)


func _toggle_settings() -> void:
	_settings_open = not _settings_open
	_settings_box.visible = _settings_open
	_settings_btn.text = _ui.text("hide_settings") if _settings_open else _ui.text("open_settings")


func _on_copy() -> void:
	var code: String = GameSession.copy_join_code()
	_status.text = _ui.text("code_copied") if code != "" else _ui.text("join_code_missing")


func _on_invite_toggled(on: bool) -> void:
	GameSession.set_invite_only(on)
	_sync_broadcast_visible()


func _on_broadcast_toggled(on: bool) -> void:
	GameSession.set_broadcast_join_code(on)


func _sync_broadcast_visible() -> void:
	_broadcast_check.visible = not _invite_check.button_pressed


func _draft_settings() -> LobbySettings:
	var s := LobbySettings.new()
	if _bound_host != null:
		s = _bound_host.settings()
	s.lobby_name = _name_edit.text.strip_edges()
	var parsed_max: int = LobbyHost.parse_max_players(_max_edit.text)
	s.max_players = parsed_max if parsed_max >= 0 else 0
	s.m100_min = _parse_m100(_mmin_edit.text)
	s.m100_max = _parse_m100(_mmax_edit.text)
	s.imports_allowed = _imports_check.button_pressed
	s.offline_allowed = _offline_check.button_pressed
	# Keep the current join code (empty would also keep it on the host).
	return s


func _refresh_validate() -> void:
	if _validate == null:
		return
	_validate.text = " ".join(_draft_settings().validate())


func _on_apply() -> void:
	var reasons: PackedStringArray = GameSession.apply_lobby_settings(_draft_settings(), _ui)
	_validate.text = " ".join(reasons)
	if reasons.is_empty():
		_status.text = ""


func _on_import_pressed() -> void:
	_file_dialog.popup_centered_ratio(0.6)


func _on_import_file(path: String) -> void:
	var blob := FileAccess.get_file_as_bytes(path)
	var code: int = GameSession.import_for_local_player(blob)
	_status.text = _ui.import_message(code)


func _parse_m100(text: String) -> int:
	var trimmed: String = text.strip_edges()
	if trimmed.is_empty() or not trimmed.is_valid_int():
		return 0
	return trimmed.to_int()
