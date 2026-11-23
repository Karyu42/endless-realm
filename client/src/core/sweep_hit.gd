class_name SweepHit
extends Object
## Swept circle-circle test between two ticks. Shared contract with server/internal/sim.


static func segment_circle(ax: float, ay: float, bx: float, by: float, cx: float, cy: float, radius: float) -> bool:
	var abx: float = bx - ax
	var aby: float = by - ay
	var acx: float = cx - ax
	var acy: float = cy - ay
	var ab_len2: float = abx * abx + aby * aby
	var t: float = 0.0
	if ab_len2 > SimConstants.MOVE_EPS:
		t = clampf((acx * abx + acy * aby) / ab_len2, 0.0, 1.0)
	var dx: float = ax + abx * t - cx
	var dy: float = ay + aby * t - cy
	return dx * dx + dy * dy <= radius * radius


static func moving_circles(a0x: float, a0y: float, a1x: float, a1y: float, ra: float, b0x: float, b0y: float, b1x: float, b1y: float, rb: float) -> bool:
	return segment_circle(b0x - a0x, b0y - a0y, b1x - a1x, b1y - a1y, 0.0, 0.0, ra + rb)
