class_name EnemyDef
extends RefCounted
## One entry from data/enemies.json.

const DEFAULT_DEAGGRO_PAD: float = 4.0

var id: String = ""
var display_name: String = ""
var rank: String = "normal"
var base_hp: int = 1
var base_ward: float = 0.0
var contact_damage: int = 0
var damage: Dictionary = {} # damage_key -> int
var move_speed: float = 0.0
var wander_speed: float = 0.0
var radius: float = 0.35
var aggro_radius: float = 8.0
## Optional. When omitted or negative, defaults to aggro_radius + DEFAULT_DEAGGRO_PAD.
var deaggro_radius: float = -1.0
## When true, the 16-tile leash is ignored. The Mirebell Matron doesn't leash
## while any eligible player is within 20 tiles (deaggro_radius 20), as data,
## not a hardcoded name.
var no_leash: bool = false
var hover_radius: float = 3.0
var leash: float = 16.0
var strafe_switch_ticks: int = 40
var ai_type: String = ""
var pattern_id: String = ""
var fire_interval_ticks: int = 0
var alt_pattern_id: String = ""
var alt_every_cycles: int = 0
var sidestep_tiles: float = 0.0
var sidestep_interval_ticks: int = 0
var sidestep_duration_ticks: int = 10
var party_scaling: String = "normal"
var target_rule: String = ""
var phases: Array[Dictionary] = []
var _ai_fields: Dictionary = {}


static func from_json(d: Dictionary) -> EnemyDef:
	var e := EnemyDef.new()
	e.id = String(d.get("id", ""))
	e.display_name = String(d.get("name", e.id))
	e.rank = String(d.get("rank", "normal"))
	var base: Variant = d.get("base", {})
	if base is Dictionary:
		e.base_hp = int(base.get("hp", 1))
		e.base_ward = float(base.get("ward", 0.0))
		e.contact_damage = int(base.get("contact", 0))
		var dmg: Variant = base.get("damage", {})
		if dmg is Dictionary:
			e.damage = dmg
	e.move_speed = float(d.get("move_speed", 0.0))
	e.wander_speed = float(d.get("wander_speed", e.move_speed))
	e.radius = float(d.get("radius", 0.35))
	e.aggro_radius = float(d.get("aggro_radius", 8.0))
	if d.has("deaggro_radius"):
		e.deaggro_radius = float(d["deaggro_radius"])
	e.no_leash = bool(d.get("no_leash", false))
	e.hover_radius = float(d.get("hover_radius", 3.0))
	e.leash = float(d.get("leash", 16.0))
	e.strafe_switch_ticks = int(d.get("strafe_switch_ticks", 40))
	var ai: Variant = d.get("ai", {})
	if ai is Dictionary:
		for k in ai.keys():
			e._ai_fields[String(k)] = true
		e.ai_type = String(ai.get("type", ""))
		e.pattern_id = String(ai.get("pattern", ""))
		if e._ai_fields.has("fire_interval_ticks"):
			e.fire_interval_ticks = int(ai.get("fire_interval_ticks", 0))
		e.alt_pattern_id = String(ai.get("alt_pattern", ""))
		e.alt_every_cycles = int(ai.get("alt_every_cycles", 0))
		e.sidestep_tiles = float(ai.get("sidestep_tiles", 0.0))
		e.sidestep_interval_ticks = int(ai.get("sidestep_interval_ticks", 0))
		if e._ai_fields.has("sidestep_duration_ticks"):
			e.sidestep_duration_ticks = int(ai.get("sidestep_duration_ticks", 10))
	e.party_scaling = String(d.get("party_scaling", "normal"))
	e.target_rule = String(d.get("target_rule", ""))
	var raw_phases: Variant = d.get("phases", [])
	if raw_phases is Array:
		for phase in raw_phases:
			if phase is Dictionary:
				e.phases.append(phase)
	return e


func is_rooted() -> bool:
	return ai_type == "rooted"


func is_boss() -> bool:
	return rank == "boss" or ai_type == "boss"


func pattern_ids() -> PackedStringArray:
	var out := PackedStringArray()
	var seen: Dictionary = {}
	if pattern_id != "" and not seen.has(pattern_id):
		out.append(pattern_id)
		seen[pattern_id] = true
	if alt_pattern_id != "" and not seen.has(alt_pattern_id):
		out.append(alt_pattern_id)
		seen[alt_pattern_id] = true
	for phase in phases:
		var loops: Variant = phase.get("loops", [])
		if loops is Array:
			for loop in loops:
				if not (loop is Dictionary):
					continue
				var pid: String = String(loop.get("pattern", ""))
				if pid != "" and not seen.has(pid):
					out.append(pid)
					seen[pid] = true
		var actions: Variant = phase.get("on_enter", [])
		if actions is Array:
			for action in actions:
				if action is Dictionary:
					var sid: String = String(action.get("summon", ""))
					if sid != "" and not seen.has("summon:" + sid):
						# summon ids are enemy ids; tagged so callers can split.
						out.append("summon:" + sid)
						seen["summon:" + sid] = true
	return out


func missing_pack_ids() -> PackedStringArray:
	var out := PackedStringArray()
	if not is_rooted():
		return out
	if not _ai_fields.has("type") or ai_type == "":
		out.append("%s.ai.type" % id)
	if not _ai_fields.has("pattern") or pattern_id == "":
		out.append("%s.ai.pattern" % id)
	if not _ai_fields.has("fire_interval_ticks"):
		out.append("%s.ai.fire_interval_ticks" % id)
	return out


## Drop-aggro radius: explicit value, or aggro_radius + 4 tiles.
func deaggro_range() -> float:
	if deaggro_radius >= 0.0:
		return deaggro_radius
	return aggro_radius + DEFAULT_DEAGGRO_PAD


func damage_for(key: String) -> int:
	if damage.has(key):
		return int(damage[key])
	return 0
