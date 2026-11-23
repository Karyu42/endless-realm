class_name LobbyUiSettings
extends RefCounted
## Packed lobby UI strings and touch sizes from data/lobby_ui.json.
## Missing fields are not replaced with code defaults. If data/feel.json is
## present, its touch.stick_thumb_mm and touch.margin_mm are used for the
## minimum target and margin; otherwise the lobby pack's own sizes are used.

const PACKED_PATH := "res://data/lobby_ui.json"
const FEEL_PACKED_PATH := "res://data/feel.json"

var min_target_mm: float = 0.0
var margin_mm: float = 0.0
var row_min_mm: float = 0.0
var font_size: int = 0
var status_font_size: int = 0
var stack_narrow_px: int = 0
var assume_dpi: int = 0
var strings: Dictionary = {}
var import_messages: Dictionary = {}
var error_messages: Dictionary = {}
var _valid: bool = false


static func load_default() -> LobbyUiSettings:
	var path := PACKED_PATH
	if not FileAccess.file_exists(path):
		path = DataCatalog.repo_root().path_join("data/lobby_ui.json")
	return from_json(DataCatalog._read_json(path), _optional_feel_touch())


static func from_json(d: Dictionary, feel_touch: Dictionary = {}) -> LobbyUiSettings:
	var u := LobbyUiSettings.new()
	if d.is_empty():
		push_error("LobbyUiSettings: missing or empty lobby UI pack")
		return u
	var touch: Variant = d.get("touch", null)
	var strs: Variant = d.get("strings", null)
	var msgs: Variant = d.get("import_messages", null)
	var errs: Variant = d.get("error_messages", null)
	if not (touch is Dictionary and strs is Dictionary and msgs is Dictionary and errs is Dictionary):
		push_error("LobbyUiSettings: missing required group")
		return u
	var td: Dictionary = touch
	if not u._num(td, "min_target_mm", "min_target_mm"):
		return u
	if not u._num(td, "margin_mm", "margin_mm"):
		return u
	if not u._num(td, "row_min_mm", "row_min_mm"):
		return u
	if not u._int(td, "font_size", "font_size"):
		return u
	if not u._int(td, "status_font_size", "status_font_size"):
		return u
	if not u._int(td, "stack_narrow_px", "stack_narrow_px"):
		return u
	if not u._int(td, "assume_dpi", "assume_dpi"):
		return u
	if u.min_target_mm <= 0.0 or u.margin_mm <= 0.0 or u.row_min_mm <= 0.0 \
			or u.font_size < 1 or u.status_font_size < 1 or u.stack_narrow_px < 1 \
			or u.assume_dpi < 1:
		push_error("LobbyUiSettings: invalid packed value")
		return u
	var sd: Dictionary = strs
	for key in sd.keys():
		if typeof(sd[key]) != TYPE_STRING or String(sd[key]) == "":
			push_error("LobbyUiSettings: empty string %s" % key)
			return u
		u.strings[String(key)] = String(sd[key])
	var md: Dictionary = msgs
	for key in md.keys():
		if typeof(md[key]) != TYPE_STRING or String(md[key]) == "":
			push_error("LobbyUiSettings: empty import message %s" % key)
			return u
		u.import_messages[String(key)] = String(md[key])
	var ed: Dictionary = errs
	for key in ed.keys():
		if typeof(ed[key]) != TYPE_STRING or String(ed[key]) == "":
			push_error("LobbyUiSettings: empty error message %s" % key)
			return u
		u.error_messages[String(key)] = String(ed[key])
	if feel_touch.has("stick_thumb_mm"):
		var thumb: float = float(feel_touch["stick_thumb_mm"])
		if thumb > 0.0:
			u.min_target_mm = thumb
	if feel_touch.has("margin_mm"):
		var feel_margin: float = float(feel_touch["margin_mm"])
		if feel_margin > 0.0:
			u.margin_mm = feel_margin
	u._valid = true
	return u


func is_valid() -> bool:
	return _valid


func text(key: String) -> String:
	return String(strings.get(key, ""))


func import_message(code: int) -> String:
	var key := ImportResult.name_of(code)
	return String(import_messages.get(key, ""))


func maps_import(code: int) -> bool:
	var key := ImportResult.name_of(code)
	return key != "UNKNOWN" and import_messages.has(key) and String(import_messages[key]) != ""


func error_message(code: int) -> String:
	var key := ErrorCodes.name_of(code)
	return String(error_messages.get(key, ""))


func maps_error(code: int) -> bool:
	var key := ErrorCodes.name_of(code)
	return key != "UNKNOWN" and error_messages.has(key) and String(error_messages[key]) != ""


func dpi() -> float:
	var d: int = DisplayServer.screen_get_dpi()
	if d <= 0:
		return float(assume_dpi)
	return float(d)


func px_from_mm(mm: float) -> int:
	return int(round(mm * dpi() / 25.4))


func min_target_px() -> int:
	return maxi(px_from_mm(min_target_mm), 1)


func margin_px() -> int:
	return maxi(px_from_mm(margin_mm), 1)


func row_min_px() -> int:
	return maxi(px_from_mm(row_min_mm), 1)


func _num(d: Dictionary, key: String, field: String) -> bool:
	if not d.has(key):
		push_error("LobbyUiSettings: missing %s" % key)
		return false
	set(field, float(d[key]))
	return true


func _int(d: Dictionary, key: String, field: String) -> bool:
	if not d.has(key):
		push_error("LobbyUiSettings: missing %s" % key)
		return false
	set(field, int(d[key]))
	return true


static func _optional_feel_touch() -> Dictionary:
	var path := FEEL_PACKED_PATH
	if not FileAccess.file_exists(path):
		path = DataCatalog.repo_root().path_join("data/feel.json")
	if not FileAccess.file_exists(path):
		return {}
	var d: Dictionary = DataCatalog._read_json(path)
	var touch: Variant = d.get("touch", null)
	if not (touch is Dictionary):
		return {}
	var td: Dictionary = touch
	var out := {}
	if td.has("stick_thumb_mm"):
		out["stick_thumb_mm"] = float(td["stick_thumb_mm"])
	if td.has("margin_mm"):
		out["margin_mm"] = float(td["margin_mm"])
	return out
