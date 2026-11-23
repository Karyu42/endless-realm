class_name ClientWorldSource
extends WorldSource
## Remote view of a hosted lobby. Input is sent to the host; snapshots are
## stubs until replication lands (TODO: real snapshot + prediction).

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
	# Authority is the host. A later PR applies snapshots / prediction here.
	if client != null and not client.last_snapshot.is_empty():
		last_tick = int(client.last_snapshot.get("tick", last_tick))


func tick() -> int:
	return last_tick


func snapshot() -> WorldSnapshot:
	var snap := WorldSnapshot.new()
	snap.tick = last_tick
	return snap
