class_name LobbyBeaconBroadcaster
extends RefCounted
## Sends LAN discovery beacons for a listen host. Not part of LobbyHost
## (that tree is owned by the Server Engineer).

const INTERVAL_S: float = 1.0

var settings: LobbySettings
var player_count: int = 1
var _udp: PacketPeerUDP = PacketPeerUDP.new()
var _ready: bool = false
var _accum: float = 0.0


func start(p_settings: LobbySettings, bind_host: String) -> Error:
	settings = p_settings
	var bind := bind_host
	if bind == "*" or bind == "":
		bind = "0.0.0.0"
	var err: Error = _udp.bind(LobbyBeacon.DISCOVERY_PORT, bind)
	if err != OK:
		return err
	_udp.set_broadcast_enabled(true)
	_ready = true
	return OK


func poll(delta: float) -> void:
	if not _ready or settings == null:
		return
	_accum += delta
	if _accum < INTERVAL_S:
		return
	_accum = 0.0
	broadcast()


func broadcast() -> void:
	if not _ready or settings == null:
		return
	var payload := LobbyBeacon.encode(settings.to_beacon(player_count))
	_udp.set_dest_address("255.255.255.255", LobbyBeacon.DISCOVERY_PORT)
	_udp.put_packet(payload)


func stop() -> void:
	if _ready:
		_udp.close()
		_ready = false
