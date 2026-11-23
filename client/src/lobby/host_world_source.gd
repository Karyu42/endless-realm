class_name HostWorldSource
extends WorldSource
## Listen-host WorldSource. Network ticks run on the Server Engineer's
## LobbyHost (service()). The local player's view comes from
## LobbyHost.world_view() when it is available (null before the first tick).

var host: LobbyHost
var local_player_id: int = 0


func _init(p_host: LobbyHost, p_local_player_id: int = 1) -> void:
	host = p_host
	local_player_id = p_local_player_id


func submit_input(intent: InputIntent) -> void:
	if host != null:
		host.submit_local_input(local_player_id, intent)


func submit_player_input(player_id: int, intent: InputIntent) -> void:
	if host != null:
		host.submit_local_input(player_id, intent)


func step() -> void:
	# LobbyHost.service() / run_tick() is the advance; GameSession calls
	# that around submit_local_input so this is a no-op.
	pass


func tick() -> int:
	if host == null:
		return 0
	return host.tick


func snapshot() -> WorldSnapshot:
	if host == null:
		return WorldSnapshot.new()
	var view: WorldSnapshot = host.world_view(local_player_id)
	return view if view != null else WorldSnapshot.new()
