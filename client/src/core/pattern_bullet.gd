class_name PatternBullet
extends RefCounted
## One closed-form shot emitted by a PatternSpawn.

var id: int = 0
var index: int = 0
var spawn_tick: int = 0
var angle_rad: float = 0.0
var origin_x: float = 0.0
var origin_y: float = 0.0
var speed: float = 0.0
var range_tiles: float = 0.0
var lifetime_ticks: int = 0
var radius_tiles: float = 0.15
var damage_key: String = ""
var source_id: int = 0
var consumed: bool = false


func write_position_at_time(time_ticks: float, out: SimVec2) -> void:
	var elapsed: float = time_ticks - float(spawn_tick)
	if elapsed < 0.0:
		elapsed = 0.0
	var dist: float = speed * elapsed * SimConstants.TICK_DT
	out.x = origin_x + cos(angle_rad) * dist
	out.y = origin_y + sin(angle_rad) * dist


func position_at_time(time_ticks: float) -> SimVec2:
	var out := SimVec2.new()
	write_position_at_time(time_ticks, out)
	return out


func pixel_position_at_time(time_ticks: float) -> Vector2:
	var elapsed: float = time_ticks - float(spawn_tick)
	if elapsed < 0.0:
		elapsed = 0.0
	var dist: float = speed * elapsed * SimConstants.TICK_DT
	var px := SimConstants.TILE_PX
	return Vector2((origin_x + cos(angle_rad) * dist) * px, (origin_y + sin(angle_rad) * dist) * px)


func is_alive_at(tick: int) -> bool:
	if consumed:
		return false
	var elapsed: int = tick - spawn_tick
	if elapsed < 0 or elapsed >= lifetime_ticks:
		return false
	var dist: float = speed * float(elapsed) * SimConstants.TICK_DT
	return dist < range_tiles
