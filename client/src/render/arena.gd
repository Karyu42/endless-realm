extends Node2D
## Practice yard: placeholder primitive-shape art, interpolation, and input.

const ARENA_TILES: float = 32.0
const PLAYER_COLOR := Color(0.91, 0.76, 0.48)
const FLASH_COLOR := Color(1.0, 0.55, 0.45)
const ENEMY_COLOR := Color(0.78, 0.42, 0.38)
const DRIFTCAP_COLOR := Color(0.42, 0.62, 0.36)
const SHOT_COLOR := Color(0.48, 0.82, 0.78)
const PATTERN_COLOR := Color(0.92, 0.62, 0.28)
const SPORE_COLOR := Color(0.45, 0.82, 0.52)
const BAG_BROWN := Color(0.55, 0.38, 0.22)
const BAG_TEAL := Color(0.28, 0.72, 0.70)
const BAG_GOLD := Color(0.92, 0.74, 0.28)
const SHOT_OUTLINE := Color(0.06, 0.08, 0.10, 0.95)
const PATTERN_OUTLINE := Color(0.18, 0.08, 0.04, 0.95)
const DAMAGE_COLOR := Color(0.95, 0.35, 0.28)
const HEAL_COLOR := Color(0.45, 0.85, 0.55)
const PORTAL_COLOR := Color(0.42, 0.78, 0.95)
const PORTAL_CORE := Color(0.08, 0.16, 0.28)
const EXIT_COLOR := Color(0.95, 0.78, 0.38)
const PLACEHOLDER_COLOR := Color(0.72, 0.58, 0.28)
const CRYPT_FLOOR := Color(0.11, 0.09, 0.08)
const CRYPT_DARK := Color(0.16, 0.12, 0.10)

var _sticks: VirtualSticks
var _player: Polygon2D
var _shots: Node2D
var _patterns: Node2D
var _enemies: Node2D
var _camera: Camera2D
var _hint: Label
var _hp: Label
var _level: Label
var _xp: Label
var _xp_bar: ProgressBar
var _inv: Label
var _bags: Node2D
var _bag_views: Dictionary = {}
var _bag_free: Array[Polygon2D] = []
var _portals: Node2D
var _portal_views: Dictionary = {}
var _portal_free: Array[Polygon2D] = []
var _loot_btn: Button
var _prompt: Label
var _ability: Label
var _floats: Node2D
var _last_player_hp: int = -1
var _last_enemy_hp: Dictionary = {}
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
	_bags = Node2D.new()
	_bags.name = "LootBags"
	add_child(_bags)
	_portals = Node2D.new()
	_portals.name = "Portals"
	add_child(_portals)
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
	_level = Label.new()
	_level.name = "Level"
	_level.add_theme_font_size_override("font_size", 16)
	_level.add_theme_color_override("font_color", Color(0.91, 0.76, 0.48))
	_xp = Label.new()
	_xp.name = "XP"
	_xp.add_theme_font_size_override("font_size", 14)
	_xp.add_theme_color_override("font_color", Color(0.82, 0.9, 0.88))
	_xp_bar = ProgressBar.new()
	_xp_bar.name = "XPBar"
	_xp_bar.min_value = 0.0
	_xp_bar.max_value = 1.0
	_xp_bar.value = 0.0
	_xp_bar.show_percentage = false
	_xp_bar.custom_minimum_size = Vector2(220, 8)
	_inv = Label.new()
	_inv.name = "Inventory"
	_inv.add_theme_font_size_override("font_size", 14)
	_inv.add_theme_color_override("font_color", Color(0.82, 0.9, 0.88))
	_ability = Label.new()
	_ability.name = "Ability"
	_ability.add_theme_font_size_override("font_size", 14)
	_ability.add_theme_color_override("font_color", Color(0.82, 0.9, 0.88))
	_prompt = Label.new()
	_prompt.name = "InteractPrompt"
	_prompt.add_theme_font_size_override("font_size", 18)
	_prompt.add_theme_color_override("font_color", Color(0.85, 0.95, 0.98))
	_loot_btn = Button.new()
	_loot_btn.name = "LootButton"
	_loot_btn.text = "Loot"
	_loot_btn.visible = false
	_loot_btn.pressed.connect(_on_loot_pressed)
	_floats = Node2D.new()
	_floats.name = "Floaters"
	add_child(_floats)
	var layer := CanvasLayer.new()
	layer.layer = 5
	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	margin.add_theme_constant_override("margin_left", 16)
	margin.add_theme_constant_override("margin_top", 12)
	var vbox := VBoxContainer.new()
	vbox.add_child(_hint)
	vbox.add_child(_hp)
	vbox.add_child(_level)
	vbox.add_child(_xp)
	vbox.add_child(_xp_bar)
	vbox.add_child(_inv)
	vbox.add_child(_ability)
	vbox.add_child(_prompt)
	vbox.add_child(_loot_btn)
	margin.add_child(vbox)
	layer.add_child(margin)
	add_child(layer)
	var host_panel: Control = preload("res://src/render/host_lobby_panel.tscn").instantiate() as Control
	host_panel.name = "HostLobbyPanel"
	var host_layer := CanvasLayer.new()
	host_layer.layer = 6
	host_layer.add_child(host_panel)
	add_child(host_layer)
	_refresh_hint()
	queue_redraw()


