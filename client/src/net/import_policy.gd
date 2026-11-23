class_name ImportPolicy
extends RefCounted
## Client-side import-refusal rules (vision §11.3 / §11.5).
## Applied when importing a character, not when joining a lobby.
## Codes are ImportResult constants; use ImportResult.name_of() / all()
## for UI and wire mapping. LobbyHost.import_character() is the host check.

## Allowed; same value as ImportResult.IMPORT_RESULT_OK.
const IMPORT_RESULT_OK := ImportResult.IMPORT_RESULT_OK
const REJECTED_IMPORTS_OFF := ImportResult.REJECTED_IMPORTS_OFF
const REJECTED_OFFLINE_OFF := ImportResult.REJECTED_OFFLINE_OFF


## ImportResult.IMPORT_RESULT_OK means the import is allowed. Any other
## code is a refusal (ImportResult.name_of(code) is the reason name).
static func refuse_reason(
	is_import: bool,
	played_offline: bool,
	imports_allowed: bool,
	offline_allowed: bool
) -> int:
	if not is_import:
		return ImportResult.IMPORT_RESULT_OK
	if not imports_allowed:
		return ImportResult.REJECTED_IMPORTS_OFF
	if played_offline and not offline_allowed:
		return ImportResult.REJECTED_OFFLINE_OFF
	return ImportResult.IMPORT_RESULT_OK
