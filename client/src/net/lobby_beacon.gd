class_name LobbyBeacon
extends RefCounted
## LAN discovery beacon (encode/decode only; sockets live in the broadcaster
## and LobbyClient). UDP payload: magic ERLB + JSON (protocol version, name,
## counts, optional join code, WebSocket port, open portal multipliers,
## import policy stubs).

const MAGIC := "ERLB"
const DISCOVERY_PORT: int = 18080
const DEFAULT_WS_PORT: int = 8080


static func encode(info: Dictionary) -> PackedByteArray:
	var body := {
		"v": SimConstants.PROTOCOL_VERSION,
		"name": String(info.get("name", "Lobby")),
		"players": int(info.get("players", 1)),
		"max": int(info.get("max", 50)),
		"code": String(info.get("code", "")),
		"port": int(info.get("port", DEFAULT_WS_PORT)),
		"path": String(info.get("path", "/ws")),
		"portals": info.get("portals", []),
		"imports_allowed": bool(info.get("imports_allowed", info.get("allow_imports", true))),
		"offline_allowed": bool(info.get("offline_allowed", info.get("allow_offline_imports", true))),
		"m100_min": int(info.get("m100_min", 100)),
		"m100_max": int(info.get("m100_max", 100)),
	}
	var out := PackedByteArray()
	out.append_array(MAGIC.to_utf8_buffer())
	out.append_array(JSON.stringify(body).to_utf8_buffer())
	return out


static func decode(buf: PackedByteArray) -> Dictionary:
	var magic_buf := MAGIC.to_utf8_buffer()
	if buf.size() < magic_buf.size() + 2:
		return {}
	for i in range(magic_buf.size()):
		if buf[i] != magic_buf[i]:
			return {}
	var json_buf := buf.slice(magic_buf.size())
	var parsed: Variant = JSON.parse_string(json_buf.get_string_from_utf8())
	if not (parsed is Dictionary):
		return {}
	var d: Dictionary = parsed
	if int(d.get("v", 0)) != SimConstants.PROTOCOL_VERSION:
		return {}
	var portals: Array[float] = []
	var raw: Variant = d.get("portals", [])
	if raw is Array:
		for x in raw:
			portals.append(float(x))
	return {
		"name": String(d.get("name", "Lobby")),
		"players": int(d.get("players", 0)),
		"max": int(d.get("max", 50)),
		"code": String(d.get("code", "")),
		"port": int(d.get("port", DEFAULT_WS_PORT)),
		"path": String(d.get("path", "/ws")),
		"portals": portals,
		"imports_allowed": bool(d.get("imports_allowed", d.get("allow_imports", true))),
		"offline_allowed": bool(d.get("offline_allowed", d.get("allow_offline_imports", true))),
		"m100_min": int(d.get("m100_min", 100)),
		"m100_max": int(d.get("m100_max", 100)),
		"preview": PortalPreview.select(portals),
		"more": PortalPreview.overflow_count(portals.size()),
	}
