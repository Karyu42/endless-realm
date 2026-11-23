class_name LobbyConfig
extends RefCounted
## UI and LAN fields for the lobby browser and beacon. Host settings
## (max players, M range, import flags, name, join code) live on
## `host_settings`, a stub of the Server Engineer's LobbySettings until
## that API lands in net/host/.

const DEFAULT_WS_PORT: int = 8080
const HostSettings := preload("res://src/lobby/lobby_settings_stub.gd")

var broadcast_join_code: bool = false
var ws_port: int = DEFAULT_WS_PORT
var bind_host: String = "*"
var instance_seed: int = 1
## Display-only default portal multiplier until real portals exist.
var display_multiplier: float = 1.0
var open_portals: Array[float] = []
var host_settings = HostSettings.new()


static func generate_join_code() -> String:
	var alphabet := "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	var code := ""
	for i in range(6):
		code += alphabet[rng.randi_range(0, alphabet.length() - 1)]
	return code


## Beacon occupancy until add_local_player lands. The listen host is not in
## LobbyHost.players, so we count them as one but never report more than
## max (a full remote list would otherwise show 51/50).
static func beacon_player_count(remote_count: int, max_players: int) -> int:
	var cap: int = maxi(max_players, 0)
	return mini(remote_count + 1, cap)


func to_beacon(player_count: int) -> Dictionary:
	var hs = host_settings
	return {
		"name": hs.lobby_name if hs.lobby_name != "" else "Practice Lobby",
		"players": player_count,
		"max": hs.max_players,
		"code": hs.join_code if broadcast_join_code else "",
		"port": ws_port,
		"path": "/ws",
		"portals": open_portals.duplicate(),
		"imports_allowed": hs.imports_allowed,
		"offline_allowed": hs.offline_allowed,
		"m100_min": hs.m100_min,
		"m100_max": hs.m100_max,
	}
