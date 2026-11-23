class_name PlayerCarry
extends RefCounted
## Character state copied across a portal instance switch.

var player_id: int = 0
var class_id: String = ""
var level: int = 1
var xp_tenths: int = 0
var hp: int = 0
var pending_glint: int = 0
var pending_riftstone: int = 0
var aim: float = 0.0
var inventory: PlayerInventory = null
var ability: PlayerAbilityState = null
var last_interact_seq: int = 0


static func from_sim(p: SimPlayerState, ability: PlayerAbilityState) -> PlayerCarry:
	var c := PlayerCarry.new()
	if p == null:
		return c
	c.player_id = p.id
	c.class_id = p.class_id
	c.level = p.level
	c.xp_tenths = p.xp_tenths
	c.hp = p.hp
	c.pending_glint = p.pending_glint
	c.pending_riftstone = p.pending_riftstone
	c.aim = p.aim
	c.inventory = p.inventory
	c.ability = ability
	c.last_interact_seq = p.last_interact_seq
	return c
