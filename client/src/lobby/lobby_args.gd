class_name LobbyArgs
extends RefCounted
## User command-line args after `--`. Example:
##   godot --headless --path client -- --host --port=8080 --max-players=50

var host: bool = false
var join_code: String = ""
var join_url: String = ""
var lobby_name: String = "Practice Lobby"
var max_players: int = -1
var allow_offline_imports: bool = true
var port: int = LobbySettings.DEFAULT_WS_PORT
var bind_host: String = "*"
var played_offline: bool = false


static func parse(args: PackedStringArray) -> LobbyArgs:
	var out := LobbyArgs.new()
	for a in args:
		if a == "--host":
			out.host = true
		elif a.begins_with("--join="):
			out.join_code = a.substr(len("--join="))
		elif a.begins_with("--join-url="):
			out.join_url = a.substr(len("--join-url="))
		elif a.begins_with("--name="):
			out.lobby_name = a.substr(len("--name="))
		elif a.begins_with("--max-players="):
			out.max_players = int(a.substr(len("--max-players=")))
		elif a.begins_with("--port="):
			out.port = int(a.substr(len("--port=")))
		elif a.begins_with("--bind="):
			out.bind_host = a.substr(len("--bind="))
		elif a == "--refuse-imports" or a == "--allow-imports=0":
			out.allow_offline_imports = false
		elif a == "--allow-imports" or a == "--allow-imports=1":
			out.allow_offline_imports = true
		elif a == "--played-offline" or a == "--played-offline=1":
			out.played_offline = true
		elif a.begins_with("--join-code="):
			# Host can pin a code; clients also accept this as --join.
			var code := a.substr(len("--join-code="))
			if out.join_code == "":
				out.join_code = code
	return out


func is_join() -> bool:
	return join_url != "" or join_code != ""
