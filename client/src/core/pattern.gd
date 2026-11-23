class_name PatternDef
extends RefCounted
## Closed-form bullet pattern. Mirrors server/internal/sim and data/patterns.json.

const RADIUS_S: float = 0.15
const RADIUS_M: float = 0.25
const RADIUS_L: float = 0.40

var id: String = ""
var type: String = "fan"
var count: int = 1
var spread_deg: float = 0.0
var aim: String = "aimed"
var start_angle_deg: float = 0.0
var rotate_per_fire_deg: float = 0.0
var angle_offset_cycle_deg: Array[float] = []
var skip_consecutive: int = 0
var skip_start_rng: bool = false
var skip_start: int = 0
var speed: float = 1.0
var range_tiles: float = 1.0
var size: String = "S"
var damage_key: String = ""
var trigger: String = "timer"
var interval_ticks: int = 30


static func lifetime_ticks(range_tiles: float, speed: float) -> int:
	if speed <= SimConstants.MOVE_EPS:
		return 1
	return int(ceil(range_tiles / speed * float(SimConstants.TICK_HZ)))


static func size_radius(size: String) -> float:
	match size:
		"M":
			return RADIUS_M
		"L":
			return RADIUS_L
		_:
			return RADIUS_S


static func from_json(d: Dictionary) -> PatternDef:
	var p := PatternDef.new()
	p.id = String(d.get("id", ""))
	p.type = String(d.get("type", "fan"))
	p.count = int(d.get("count", 1))
	p.spread_deg = float(d.get("spread_deg", 0.0))
	p.aim = String(d.get("aim", "aimed"))
	p.start_angle_deg = float(d.get("start_angle_deg", 0.0))
	p.rotate_per_fire_deg = float(d.get("rotate_per_fire_deg", 0.0))
	p.speed = float(d.get("speed", 1.0))
	p.range_tiles = float(d.get("range", 1.0))
	p.size = String(d.get("size", "S"))
	p.damage_key = String(d.get("damage_key", ""))
	p.trigger = String(d.get("trigger", "timer"))
	p.interval_ticks = int(d.get("interval_ticks", 30))
	var cycle: Variant = d.get("angle_offset_cycle_deg", [])
	if cycle is Array:
		for v in cycle:
			p.angle_offset_cycle_deg.append(float(v))
	var skip: Variant = d.get("skip", null)
	if skip is Dictionary:
		p.skip_consecutive = int(skip.get("consecutive", 0))
		var start: Variant = skip.get("start", 0)
		if start is String and String(start) == "rng":
			p.skip_start_rng = true
		else:
			p.skip_start = int(start)
	if p.count < 1:
		p.count = 1
	return p


func emit(seed: int, origin_x: float, origin_y: float, aim_rad: float, volley_index: int) -> Array[PatternBullet]:
	var base: float = _base_angle(aim_rad, volley_index)
	if type == "ring":
		var rng: PCG32 = PCG32.new(seed, 1) if skip_start_rng else null
		return _emit_ring(rng, origin_x, origin_y, base)
	return _emit_fan(origin_x, origin_y, base)


func _base_angle(aim_rad: float, volley_index: int) -> float:
	var angle: float = aim_rad
	if aim == "fixed":
		angle = deg_to_rad(start_angle_deg)
	angle += deg_to_rad(rotate_per_fire_deg * float(volley_index))
	var n: int = angle_offset_cycle_deg.size()
	if n > 0:
		angle += deg_to_rad(angle_offset_cycle_deg[volley_index % n])
	return angle


func _emit_fan(ox: float, oy: float, base: float) -> Array[PatternBullet]:
	var out: Array[PatternBullet] = []
	if count <= 1:
		out.append(_bullet(0, base, ox, oy))
		return out
	var spread: float = deg_to_rad(spread_deg)
	var step: float = spread / float(count - 1)
	var start: float = base - spread * 0.5
	for i in range(count):
		out.append(_bullet(i, start + float(i) * step, ox, oy))
	return out


func _emit_ring(rng: PCG32, ox: float, oy: float, base: float) -> Array[PatternBullet]:
	var start_i: int = skip_start
	if skip_start_rng and rng != null:
		start_i = int(rng.uint32() % (count as int))
	var step: float = TAU / float(count)
	var out: Array[PatternBullet] = []
	for i in range(count):
		if skip_consecutive > 0 and _in_skip(i, start_i, skip_consecutive, count):
			continue
		out.append(_bullet(i, base + float(i) * step, ox, oy))
	return out


static func _in_skip(i: int, start: int, consecutive: int, n: int) -> bool:
	for k in range(consecutive):
		if i == (start + k) % n:
			return true
	return false


func _bullet(index: int, angle: float, ox: float, oy: float) -> PatternBullet:
	var b := PatternBullet.new()
	b.index = index
	b.angle_rad = angle
	b.origin_x = ox
	b.origin_y = oy
	b.speed = speed
	b.range_tiles = range_tiles
	b.lifetime_ticks = lifetime_ticks(range_tiles, speed)
	b.radius_tiles = size_radius(size)
	b.damage_key = damage_key
	return b
