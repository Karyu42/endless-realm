class_name ClientWorldSource
extends WorldSource
## Remote view of a hosted lobby. Input is sent as proto InputFrame; snapshots
## are filled from Snapshot.portals and admitted_portal_ids.

var client: LobbyClient
var catalog: DataCatalog
var last_tick: int = 0


func _init(p_client: LobbyClient, p_catalog: DataCatalog = null) -> void:
	client = p_client
	catalog = p_catalog


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
	if client != null and client.last_snapshot != null:
		SnapshotDecode.fill_world(snap, client.last_snapshot, catalog)
	return snap
