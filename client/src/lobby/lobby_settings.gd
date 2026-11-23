class_name LobbySettings
extends RefCounted
## Host-set lobby options shown in the browser. Max players maps onto
## LobbyHost.max_players (1–50, never clamped). Import / offline / allowed-M
## flags are stubs until the Server Engineer's host-settings API lands.

const DEFAULT_WS_PORT: int = 8080

var lobby_name: String = "Practice Lobby"
var max_players: int = LobbyHost.DEFAULT_MAX_PLAYERS
var join_code: String = ""
## When false, the LAN beacon omits the join code.
var broadcast_join_code: bool = false
var ws_port: int = DEFAULT_WS_PORT
var bind_host: String = "*"
## Stub: allow character imports into this lobby.
var allow_imports: bool = true
## Stub: allow imports flagged played_offline.
var allow_offline_imports: bool = true
## Stub: allowed portal M range. 0 means unset (no client-side filter yet).
var allowed_m_min: float = 0.0
var allowed_m_max: float = 0.0
var instance_seed: int = 1
## Display-only default portal multiplier until real portals exist.
var display_multiplier: float = 1.0
var open_portals: Array[float] = []


static func generate_join_code() -> String:
	var alphabet := "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	var code := ""
	for i in range(6):
		code += alphabet[rng.randi_range(0, alphabet.length() - 1)]
	return code


## Sets max_players from a UI or CLI string. Returns false if the value is
## not an integer in [1, 50] (blank and out-of-range are both invalid).
func try_set_max_players(text: String) -> bool:
	var n: int = LobbyHost.parse_max_players(text)
	if n < 0:
		return false
	max_players = n
	return true


func to_beacon(player_count: int) -> Dictionary:
	return {
		"name": lobby_name,
		"players": player_count,
		"max": max_players,
		"code": join_code if broadcast_join_code else "",
		"port": ws_port,
		"path": "/ws",
		"portals": open_portals.duplicate(),
		"allow_imports": allow_imports,
		"allow_offline_imports": allow_offline_imports,
	}
