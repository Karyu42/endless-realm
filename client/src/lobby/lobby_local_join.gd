class_name LobbyLocalJoin
extends RefCounted
## UI-side wrapper for LobbyHost.add_local_player / remove_local_player.
## Local join state tracking per QA: joined/left, a single saved token,
## and one first-join empty token per session.

var token: String = ""
var joined: bool = false
var left: bool = false
var _first_add_done: bool = false


func reset() -> void:
	token = ""
	joined = false
	left = false
	_first_add_done = false


func add(host: LobbyHost, character: Variant = null) -> int:
	if host == null or joined:
		return -1
	var pass_token: String = token
	if pass_token == "" and _first_add_done:
		# Later tokenless adds are conservative (unused token, not empty).
		pass_token = Crypto.new().generate_random_bytes(16).hex_encode()
	var id: int = host.add_local_player(character, pass_token)
	if id >= 0:
		token = ""
		joined = true
		left = false
		_first_add_done = true
	return id


## Rejoin after a drop. Refused if still joined or if there was no prior drop.
func restore(host: LobbyHost, character: Variant = null) -> int:
	if joined or not left or token == "":
		return -1
	return add(host, character)


func remove(host: LobbyHost, player_id: int) -> String:
	if not joined:
		return token
	if host == null:
		return token
	var got: String = host.remove_local_player(player_id)
	if got == "":
		return token
	token = got
	joined = false
	left = true
	return token
