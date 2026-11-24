class_name SnapshotDecode
extends RefCounted
## Client-side mapping from proto Snapshot / InstanceList into game types.
## Does not edit generated proto or host code.

const PB := preload("res://src/net/proto/protocol_v1_pb.gd")


static func fill_world(snap: WorldSnapshot, proto_snap, catalog: DataCatalog) -> void:
	if snap == null or proto_snap == null:
		return
	snap.tick = int(proto_snap.get_tick())
	var admitted: Dictionary = {}
	for pid in proto_snap.get_admitted_portal_ids():
		admitted[int(pid)] = true
	var portals: Array[PortalSnapshot] = []
	for state in proto_snap.get_portals():
		portals.append(portal_from_state(state, admitted, catalog))
	snap.portals = portals


static func portal_from_state(state, admitted: Dictionary, catalog: DataCatalog) -> PortalSnapshot:
	var portal := PortalSnapshot.new()
	if state == null:
		return portal
	portal.id = int(state.get_id())
	portal.x = float(state.get_x())
	portal.y = float(state.get_y())
	portal.radius = float(state.get_radius())
	portal.kind = kind_from_proto(state.get_kind())
	portal.dungeon_id = String(state.get_dungeon_id())
	portal.marker_id = String(state.get_marker_id())
	portal.m100 = int(state.get_m100())
	portal.base_level = int(state.get_base_level())
	portal.content_level = int(state.get_content_level())
	portal.capacity = int(state.get_capacity())
	portal.admitted_count = int(state.get_admitted_count())
	portal.closed = bool(state.get_closed())
	portal.persistent = bool(state.get_persistent())
	portal.grants_persistent = bool(state.get_grants_persistent())
	portal.expire_tick = int(state.get_expire_tick())
	portal.admitted_for_me = admitted.has(portal.id)
	fill_names(portal, catalog)
	return portal


static func kind_from_proto(kind) -> String:
	match int(kind):
		PB.PortalKind.ENTER:
			return PortalSnapshot.KIND_ENTER
		PB.PortalKind.EXIT:
			return PortalSnapshot.KIND_EXIT
		PB.PortalKind.PLACEHOLDER:
			return PortalSnapshot.KIND_PLACEHOLDER
		_:
			return ""


static func fill_names(portal: PortalSnapshot, catalog: DataCatalog) -> void:
	if portal == null:
		return
	# Names come only from packed data. Unknown ids are logged; no fallbacks.
	if portal.dungeon_id != "":
		var def: DungeonDef = catalog.dungeon(portal.dungeon_id) if catalog != null else null
		if def == null:
			DataCatalog.report_unknown_id(portal.dungeon_id)
		else:
			portal.dungeon_name = def.name
			if portal.marker_id != "":
				var marker_name: String = _marker_name(def, portal.marker_id)
				if marker_name == "":
					DataCatalog.report_unknown_id("%s.%s" % [portal.dungeon_id, portal.marker_id])
				else:
					portal.marker_name = marker_name
	elif portal.marker_id != "":
		DataCatalog.report_unknown_id(portal.marker_id)


static func _marker_name(def: DungeonDef, marker_id: String) -> String:
	for room in def.rooms:
		var src: Variant = room.get("boss_placeholder", null)
		if src is Dictionary and String((src as Dictionary).get("id", "")) == marker_id:
			return String((src as Dictionary).get("name", ""))
	return ""


static func instance_from_info(info) -> Dictionary:
	if info == null:
		return {}
	return {
		"instance": int(info.get_instance()),
		"m100": int(info.get_m100()),
		"seed": int(info.get_seed()),
		"player_count": int(info.get_player_count()),
		"is_default": bool(info.get_is_default()),
		"base_level": int(info.get_base_level()),
		"capacity": int(info.get_capacity()),
		"admitted_count": int(info.get_admitted_count()),
		"closed": bool(info.get_closed()),
	}


static func instances_from_list(listing) -> Array:
	var out: Array = []
	if listing == null:
		return out
	for info in listing.get_instances():
		out.append(instance_from_info(info))
	return out
