extends SceneTree
## Headless entry point for the Godot lobby host.
##   godot --headless --path client -s res://src/net/host/host_main.gd -- --host --port 8090
## Flags (after `--`):
##   --host                 required
##   --port N               listen port (default 8090; 0 = any free port)
##   --bind ADDR            bind address (default 127.0.0.1)
##   --seed N               instance seed sent in Welcome (default 1, matches the bot's -seed)
##   --emitters N           stand-in enemy emitters (default 20, ~1000 live bullets)
##   --arena TILES          square arena edge in tiles (default 48)
##   --expect-clients N     record stats only while >= N players are connected
##   --run-seconds S        hard stop after S seconds (default 0 = no limit)
##   --exit-when-empty      exit (and print stats) once every player has left
## Prints "HOST_READY port=N" when listening and "HOST_STATS {json}" on exit.

var _host: LobbyHost
var _run_until_usec: int = 0
var _exit_when_empty: bool = false
var _empty_since_usec: int = -1


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if not args.has("--host"):
		printerr("usage: godot --headless --path client -s res://src/net/host/host_main.gd -- --host [--port N]")
		quit(2)
		return
	_host = LobbyHost.new(_load_config())
	_host.port = 8090
	var i: int = 0
	while i < args.size():
		var a: String = args[i]
		var v: String = args[i + 1] if i + 1 < args.size() else ""
		match a:
			"--port":
				_host.port = int(v); i += 1
			"--bind":
				_host.bind_address = v; i += 1
			"--seed":
				_host.instance_seed = int(v); i += 1
			"--emitters":
				_host.emitter_count = int(v); i += 1
			"--arena":
				_host.arena_size = float(v); i += 1
			"--expect-clients":
				_host.expect_clients = int(v); i += 1
			"--run-seconds":
				_run_until_usec = Time.get_ticks_usec() + int(float(v) * 1e6); i += 1
			"--exit-when-empty":
				_exit_when_empty = true
		i += 1
	var err := _host.start()
	if err != OK:
		printerr("HOST_ERROR listen %s:%d failed: %s" % [_host.bind_address, _host.port, error_string(err)])
		quit(1)
		return
	print("HOST_READY port=%d bind=%s seed=%d emitters=%d" % [_host.port, _host.bind_address, _host.instance_seed, _host.emitter_count])


func _load_config() -> SimConfig:
	var cfg := load("res://resources/sim_config.tres") as SimConfig
	return cfg if cfg != null else SimConfig.new()


func _process(_delta: float) -> bool:
	if _host == null:
		return true
	_host.service()
	var now := Time.get_ticks_usec()
	if _run_until_usec > 0 and now >= _run_until_usec:
		return _finish()
	if _exit_when_empty and _host.peak_players > 0:
		if _host.players.is_empty() and _host.connection_count() == 0:
			if _empty_since_usec < 0:
				_empty_since_usec = now
			elif now - _empty_since_usec > 500000:
				return _finish()
		else:
			_empty_since_usec = -1
	var wait: int = _host.next_deadline_usec() - Time.get_ticks_usec()
	if wait > 0:
		OS.delay_usec(mini(wait, 50000))
	return false


func _finish() -> bool:
	print("HOST_STATS " + JSON.stringify(_host.stats()))
	_host.stop()
	return true
