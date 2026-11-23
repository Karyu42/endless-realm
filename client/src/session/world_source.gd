class_name WorldSource
extends RefCounted
## Interface for the in-process sim (solo now; a player-hosted lobby later).
## Gameplay nodes must not step the world themselves — they only emit
## InputIntent and read snapshots. The sim itself has no Node dependency.


func submit_input(_intent: InputIntent) -> void:
	pass


func step() -> void:
	pass


func tick() -> int:
	return 0


func snapshot() -> WorldSnapshot:
	return WorldSnapshot.new()
