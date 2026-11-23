class_name HostInteractValidator
extends RefCounted
## Host-side check for InputFrame.interact_target_id (proto/v1).
##
## A nonzero target is an interact press on that frame's seq. The host applies
## it at most once per seq and drops it silently (no ErrorReply) when the id is
## unknown, the target is not allowed for the player, or it is farther than
## the accept range in data/scaling.json (`interact_accept_range_tiles`),
## center to center, from the player's host position.
##
## `resolver` is a Callable
##   func(target_id: int, player_id: int) -> Dictionary
## that returns {"x": float, "y": float} (tile units) for a target that exists
## and that this player may use, or {} otherwise. LobbyHost sets it to the
## player's own live bags in its shared LocalSim; on its own the validator
## treats every target as unknown.

## Accept range, loaded through DataCatalog / SimScaling (same as #30).
var scaling: SimScaling = DataCatalog.load_default().scaling

var resolver: Callable = func(_target_id: int, _player_id: int) -> Dictionary: return {}

var accepted: int = 0
var dropped_repeat: int = 0
var dropped_unknown: int = 0
var dropped_range: int = 0

var _last_seq: Dictionary = {}  # player_id -> last seq an interact was evaluated for


func max_range_tiles() -> float:
	return scaling.interact_accept_range_tiles


## Returns true if the press should be applied. Never sends anything.
func validate(player_id: int, seq: int, target_id: int, px: float, py: float) -> bool:
	if target_id == 0:
		return false
	var last: int = int(_last_seq.get(player_id, 0))
	if not Seq.seq_is_next(seq, last):
		dropped_repeat += 1
		return false
	_last_seq[player_id] = seq
	var t: Dictionary = resolver.call(target_id, player_id)
	if t.is_empty() or not t.has("x") or not t.has("y"):
		dropped_unknown += 1
		return false
	var dist: float = SimConstants.interact_distance(float(t["x"]), float(t["y"]), px, py)
	if not is_finite(dist) or not scaling.in_accept_range(dist):
		dropped_range += 1
		return false
	accepted += 1
	return true


func forget_player(player_id: int) -> void:
	_last_seq.erase(player_id)
