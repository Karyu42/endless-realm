class_name NetClient
extends WorldSource
## Stub for the future WebSocket + Protobuf client (docs/tech/stack.md).
## Does not connect and does not simulate. GameSession uses LocalSim offline.
## Later this will send InputFrame messages and apply server snapshots with
## prediction / reconciliation for self and interpolation buffers for others.

var last_intent: InputIntent = InputIntent.new()


func submit_input(intent: InputIntent) -> void:
	last_intent = intent


func step() -> void:
	pass


func tick() -> int:
	return 0


func snapshot() -> WorldSnapshot:
	return WorldSnapshot.new()
