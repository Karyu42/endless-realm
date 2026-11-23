class_name LobbySettings
extends RefCounted
## Host-set lobby options. Max players is 1–50, default 50 (desktop / headless).
## Android is join-only in v0.1 (stack.md); a phone listen-host cap is a follow-up.

const MAX_CAP: int = 50
const DEFAULT_MAX: int = 50
const DEFAULT_WS_PORT: int = 8080

var lobby_name: String = "Practice Lobby"
var max_players: int = DEFAULT_MAX
var join_code: String = ""
var ws_port: int = DEFAULT_WS_PORT
var bind_host: String = "*"
var allow_offline_imports: bool = true
var instance_seed: int = 1
## Display-only default portal multiplier until real portals exist.
var display_multiplier: float = 1.0
var open_portals: Array[float] = []


static func default_max_for_listen() -> int:
	return DEFAULT_MAX


static func generate_join_code() -> String:
	var alphabet := "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	var code := ""
	for i in range(6):
		code += alphabet[rng.randi_range(0, alphabet.length() - 1)]
	return code


func clamped_max() -> int:
	return clampi(max_players, 1, MAX_CAP)


func to_beacon(player_count: int) -> Dictionary:
	return {
		"name": lobby_name,
		"players": player_count,
		"max": clamped_max(),
		"code": join_code,
		"port": ws_port,
		"path": "/ws",
		"portals": open_portals.duplicate(),
		"allow_offline_imports": allow_offline_imports,
	}
