class_name WorldSource
extends RefCounted
## Interface for the offline sim and the future net client. Gameplay nodes must
## not step the world themselves — they only emit InputIntent and read snapshots.


func submit_input(_intent: InputIntent) -> void:
	pass


func step() -> void:
	pass


func tick() -> int:
	return 0


func snapshot() -> WorldSnapshot:
	return WorldSnapshot.new()
