class_name EnemyState
extends RefCounted
## Runtime enemy in LocalSim. Plain RefCounted; no Node or input.

var id: int = 0
var def: EnemyDef
var x: float = 0.0
var y: float = 0.0
var prev_x: float = 0.0
var prev_y: float = 0.0
var home_x: float = 0.0
var home_y: float = 0.0
var hp: int = 1
var aim: float = 0.0
var alive: bool = true
var aggro: bool = false
var target_id: int = 0
var target_repick_tick: int = 0
var fire_cooldown: int = 0
var volley_index: int = 0
var strafe_sign: float = 1.0
var strafe_ticks: int = 0
var wander_angle: float = 0.0
var wander_ticks: int = 0
var contact_cooldown: int = 0
var content_level: int = 1
var damaged_by: Dictionary = {} # player_id -> true
var rewards_granted: bool = false
var flash_ticks: int = 0
var scaled_max_hp: int = 0
var n_peak: int = 1
var phase_index: int = 0
var phase_age: int = 0
var invulnerable: bool = false
var seal_tick: int = -1
var last_aim_target_id: int = 0
var same_target_streak: int = 0
var drops_loot: bool = true
var summoned: bool = false
var room_id: String = ""
var fire_cycle: int = 0
var sidestep_cooldown: int = 0
var sidestep_left: int = 0
var sidestep_dx: float = 0.0
var sidestep_dy: float = 0.0
var loop_once_fired: Dictionary = {}


func radius() -> float:
	return def.radius if def != null else 0.35


func max_hp() -> int:
	if scaled_max_hp > 0:
		return scaled_max_hp
	return def.base_hp if def != null else 1


func phase_id() -> String:
	if def == null or phase_index < 0 or phase_index >= def.phases.size():
		return ""
	return String(def.phases[phase_index].get("id", ""))


func current_phase() -> Dictionary:
	if def == null or phase_index < 0 or phase_index >= def.phases.size():
		return {}
	return def.phases[phase_index]


func is_boss() -> bool:
	return def != null and def.is_boss()
