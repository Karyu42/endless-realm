class_name StickMath
extends RefCounted
## Touch-stick and gamepad aim math. Pure functions, no Nodes.

## Viewport-pixel radius of a physical thumb size.
## screen_px and viewport_px are the same axis (width or height).
static func radius_viewport_px(size_mm: float, dpi: float, screen_px: float, viewport_px: float) -> float:
	if size_mm <= 0.0 or dpi <= 0.0 or screen_px <= 0.0 or viewport_px <= 0.0:
		return 0.0
	return size_mm / 25.4 * dpi * (viewport_px / screen_px)


## Offset from the stick center, clamped to radius.
static func clamped_offset(pos: Vector2, center: Vector2, radius: float) -> Vector2:
	var offset := pos - center
	if radius <= 0.0:
		return Vector2.ZERO
	if offset.length() > radius:
		return offset.normalized() * radius
	return offset


## Unit-length stick vector after a radial deadzone. Zero if inside the zone.
static func after_deadzone(offset: Vector2, radius: float, deadzone: float) -> Vector2:
	if radius <= 0.0:
		return Vector2.ZERO
	var raw := offset / radius
	if raw.length() < deadzone:
		return Vector2.ZERO
	return raw


## Shortest-path exponential smoothing toward target, with half-life seconds.
static func smooth_angle(current: float, target: float, dt: float, halflife: float) -> float:
	var diff: float = fposmod(target - current + PI, TAU) - PI
	if halflife <= 0.0 or dt <= 0.0:
		return current + diff
	var t: float = 1.0 - pow(0.5, dt / halflife)
	return current + diff * clampf(t, 0.0, 1.0)
