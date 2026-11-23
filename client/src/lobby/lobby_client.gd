class_name LobbyClient
extends Node
## WebSocket client for a player-hosted lobby. Also listens for LAN beacons.

signal welcomed(player_id: int)
signal rejected(reason: String)
signal snapshot_received(msg: Dictionary)
signal lobbies_changed

var codec: ProtocolCodec = ProtocolCodec.new()
var player_id: int = 0
var last_reason: String = ""
var last_welcome: Dictionary = {}
var last_snapshot: Dictionary = {}
var connected: bool = false
var lobbies: Array[Dictionary] = [] # decoded beacons plus "ip"

var _ws: WebSocketPeer
var _udp: PacketPeerUDP = PacketPeerUDP.new()
var _udp_ready: bool = false
var _played_offline: bool = false
var _join_code: String = ""
var _url: String = ""


func start_discovery() -> Error:
	var err: Error = _udp.bind(LobbyBeacon.DISCOVERY_PORT)
	if err != OK:
		return err
	_udp_ready = true
	return OK


func connect_to(url: String, played_offline: bool = false, join_code: String = "") -> Error:
	_url = url
	_played_offline = played_offline
	_join_code = join_code
	_ws = WebSocketPeer.new()
	var err: Error = _ws.connect_to_url(url)
	if err != OK:
		_ws = null
		return err
	return OK


func connect_to_lobby(info: Dictionary, played_offline: bool = false) -> Error:
	var ip := String(info.get("ip", "127.0.0.1"))
	var port: int = int(info.get("port", LobbyBeacon.DEFAULT_WS_PORT))
	var path := String(info.get("path", "/ws"))
	if not path.begins_with("/"):
		path = "/" + path
	var url := "ws://%s:%d%s" % [ip, port, path]
	return connect_to(url, played_offline, String(info.get("code", "")))


func find_by_code(code: String) -> Dictionary:
	var want := code.strip_edges().to_upper()
	for lobby in lobbies:
		if String(lobby.get("code", "")).to_upper() == want:
			return lobby
	return {}


func send_intent(intent: InputIntent) -> void:
	if _ws == null or _ws.get_ready_state() != WebSocketPeer.STATE_OPEN:
		return
	_ws.send(codec.encode(Handshake.input_payload(intent)), WebSocketPeer.WRITE_MODE_BINARY)


func _process(_delta: float) -> void:
	poll()


func poll() -> void:
	_poll_ws()
	_poll_udp()


func _poll_ws() -> void:
	if _ws == null:
		return
	_ws.poll()
	var state: int = _ws.get_ready_state()
	if state == WebSocketPeer.STATE_OPEN:
		if not connected:
			_ws.send(
				codec.encode(Handshake.hello_payload(_played_offline, _join_code)),
				WebSocketPeer.WRITE_MODE_BINARY
			)
			connected = true
		while _ws.get_available_packet_count() > 0:
			_on_packet(_ws.get_packet())
	elif state == WebSocketPeer.STATE_CLOSED:
		connected = false


func _on_packet(buf: PackedByteArray) -> void:
	var msg := codec.decode(buf)
	var typ := String(msg.get("type", ""))
	if typ == "welcome":
		last_welcome = msg
		player_id = int(msg.get("player_id", 0))
		welcomed.emit(player_id)
	elif typ == "reject":
		last_reason = String(msg.get("reason", ""))
		rejected.emit(last_reason)
	elif typ == "snapshot":
		last_snapshot = msg
		snapshot_received.emit(msg)


func _poll_udp() -> void:
	if not _udp_ready:
		return
	var changed := false
	while _udp.get_available_packet_count() > 0:
		var buf := _udp.get_packet()
		var ip := _udp.get_packet_ip()
		var info := LobbyBeacon.decode(buf)
		if info.is_empty():
			continue
		info["ip"] = ip
		var key := "%s:%d:%s" % [ip, int(info.get("port", 0)), String(info.get("code", ""))]
		var found := false
		for i in range(lobbies.size()):
			var existing: Dictionary = lobbies[i]
			var ekey := "%s:%d:%s" % [
				String(existing.get("ip", "")),
				int(existing.get("port", 0)),
				String(existing.get("code", "")),
			]
			if ekey == key:
				lobbies[i] = info
				found = true
				changed = true
				break
		if not found:
			lobbies.append(info)
			changed = true
	if changed:
		lobbies_changed.emit()


func stop() -> void:
	if _ws != null:
		_ws.close()
		_ws = null
	connected = false
	if _udp_ready:
		_udp.close()
		_udp_ready = false


func _exit_tree() -> void:
	stop()
