extends Node2D
## Practice yard: placeholder primitive-shape art, interpolation, and input.

const ARENA_TILES: float = 32.0
const PLAYER_COLOR := Color(0.91, 0.76, 0.48)
const FLASH_COLOR := Color(1.0, 0.55, 0.45)
const ENEMY_COLOR := Color(0.78, 0.42, 0.38)
const SHOT_COLOR := Color(0.48, 0.82, 0.78)
const PATTERN_COLOR := Color(0.92, 0.62, 0.28)

var _sticks: VirtualSticks
var _player: Polygon2D
var _shots: Node2D
var _patterns: Node2D
var _enemies: Node2D
var _camera: Camera2D
var _hint: Label
var _hp: Label
var _shot_views: Dictionary = {} # projectile id -> Polygon2D
var _pattern_views: Dictionary = {}
var _enemy_views: Dictionary = {}
var _shot_free: Array[Polygon2D] = []
var _pattern_free: Array[Polygon2D] = []
var _enemy_free: Array[Polygon2D] = []
var _hint_touch: bool = false


func _ready() -> void:
	_shots = Node2D.new()
	_shots.name = "Shots"
	add_child(_shots)
	_patterns = Node2D.new()
	_patterns.name = "PatternShots"
	add_child(_patterns)
	_enemies = Node2D.new()
	_enemies.name = "Enemies"
	add_child(_enemies)
	_player = Polygon2D.new()
	_player.name = "Player"
	_player.polygon = PackedVector2Array([
		Vector2(12, 0), Vector2(-8, 8), Vector2(-5, 0), Vector2(-8, -8),
	])
	_player.color = PLAYER_COLOR
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
	_hp = Label.new()
	_hp.name = "HP"
	_hp.add_theme_font_size_override("font_size", 16)
	_hp.add_theme_color_override("font_color", Color(0.91, 0.76, 0.48))
	var layer := CanvasLayer.new()
	layer.layer = 5
	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	margin.add_theme_constant_override("margin_left", 16)
	margin.add_theme_constant_override("margin_top", 12)
	var vbox := VBoxContainer.new()
	vbox.add_child(_hint)
	vbox.add_child(_hp)
	margin.add_child(vbox)
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
	_update_enemy_views()
	_update_shot_views()
	_update_pattern_views()
	if _hint_touch != _sticks.using_touch:
		_refresh_hint()


func _refresh_hint() -> void:
	_hint_touch = _sticks.using_touch
	if _hint_touch:
		_hint.text = "Left stick moves · right stick aims and fires · a Burrmite wanders the yard"
	else:
		_hint.text = "WASD or arrows to move · mouse to aim · hold left click to fire · a Burrmite wanders the yard"


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
	var snap := GameSession.curr_snapshot
	if snap.player_flash_ticks > 0:
		_player.color = FLASH_COLOR
	else:
		_player.color = PLAYER_COLOR
	_hp.text = "HP %d / %d" % [snap.player_hp, snap.player_max_hp]
	_camera.position = _player.position


func _diamond(radius_px: float) -> PackedVector2Array:
	return PackedVector2Array([
		Vector2(radius_px, 0.0), Vector2(0.0, radius_px),
		Vector2(-radius_px, 0.0), Vector2(0.0, -radius_px),
	])


func _enemy_shape(radius_px: float) -> PackedVector2Array:
	return PackedVector2Array([
		Vector2(radius_px * 1.15, 0.0), Vector2(0.0, radius_px * 0.85),
		Vector2(-radius_px * 0.7, radius_px * 0.7),
		Vector2(-radius_px * 0.7, -radius_px * 0.7), Vector2(0.0, -radius_px * 0.85),
	])


func _acquire_view(
	parent: Node2D,
	pool: Dictionary,
	free: Array[Polygon2D],
	id: int,
	color: Color,
	radius_px: float,
	kind: String
) -> Polygon2D:
	var view: Polygon2D
	if pool.has(id):
		view = pool[id]
	elif not free.is_empty():
		view = free.pop_back()
		view.visible = true
		pool[id] = view
	else:
		view = Polygon2D.new()
		view.color = color
		parent.add_child(view)
		pool[id] = view
	if not view.has_meta("r") or float(view.get_meta("r")) != radius_px:
		if kind == "enemy":
			view.polygon = _enemy_shape(radius_px)
		else:
			view.polygon = _diamond(radius_px)
		view.color = color
		view.set_meta("r", radius_px)
	return view


func _release_unused(pool: Dictionary, free: Array[Polygon2D], live: Dictionary) -> void:
	for id in pool.keys():
		if not live.has(id):
			var view: Polygon2D = pool[id]
			view.visible = false
			free.append(view)
			pool.erase(id)


func _update_shot_views() -> void:
	var time := GameSession.render_time_ticks()
	var live: Dictionary = {}
	for shot in GameSession.curr_snapshot.projectiles:
		var elapsed: float = time - float(shot.spawn_tick)
		if elapsed < 0.0 or elapsed >= float(shot.lifetime_ticks):
			continue
		if shot.distance_at_time(time) >= shot.range_tiles:
			continue
		live[shot.id] = shot
	_release_unused(_shot_views, _shot_free, live)
	for id in live.keys():
		var shot: SimProjectile = live[id]
		var r: float = shot.radius_tiles * SimConstants.TILE_PX
		var view := _acquire_view(_shots, _shot_views, _shot_free, id, SHOT_COLOR, r, "diamond")
		view.position = shot.pixel_position_at_time(time)


func _update_pattern_views() -> void:
	var time := GameSession.render_time_ticks()
	var live: Dictionary = {}
	for b in GameSession.curr_snapshot.pattern_bullets:
		var elapsed: float = time - float(b.spawn_tick)
		if elapsed < 0.0 or elapsed >= float(b.lifetime_ticks):
			continue
		if b.speed * elapsed * SimConstants.TICK_DT >= b.range_tiles:
			continue
		live[b.id] = b
	_release_unused(_pattern_views, _pattern_free, live)
	for id in live.keys():
		var b: PatternBullet = live[id]
		var r: float = b.radius_tiles * SimConstants.TILE_PX
		var view := _acquire_view(_patterns, _pattern_views, _pattern_free, id, PATTERN_COLOR, r, "diamond")
		view.position = b.pixel_position_at_time(time)


func _update_enemy_views() -> void:
	var prev := GameSession.prev_snapshot
	var curr := GameSession.curr_snapshot
	var alpha := GameSession.alpha
	var prev_by_id: Dictionary = {}
	for e in prev.enemies:
		prev_by_id[e.id] = e
	var live: Dictionary = {}
	for e in curr.enemies:
		live[e.id] = e
	_release_unused(_enemy_views, _enemy_free, live)
	for id in live.keys():
		var e: EnemySnapshot = live[id]
		var r: float = e.radius * SimConstants.TILE_PX
		var view := _acquire_view(_enemies, _enemy_views, _enemy_free, id, ENEMY_COLOR, r, "enemy")
		var x: float = e.x
		var y: float = e.y
		if prev_by_id.has(id):
			var p: EnemySnapshot = prev_by_id[id]
			x = lerpf(p.x, e.x, alpha)
			y = lerpf(p.y, e.y, alpha)
		view.position = Vector2(x * SimConstants.TILE_PX, y * SimConstants.TILE_PX)
		view.rotation = e.aim
