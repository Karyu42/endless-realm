class_name ItemState
extends RefCounted
## One personal item. drop_id is idempotent (same seed, enemy, looter, index).

const SLOT_WEAPON := "weapon"
const SLOT_ARMOR := "armor"
const SLOT_CHARM := "charm"
const LOC_GROUND := "GROUND"
const LOC_INVENTORY := "INVENTORY"
const LOC_EQUIPPED := "EQUIPPED"
const STATE_LIVE := "LIVE"
const STATE_TOMBSTONED := "TOMBSTONED"

var drop_id: String = ""
var slot: String = SLOT_WEAPON
var base_id: String = ""
var display_base: String = ""
var tier: int = 0
var content_level: int = 1
var charm_line: String = ""
var charm_pct: int = 0
var owner_player_id: int = 0
var location: String = LOC_GROUND
var pending: bool = true
var state: String = STATE_LIVE
var tombstone_reason: String = ""


func display_name() -> String:
	return "%s T%d" % [display_base, tier]


func bag_color_kind(t_star: int) -> String:
	## content-v0.1 §4.1: brown ≤ T*, teal T*+1, gold T*+2 or higher.
	if tier <= t_star:
		return "brown"
	if tier == t_star + 1:
		return "teal"
	return "gold"


func duplicate_item() -> ItemState:
	var c := ItemState.new()
	c.drop_id = drop_id
	c.slot = slot
	c.base_id = base_id
	c.display_base = display_base
	c.tier = tier
	c.content_level = content_level
	c.charm_line = charm_line
	c.charm_pct = charm_pct
	c.owner_player_id = owner_player_id
	c.location = location
	c.pending = pending
	c.state = state
	c.tombstone_reason = tombstone_reason
	return c
