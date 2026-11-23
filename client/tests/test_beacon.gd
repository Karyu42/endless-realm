extends GutTest
## LAN beacon encode / decode.


func test_round_trip_includes_preview_and_overflow() -> void:
	var portals: Array[float] = [0.50, 0.80, 1.00, 1.00, 1.20, 1.35, 1.50]
	var buf := LobbyBeacon.encode({
		"name": "Yard",
		"players": 3,
		"max": 50,
		"code": "AB12CD",
		"port": 8080,
		"path": "/ws",
		"portals": portals,
		"imports_allowed": true,
		"offline_allowed": false,
		"m100_min": 80,
		"m100_max": 120,
	})
	var info := LobbyBeacon.decode(buf)
	assert_eq(info["name"], "Yard")
	assert_eq(info["players"], 3)
	assert_eq(info["max"], 50)
	assert_eq(info["code"], "AB12CD")
	assert_eq(info["port"], 8080)
	assert_eq(info["path"], "/ws")
	assert_true(info["imports_allowed"])
	assert_false(info["offline_allowed"])
	assert_eq(info["m100_min"], 80)
	assert_eq(info["m100_max"], 120)
	assert_eq(info["portals"].size(), 7)
	assert_eq(info["preview"], [0.50, 0.80, 1.00, 1.35, 1.50])
	assert_eq(info["more"], 2)


func test_settings_omit_join_code_unless_broadcast_is_on() -> void:
	var settings := LobbyConfig.new()
	settings.host_settings.join_code = "SECRET"
	settings.broadcast_join_code = false
	var hidden := LobbyBeacon.decode(LobbyBeacon.encode(settings.to_beacon(1)))
	assert_eq(hidden["code"], "")
	settings.broadcast_join_code = true
	var shown := LobbyBeacon.decode(LobbyBeacon.encode(settings.to_beacon(1)))
	assert_eq(shown["code"], "SECRET")


func test_rejects_bad_magic_and_wrong_version() -> void:
	assert_eq(LobbyBeacon.decode(PackedByteArray()), {})
	var bad := "XXXX{}".to_utf8_buffer()
	assert_eq(LobbyBeacon.decode(bad), {})
	var raw := LobbyBeacon.encode({"name": "X", "portals": [1.0]})
	# Flip protocol version in the JSON body.
	var body := raw.slice(LobbyBeacon.MAGIC.to_utf8_buffer().size()).get_string_from_utf8()
	var parsed: Dictionary = JSON.parse_string(body)
	parsed["v"] = 99
	var flipped := PackedByteArray()
	flipped.append_array(LobbyBeacon.MAGIC.to_utf8_buffer())
	flipped.append_array(JSON.stringify(parsed).to_utf8_buffer())
	assert_eq(LobbyBeacon.decode(flipped), {})
