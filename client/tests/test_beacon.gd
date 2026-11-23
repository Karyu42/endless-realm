extends GutTest
## LAN beacon encode / decode.


func test_round_trip_includes_preview() -> void:
	var portals: Array[float] = [1.4, 0.5, 0.6, 0.9, 1.0, 1.5]
	var buf := LobbyBeacon.encode({
		"name": "Yard",
		"players": 3,
		"max": 50,
		"code": "AB12CD",
		"port": 8080,
		"path": "/ws",
		"portals": portals,
		"allow_offline_imports": false,
	})
	var info := LobbyBeacon.decode(buf)
	assert_eq(info["name"], "Yard")
	assert_eq(info["players"], 3)
	assert_eq(info["max"], 50)
	assert_eq(info["code"], "AB12CD")
	assert_eq(info["port"], 8080)
	assert_eq(info["path"], "/ws")
	assert_false(info["allow_offline_imports"])
	assert_eq(info["portals"].size(), 6)
	assert_eq(info["preview"], PortalPreview.select(portals))
	assert_eq(info["preview"][0], 0.5)
	assert_eq(info["preview"][1], 0.6)
	assert_eq(info["preview"][info["preview"].size() - 1], 1.5)


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
