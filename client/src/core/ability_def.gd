class_name AbilityDef
extends RefCounted
## One entry from data/abilities.json (vision §2 / content-v0.1 §1).
## Times are ticks, distances are tiles. Numbers come from the pack only.

var id: String = ""
var display_name: String = ""
var class_id: String = ""
var focus_cost: int = 0
var cooldown_ticks: int = 0
var duration_ticks: int = 0
var damage_taken_mult: float = 1.0
var cast_lock_ticks: int = 0
var heal_radius_tiles: float = 0.0
var heal_max_hp_frac: float = 0.0
var blink_tiles: float = 0.0
var invuln_ticks: int = 0


static func from_json(d: Dictionary) -> AbilityDef:
	var a := AbilityDef.new()
	a.id = String(d.get("id", ""))
	a.display_name = String(d.get("name", a.id))
	a.class_id = String(d.get("class_id", ""))
	a.focus_cost = int(d.get("focus_cost", 0))
	a.cooldown_ticks = int(d.get("cooldown_ticks", 0))
	a.duration_ticks = int(d.get("duration_ticks", 0))
	a.damage_taken_mult = float(d.get("damage_taken_mult", 1.0))
	a.cast_lock_ticks = int(d.get("cast_lock_ticks", 0))
	a.heal_radius_tiles = float(d.get("heal_radius_tiles", 0.0))
	a.heal_max_hp_frac = float(d.get("heal_max_hp_frac", 0.0))
	a.blink_tiles = float(d.get("blink_tiles", 0.0))
	a.invuln_ticks = int(d.get("invuln_ticks", 0))
	return a
