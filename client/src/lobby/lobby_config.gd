class_name LobbyConfig
extends RefCounted
## UI and LAN fields for the lobby browser and beacon. Host settings
## (max players, M range, import flags, name, join code) live on
## `host_settings`, a real LobbySettings from net/host/.

const DEFAULT_WS_PORT: int = 8080

var broadcast_join_code: bool = false
## When true the lobby is invite-only: it is not broadcast on LAN.
## Join-by-code still works for listed hosts that include their code.
## Hidden-but-resolvable-by-code LAN beacons need a listed/invite_only
## beacon field from the Server Engineer.
var invite_only: bool = false
var ws_port: int = DEFAULT_WS_PORT
var bind_host: String = "*"
var instance_seed: int = 1
## Display-only default portal multiplier until real portals exist.
var display_multiplier: float = 1.0
var open_portals: Array[float] = []
var host_settings: LobbySettings = LobbySettings.new()


static func generate_join_code() -> String:
	return LobbySettings.generate_join_code()


## Occupancy for the beacon. `player_count` already includes the listen host
## once they have been added with add_local_player. Never report more than max.
static func beacon_player_count(player_count: int, max_players: int) -> int:
	var cap: int = maxi(max_players, 0)
	return clampi(player_count, 0, cap)


func should_broadcast() -> bool:
	return not invite_only


func to_beacon(player_count: int) -> Dictionary:
	var hs: LobbySettings = host_settings
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
