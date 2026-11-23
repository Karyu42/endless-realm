class_name HostInteractValidator
extends RefCounted
## Host-side check for InputFrame.interact_target_id (proto/v1).
##
## A nonzero target is an interact press on that frame's seq. The host applies
## it at most once per seq and drops it silently (no ErrorReply) when the id is
## unknown, the target is not allowed for the player, or it is more than
## MAX_RANGE_TILES away, center to center, from the player's host position.
##
## HOOK for the loot/interact work (#30): set `resolver` to a Callable
##   func(target_id: int, player_id: int) -> Dictionary
## that returns {"x": float, "y": float} (tile units) for a target that exists
## and that this player may use, or {} otherwise. Then set LobbyHost.on_interact
## to receive accepted presses. Until then every target is unknown and dropped.

const MAX_RANGE_TILES: float = 2.0

var resolver: Callable = func(_target_id: int, _player_id: int) -> Dictionary: return {}

var accepted: int = 0
var dropped_repeat: int = 0
var dropped_unknown: int = 0
var dropped_range: int = 0

var _last_seq: Dictionary = {}  # player_id -> last seq an interact was evaluated for


## Returns true if the press should be applied. Never sends anything.
func validate(player_id: int, seq: int, target_id: int, px: float, py: float) -> bool:
	if target_id == 0:
		return false
	if _last_seq.has(player_id) and seq <= int(_last_seq[player_id]):
		dropped_repeat += 1
		return false
	_last_seq[player_id] = seq
	var t: Dictionary = resolver.call(target_id, player_id)
	if t.is_empty() or not t.has("x") or not t.has("y"):
		dropped_unknown += 1
		return false
	var dx: float = float(t["x"]) - px
	var dy: float = float(t["y"]) - py
	if not is_finite(dx) or not is_finite(dy) or dx * dx + dy * dy > MAX_RANGE_TILES * MAX_RANGE_TILES:
		dropped_range += 1
		return false
	accepted += 1
	return true


func forget_player(player_id: int) -> void:
	_last_seq.erase(player_id)