func _in_crypt() -> bool:
	var snap := GameSession.curr_snapshot
	if snap == null:
		return false
	for portal in snap.portals:
		if portal.kind == PortalSnapshot.KIND_EXIT or portal.kind == PortalSnapshot.KIND_PLACEHOLDER:
			return true
	return false


func _arena_tiles() -> int:
	var tiles: int = int(ARENA_TILES)
	var snap := GameSession.curr_snapshot
	if snap == null:
		return tiles
	var max_c: float = float(tiles)
	max_c = maxf(max_c, snap.player_x + 2.0)
	max_c = maxf(max_c, snap.player_y + 2.0)
	for e in snap.enemies:
		max_c = maxf(max_c, e.x + 2.0)
		max_c = maxf(max_c, e.y + 2.0)
	for portal in snap.portals:
		max_c = maxf(max_c, portal.x + 2.0)
		max_c = maxf(max_c, portal.y + 2.0)
	return int(ceil(max_c))


func _draw() -> void:
	var tiles := _arena_tiles()
	var px := SimConstants.TILE_PX
	var size := float(tiles) * px
	var crypt := _in_crypt()
	var floor_c := CRYPT_FLOOR if crypt else Color(0.09, 0.13, 0.16)
	var dark := CRYPT_DARK if crypt else Color(0.13, 0.18, 0.22)
	var edge := Color(0.78, 0.58, 0.28, 0.55) if crypt else Color(0.48, 0.82, 0.78, 0.55)
	draw_rect(Rect2(0.0, 0.0, size, size), floor_c)
	for y in range(tiles):
		for x in range(tiles):
			if (x + y) % 2 == 0:
				draw_rect(Rect2(float(x) * px, float(y) * px, px, px), dark)
	draw_rect(Rect2(0.0, 0.0, size, size), edge, false, 2.0)


func _process(_delta: float) -> void:
	_sample_input()
	_update_player_view()
	_update_enemy_views()
	_update_shot_views()
	_update_pattern_views()
	_update_bag_views()
	_update_portal_views()
	_update_hud()
	queue_redraw()
	_update_combat_floaters()
	_update_floaters()
	if _hint_touch != _sticks.using_touch:
		_refresh_hint()


func _refresh_hint() -> void:
	_hint_touch = _sticks.using_touch
	if _hint_touch:
		_hint.text = "Left stick moves · right stick aims and fires · ability button above the right stick · Loot or Enter when something is in range · a Burrmite, a Driftcap Spore, and a Hollowmere portal share the yard"
	else:
		_hint.text = "WASD or arrows to move · mouse to aim · hold left click to fire · Space or right-click for ability · E to loot or enter · 1–8 equip · a Burrmite, a Driftcap Spore, and a Hollowmere portal share the yard"


func _sample_input() -> void:
	if _sticks.using_touch:
		GameSession.move_x = _sticks.move_x
		GameSession.move_y = _sticks.move_y
		GameSession.aim = _sticks.aim
		GameSession.fire_held = _sticks.fire_held
		if _sticks.consume_ability_pressed():
			GameSession.ability_pressed = true
		return
	GameSession.move_x = Input.get_axis("move_left", "move_right")
	GameSession.move_y = Input.get_axis("move_up", "move_down")
	GameSession.fire_held = Input.is_action_pressed("fire")
	if Input.is_action_just_pressed("ability"):
		GameSession.ability_pressed = true
	if Input.is_action_just_pressed("interact"):
		GameSession.interact_pressed = true
		GameSession.interact_target_id = _nearest_prompt_interactable_id()
	for i in range(1, 9):
		if Input.is_action_just_pressed("inventory_%d" % i):
			GameSession.inventory_slot = i
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


