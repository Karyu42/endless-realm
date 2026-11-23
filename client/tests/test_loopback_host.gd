extends GutTest
## Headless loopback: one listen host and one WebSocket client on 127.0.0.1.


func _listen(settings: LobbySettings) -> Dictionary:
	var sim := LocalSim.new(SimConfig.new(), 16.0, 16.0)
	sim.set_bounds(0.0, 0.0, 32.0, 32.0)
	var host := LobbyHost.new()
	add_child_autofree(host)
	var err: Error = ERR_CANT_CREATE
	var port: int = 18081
	while port < 18121:
		settings.ws_port = port
		err = host.start(settings, sim, "127.0.0.1")
		if err == OK:
			break
		port += 1
	return {"host": host, "sim": sim, "err": err, "port": settings.ws_port}


func _pump(host: LobbyHost, client: LobbyClient, frames: int = 60) -> void:
	for i in range(frames):
		host.poll()
		client.poll()
		await get_tree().process_frame


func test_host_and_client_handshake_and_snapshot() -> void:
	var settings := LobbySettings.new()
	settings.join_code = "LOOP01"
	settings.allow_offline_imports = true
	settings.max_players = 8
	var started: Dictionary = _listen(settings)
	assert_eq(started["err"], OK, "host should listen on loopback")
	if started["err"] != OK:
		return
	var host: LobbyHost = started["host"]
	var client := LobbyClient.new()
	add_child_autofree(client)
	var url := "ws://127.0.0.1:%d/ws" % started["port"]
	assert_eq(client.connect_to(url, true, "LOOP01"), OK)
	await _pump(host, client, 90)
	assert_eq(client.player_id, 2, "client should be welcomed as player 2")
	assert_eq(client.last_reason, "")
	assert_eq(host.player_count(), 2)
	var intent := InputIntent.from_raw(1, 1.0, 0.0, 0.0, false)
	client.send_intent(intent)
	host.set_intent(host.host_player_id, intent)
	host.step_world()
	await _pump(host, client, 30)
	assert_eq(client.last_snapshot.get("type", ""), "snapshot")
	assert_gt(int(client.last_snapshot.get("tick", 0)), 0)


func test_loopback_refuses_offline_import() -> void:
	var settings := LobbySettings.new()
	settings.join_code = "LOOP02"
	settings.allow_offline_imports = false
	settings.max_players = 8
	var started: Dictionary = _listen(settings)
	assert_eq(started["err"], OK)
	if started["err"] != OK:
		return
	var host: LobbyHost = started["host"]
	var client := LobbyClient.new()
	add_child_autofree(client)
	var url := "ws://127.0.0.1:%d/ws" % started["port"]
	assert_eq(client.connect_to(url, true, "LOOP02"), OK)
	await _pump(host, client, 90)
	assert_eq(client.last_reason, Handshake.REASON_IMPORT_REFUSED)
	assert_eq(client.player_id, 0)
	assert_eq(host.player_count(), 1)
