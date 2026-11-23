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
var ai_type: String = "chase_hover"
var pattern_id: String = ""
var fire_interval_ticks: int = 30


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
		e.ai_type = String(ai.get("type", "chase_hover"))
		e.pattern_id = String(ai.get("pattern", ""))
		e.fire_interval_ticks = int(ai.get("fire_interval_ticks", 30))
	return e


## Drop-aggro radius: explicit value, or aggro_radius + 4 tiles.
func deaggro_range() -> float:
	if deaggro_radius >= 0.0:
		return deaggro_radius
	return aggro_radius + DEFAULT_DEAGGRO_PAD


func damage_for(key: String) -> int:
	if damage.has(key):
		return int(damage[key])
	return 0
