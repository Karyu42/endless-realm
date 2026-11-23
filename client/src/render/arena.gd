extends Node2D
## Practice yard: placeholder primitive-shape art, interpolation, and input.

const ARENA_TILES: float = 32.0

var _sticks: VirtualSticks
var _player: Polygon2D
var _shots: Node2D
var _camera: Camera2D
var _hint: Label
var _shot_views: Dictionary = {} # projectile id -> Polygon2D
var _hint_touch: bool = false


func _ready() -> void:
	print("DataCatalog: cannot read res://data/qa_probe.json (QA probe, revert me)")
	_shots = Node2D.new()
	_shots.name = "Shots"
	add_child(_shots)
	_player = Polygon2D.new()
	_player.name = "Player"
	_player.polygon = PackedVector2Array([
		Vector2(12, 0), Vector2(-8, 8), Vector2(-5, 0), Vector2(-8, -8),
	])
	_player.color = Color(0.91, 0.76, 0.48)
	add_child(_player)
	_camera = Camera2D.new()
	_camera.name = "Camera"
	_camera.zoom = Vector2(1.6, 1.6)
	add_child(_camera)
	_camera.make_current()
	_sticks = VirtualSticks.new()
	_sticks.name = "VirtualSticks"
	add_child(_sticks)
	_hint = Label.new()
	_hint.name = "Hint"
	_hint.add_theme_font_size_override("font_size", 16)
	_hint.add_theme_color_override("font_color", Color(0.82, 0.9, 0.88))
	var layer := CanvasLayer.new()
	layer.layer = 5
	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	margin.add_theme_constant_override("margin_left", 16)
	margin.add_theme_constant_override("margin_top", 12)
	margin.add_child(_hint)
	layer.add_child(margin)
	add_child(layer)
	_refresh_hint()
	queue_redraw()


func _draw() -> void:
	var tiles := int(ARENA_TILES)
	var px := SimConstants.TILE_PX
	var size := float(tiles) * px
	draw_rect(Rect2(0.0, 0.0, size, size), Color(0.09, 0.13, 0.16))
	var dark := Color(0.13, 0.18, 0.22)
	for y in range(tiles):
		for x in range(tiles):
			if (x + y) % 2 == 0:
				draw_rect(Rect2(float(x) * px, float(y) * px, px, px), dark)
	draw_rect(Rect2(0.0, 0.0, size, size), Color(0.48, 0.82, 0.78, 0.55), false, 2.0)


func _process(_delta: float) -> void:
	_sample_input()
	_update_player_view()
	_update_shot_views()
	if _hint_touch != _sticks.using_touch:
		_refresh_hint()


func _refresh_hint() -> void:
	_hint_touch = _sticks.using_touch
	if _hint_touch:
		_hint.text = "Left stick moves · right stick aims and fires"
	else:
		_hint.text = "WASD or arrows to move · mouse to aim · hold left click to fire"


func _sample_input() -> void:
	if _sticks.using_touch:
		GameSession.move_x = _sticks.move_x
		GameSession.move_y = _sticks.move_y
		GameSession.aim = _sticks.aim
		GameSession.fire_held = _sticks.fire_held
		return
	GameSession.move_x = Input.get_axis("move_left", "move_right")
	GameSession.move_y = Input.get_axis("move_up", "move_down")
	GameSession.fire_held = Input.is_action_pressed("fire")
	var player_px := GameSession.interpolated_player_pixels()
	var mouse := get_global_mouse_position()
	GameSession.aim = atan2(mouse.y - player_px.y, mouse.x - player_px.x)


func _update_player_view() -> void:
	_player.position = GameSession.interpolated_player_pixels()
	_player.rotation = GameSession.interpolated_aim()
	_camera.position = _player.position


func _update_shot_views() -> void:
	var snap := GameSession.curr_snapshot
	var time := GameSession.render_time_ticks()
	var live: Dictionary = {}
	for shot in snap.projectiles:
		var elapsed: float = time - float(shot.spawn_tick)
		if elapsed < 0.0 or elapsed >= float(shot.lifetime_ticks):
			continue
		if shot.distance_at_time(time) >= shot.range_tiles:
			continue
		live[shot.id] = shot
	for id in _shot_views.keys():
		if not live.has(id):
			(_shot_views[id] as Node).queue_free()
			_shot_views.erase(id)
	for id in live.keys():
		if not _shot_views.has(id):
			var view := Polygon2D.new()
			_shots.add_child(view)
			_shot_views[id] = view
		var shot: SimProjectile = live[id]
		var view: Polygon2D = _shot_views[id]
		var r: float = shot.radius_tiles * SimConstants.TILE_PX
		view.polygon = PackedVector2Array([
			Vector2(r, 0.0), Vector2(0.0, r), Vector2(-r, 0.0), Vector2(0.0, -r),
		])
		view.color = Color(0.48, 0.82, 0.78)
		view.position = shot.position_at_time(time).to_pixels()
