class_name SimVec2
extends RefCounted
## float64 2D vector for sim math. Do not use Godot's Vector2 (float32) in the sim.
## Rendering may convert with to_pixels().

var x: float = 0.0
var y: float = 0.0


static func from_xy(x0: float, y0: float) -> SimVec2:
	var v := SimVec2.new()
	v.x = x0
	v.y = y0
	return v


func length_squared() -> float:
	return x * x + y * y


func length() -> float:
	return sqrt(length_squared())


func plus(other: SimVec2) -> SimVec2:
	return SimVec2.from_xy(x + other.x, y + other.y)


func scaled(s: float) -> SimVec2:
	return SimVec2.from_xy(x * s, y * s)


## Unit length, or zero if this is near the origin.
func normalized() -> SimVec2:
	var len := length()
	if len <= SimConstants.MOVE_EPS:
		return SimVec2.new()
	return SimVec2.from_xy(x / len, y / len)


## Godot 2D convention: +X = 0 rad, +Y down, clockwise positive.
static func from_angle(radians: float) -> SimVec2:
	return SimVec2.from_xy(cos(radians), sin(radians))


func to_pixels() -> Vector2:
	return Vector2(x * SimConstants.TILE_PX, y * SimConstants.TILE_PX)
