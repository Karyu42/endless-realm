extends GutTest
## Protocol v1 handshake rules (no sockets).


func test_welcome_on_matching_version() -> void:
	var r := Handshake.evaluate(SimConstants.PROTOCOL_VERSION, false, false, 1, 50, 2, 7, 1.0)
	assert_true(r["ok"])
	assert_eq(r["welcome"]["type"], "welcome")
	assert_eq(r["welcome"]["player_id"], 2)
	assert_eq(r["welcome"]["tick_hz"], SimConstants.TICK_HZ)
	assert_eq(r["welcome"]["instance_seed"], 7)
	assert_eq(r["welcome"]["protocol_version"], SimConstants.PROTOCOL_VERSION)


func test_rejects_wrong_protocol_version() -> void:
	var r := Handshake.evaluate(0, false, true, 1, 50, 2, 1, 1.0)
	assert_false(r["ok"])
	assert_eq(r["reason"], Handshake.REASON_PROTOCOL_VERSION)
	assert_eq(r["reject"]["type"], "reject")
	assert_eq(r["reject"]["server_protocol_version"], SimConstants.PROTOCOL_VERSION)
	assert_eq(r["reject"]["client_protocol_version"], 0)


func test_rejects_when_lobby_is_full() -> void:
	var r := Handshake.evaluate(SimConstants.PROTOCOL_VERSION, false, true, 50, 50, 3, 1, 1.0)
	assert_false(r["ok"])
	assert_eq(r["reason"], Handshake.REASON_LOBBY_FULL)


func test_hello_round_trips_through_codec() -> void:
	var codec := ProtocolCodec.new()
	var hello := Handshake.hello_payload(true, "AB12CD", "Kai")
	var back := codec.decode(codec.encode(hello))
	assert_eq(back["type"], "hello")
	assert_eq(back["protocol_version"], SimConstants.PROTOCOL_VERSION)
	assert_true(back["played_offline"])
	assert_eq(back["join_code"], "AB12CD")
