class_name ClientWorldSource
extends WorldSource
## Remote view of a hosted lobby. Input is sent as proto InputFrame; snapshots
## are tick stubs until replication lands (TODO: real snapshot + prediction).

var client: LobbyClient
var last_tick: int = 0


func _init(p_client: LobbyClient) -> void:
	client = p_client


func submit_input(intent: InputIntent) -> void:
	if client != null:
		client.send_intent(intent)


func submit_player_input(_player_id: int, intent: InputIntent) -> void:
	submit_input(intent)


func step() -> void:
	if client != null and client.last_tick > 0:
		last_tick = client.last_tick


func tick() -> int:
	return last_tick


func snapshot() -> WorldSnapshot:
	var snap := WorldSnapshot.new()
	snap.tick = last_tick
	return snap
