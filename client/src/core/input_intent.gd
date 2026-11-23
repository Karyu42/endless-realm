class_name InputIntent
extends RefCounted
## One sampled input frame, matching proto InputFrame: (move, aim, fire_held, seq).
## move_* are in sim axes (Godot 2D: +Y down). Diagonals longer than 1 are normalized.

var seq: int = 0
var move_x: float = 0.0
var move_y: float = 0.0
var aim: float = 0.0
var fire_held: bool = false
## One-shot ability press on this seq, consumed by the host once per tick.
var ability_pressed: bool = false
var interact_pressed: bool = false
## 1–8 equips that inventory slot this tick; 0 means no slot action.
var inventory_slot: int = 0
## Mirrors upcoming proto InputFrame.interact_target_id = 6 (uint64). 0 means
## none. A nonzero value is an interact press on this seq, applied at most once
## per seq. Entity ids are int from LocalSim's single counter.
var interact_target_id: int = 0


## Build an intent from raw stick/key axes. Lengths above 1 (including 8-dir
## diagonals) are normalized so diagonal speed matches axis-aligned speed.
## Lengths in (0, 1] are kept, so a short analog tilt stays short.
static func from_raw(
	seq: int,
	raw_x: float,
	raw_y: float,
	aim: float,
	fire_held: bool,
	interact_pressed: bool = false,
	inventory_slot: int = 0,
	interact_target_id: int = 0
) -> InputIntent:
	var intent := InputIntent.new()
	intent.seq = seq
	intent.aim = aim
	intent.fire_held = fire_held
	intent.interact_pressed = interact_pressed
	intent.inventory_slot = inventory_slot
	intent.interact_target_id = interact_target_id
	var move_len := sqrt(raw_x * raw_x + raw_y * raw_y)
	if move_len <= SimConstants.MOVE_EPS:
		intent.move_x = 0.0
		intent.move_y = 0.0
	elif move_len > 1.0:
		intent.move_x = raw_x / move_len
		intent.move_y = raw_y / move_len
	else:
		intent.move_x = raw_x
		intent.move_y = raw_y
	return intent
