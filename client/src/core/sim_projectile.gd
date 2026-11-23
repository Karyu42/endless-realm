class_name SimProjectile
extends RefCounted
## Linear, closed-form shot: position = origin + dir * speed * elapsed * TICK_DT.

var id: int = 0
var spawn_tick: int = 0
var origin_x: float = 0.0
var origin_y: float = 0.0
var dir_x: float = 1.0
var dir_y: float = 0.0
var speed: float = 0.0
var range_tiles: float = 0.0
var lifetime_ticks: int = 0
var radius_tiles: float = 0.15
## The player who fired this shot. Used so remove_player can drop in-flight shots.
var owner_id: int = 0
## Set when the shot hits a target; it is culled at the end of the tick.
var consumed: bool = false


func elapsed_ticks_at(tick: int) -> int:
	return tick - spawn_tick


func distance_at_time(time_ticks: float) -> float:
	var elapsed: float = time_ticks - float(spawn_tick)
	if elapsed <= 0.0:
		return 0.0
	return speed * elapsed * SimConstants.TICK_DT


func is_alive_at(tick: int) -> bool:
	if consumed:
		return false
	var elapsed := elapsed_ticks_at(tick)
	if elapsed < 0 or elapsed >= lifetime_ticks:
		return false
	return distance_at_time(float(tick)) < range_tiles


func write_position_at_time(time_ticks: float, out: SimVec2) -> void:
	var elapsed: float = time_ticks - float(spawn_tick)
	if elapsed < 0.0:
		elapsed = 0.0
	var dist: float = speed * elapsed * SimConstants.TICK_DT
	out.x = origin_x + dir_x * dist
	out.y = origin_y + dir_y * dist


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
	return Vector2((origin_x + dir_x * dist) * px, (origin_y + dir_y * dist) * px)
