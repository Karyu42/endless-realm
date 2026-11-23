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
var radius_tiles: float = 0.12
var damage_key: String = ""
var source_id: int = 0
var consumed: bool = false


func position_at_time(time_ticks: float) -> SimVec2:
	var elapsed: float = time_ticks - float(spawn_tick)
	if elapsed < 0.0:
		elapsed = 0.0
	var dist: float = speed * elapsed * SimConstants.TICK_DT
	return SimVec2.from_xy(origin_x + cos(angle_rad) * dist, origin_y + sin(angle_rad) * dist)


func is_alive_at(tick: int) -> bool:
	if consumed:
		return false
	var elapsed: int = tick - spawn_tick
	if elapsed < 0 or elapsed >= lifetime_ticks:
		return false
	var dist: float = speed * float(elapsed) * SimConstants.TICK_DT
	return dist < range_tiles
