class_name LobbyArgs
extends RefCounted
## User command-line args after `--`. Example:
##   godot --headless --path client -- --host --port=8080 --max-players=50
## Headless does not host unless `--host` is set (CI smoke stays unchanged).
## `--max-players` / `ER_MAX_PLAYERS` match host_main: 1–50, never clamped;
## the flag wins over the env var.

const ENV_MAX_PLAYERS := "ER_MAX_PLAYERS"

var host: bool = false
var join_code: String = ""
var join_url: String = ""
var lobby_name: String = "Practice Lobby"
## Raw max-players value from the flag or, if the flag was omitted, from
## ER_MAX_PLAYERS. Empty means "use the default".
var max_players_raw: String = ""
## "--max-players" or "ER_MAX_PLAYERS" when max_players_raw is set; else "".
var max_players_source: String = ""
var imports_allowed: bool = true
var offline_allowed: bool = true
var broadcast_join_code: bool = false
var port: int = LobbyConfig.DEFAULT_WS_PORT
var bind_host: String = "*"
var played_offline: bool = false


static func parse(args: PackedStringArray) -> LobbyArgs:
	var out := LobbyArgs.new()
	var saw_max_flag: bool = false
	var i: int = 0
	while i < args.size():
		var a: String = args[i]
		if a == "--host":
			out.host = true
		elif a.begins_with("--join="):
			out.join_code = a.substr("--join=".length())
		elif a.begins_with("--join-url="):
			out.join_url = a.substr("--join-url=".length())
		elif a.begins_with("--name="):
			out.lobby_name = a.substr("--name=".length())
		elif a == "--max-players":
			saw_max_flag = true
			out.max_players_raw = args[i + 1] if i + 1 < args.size() else ""
			out.max_players_source = "--max-players"
			if i + 1 < args.size():
				i += 1
		elif a.begins_with("--max-players="):
			saw_max_flag = true
			out.max_players_raw = a.substr("--max-players=".length())
			out.max_players_source = "--max-players"
		elif a.begins_with("--port="):
			out.port = int(a.substr("--port=".length()))
		elif a.begins_with("--bind="):
			out.bind_host = a.substr("--bind=".length())
		elif a == "--refuse-imports" or a == "--allow-imports=0":
			out.imports_allowed = false
		elif a == "--allow-imports" or a == "--allow-imports=1":
			out.imports_allowed = true
		elif a == "--refuse-offline" or a == "--allow-offline=0":
			out.offline_allowed = false
		elif a == "--allow-offline" or a == "--allow-offline=1":
			out.offline_allowed = true
		elif a == "--broadcast-code" or a == "--broadcast-code=1":
			out.broadcast_join_code = true
		elif a == "--played-offline" or a == "--played-offline=1":
			out.played_offline = true
		elif a.begins_with("--join-code="):
			var code := a.substr("--join-code=".length())
			if out.join_code == "":
				out.join_code = code
		i += 1
	if not saw_max_flag:
		var env_max: String = OS.get_environment(ENV_MAX_PLAYERS)
		if env_max != "":
			out.max_players_raw = env_max
			out.max_players_source = ENV_MAX_PLAYERS
	return out


func is_join() -> bool:
	return join_url != "" or join_code != ""


## Plan a `--host` start. Tests use this so a bad cap can be checked without
## quitting the GUT process. Headless + invalid cap => exit_code 2 (same as
## host_main). With a display, stay_on_browser is true and the caller must
## not enter the arena.
static func plan_host(args: LobbyArgs, headless: bool) -> Dictionary:
	var cfg := LobbyConfig.new()
	cfg.ws_port = args.port
	cfg.bind_host = args.bind_host
	cfg.broadcast_join_code = args.broadcast_join_code
	var hs = cfg.host_settings
	hs.lobby_name = args.lobby_name
	hs.imports_allowed = args.imports_allowed
	hs.offline_allowed = args.offline_allowed
	if args.join_code != "":
		hs.join_code = args.join_code.to_upper()
	if args.max_players_raw != "":
		var parsed: int = LobbyHost.parse_max_players(args.max_players_raw)
		if parsed < 0:
			var source: String = args.max_players_source
			if source == "":
				source = "--max-players"
			var err: String = "HOST_ERROR %s must be an integer in [%d, %d], got %s" % [
				source, LobbyHost.MIN_MAX_PLAYERS, LobbyHost.MAX_MAX_PLAYERS, args.max_players_raw]
			return _reject_host(err, headless, cfg)
		hs.max_players = parsed
	var reasons: PackedStringArray = hs.validate()
	if not reasons.is_empty():
		return _reject_host("HOST_ERROR " + " ".join(reasons), headless, cfg)
	if cfg.open_portals.is_empty():
		cfg.open_portals = [1.0] as Array[float]
	return {
		"ok": true,
		"exit_code": 0,
		"error": "",
		"stay_on_browser": false,
		"config": cfg,
	}


static func _reject_host(error: String, headless: bool, cfg: LobbyConfig) -> Dictionary:
	return {
		"ok": false,
		"exit_code": 2 if headless else 0,
		"error": error,
		"stay_on_browser": not headless,
		"config": cfg,
	}
