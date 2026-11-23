class_name ImportResult
extends RefCounted
## Result codes of LobbyHost.import_character(). One place for the lobby UI to
## map to messages. Import checks run only at import, never at Hello.

## Imported; the character is attached to the player.
const IMPORT_RESULT_OK: int = 0
## The lobby does not accept imported characters (imports_allowed = false).
const REJECTED_IMPORTS_OFF: int = 1
## The character was played offline and the lobby disallows that
## (offline_allowed = false).
const REJECTED_OFFLINE_OFF: int = 2
## The blob is not a character file (bad header or truncated).
const REJECTED_BAD_FORMAT: int = 3
## A character file from a format version this host does not read.
const REJECTED_UNSUPPORTED_VERSION: int = 4
## The signature is missing or did not verify. Import fails closed: until
## verification lands (host-lobby protocol PR) every well-formed blob gets this.
const REJECTED_BAD_SIGNATURE: int = 5
## This player already imported a character in this lobby.
const REJECTED_ALREADY_EXISTS: int = 6
## No such player in the lobby.
const REJECTED_UNKNOWN_PLAYER: int = 7

const NAMES: Dictionary = {
	IMPORT_RESULT_OK: "IMPORT_RESULT_OK",
	REJECTED_IMPORTS_OFF: "REJECTED_IMPORTS_OFF",
	REJECTED_OFFLINE_OFF: "REJECTED_OFFLINE_OFF",
	REJECTED_BAD_FORMAT: "REJECTED_BAD_FORMAT",
	REJECTED_UNSUPPORTED_VERSION: "REJECTED_UNSUPPORTED_VERSION",
	REJECTED_BAD_SIGNATURE: "REJECTED_BAD_SIGNATURE",
	REJECTED_ALREADY_EXISTS: "REJECTED_ALREADY_EXISTS",
	REJECTED_UNKNOWN_PLAYER: "REJECTED_UNKNOWN_PLAYER",
}


## Every defined code, in value order.
static func all() -> PackedInt32Array:
	return PackedInt32Array(NAMES.keys())


static func name_of(code: int) -> String:
	return NAMES.get(code, "UNKNOWN")
