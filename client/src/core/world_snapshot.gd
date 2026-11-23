class_name WorldSnapshot
extends RefCounted
## Read-only view of sim state at one tick. Render nodes interpolate between two of these.

var tick: int = 0
var player_id: int = 1
var player_x: float = 0.0
var player_y: float = 0.0
var player_aim: float = 0.0
var player_hp: int = 0
var player_max_hp: int = 0
var player_flash_ticks: int = 0
var applied_seq: int = 0
var player_level: int = 1
var xp_tenths: int = 0
var xp_to_next_tenths: int = 0
var pending_glint: int = 0
var inventory: Array[ItemState] = []
var equipped_weapon: ItemState = null
var equipped_armor: ItemState = null
var equipped_charm: ItemState = null
var ground_drops: Array[GroundDrop] = []
var projectiles: Array[SimProjectile] = []
var enemies: Array[EnemySnapshot] = []
var pattern_bullets: Array[PatternBullet] = []


func player_pixels() -> Vector2:
	return Vector2(player_x * SimConstants.TILE_PX, player_y * SimConstants.TILE_PX)


func player_alive() -> bool:
	return player_hp > 0


func duplicate_snapshot() -> WorldSnapshot:
	var copy := WorldSnapshot.new()
	copy.tick = tick
	copy.player_id = player_id
	copy.player_x = player_x
	copy.player_y = player_y
	copy.player_aim = player_aim
	copy.player_hp = player_hp
	copy.player_max_hp = player_max_hp
	copy.player_flash_ticks = player_flash_ticks
	copy.applied_seq = applied_seq
	copy.player_level = player_level
	copy.xp_tenths = xp_tenths
	copy.xp_to_next_tenths = xp_to_next_tenths
	copy.pending_glint = pending_glint
	copy.inventory = inventory.duplicate()
	copy.equipped_weapon = equipped_weapon
	copy.equipped_armor = equipped_armor
	copy.equipped_charm = equipped_charm
	copy.ground_drops = ground_drops.duplicate()
	copy.projectiles = projectiles.duplicate()
	copy.enemies = enemies.duplicate()
	copy.pattern_bullets = pattern_bullets.duplicate()
	return copy
