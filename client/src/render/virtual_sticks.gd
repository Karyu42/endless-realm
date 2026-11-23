class_name VirtualSticks
extends CanvasLayer
## Twin virtual sticks for touch / Android: left moves, right aims and fires
## while held. An ability button sits above the right stick; an interact
## button appears beside it when something is in prompt range.
## Mode follows the last real input event (touch vs key/mouse), so a
## touchscreen laptop can still use keyboard and mouse.
## Sizes come from FeelSettings (physical mm at the screen DPI).

var move_x: float = 0.0
var move_y: float = 0.0
var aim: float = 0.0
var fire_held: bool = false
var using_touch: bool = false
var interact_available: bool = false
var _ability_pressed: bool = false
var _interact_pressed: bool = false
var _feel: FeelSettings

var _stick_radius_px: float = 0.0
var _knob_radius_px: float = 0.0
var _ability_radius_px: float = 0.0
var _interact_radius_px: float = 0.0
var _margin_px: float = 0.0
var _gap_px: float = 0.0
var _deadzone: float = 0.0

var _left_center: Vector2 = Vector2.ZERO
var _right_center: Vector2 = Vector2.ZERO
var _left_knob: Vector2 = Vector2.ZERO
var _right_knob: Vector2 = Vector2.ZERO
var _left_index: int = -1
var _right_index: int = -1
var _ability_index: int = -1
var _ability_center: Vector2 = Vector2.ZERO
var _interact_index: int = -1
var _interact_center: Vector2 = Vector2.ZERO
var _pad: Control


func _ready() -> void:
	using_touch = false
	visible = false
	set_process_input(true)
	set_process(true)
	layer = 10
	_pad = Control.new()
	_pad.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_pad.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_pad.draw.connect(_on_pad_draw)
	add_child(_pad)


func set_feel(feel: FeelSettings) -> void:
	_feel = feel
	_layout_metrics()


func _layout_metrics() -> void:
	if _feel == null or not _feel.is_valid():
		return
	var vp := get_viewport().get_visible_rect().size
	var win := DisplayServer.window_get_size()
	var dpi: float = float(DisplayServer.screen_get_dpi())
	var screen_x: float = float(win.x) if win.x > 0 else vp.x
	var view_x: float = vp.x if vp.x > 0.0 else screen_x
	_stick_radius_px = StickMath.radius_viewport_px(_feel.stick_thumb_mm, dpi, screen_x, view_x)
	_knob_radius_px = _stick_radius_px * _feel.stick_knob_ratio
	_ability_radius_px = StickMath.radius_viewport_px(_feel.ability_button_mm, dpi, screen_x, view_x)
	_interact_radius_px = StickMath.radius_viewport_px(_feel.interact_button_mm, dpi, screen_x, view_x)
	_margin_px = StickMath.radius_viewport_px(_feel.stick_margin_mm, dpi, screen_x, view_x)
	_gap_px = StickMath.radius_viewport_px(_feel.button_gap_mm, dpi, screen_x, view_x)
	_deadzone = _feel.touch_deadzone


func _process(_delta: float) -> void:
	if not using_touch:
		return
	_layout_metrics()
	var size := get_viewport().get_visible_rect().size
	_left_center = Vector2(_stick_radius_px + _margin_px, size.y - _stick_radius_px - _margin_px)
	_right_center = Vector2(size.x - _stick_radius_px - _margin_px, size.y - _stick_radius_px - _margin_px)
	# Ability above the right stick; interact to its left, only drawn when in range.
	_ability_center = Vector2(
		_right_center.x,
		_right_center.y - _stick_radius_px - _ability_radius_px - _gap_px
	)
	_interact_center = Vector2(
		_ability_center.x - _ability_radius_px - _interact_radius_px - _gap_px,
		_ability_center.y
	)
	_pad.queue_redraw()


func _on_pad_draw() -> void:
	if _stick_radius_px <= 0.0:
		return
	_draw_stick(_left_center, _left_knob)
	_draw_stick(_right_center, _right_knob)
	_draw_ability_button()
	if interact_available:
		_draw_interact_button()


func _draw_stick(center: Vector2, knob_offset: Vector2) -> void:
	_pad.draw_circle(center, _stick_radius_px, Color(0.15, 0.2, 0.24, 0.55))
	_pad.draw_arc(center, _stick_radius_px, 0.0, TAU, 48, Color(0.48, 0.82, 0.78, 0.7), 3.0, true)
	_pad.draw_circle(center + knob_offset, _knob_radius_px, Color(0.91, 0.76, 0.48, 0.9))


func _set_using_touch(touch: bool) -> void:
	if using_touch == touch:
		return
	using_touch = touch
	visible = touch
	if not touch:
		_left_index = -1
		_right_index = -1
		_left_knob = Vector2.ZERO
		_right_knob = Vector2.ZERO
		_ability_index = -1
		_interact_index = -1
		move_x = 0.0
		move_y = 0.0
		fire_held = false
		_ability_pressed = false
		_interact_pressed = false
		if _pad:
			_pad.queue_redraw()


