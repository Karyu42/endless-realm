class_name WorldSnapshot
extends RefCounted
## Read-only view of sim state at one tick. Render nodes interpolate between two of these.

var tick: int = 0
var player_id: int = 1
var player_x: float = 0.0
var player_y: float = 0.0
var player_aim: float = 0.0
var applied_seq: int = 0
var projectiles: Array[SimProjectile] = []


func player_pixels() -> Vector2:
	return Vector2(player_x * SimConstants.TILE_PX, player_y * SimConstants.TILE_PX)


func duplicate_snapshot() -> WorldSnapshot:
	var copy := WorldSnapshot.new()
	copy.tick = tick
	copy.player_id = player_id
	copy.player_x = player_x
	copy.player_y = player_y
	copy.player_aim = player_aim
	copy.applied_seq = applied_seq
	copy.projectiles = projectiles.duplicate()
	return copy
