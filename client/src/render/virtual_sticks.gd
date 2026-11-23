class_name VirtualSticks
extends CanvasLayer
## Twin virtual sticks for touch / Android: left moves, right aims and fires
## while held. Hidden on desktop unless a touch screen is present.

var move_x: float = 0.0
var move_y: float = 0.0
var aim: float = 0.0
var fire_held: bool = false
var using_touch: bool = false

const STICK_RADIUS_PX: float = 72.0
const KNOB_RADIUS_PX: float = 28.0
const DEADZONE: float = 0.15

var _left_center: Vector2 = Vector2.ZERO
var _right_center: Vector2 = Vector2.ZERO
var _left_knob: Vector2 = Vector2.ZERO
var _right_knob: Vector2 = Vector2.ZERO
var _left_index: int = -1
var _right_index: int = -1
var _pad: Control


func _ready() -> void:
	using_touch = DisplayServer.is_touchscreen_available()
	visible = using_touch
	set_process_input(using_touch)
	set_process(using_touch)
	layer = 10
	_pad = Control.new()
	_pad.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_pad.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_pad.draw.connect(_on_pad_draw)
	add_child(_pad)


func _process(_delta: float) -> void:
	if not using_touch:
		return
	var size := get_viewport().get_visible_rect().size
	_left_center = Vector2(STICK_RADIUS_PX + 48.0, size.y - STICK_RADIUS_PX - 48.0)
	_right_center = Vector2(size.x - STICK_RADIUS_PX - 48.0, size.y - STICK_RADIUS_PX - 48.0)
	_pad.queue_redraw()


func _on_pad_draw() -> void:
	_draw_stick(_left_center, _left_knob)
	_draw_stick(_right_center, _right_knob)


func _draw_stick(center: Vector2, knob_offset: Vector2) -> void:
	_pad.draw_circle(center, STICK_RADIUS_PX, Color(0.15, 0.2, 0.24, 0.55))
	_pad.draw_arc(center, STICK_RADIUS_PX, 0.0, TAU, 48, Color(0.48, 0.82, 0.78, 0.7), 3.0, true)
	_pad.draw_circle(center + knob_offset, KNOB_RADIUS_PX, Color(0.91, 0.76, 0.48, 0.9))


func _input(event: InputEvent) -> void:
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


func _press(index: int, pos: Vector2) -> void:
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


func _apply_left(pos: Vector2) -> void:
	var offset := _clamped_offset(pos, _left_center)
	_left_knob = offset
	var raw := offset / STICK_RADIUS_PX
	var len := raw.length()
	if len < DEADZONE:
		move_x = 0.0
		move_y = 0.0
	else:
		move_x = raw.x
		move_y = raw.y


func _apply_right(pos: Vector2) -> void:
	var offset := _clamped_offset(pos, _right_center)
	_right_knob = offset
	var raw := offset / STICK_RADIUS_PX
	var len := raw.length()
	if len < DEADZONE:
		fire_held = false
	else:
		fire_held = true
		# Godot 2D: atan2(y, x) is already +X = 0, +Y down, clockwise positive.
		aim = atan2(raw.y, raw.x)


func _clamped_offset(pos: Vector2, center: Vector2) -> Vector2:
	var offset := pos - center
	if offset.length() > STICK_RADIUS_PX:
		offset = offset.normalized() * STICK_RADIUS_PX
	return offset
