class_name InstanceRowFormat
extends RefCounted
## Player-facing row for one InstanceInfo from an InstanceList.


static func format(info: Dictionary, ui: LobbyUiSettings) -> String:
	var parts: PackedStringArray = []
	parts.append(ui.text("instance_base_level") % int(info.get("base_level", 0)))
	parts.append(ui.text("instance_admitted") % [
		int(info.get("admitted_count", 0)),
		int(info.get("capacity", 0)),
	])
	if bool(info.get("closed", false)):
		parts.append(ui.text("instance_closed"))
	return "  ".join(parts)
