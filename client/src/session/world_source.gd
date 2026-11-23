class_name WorldSource
extends RefCounted
## Interface for the in-process sim (solo or a player-hosted lobby).
## Gameplay nodes must not step the world themselves — they only emit
## InputIntent and read snapshots. The sim itself has no Node dependency.


func submit_input(_intent: InputIntent) -> void:
	pass


## Hosted play: same InputIntent path for the listen-server host and remotes.
## Solo LocalSim ignores the id and applies the intent to the local player.
func submit_player_input(_player_id: int, intent: InputIntent) -> void:
	submit_input(intent)


func step() -> void:
	pass


func tick() -> int:
	return 0


func snapshot() -> WorldSnapshot:
	return WorldSnapshot.new()
