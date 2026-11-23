class_name GroundDrop
extends RefCounted
## A personal bag on the ground. Visible only to its owner.

var id: int = 0
var item: ItemState
var x: float = 0.0
var y: float = 0.0
var spawn_tick: int = 0
var t_star: int = 0


func expired_at(sim_tick: int, expiry_ticks: int) -> bool:
	return sim_tick - spawn_tick >= expiry_ticks
