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


func radius() -> float:
	return def.radius if def != null else 0.35


func max_hp() -> int:
	return def.base_hp if def != null else 1
