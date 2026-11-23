class_name ImportPolicy
extends RefCounted
## Host policy for character imports (vision §11.3 / §11.5).
## Applied when importing a character, not when joining a lobby.
## Codes go on the wire via the Server Engineer's protocol PR; this is the
## client-side rule used by the settings UI until that API lands.

const REJECTED_IMPORTS_OFF := "REJECTED_IMPORTS_OFF"
const REJECTED_OFFLINE_OFF := "REJECTED_OFFLINE_OFF"


## Empty string means the import is allowed. A non-empty code is a refusal.
static func refuse_reason(
	is_import: bool,
	played_offline: bool,
	imports_allowed: bool,
	offline_allowed: bool
) -> String:
	if not is_import:
		return ""
	if not imports_allowed:
		return REJECTED_IMPORTS_OFF
	if played_offline and not offline_allowed:
		return REJECTED_OFFLINE_OFF
	return ""
