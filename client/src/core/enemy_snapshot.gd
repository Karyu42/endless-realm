class_name EnemySnapshot
extends RefCounted
## Render-facing copy of one enemy at a tick. Not a sim object.

var id: int = 0
var def_id: String = ""
var x: float = 0.0
var y: float = 0.0
var aim: float = 0.0
var hp: int = 0
var max_hp: int = 0
var radius: float = 0.35
var content_level: int = 1
var flash_ticks: int = 0
var alive: bool = true
var phase_id: String = ""
var invulnerable: bool = false


func to_pixels() -> Vector2:
	return Vector2(x * SimConstants.TILE_PX, y * SimConstants.TILE_PX)