func _circle_shape(radius_px: float, sides: int = 10) -> PackedVector2Array:
	var pts := PackedVector2Array()
	for i in range(sides):
		var a: float = TAU * float(i) / float(sides)
		pts.append(Vector2(cos(a) * radius_px, sin(a) * radius_px))
	return pts


func _cap_shape(radius_px: float) -> PackedVector2Array:
	# Wide mushroom cap, distinct from the Burrmite silhouette.
	return PackedVector2Array([
		Vector2(radius_px * 1.15, 0.15 * radius_px),
		Vector2(radius_px * 0.85, 0.55 * radius_px),
		Vector2(0.0, 0.45 * radius_px),
		Vector2(-radius_px * 0.85, 0.55 * radius_px),
		Vector2(-radius_px * 1.15, 0.15 * radius_px),
		Vector2(-radius_px * 0.7, -0.45 * radius_px),
		Vector2(0.0, -0.70 * radius_px),
		Vector2(radius_px * 0.7, -0.45 * radius_px),
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
	if pool.has(id):
		return pool[id]
	# Reuse a recycled view only when radius, kind and color match, so a
	# brown bag cannot inherit a gold bag's color. Color is also written
	# on reuse so a mismatch can never show the previous tint.
	for i in range(free.size() - 1, -1, -1):
		var cand: Polygon2D = free[i]
		if float(cand.get_meta("r", -1.0)) == radius_px \
				and String(cand.get_meta("kind", "")) == kind \
				and cand.get_meta("color", Color(0, 0, 0, 0)) == color:
			free.remove_at(i)
			cand.color = color
			cand.visible = true
			pool[id] = cand
			_ensure_shot_outline(cand, parent, radius_px)
			return cand
	var view := Polygon2D.new()
	view.color = color
	if kind == "enemy":
		view.polygon = _enemy_shape(radius_px)
	elif kind == "driftcap":
		view.polygon = _cap_shape(radius_px)
	elif kind == "spore":
		view.polygon = _circle_shape(radius_px)
	else:
		view.polygon = _diamond(radius_px)
	view.set_meta("r", radius_px)
	view.set_meta("kind", kind)
	view.set_meta("color", color)
	parent.add_child(view)
	pool[id] = view
	_ensure_shot_outline(view, parent, radius_px)
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
		var is_spore: bool = b.pattern_id == "spore_ring"
		var color: Color = SPORE_COLOR if is_spore else PATTERN_COLOR
		var kind: String = "spore" if is_spore else "diamond"
		var view := _acquire_view(_patterns, _pattern_views, _pattern_free, id, color, r, kind)
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
		var is_cap: bool = e.def_id == "driftcap_spore"
		var color: Color = DRIFTCAP_COLOR if is_cap else ENEMY_COLOR
		var kind: String = "driftcap" if is_cap else "enemy"
		var view := _acquire_view(_enemies, _enemy_views, _enemy_free, id, color, r, kind)
		var x: float = e.x
		var y: float = e.y
		if prev_by_id.has(id):
			var p: EnemySnapshot = prev_by_id[id]
			x = lerpf(p.x, e.x, alpha)
			y = lerpf(p.y, e.y, alpha)
		view.position = Vector2(x * SimConstants.TILE_PX, y * SimConstants.TILE_PX)
		# Rooted Driftcaps do not rotate with aim; Burrmites still do.
		if not is_cap:
			view.rotation = e.aim
		view.color = FLASH_COLOR if e.flash_ticks > 0 else color

func _on_loot_pressed() -> void:
	GameSession.interact_pressed = true
	GameSession.interact_target_id = _nearest_prompt_interactable_id()


func _prompt_range() -> float:
	if GameSession.catalog != null and GameSession.catalog.scaling != null:
		return GameSession.catalog.scaling.interact_prompt_range_tiles
	return 0.0


func _nearest_prompt_interactable_id() -> int:
	var snap := GameSession.curr_snapshot
	if snap == null or GameSession.catalog == null or GameSession.catalog.scaling == null:
		return 0
	var best_id: int = 0
	var best_d: float = _prompt_range()
	for bag in snap.ground_drops:
		var d: float = SimConstants.interact_distance(snap.player_x, snap.player_y, bag.x, bag.y)
		if GameSession.catalog.scaling.in_prompt_range(d) and d <= best_d:
			best_d = d
			best_id = bag.id
	for portal in snap.portals:
		if not portal.is_interactable():
			continue
		var d: float = SimConstants.interact_distance(snap.player_x, snap.player_y, portal.x, portal.y)
		if GameSession.catalog.scaling.in_prompt_range(d) and d <= best_d:
			best_d = d
			best_id = portal.id
	return best_id


func _nearest_portal() -> PortalSnapshot:
	var snap := GameSession.curr_snapshot
	if snap == null:
		return null
	var id: int = _nearest_prompt_interactable_id()
	for portal in snap.portals:
		if portal.id == id and portal.is_interactable():
			return portal
	return null


func _bag_in_range() -> bool:
	return _nearest_prompt_interactable_id() != 0


func _update_hud() -> void:
	var snap := GameSession.curr_snapshot
	_hp.text = "HP %d / %d" % [snap.player_hp, snap.player_max_hp]
	_level.text = "Lv %d" % snap.player_level
	var need: int = snap.xp_to_next_tenths
	var have: int = snap.xp_tenths
	var frac: float = 0.0
	if need > 0:
		frac = clampf(float(have) / float(need), 0.0, 1.0)
	_xp.text = "XP %.1f / %.1f" % [float(have) / 10.0, float(need) / 10.0]
	_xp_bar.value = frac
	var parts: PackedStringArray = PackedStringArray()
	for i in range(snap.inventory.size()):
		var it: ItemState = snap.inventory[i]
		if it != null:
			parts.append("%d:%s" % [i + 1, it.display_name()])
		else:
			parts.append("%d:—" % [i + 1])
	var eq: String = "eq:"
	if snap.equipped_weapon != null:
		eq += " " + snap.equipped_weapon.display_name()
	if snap.equipped_armor != null:
		eq += " " + snap.equipped_armor.display_name()
	if snap.equipped_charm != null:
		eq += " " + snap.equipped_charm.display_name()
	_inv.text = " ".join(parts) + "  " + eq
	if snap.pending_glint > 0:
		_inv.text += "  Glint %d (pending)" % snap.pending_glint
	var focus_show: int = int(snap.player_focus)
	var ability_name: String = snap.ability_name if snap.ability_name != "" else "Ability"
	if snap.ability_cooldown_ticks > 0:
		var secs: float = float(snap.ability_cooldown_ticks) * SimConstants.TICK_DT
		_ability.text = "%s  %.1fs  Focus %d / %d" % [ability_name, secs, focus_show, snap.player_focus_max]
	else:
		_ability.text = "%s  Ready  Focus %d / %d" % [ability_name, focus_show, snap.player_focus_max]
	var portal := _nearest_portal()
	if portal != null:
		var m_label: String = "×%.2f" % (float(portal.m100) / 100.0)
		if portal.kind == PortalSnapshot.KIND_ENTER:
			_prompt.text = "E to enter %s  ·  E%d  %s" % [portal.dungeon_name, portal.content_level, m_label]
			_loot_btn.text = "Enter"
		else:
			_prompt.text = "E to leave %s" % portal.dungeon_name
			_loot_btn.text = "Leave"
		_prompt.visible = true
	else:
		_prompt.text = ""
		_prompt.visible = false
		_loot_btn.text = "Loot"
	_loot_btn.visible = _sticks.using_touch and _bag_in_range()


func _bag_color(kind: String) -> Color:
	match kind:
		"teal":
			return BAG_TEAL
		"gold":
			return BAG_GOLD
		_:
			return BAG_BROWN


func _update_bag_views() -> void:
	var snap := GameSession.curr_snapshot
	var live: Dictionary = {}
	for bag in snap.ground_drops:
		live[bag.id] = bag
	_release_unused(_bag_views, _bag_free, live)
	for id in live.keys():
		var bag: GroundDrop = live[id]
		var kind: String = "brown"
		if bag.item != null:
			kind = bag.item.bag_color_kind(bag.t_star)
		var view := _acquire_view(_bags, _bag_views, _bag_free, id, _bag_color(kind), 6.0, "diamond")
		view.position = Vector2(bag.x * SimConstants.TILE_PX, bag.y * SimConstants.TILE_PX)



func _ring_shape(radius_px: float, sides: int = 10) -> PackedVector2Array:
	var pts := PackedVector2Array()
	for i in range(sides):
		var a: float = TAU * float(i) / float(sides)
		pts.append(Vector2(cos(a), sin(a)) * radius_px)
	return pts


func _candle_shape(radius_px: float) -> PackedVector2Array:
	var r: float = radius_px
	return PackedVector2Array([
		Vector2(0.0, -r * 1.6),
		Vector2(r * 0.55, -r * 0.2),
		Vector2(r * 0.35, r * 1.1),
		Vector2(-r * 0.35, r * 1.1),
		Vector2(-r * 0.55, -r * 0.2),
	])


func _update_portal_views() -> void:
	var snap := GameSession.curr_snapshot
	var live: Dictionary = {}
	if snap != null:
		for portal in snap.portals:
			live[portal.id] = portal
	_release_unused(_portal_views, _portal_free, live)
	var spin: float = Time.get_ticks_msec() * 0.0015
	for id in live.keys():
		var portal: PortalSnapshot = live[id]
		var r: float = maxf(portal.radius, 0.4) * SimConstants.TILE_PX
		var kind: String = portal.kind
		var color: Color = PORTAL_COLOR
		if kind == PortalSnapshot.KIND_EXIT:
			color = EXIT_COLOR
		elif kind == PortalSnapshot.KIND_PLACEHOLDER:
			color = PLACEHOLDER_COLOR
		var view := _acquire_view(_portals, _portal_views, _portal_free, id, color, r, kind)
		view.position = Vector2(portal.x * SimConstants.TILE_PX, portal.y * SimConstants.TILE_PX)
		if kind == PortalSnapshot.KIND_PLACEHOLDER:
			view.polygon = _candle_shape(r)
			view.rotation = 0.0
		else:
			view.polygon = _ring_shape(r)
			view.rotation = spin if kind == PortalSnapshot.KIND_ENTER else -spin
			var core: Polygon2D = view.get_node_or_null("Core")
			if core == null:
				core = Polygon2D.new()
				core.name = "Core"
				view.add_child(core)
			core.color = PORTAL_CORE
			core.polygon = _ring_shape(r * 0.45)

func _ensure_shot_outline(view: Polygon2D, parent: Node2D, radius_px: float) -> void:
	if parent != _shots and parent != _patterns:
		return
	var outline: Polygon2D = view.get_node_or_null("Outline")
	if outline == null:
		outline = Polygon2D.new()
		outline.name = "Outline"
		outline.show_behind_parent = true
		outline.color = SHOT_OUTLINE if parent == _shots else PATTERN_OUTLINE
		view.add_child(outline)
	var kind := String(view.get_meta("kind", "diamond"))
	if kind == "spore":
		outline.polygon = _circle_shape(radius_px + 1.5)
	else:
		outline.polygon = _diamond(radius_px + 1.5)


func _update_combat_floaters() -> void:
	var curr := GameSession.curr_snapshot
	var prev := GameSession.prev_snapshot
	if curr.tick <= 0:
		_last_player_hp = curr.player_hp
		_last_enemy_hp.clear()
		for e in curr.enemies:
			_last_enemy_hp[e.id] = e.hp
		return
	if _last_player_hp >= 0 and curr.player_hp != _last_player_hp:
		_spawn_floater(GameSession.interpolated_player_pixels(), curr.player_hp - _last_player_hp)
	_last_player_hp = curr.player_hp
	var seen: Dictionary = {}
	for e in curr.enemies:
		seen[e.id] = true
		var prev_hp: int = int(_last_enemy_hp.get(e.id, e.hp))
		for p in prev.enemies:
			if p.id == e.id:
				prev_hp = p.hp
				break
		if e.hp != prev_hp:
			_spawn_floater(Vector2(e.x * SimConstants.TILE_PX, e.y * SimConstants.TILE_PX), e.hp - prev_hp)
		_last_enemy_hp[e.id] = e.hp
	for id in _last_enemy_hp.keys():
		if not seen.has(id):
			_last_enemy_hp.erase(id)


func _spawn_floater(pos: Vector2, delta: int) -> void:
	if delta == 0 or _floats == null:
		return
	var lab := Label.new()
	lab.text = ("+%d" % delta) if delta > 0 else str(delta)
	lab.add_theme_font_size_override("font_size", 14)
	lab.add_theme_color_override("font_color", HEAL_COLOR if delta > 0 else DAMAGE_COLOR)
	lab.position = pos + Vector2(-8.0, -18.0)
	lab.set_meta("age", 0.0)
	lab.set_meta("origin", lab.position)
	_floats.add_child(lab)


func _update_floaters() -> void:
	if _floats == null:
		return
	var dt: float = get_process_delta_time()
	for child in _floats.get_children():
		var lab := child as Label
		if lab == null:
			continue
		var age: float = float(lab.get_meta("age", 0.0)) + dt
		lab.set_meta("age", age)
		var origin: Vector2 = lab.get_meta("origin", lab.position)
		lab.position = origin + Vector2(0.0, -28.0 * age)
		var col: Color = lab.get_theme_color("font_color")
		col.a = clampf(1.0 - age / 0.7, 0.0, 1.0)
		lab.add_theme_color_override("font_color", col)
		if age >= 0.7:
			lab.queue_free()
