class_name LobbyArgs
extends RefCounted
## User command-line args after `--`. Example:
##   godot --headless --path client -- --host --port=8080 --max-players=50
## Headless does not host unless `--host` is set (CI smoke stays unchanged).

var host: bool = false
var join_code: String = ""
var join_url: String = ""
var lobby_name: String = "Practice Lobby"
## Raw --max-players value. Empty means "use the default".
var max_players_raw: String = ""
var allow_imports: bool = true
var allow_offline_imports: bool = true
var broadcast_join_code: bool = false
var port: int = LobbySettings.DEFAULT_WS_PORT
var bind_host: String = "*"
var played_offline: bool = false


static func parse(args: PackedStringArray) -> LobbyArgs:
	var out := LobbyArgs.new()
	for a in args:
		if a == "--host":
			out.host = true
		elif a.begins_with("--join="):
			out.join_code = a.substr("--join=".length())
		elif a.begins_with("--join-url="):
			out.join_url = a.substr("--join-url=".length())
		elif a.begins_with("--name="):
			out.lobby_name = a.substr("--name=".length())
		elif a.begins_with("--max-players="):
			out.max_players_raw = a.substr("--max-players=".length())
		elif a.begins_with("--port="):
			out.port = int(a.substr("--port=".length()))
		elif a.begins_with("--bind="):
			out.bind_host = a.substr("--bind=".length())
		elif a == "--refuse-imports" or a == "--allow-imports=0":
			out.allow_imports = false
		elif a == "--allow-imports" or a == "--allow-imports=1":
			out.allow_imports = true
		elif a == "--refuse-offline" or a == "--allow-offline=0":
			out.allow_offline_imports = false
		elif a == "--allow-offline" or a == "--allow-offline=1":
			out.allow_offline_imports = true
		elif a == "--broadcast-code" or a == "--broadcast-code=1":
			out.broadcast_join_code = true
		elif a == "--played-offline" or a == "--played-offline=1":
			out.played_offline = true
		elif a.begins_with("--join-code="):
			var code := a.substr("--join-code=".length())
			if out.join_code == "":
				out.join_code = code
	return out


func is_join() -> bool:
	return join_url != "" or join_code != ""
