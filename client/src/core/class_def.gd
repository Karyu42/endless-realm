class_name ClassDef
extends RefCounted
## One entry from data/classes.json (vision §2 / content-v0.1 §1).

var id: String = ""
var display_name: String = ""
var base_hp: int = 200
var base_ward: float = 0.0
var stride: float = 4.5
var tempo: float = 2.0
var focus: int = 100
var focus_regen: float = 5.0
var weapon_id: String = ""
var ability_id: String = ""


static func from_json(d: Dictionary) -> ClassDef:
	var c := ClassDef.new()
	c.id = String(d.get("id", ""))
	c.display_name = String(d.get("name", c.id))
	c.base_hp = int(d.get("base_hp", 200))
	c.base_ward = float(d.get("base_ward", 0.0))
	c.stride = float(d.get("stride", 4.5))
	c.tempo = float(d.get("tempo", 2.0))
	c.focus = int(d.get("focus", 100))
	c.focus_regen = float(d.get("focus_regen", 5.0))
	c.weapon_id = String(d.get("weapon_id", ""))
	c.ability_id = String(d.get("ability_id", ""))
	return c
