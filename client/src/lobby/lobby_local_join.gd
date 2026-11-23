class_name LobbyLocalJoin
extends RefCounted
## UI-side wrapper for LobbyHost.add_local_player / remove_local_player.
## A first join uses an empty token (ready). remove() stores the host-issued
## rejoin token and the next add() spends it once.

var token: String = ""


func reset() -> void:
	token = ""


func add(host: LobbyHost, character: Variant = null) -> int:
	if host == null:
		return -1
	var spent := token
	var id: int = host.add_local_player(character, spent)
	if id >= 0:
		token = ""
	return id


func remove(host: LobbyHost, player_id: int) -> String:
	if host == null:
		return ""
	token = host.remove_local_player(player_id)
	return token
