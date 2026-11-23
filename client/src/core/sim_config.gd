class_name SimConfig
extends Resource
## Tunables for the offline slice. Placeholder values until class data lands in data/.
## Stride / Tempo numbers follow the unmerged design notes (vision §2, content-v0.1).

@export var move_speed_tiles_per_s: float = 5.0
@export var fire_rate_shots_per_s: float = 2.0
@export var tempo_bonus: float = 0.0
@export var projectile_speed_tiles_per_s: float = 14.0
@export var projectile_range_tiles: float = 7.0
## 0 means ceil(range / speed * TICK_HZ), per the content-spec rule.
@export var projectile_lifetime_ticks_override: int = 0
@export var player_radius_tiles: float = 0.35
@export var projectile_radius_tiles: float = 0.15


func projectile_lifetime_ticks() -> int:
	if projectile_lifetime_ticks_override > 0:
		return projectile_lifetime_ticks_override
	var speed := projectile_speed_tiles_per_s
	if speed <= SimConstants.MOVE_EPS:
		return 1
	return int(ceil(projectile_range_tiles / speed * float(SimConstants.TICK_HZ)))


## Ticks between shots: ceil(TICK_HZ / rate). 0 means the weapon cannot fire
## (rate is zero or negative). At 2 shots/s and 20 Hz this is exactly 10.
func fire_interval_ticks() -> int:
	var rate: float = fire_rate_shots_per_s * (1.0 + tempo_bonus)
	if rate <= SimConstants.MOVE_EPS:
		return 0
	return int(ceil(float(SimConstants.TICK_HZ) / rate))
