class_name Handshake
extends RefCounted
## Protocol v1 handshake: version check, lobby cap, and import policy.
## Pure rules, no sockets.

const REASON_PROTOCOL_VERSION := "PROTOCOL_VERSION"
const REASON_LOBBY_FULL := "LOBBY_FULL"
const REASON_IMPORT_REFUSED := "IMPORT_REFUSED"


static func evaluate(
	client_protocol_version: int,
	played_offline: bool,
	allow_offline_imports: bool,
	player_count: int,
	max_players: int,
	next_player_id: int,
	instance_seed: int,
	multiplier: float
) -> Dictionary:
	if client_protocol_version != SimConstants.PROTOCOL_VERSION:
		return {
			"ok": false,
			"reason": REASON_PROTOCOL_VERSION,
			"reject": reject_payload(client_protocol_version, REASON_PROTOCOL_VERSION),
		}
	if player_count >= max_players:
		return {
			"ok": false,
			"reason": REASON_LOBBY_FULL,
			"reject": reject_payload(client_protocol_version, REASON_LOBBY_FULL),
		}
	if not ImportPolicy.allows(played_offline, allow_offline_imports):
		return {
			"ok": false,
			"reason": REASON_IMPORT_REFUSED,
			"reject": reject_payload(client_protocol_version, REASON_IMPORT_REFUSED),
		}
	return {
		"ok": true,
		"reason": "",
		"welcome": {
			"type": "welcome",
			"protocol_version": SimConstants.PROTOCOL_VERSION,
			"player_id": next_player_id,
			"tick_hz": SimConstants.TICK_HZ,
			"instance_seed": instance_seed,
			"multiplier": multiplier,
		},
	}


static func reject_payload(client_protocol_version: int, reason: String) -> Dictionary:
	return {
		"type": "reject",
		"server_protocol_version": SimConstants.PROTOCOL_VERSION,
		"client_protocol_version": client_protocol_version,
		"reason": reason,
	}


static func hello_payload(played_offline: bool, join_code: String = "", display_name: String = "") -> Dictionary:
	return {
		"type": "hello",
		"protocol_version": SimConstants.PROTOCOL_VERSION,
		"played_offline": played_offline,
		"join_code": join_code,
		"display_name": display_name,
	}


static func input_payload(intent: InputIntent) -> Dictionary:
	return {
		"type": "input",
		"seq": intent.seq,
		"move_x": intent.move_x,
		"move_y": intent.move_y,
		"aim": intent.aim,
		"fire_held": intent.fire_held,
	}


static func intent_from_input(msg: Dictionary) -> InputIntent:
	return InputIntent.from_raw(
		int(msg.get("seq", 0)),
		float(msg.get("move_x", 0.0)),
		float(msg.get("move_y", 0.0)),
		float(msg.get("aim", 0.0)),
		bool(msg.get("fire_held", false))
	)


static func snapshot_stub(tick: int, applied: Dictionary) -> Dictionary:
	# TODO: replace with a real WorldSnapshot replication + prediction.
	var players: Array = []
	for id in applied.keys():
		players.append({"id": int(id), "applied_seq": int(applied[id])})
	return {"type": "snapshot", "tick": tick, "players": players}
