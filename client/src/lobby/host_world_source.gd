class_name HostWorldSource
extends WorldSource
## Listen-host WorldSource. Network ticks run on the Server Engineer's
## LobbyHost (service()). The local player's view is a LocalSim until a hook
## exists to register the host player on LobbyHost and read its snapshot.

var host: LobbyHost
var sim: LocalSim


func _init(p_host: LobbyHost, p_sim: LocalSim) -> void:
	host = p_host
	sim = p_sim


func submit_input(intent: InputIntent) -> void:
	if sim != null:
		sim.submit_input(intent)


func submit_player_input(_player_id: int, intent: InputIntent) -> void:
	submit_input(intent)


func step() -> void:
	if sim != null:
		sim.step()


func tick() -> int:
	return sim.tick() if sim != null else 0


func snapshot() -> WorldSnapshot:
	if sim == null:
		return WorldSnapshot.new()
	return sim.snapshot()
