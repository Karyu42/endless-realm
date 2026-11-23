extends GutTest
## Headless loopback against the Server Engineer's proto/v1 LobbyHost.


func test_lobby_client_hello_on_loopback() -> void:
	var host := LobbyHost.new(SimConfig.new())
	host.port = 0
	host.bind_address = "127.0.0.1"
	host.emitter_count = 2
	assert_eq(host.start(), OK, "host should listen on loopback")
	var client := LobbyClient.new()
	add_child_autofree(client)
	var url := "ws://127.0.0.1:%d/ws" % host.port
	assert_eq(client.connect_to(url), OK)
	var welcomed := false
	for i in range(500):
		host.run_tick()
		client.poll()
		if client.player_id != 0:
			welcomed = true
			break
		OS.delay_msec(10)
	assert_true(welcomed, "client should be welcomed over proto/v1")
	assert_eq(client.last_reason, "")
	assert_gt(client.player_id, 0)
	var intent := InputIntent.from_raw(1, 1.0, 0.0, 0.0, true)
	client.send_intent(intent)
	var saw_tick := false
	for i in range(200):
		host.run_tick()
		client.poll()
		if client.last_tick > 0:
			saw_tick = true
			break
		OS.delay_msec(10)
	assert_true(saw_tick, "client should receive a snapshot tick")
	host.stop()


func test_max_players_is_rejected_not_clamped() -> void:
	var settings := LobbySettings.new()
	assert_false(settings.try_set_max_players(""))
	assert_false(settings.try_set_max_players("0"))
	assert_false(settings.try_set_max_players("51"))
	assert_false(settings.try_set_max_players("x"))
	assert_eq(settings.max_players, LobbyHost.DEFAULT_MAX_PLAYERS)
	assert_true(settings.try_set_max_players("8"))
	assert_eq(settings.max_players, 8)
	assert_true(settings.try_set_max_players("1"))
	assert_eq(settings.max_players, 1)
	assert_true(settings.try_set_max_players("50"))
	assert_eq(settings.max_players, 50)
