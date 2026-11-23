class_name LobbyRowFormat
extends RefCounted
## Player-facing lobby browser row. Uses only fields the listing already
## carries, plus optional invite-only / ping keys when the source provides
## them. Does not invent beacon payload fields.


static func format(info: Dictionary, ui: LobbyUiSettings) -> String:
	var parts: PackedStringArray = []
	parts.append(String(info.get("name", "?")))
	parts.append(ui.text("players") % [int(info.get("players", 0)), int(info.get("max", 0))])
	parts.append(ui.text("m100_range") % [
		float(int(info.get("m100_min", 100))) / 100.0,
		float(int(info.get("m100_max", 100))) / 100.0,
	])
	parts.append(imports_label(info, ui))
	if is_invite_only(info):
		parts.append(ui.text("invite_only"))
	if info.has("ping_ms") and int(info["ping_ms"]) >= 0:
		parts.append(ui.text("ping_ms") % int(info["ping_ms"]))
	var preview: Array = info.get("preview", info.get("portals", []))
	if preview is Array and not (preview as Array).is_empty():
		var chips: PackedStringArray = []
		for v in preview:
			chips.append("%.2f" % float(v))
		var more: int = int(info.get("more", 0))
		if more > 0:
			chips.append("+%d more" % more)
		parts.append("portals [%s]" % ", ".join(chips))
	return "  ".join(parts)


static func imports_label(info: Dictionary, ui: LobbyUiSettings) -> String:
	if not bool(info.get("imports_allowed", info.get("allow_imports", true))):
		return ui.text("imports_off")
	if not bool(info.get("offline_allowed", info.get("allow_offline_imports", true))):
		return ui.text("imports_no_offline")
	return ui.text("imports_ok")


## True only when the listing actually carries an invite-only / unlisted
## flag. A missing key is not treated as invite-only (the beacon does not
## yet carry this field).
static func is_invite_only(info: Dictionary) -> bool:
	if info.has("invite_only"):
		return bool(info["invite_only"])
	if info.has("listed"):
		return not bool(info["listed"])
	return false
