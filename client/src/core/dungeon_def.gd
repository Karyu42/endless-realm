class_name DungeonDef
extends RefCounted
## Packed dungeon layout from data/dungeons/*.json (content-v0.1 §3, §5).

var id: String = ""
var name: String = ""
var base_level: int = 0
## Official runs: whether kills persist XP, currency, gear, bags, and found portals.
var grants_persistent: bool = false
var rooms: Array[Dictionary] = []
var corridors: Array[Dictionary] = []
var practice_yard_portal: Dictionary = {}
var _present: Dictionary = {}


static func from_json(d: Dictionary) -> DungeonDef:
	var def := DungeonDef.new()
	for key in d.keys():
		def._present[String(key)] = true
	def.id = String(d.get("id", ""))
	def.name = String(d.get("name", ""))
	if d.has("base_level"):
		def.base_level = int(d["base_level"])
	if d.has("grants_persistent"):
		def.grants_persistent = bool(d["grants_persistent"])
	for item in d.get("rooms", []):
		if item is Dictionary:
			def.rooms.append((item as Dictionary).duplicate(true))
	for item in d.get("corridors", []):
		if item is Dictionary:
			def.corridors.append((item as Dictionary).duplicate(true))
	var portal: Variant = d.get("practice_yard_portal", {})
	if portal is Dictionary:
		def.practice_yard_portal = (portal as Dictionary).duplicate(true)
	return def


func missing_pack_ids() -> PackedStringArray:
	var ids: PackedStringArray = PackedStringArray()
	for field in ["id", "name", "base_level", "grants_persistent", "rooms", "corridors"]:
		if not _present.has(field):
			ids.append("%s.%s" % [id if id != "" else "dungeon", field])
	if id == "hollowmere_vault":
		for field in ["x", "y", "radius", "m100", "practice_base_level", "grants_persistent", "placeholder"]:
			if not practice_yard_portal.has(field):
				ids.append("%s.practice_yard_portal.%s" % [id, field])
	return ids


func practice_grants_persistent() -> bool:
	# Packed practice_yard_portal.grants_persistent only. A missing field is
	# a pack error (missing_pack_ids) and fails closed (no persistent grants).
	if not practice_yard_portal.has("grants_persistent"):
		return false
	return bool(practice_yard_portal["grants_persistent"])


func arrival_point() -> Vector2:
	for room in rooms:
		if room.has("arrival"):
			var a: Variant = room["arrival"]
			if a is Array and (a as Array).size() >= 2:
				return Vector2(float(a[0]), float(a[1]))
	return Vector2.ZERO


func room_contains(room: Dictionary, x: float, y: float) -> bool:
	var origin: Variant = room.get("origin", [])
	var size: Variant = room.get("size", [])
	if not (origin is Array and size is Array):
		return false
	if (origin as Array).size() < 2 or (size as Array).size() < 2:
		return false
	var ox: float = float(origin[0])
	var oy: float = float(origin[1])
	var w: float = float(size[0])
	var h: float = float(size[1])
	return x >= ox and x < ox + w and y >= oy and y < oy + h


func bounds_rect() -> Rect2:
	var min_x: float = 0.0
	var min_y: float = 0.0
	var max_x: float = 0.0
	var max_y: float = 0.0
	var any: bool = false
	for rect in rooms + corridors:
		var origin: Variant = rect.get("origin", [])
		var size: Variant = rect.get("size", [])
		if not (origin is Array and size is Array):
			continue
		if (origin as Array).size() < 2 or (size as Array).size() < 2:
			continue
		var ox: float = float(origin[0])
		var oy: float = float(origin[1])
		var w: float = float(size[0])
		var h: float = float(size[1])
		if not any:
			min_x = ox
			min_y = oy
			max_x = ox + w
			max_y = oy + h
			any = true
		else:
			min_x = minf(min_x, ox)
			min_y = minf(min_y, oy)
			max_x = maxf(max_x, ox + w)
			max_y = maxf(max_y, oy + h)
	return Rect2(min_x, min_y, max_x - min_x, max_y - min_y)
