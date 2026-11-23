class_name PlayerSnapshot
extends RefCounted
## One player's public pose in a WorldSnapshot.players list.

var id: int = 0
var x: float = 0.0
var y: float = 0.0
var aim: float = 0.0
var hp: int = 0
var max_hp: int = 0
var flash_ticks: int = 0
var applied_seq: int = 0


func duplicate_snapshot() -> PlayerSnapshot:
	var c := PlayerSnapshot.new()
	c.id = id
	c.x = x
	c.y = y
	c.aim = aim
	c.hp = hp
	c.max_hp = max_hp
	c.flash_ticks = flash_ticks
	c.applied_seq = applied_seq
	return c
