class_name HazardState
extends RefCounted
## Ground pool or telegraph (content-v0.1 hazard patterns). Render-safe.

var id: int = 0
var x: float = 0.0
var y: float = 0.0
var radius: float = 1.5
var telegraph_ticks: int = 0
var duration_ticks: int = 0
var tick_interval_ticks: int = 1
var slow_pct: float = 0.0
var damage_key: String = ""
var source_id: int = 0
var spawn_tick: int = 0


func age(tick: int) -> int:
	return tick - spawn_tick


func is_telegraph(tick: int) -> bool:
	var a: int = age(tick)
	return a >= 0 and a < telegraph_ticks


func is_active(tick: int) -> bool:
	var a: int = age(tick)
	return a >= telegraph_ticks and a < telegraph_ticks + duration_ticks


## Active-period age, 0 on the first damaging tick.
func active_age(tick: int) -> int:
	return age(tick) - telegraph_ticks


func should_damage(tick: int) -> bool:
	if not is_active(tick):
		return false
	if tick_interval_ticks <= 0:
		return false
	var a: int = active_age(tick)
	return a < duration_ticks and a % tick_interval_ticks == 0


func expired(tick: int) -> bool:
	return age(tick) >= telegraph_ticks + duration_ticks


func contains(px: float, py: float) -> bool:
	var dx: float = px - x
	var dy: float = py - y
	return dx * dx + dy * dy <= radius * radius
