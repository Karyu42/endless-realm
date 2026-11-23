class_name ErrorCodes
extends RefCounted
## proto/v1 ErrorCode names for lobby and portal UI copy. Packed messages live
## in data/lobby_ui.json. This does not change the wire enum.

const PB := preload("res://src/net/proto/protocol_v1_pb.gd")

## proto ErrorCode.JOIN_REFUSED = 7, added in PR #73. Defined here so the
## client can show packed copy before that proto change lands. Do not edit
## proto or net/host in this PR.
const JOIN_REFUSED := 7

const NAMES: Dictionary = {
	PB.ErrorCode.MULTIPLIER_NOT_ALLOWED: "MULTIPLIER_NOT_ALLOWED",
	PB.ErrorCode.INSTANCE_FULL: "INSTANCE_FULL",
	PB.ErrorCode.INSTANCE_NOT_FOUND: "INSTANCE_NOT_FOUND",
	JOIN_REFUSED: "JOIN_REFUSED",
}


## Codes that must have packed player-facing copy.
static func packed() -> PackedInt32Array:
	return PackedInt32Array([
		PB.ErrorCode.MULTIPLIER_NOT_ALLOWED,
		PB.ErrorCode.INSTANCE_FULL,
		PB.ErrorCode.INSTANCE_NOT_FOUND,
		JOIN_REFUSED,
	])


static func name_of(code: int) -> String:
	return String(NAMES.get(code, "UNKNOWN"))


## Id logged through DataCatalog when a code has no packed message.
static func catalog_id(code: int) -> String:
	var name: String = name_of(code)
	if name == "UNKNOWN":
		return "ErrorCode.%d" % code
	return "ErrorCode.%s" % name