func _input(event: InputEvent) -> void:
	# Android synthesizes mouse events (device == DEVICE_ID_EMULATION) from
	# touches; ignoring them keeps keyboard/mouse mode from flickering.
	if event is InputEventMouse and event.device == InputEvent.DEVICE_ID_EMULATION:
		return
	if event is InputEventScreenTouch or event is InputEventScreenDrag:
		_set_using_touch(true)
	elif event is InputEventKey or event is InputEventMouseButton:
		# Ignore mouse clicks synthesized from an active touch so a phone
		# that also emits mouse events does not flap back to keyboard mode.
		if event is InputEventMouseButton and (_left_index >= 0 or _right_index >= 0):
			return
		_set_using_touch(false)
		return
	if not using_touch:
		return
	if event is InputEventScreenTouch:
		var touch := event as InputEventScreenTouch
		if touch.pressed:
			_press(touch.index, touch.position)
		else:
			_release(touch.index)
		get_viewport().set_input_as_handled()
	elif event is InputEventScreenDrag:
		var drag := event as InputEventScreenDrag
		_drag(drag.index, drag.position)
		get_viewport().set_input_as_handled()


func consume_ability_pressed() -> bool:
	var pressed: bool = _ability_pressed
	_ability_pressed = false
	return pressed


func consume_interact_pressed() -> bool:
	var pressed: bool = _interact_pressed
	_interact_pressed = false
	return pressed


func _draw_ability_button() -> void:
	if _ability_radius_px <= 0.0:
		return
	var fill := Color(0.91, 0.76, 0.48, 0.85 if _ability_index >= 0 else 0.65)
	_pad.draw_circle(_ability_center, _ability_radius_px, Color(0.15, 0.2, 0.24, 0.55))
	_pad.draw_arc(_ability_center, _ability_radius_px, 0.0, TAU, 32, Color(0.91, 0.76, 0.48, 0.8), 2.5, true)
	_pad.draw_circle(_ability_center, _ability_radius_px * 0.45, fill)


func _draw_interact_button() -> void:
	if _interact_radius_px <= 0.0:
		return
	var fill := Color(0.42, 0.78, 0.95, 0.9 if _interact_index >= 0 else 0.7)
	_pad.draw_circle(_interact_center, _interact_radius_px, Color(0.15, 0.2, 0.24, 0.55))
	_pad.draw_arc(_interact_center, _interact_radius_px, 0.0, TAU, 32, Color(0.42, 0.78, 0.95, 0.85), 2.5, true)
	_pad.draw_circle(_interact_center, _interact_radius_px * 0.45, fill)


func _press(index: int, pos: Vector2) -> void:
	if interact_available and _interact_radius_px > 0.0 \
			and pos.distance_to(_interact_center) <= _interact_radius_px + _gap_px:
		if _interact_index < 0:
			_interact_index = index
			_interact_pressed = true
		return
	if _ability_radius_px > 0.0 and pos.distance_to(_ability_center) <= _ability_radius_px + _gap_px:
		if _ability_index < 0:
			_ability_index = index
			_ability_pressed = true
		return
	if pos.x < get_viewport().get_visible_rect().size.x * 0.5:
		if _left_index < 0:
			_left_index = index
			_apply_left(pos)
	else:
		if _right_index < 0:
			_right_index = index
			_apply_right(pos)


func _drag(index: int, pos: Vector2) -> void:
	if index == _left_index:
		_apply_left(pos)
	elif index == _right_index:
		_apply_right(pos)


func _release(index: int) -> void:
	if index == _left_index:
		_left_index = -1
		_left_knob = Vector2.ZERO
		move_x = 0.0
		move_y = 0.0
	elif index == _right_index:
		_right_index = -1
		_right_knob = Vector2.ZERO
		fire_held = false
	elif index == _ability_index:
		_ability_index = -1
	elif index == _interact_index:
		_interact_index = -1


func _apply_left(pos: Vector2) -> void:
	var offset := StickMath.clamped_offset(pos, _left_center, _stick_radius_px)
	_left_knob = offset
	var raw := StickMath.after_deadzone(offset, _stick_radius_px, _deadzone)
	move_x = raw.x
	move_y = raw.y


func _apply_right(pos: Vector2) -> void:
	var offset := StickMath.clamped_offset(pos, _right_center, _stick_radius_px)
	_right_knob = offset
	var raw := StickMath.after_deadzone(offset, _stick_radius_px, _deadzone)
	if raw == Vector2.ZERO:
		fire_held = false
	else:
		fire_held = true
		# Godot 2D: atan2(y, x) is already +X = 0, +Y down, clockwise positive.
		aim = atan2(raw.y, raw.x)
