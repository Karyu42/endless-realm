class_name PlayerAbilityState
extends RefCounted
## Per-player ability state for LocalSim (focus, cooldown, cast lock, ward,
## invuln, and a PCG32 stream). Keyed by player id so a later shared-world
## merge does not have to lift singletons off LocalSim.

## Third mix_seed argument so this stream cannot overlap loot or wander.
## ASCII "ABIL".
const STREAM_DOMAIN: int = 0x4142494C

var id: int = 0
var ability_def: AbilityDef = null
var class_def: ClassDef = null
var focus: float = 0.0
var cooldown_ticks: int = 0
var cast_lock_ticks: int = 0
var ward_ticks: int = 0
var invuln_ticks: int = 0
## 0 means no ability press has been applied yet (Seq last == 0).
var last_ability_seq: int = 0
## Count of Kindle Pulse casts that actually healed an ally. Counts toward
## boss eligibility (b); full wiring waits on the multiplayer LocalSim.
var ally_ability_heals: int = 0
var rng: PCG32 = PCG32.new(0, 1)


## Stream is pcg32_init(mix(instance_seed, player_id, STREAM_DOMAIN), 1).
func reseed(instance_seed: int, player_id: int) -> void:
	id = player_id
	rng = PCG32.new(_mix(instance_seed, player_id), 1)


func rng_uint32() -> int:
	return rng.uint32()


func tick_clocks() -> void:
	if cast_lock_ticks > 0:
		cast_lock_ticks -= 1
	if ward_ticks > 0:
		ward_ticks -= 1
	if invuln_ticks > 0:
		invuln_ticks -= 1
	if cooldown_ticks > 0:
		cooldown_ticks -= 1


func regen(dt: float) -> void:
	# Design confirmed: Focus regen is applied at the end of the tick, after
	# a spend, so the same tick's regen cannot pay a cost.
	var cap: float = float(focus_max())
	focus = minf(cap, focus + focus_regen() * dt)


func focus_max() -> int:
	if class_def != null:
		return class_def.focus
	return 0


func focus_regen() -> float:
	if class_def != null:
		return class_def.focus_regen
	return 0.0


func reset_for_class(c: ClassDef, a: AbilityDef) -> void:
	class_def = c
	ability_def = a
	focus = float(focus_max())
	cooldown_ticks = 0
	cast_lock_ticks = 0
	ward_ticks = 0
	invuln_ticks = 0
	last_ability_seq = 0
	ally_ability_heals = 0


static func _mix(instance_seed: int, player_id: int) -> int:
	return LootTables.mix_seed(instance_seed, player_id, STREAM_DOMAIN)
