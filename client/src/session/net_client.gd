class_name NetClient
extends WorldSource
## Stub for the future WebSocket + Protobuf client (docs/tech/stack.md).
## Does not connect and does not simulate. GameSession uses LocalSim offline.
## Later this will send InputFrame messages and apply server snapshots with
## prediction / reconciliation for self and interpolation buffers for others.
## encode_input is the shared InputIntent -> proto InputFrame encoder used
## by LobbyClient today.

const PB := preload("res://src/net/proto/protocol_v1_pb.gd")

var last_intent: InputIntent = InputIntent.new()


## Encode an InputIntent as a ClientMessage.input. interact_target_id is the
## auto-selected target; 0 means none and is left as the protobuf default.
## ability_pressed is proto field 7, a one-shot press on this seq.
static func encode_input(intent: InputIntent) -> PackedByteArray:
	var msg = PB.ClientMessage.new()
	var frame = msg.new_input()
	frame.set_seq(intent.seq)
	frame.set_move_x(intent.move_x)
	frame.set_move_y(intent.move_y)
	frame.set_aim(intent.aim)
	frame.set_fire_held(intent.fire_held)
	frame.set_interact_target_id(intent.interact_target_id)
	frame.set_ability_pressed(intent.ability_pressed)
	return msg.to_bytes()


func submit_input(intent: InputIntent) -> void:
	last_intent = intent


func step() -> void:
	pass


func tick() -> int:
	return 0


func snapshot() -> WorldSnapshot:
	return WorldSnapshot.new()
