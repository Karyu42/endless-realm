class_name LobbyClient
extends Node
## WebSocket client for a player-hosted lobby, speaking proto/v1.
## Also listens for LAN beacons.

const PB := preload("res://src/net/proto/protocol_v1_pb.gd")

signal welcomed(player_id: int)
signal rejected(reason: String)
## Mid-session ErrorReply (portal refusals). Not a join Reject.
signal error_received(code: int, reason: String)
## Hello-time ErrorReply, before Welcome. A join refusal, not a mid-session portal refusal.
signal join_error_received(code: int, reason: String)
signal snapshot_received(tick: int)
signal instances_received
signal lobbies_changed

var player_id: int = 0
var last_reason: String = ""
var last_error_code: int = 0
var last_tick: int = 0
var last_snapshot = null
var instances: Array = [] # dictionaries from InstanceInfo
var connected: bool = false
var hello_sent: bool = false
var lobbies: Array[Dictionary] = [] # decoded beacons plus "ip"

const INSTANCE_LIST_INTERVAL := 0.5

var _ws: WebSocketPeer
var _list_wait: float = 0.0
var _udp: PacketPeerUDP = PacketPeerUDP.new()
var _udp_ready: bool = false
var _url: String = ""


func start_discovery() -> Error:
	var err: Error = _udp.bind(LobbyBeacon.DISCOVERY_PORT)
	if err != OK:
		return err
	_udp_ready = true
	return OK


func connect_to(url: String, _played_offline: bool = false, _join_code: String = "") -> Error:
	# played_offline / join_code are not sent at join (import happens later).
	_url = url
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
	if want == "":
		return {}
	for lobby in lobbies:
		if String(lobby.get("code", "")).to_upper() == want:
			return lobby
	return {}


func send_intent(intent: InputIntent) -> void:
	if _ws == null or _ws.get_ready_state() != WebSocketPeer.STATE_OPEN:
		return
	_ws.put_packet(NetClient.encode_input(intent))


func _process(delta: float) -> void:
	poll()
	_maybe_request_instance_list(delta)


func poll() -> void:
	_poll_ws()
	_poll_udp()


func _poll_ws() -> void:
	if _ws == null:
		return
	_ws.poll()
	var state: int = _ws.get_ready_state()
	if state == WebSocketPeer.STATE_OPEN:
		if not hello_sent:
			var msg = PB.ClientMessage.new()
			msg.new_hello().set_protocol_version(SimConstants.PROTOCOL_VERSION)
			_ws.put_packet(msg.to_bytes())
			hello_sent = true
			connected = true
		while _ws.get_available_packet_count() > 0:
			_on_packet(_ws.get_packet())
	elif state == WebSocketPeer.STATE_CLOSED:
		connected = false
		hello_sent = false


func _on_packet(buf: PackedByteArray) -> void:
	var msg = PB.ServerMessage.new()
	if msg.from_bytes(buf) != PB.PB_ERR.NO_ERRORS:
		return
	if msg.has_welcome():
		var w = msg.get_welcome()
		player_id = w.get_player_id()
		welcomed.emit(player_id)
	elif msg.has_reject():
		last_reason = msg.get_reject().get_reason()
		rejected.emit(last_reason)
	elif msg.has_snapshot():
		last_snapshot = msg.get_snapshot()
		last_tick = last_snapshot.get_tick()
		snapshot_received.emit(last_tick)
	elif msg.has_instance_list():
		instances = SnapshotDecode.instances_from_list(msg.get_instance_list())
		instances_received.emit()
	elif msg.has_error():
		last_error_code = msg.get_error().get_code()
		last_reason = msg.get_error().get_reason()
		# Keep Reject, Hello-time join refusals, and mid-session portal
		# ErrorReply on separate signals so a full lobby is not shown as a
		# refused portal.
		if player_id == 0:
			join_error_received.emit(last_error_code, last_reason)
		else:
			error_received.emit(last_error_code, last_reason)


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


func request_instance_list() -> void:
	if _ws == null or _ws.get_ready_state() != WebSocketPeer.STATE_OPEN:
		return
	if player_id == 0:
		return
	var msg = PB.ClientMessage.new()
	msg.new_list_instances()
	_ws.put_packet(msg.to_bytes())


func _maybe_request_instance_list(delta: float) -> void:
	if player_id == 0 or not connected:
		return
	_list_wait += delta
	if _list_wait < INSTANCE_LIST_INTERVAL:
		return
	_list_wait = 0.0
	request_instance_list()


func stop() -> void:
	if _ws != null:
		_ws.close()
		_ws = null
	connected = false
	hello_sent = false
	last_snapshot = null
	instances = []
	_list_wait = 0.0
	if _udp_ready:
		_udp.close()
		_udp_ready = false


func _exit_tree() -> void:
	stop()
