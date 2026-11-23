class_name FeelSettings
extends RefCounted
## Packed client feel (render, UI, and input). Numbers come only from
## data/feel.json; missing fields are not replaced with code defaults.

var player_flash_color: Color = Color(0, 0, 0, 0)
var enemy_flash_color: Color = Color(0, 0, 0, 0)
var hitstop_seconds: float = 0.0
var knockback_px: float = 0.0
var knockback_recover_seconds: float = 0.0
var floater_pool_size: int = 0
var floater_lifetime_seconds: float = 0.0
var floater_rise_px: float = 0.0
var floater_font_size: int = 0
var floater_outline_size: int = 0
var floater_player_taken_color: Color = Color(0, 0, 0, 0)
var floater_dealt_color: Color = Color(0, 0, 0, 0)
var floater_heal_color: Color = Color(0, 0, 0, 0)
var floater_stack_offset_px: float = 0.0
var player_outline_px: float = 0.0
var player_outline_color: Color = Color(0, 0, 0, 0)
var enemy_outline_px: float = 0.0
var enemy_outline_color: Color = Color(0, 0, 0, 0)
var enemy_rim_px: float = 0.0
var enemy_rim_color: Color = Color(0, 0, 0, 0)
var gamepad_aim_deadzone: float = 0.0
var gamepad_aim_halflife_seconds: float = 0.0
var touch_deadzone: float = 0.0
var stick_thumb_mm: float = 0.0
var stick_knob_ratio: float = 0.0
var stick_margin_mm: float = 0.0
var ability_button_mm: float = 0.0
var interact_button_mm: float = 0.0
var button_gap_mm: float = 0.0
var _valid: bool = false


static func from_json(d: Dictionary) -> FeelSettings:
	var f := FeelSettings.new()
	if d.is_empty():
		push_error("FeelSettings: missing or empty feel pack")
		return f
	var flash: Variant = d.get("hit_flash", null)
	var stop: Variant = d.get("hit_stop", null)
	var nums: Variant = d.get("damage_numbers", null)
	var bullets: Variant = d.get("bullets", null)
	var aim: Variant = d.get("aim", null)
	var touch: Variant = d.get("touch", null)
	if not (flash is Dictionary and stop is Dictionary and nums is Dictionary \
			and bullets is Dictionary and aim is Dictionary and touch is Dictionary):
		push_error("FeelSettings: missing required group")
		return f
	var fd: Dictionary = flash
	var sd: Dictionary = stop
	var nd: Dictionary = nums
	var bd: Dictionary = bullets
	var ad: Dictionary = aim
	var td: Dictionary = touch
	if not f._color(fd, "player_color", "player_flash_color"):
		return f
	if not f._color(fd, "enemy_color", "enemy_flash_color"):
		return f
	if not f._num(sd, "seconds", "hitstop_seconds"):
		return f
	if not f._num(sd, "knockback_px", "knockback_px"):
		return f
	if not f._num(sd, "recover_seconds", "knockback_recover_seconds"):
		return f
	if not f._int(nd, "pool_size", "floater_pool_size"):
		return f
	if not f._num(nd, "lifetime_seconds", "floater_lifetime_seconds"):
		return f
	if not f._num(nd, "rise_px", "floater_rise_px"):
		return f
	if not f._int(nd, "font_size", "floater_font_size"):
		return f
	if not f._int(nd, "outline_size", "floater_outline_size"):
		return f
	if not f._color(nd, "player_taken_color", "floater_player_taken_color"):
		return f
	if not f._color(nd, "dealt_color", "floater_dealt_color"):
		return f
	if not f._color(nd, "heal_color", "floater_heal_color"):
		return f
	if not f._num(nd, "stack_offset_px", "floater_stack_offset_px"):
		return f
	if not f._num(bd, "player_outline_px", "player_outline_px"):
		return f
	if not f._color(bd, "player_outline_color", "player_outline_color"):
		return f
	if not f._num(bd, "enemy_outline_px", "enemy_outline_px"):
		return f
	if not f._color(bd, "enemy_outline_color", "enemy_outline_color"):
		return f
	if not f._num(bd, "enemy_rim_px", "enemy_rim_px"):
		return f
	if not f._color(bd, "enemy_rim_color", "enemy_rim_color"):
		return f
	if not f._num(ad, "gamepad_deadzone", "gamepad_aim_deadzone"):
		return f
	if not f._num(ad, "gamepad_smooth_halflife_seconds", "gamepad_aim_halflife_seconds"):
		return f
	if not f._num(td, "deadzone", "touch_deadzone"):
		return f
	if not f._num(td, "stick_thumb_mm", "stick_thumb_mm"):
		return f
	if not f._num(td, "knob_ratio", "stick_knob_ratio"):
		return f
	if not f._num(td, "margin_mm", "stick_margin_mm"):
		return f
	if not f._num(td, "ability_button_mm", "ability_button_mm"):
		return f
	if not f._num(td, "interact_button_mm", "interact_button_mm"):
		return f
	if not f._num(td, "button_gap_mm", "button_gap_mm"):
		return f
	if f.floater_pool_size < 1 or f.floater_lifetime_seconds <= 0.0 \
			or f.stick_thumb_mm <= 0.0 or f.ability_button_mm <= 0.0 \
			or f.interact_button_mm <= 0.0:
		push_error("FeelSettings: invalid packed value")
		return f
	f._valid = true
	return f


func is_valid() -> bool:
	return _valid


func _color(d: Dictionary, key: String, field: String) -> bool:
	if not d.has(key) or not (d[key] is Array) or (d[key] as Array).size() != 4:
		push_error("FeelSettings: missing %s" % key)
		return false
	var a: Array = d[key]
	set(field, Color(float(a[0]), float(a[1]), float(a[2]), float(a[3])))
	return true


func _num(d: Dictionary, key: String, field: String) -> bool:
	if not d.has(key):
		push_error("FeelSettings: missing %s" % key)
		return false
	set(field, float(d[key]))
	return true


func _int(d: Dictionary, key: String, field: String) -> bool:
	if not d.has(key):
		push_error("FeelSettings: missing %s" % key)
		return false
	set(field, int(d[key]))
	return true
