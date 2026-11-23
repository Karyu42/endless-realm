class_name HostWorldSource
extends WorldSource
## WorldSource that steps the shared LocalSim on the listen / headless host.
## Host and remote intents both go through set_intent (same path).

var host: LobbyHost


func _init(p_host: LobbyHost) -> void:
	host = p_host


func submit_input(intent: InputIntent) -> void:
	submit_player_input(host.host_player_id, intent)


func submit_player_input(player_id: int, intent: InputIntent) -> void:
	host.set_intent(player_id, intent)


func step() -> void:
	host.step_world()


func tick() -> int:
	return host.sim.tick() if host != null and host.sim != null else 0


func snapshot() -> WorldSnapshot:
	if host == null or host.sim == null:
		return WorldSnapshot.new()
	return host.sim.snapshot()
