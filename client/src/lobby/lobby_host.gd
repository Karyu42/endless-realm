class_name LobbyHost
extends Node
## Listen-server / headless host. Transport is WebSocketPeer + TCPServer only;
## no MultiplayerAPI RPCs. The shared LocalSim is the authority.

signal admitted(player_id: int)
signal rejected(reason: String)

const BEACON_INTERVAL_S: float = 1.0

var settings: LobbySettings
var sim: LocalSim
var codec: ProtocolCodec = ProtocolCodec.new()
var host_player_id: int = 1
var listening: bool = false

var _tcp: TCPServer = TCPServer.new()
var _udp: PacketPeerUDP = PacketPeerUDP.new()
var _udp_ready: bool = false
var _peers: Array[Dictionary] = []
var _next_id: int = 2
var _beacon_accum: float = 0.0
var _intents: Dictionary = {}
var _applied: Dictionary = {}
var _bind_host: String = "*"


func start(p_settings: LobbySettings, p_sim: LocalSim, bind_host: String = "*") -> Error:
	settings = p_settings
	sim = p_sim
	_bind_host = bind_host
	if settings.join_code == "":
		settings.join_code = LobbySettings.generate_join_code()
	var err: Error = _tcp.listen(settings.ws_port, bind_host)
	if err != OK:
		return err
	listening = true
	_intents[host_player_id] = InputIntent.new()
	_applied[host_player_id] = 0
	if bind_host != "127.0.0.1":
		var uerr: Error = _udp.bind(LobbyBeacon.DISCOVERY_PORT, bind_host)
		if uerr == OK:
			_udp.set_broadcast_enabled(true)
			_udp_ready = true
	return OK


func ws_port() -> int:
	return settings.ws_port if settings != null else 0


func player_count() -> int:
	var n: int = 1
	for p in _peers:
		if bool(p.get("admitted", false)):
			n += 1
	return n


func set_intent(player_id: int, intent: InputIntent) -> void:
	_intents[player_id] = intent


func step_world() -> void:
	if sim == null:
		return
	# Same path for the host player and remotes: intents are queued by id.
	# Full multi-pawn simulation is a follow-up; LocalSim still drives player 1.
	var intent: InputIntent = _intents.get(host_player_id, InputIntent.new())
	sim.submit_input(intent)
	sim.step()
	_applied[host_player_id] = intent.seq
	_broadcast_snapshot()


func _process(delta: float) -> void:
	if not listening:
		return
	poll()
	_beacon_accum += delta
	if _beacon_accum >= BEACON_INTERVAL_S:
		_beacon_accum = 0.0
		broadcast_beacon()


func poll() -> void:
	_accept_new()
	_poll_peers()


func _accept_new() -> void:
	while _tcp.is_connection_available():
		var tcp: StreamPeerTCP = _tcp.take_connection()
		if tcp == null:
			return
		var ws := WebSocketPeer.new()
		var err: Error = ws.accept_stream(tcp)
		if err != OK:
			tcp.disconnect_from_host()
			continue
		_peers.append({
			"ws": ws,
			"player_id": 0,
			"admitted": false,
		})


func _poll_peers() -> void:
	var live: Array[Dictionary] = []
	for p in _peers:
		var ws: WebSocketPeer = p["ws"]
		ws.poll()
		var state: int = ws.get_ready_state()
		if state == WebSocketPeer.STATE_CLOSED:
			if bool(p.get("admitted", false)):
				_intents.erase(int(p.get("player_id", 0)))
			continue
		if state == WebSocketPeer.STATE_OPEN:
			while ws.get_available_packet_count() > 0:
				_on_packet(p, ws.get_packet())
			if bool(p.get("pending_close", false)):
				if bool(p.get("reject_flushed", false)):
					ws.close()
					continue
				p["reject_flushed"] = true
		live.append(p)
	_peers = live


func _on_packet(peer: Dictionary, buf: PackedByteArray) -> void:
	var msg := codec.decode(buf)
	var typ := String(msg.get("type", ""))
	if typ == "hello":
		_on_hello(peer, msg)
	elif typ == "input" and bool(peer.get("admitted", false)):
		var intent := Handshake.intent_from_input(msg)
		var pid: int = int(peer.get("player_id", 0))
		set_intent(pid, intent)
		_applied[pid] = intent.seq


func _on_hello(peer: Dictionary, msg: Dictionary) -> void:
	if bool(peer.get("admitted", false)):
		return
	var client_v: int = int(msg.get("protocol_version", 0))
	var played_offline: bool = bool(msg.get("played_offline", false))
	var result := Handshake.evaluate(
		client_v,
		played_offline,
		settings.allow_offline_imports,
		player_count(),
		settings.clamped_max(),
		_next_id,
		settings.instance_seed,
		settings.display_multiplier
	)
	var ws: WebSocketPeer = peer["ws"]
	if not bool(result["ok"]):
		_send(ws, result["reject"])
		rejected.emit(String(result["reason"]))
		# Defer close until the next poll so the reject frame is flushed.
		peer["pending_close"] = true
		return
	var welcome: Dictionary = result["welcome"]
	peer["admitted"] = true
	peer["player_id"] = int(welcome["player_id"])
	_next_id += 1
	_intents[int(welcome["player_id"])] = InputIntent.new()
	_applied[int(welcome["player_id"])] = 0
	_send(ws, welcome)
	admitted.emit(int(welcome["player_id"]))


func _broadcast_snapshot() -> void:
	if sim == null:
		return
	var snap := Handshake.snapshot_stub(sim.tick(), _applied)
	for p in _peers:
		if bool(p.get("admitted", false)):
			_send(p["ws"], snap)


func _send(ws: WebSocketPeer, msg: Dictionary) -> void:
	if ws.get_ready_state() != WebSocketPeer.STATE_OPEN:
		return
	ws.send(codec.encode(msg), WebSocketPeer.WRITE_MODE_BINARY)


func broadcast_beacon() -> void:
	if not _udp_ready:
		return
	var payload := LobbyBeacon.encode(settings.to_beacon(player_count()))
	_udp.set_dest_address("255.255.255.255", LobbyBeacon.DISCOVERY_PORT)
	_udp.put_packet(payload)


func stop() -> void:
	listening = false
	for p in _peers:
		var ws: WebSocketPeer = p["ws"]
		ws.close()
	_peers.clear()
	if _tcp.is_listening():
		_tcp.stop()
	if _udp_ready:
		_udp.close()
		_udp_ready = false


func _exit_tree() -> void:
	stop()
