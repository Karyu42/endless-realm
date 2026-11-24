class_name SimPlayerState
extends RefCounted
## Per-player runtime state in a shared LocalSim. Named SimPlayerState because
## the host proto file already has a nested PlayerState. Class abilities can
## extend this type (or hang new fields on it) without changing the sim's player map.

var id: int = 0
var x: float = 0.0
var y: float = 0.0
var prev_x: float = 0.0
var prev_y: float = 0.0
var aim: float = 0.0
var hp: int = 0
## When >= 0, _current_max_hp uses this instead of scaled class HP (place_ally).
var max_hp_override: int = -1
var flash_ticks: int = 0
var applied_seq: int = 0
var intent: InputIntent = InputIntent.new()
## vision §6.1 rule 7: last activity stamp (a sim tick). Seeded on join or
## instance entry and never unset.
var last_activity_tick: int = 0
## Aim (radians) recorded at the last activity stamp. Seeded to 0.
var activity_aim_ref: float = 0.0
## Cumulative actual path, in tiles, since the last stamp. Seeded to 0.
var activity_path: float = 0.0
## Previous tick's fire_held, for the released-to-pressed rising edge.
var activity_fire_held: bool = false
var next_ready: float = 0.0
var hold_since_volley: bool = false
var fire_blocked: bool = false
var class_id: String = ""
var class_def: ClassDef = null
var level: int = 1
var xp_tenths: int = 0
var pending_glint: int = 0
var pending_riftstone: int = 0
var inventory: PlayerInventory = PlayerInventory.new()
var last_interact_seq: int = 0
## PCG32 stream derived from the instance seed and this player id. See
## LocalSim.player_rng_initstate().
var rng: PCG32 = null
