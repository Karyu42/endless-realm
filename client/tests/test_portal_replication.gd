extends GutTest
## Client decode of Snapshot.portals and admitted_portal_ids, plus the
## open / closed / full entrance display rules and InstanceList rows.

const PB := preload("res://src/net/proto/protocol_v1_pb.gd")


var _catalog: DataCatalog
var _ui: LobbyUiSettings
var _host: LobbyHost


func before_each() -> void:
	SnapshotDecode.reset_log_limits()
	_catalog = DataCatalog.load_default()
	_ui = LobbyUiSettings.load_default()


func after_each() -> void:
	if _host != null:
		_host.stop()
		_host = null


func _enter_portal() -> PortalSnapshot:
	var p := PortalSnapshot.new()
	p.kind = PortalSnapshot.KIND_ENTER
	return p


func _unknown_snapshot(dungeon_id: String, portal_id: int = 1) -> Variant:
	var s = PB.Snapshot.new()
	s.set_tick(1)
	var st = s.add_portals()
	st.set_id(portal_id)
	st.set_kind(PB.PortalKind.ENTER)
	st.set_dungeon_id(dungeon_id)
	return s




func test_decode_round_trips_every_portal_field() -> void:
	var s = PB.Snapshot.new()
	s.set_tick(420)
	var st = s.add_portals()
	st.set_id(1099511627783) # 2^40 + 7
	st.set_x(12.5)
	st.set_y(8.25)
	st.set_radius(0.75)
	st.set_kind(PB.PortalKind.ENTER)
	st.set_dungeon_id("hollowmere_vault")
	st.set_marker_id("")
	st.set_m100(125)
	st.set_base_level(10)
	st.set_content_level(12)
	st.set_capacity(4)
	st.set_admitted_count(1)
	st.set_closed(true)
	st.set_persistent(false)
	st.set_grants_persistent(true)
	st.set_expire_tick(2400)
	s.add_admitted_portal_ids(1099511627783)
	var ex = s.add_portals()
	ex.set_id(9)
	ex.set_x(44.0)
	ex.set_y(6.0)
	ex.set_radius(0.8)
	ex.set_kind(PB.PortalKind.EXIT)
	ex.set_dungeon_id("hollowmere_vault")
	ex.set_marker_id("")
	ex.set_m100(100)
	ex.set_base_level(10)
	ex.set_content_level(10)
	ex.set_capacity(0)
	ex.set_admitted_count(0)
	ex.set_closed(false)
	ex.set_persistent(false)
	ex.set_grants_persistent(false)
	ex.set_expire_tick(0)
	var mark = s.add_portals()
	mark.set_id(3)
	mark.set_x(42.0)
	mark.set_y(6.0)
	mark.set_radius(0.6)
	mark.set_kind(PB.PortalKind.PLACEHOLDER)
	mark.set_dungeon_id("hollowmere_vault")
	mark.set_marker_id("test_marker")
	var buf: PackedByteArray = s.to_bytes()
	var decoded = PB.Snapshot.new()
	assert_eq(decoded.from_bytes(buf), PB.PB_ERR.NO_ERRORS)
	var snap := WorldSnapshot.new()
	SnapshotDecode.fill_world(snap, decoded, _catalog)
	assert_eq(snap.tick, 420)
	assert_eq(snap.portals.size(), 3)
	var portal: PortalSnapshot = snap.portals[0]
	assert_eq(portal.id, 1099511627783)
	assert_almost_eq(portal.x, 12.5, 0.0001)
	assert_almost_eq(portal.y, 8.25, 0.0001)
	assert_almost_eq(portal.radius, 0.75, 0.0001)
	assert_eq(portal.kind, PortalSnapshot.KIND_ENTER)
	assert_eq(portal.dungeon_id, "hollowmere_vault")
	assert_eq(portal.dungeon_name, "the Hollowmere Vault")
	assert_eq(portal.marker_id, "")
	assert_eq(portal.m100, 125)
	assert_eq(portal.base_level, 10)
	assert_eq(portal.content_level, 12)
	assert_eq(portal.capacity, 4)
	assert_eq(portal.admitted_count, 1)
	assert_true(portal.closed)
	assert_false(portal.persistent)
	assert_true(portal.grants_persistent)
	assert_eq(portal.expire_tick, 2400)
	assert_true(portal.admitted_for_me)
	assert_true(portal.appears_open(), "closed but admitted shows as open")
	var leave: PortalSnapshot = snap.portals[1]
	assert_eq(leave.kind, PortalSnapshot.KIND_EXIT)
	assert_eq(leave.id, 9)
	assert_false(leave.admitted_for_me)
	assert_true(leave.appears_open())
	var candle: PortalSnapshot = snap.portals[2]
	assert_eq(candle.kind, PortalSnapshot.KIND_PLACEHOLDER)
	assert_eq(candle.marker_id, "test_marker")
	assert_eq(candle.dungeon_name, "the Hollowmere Vault")
	assert_push_error("DataCatalog: unknown id hollowmere_vault.test_marker")


func test_closed_and_admitted_shows_as_open() -> void:
	var p := _enter_portal()
	p.closed = true
	p.admitted_for_me = true
	assert_true(p.appears_open())
	assert_false(p.appears_full())


func test_closed_and_not_admitted_shows_as_closed() -> void:
	var p := _enter_portal()
	p.closed = true
	p.admitted_for_me = false
	assert_false(p.appears_open())
	assert_false(p.appears_full())


func test_persistent_at_capacity_shows_as_full() -> void:
	var p := _enter_portal()
	p.persistent = true
	p.capacity = 4
	p.admitted_count = 4
	p.closed = false
	p.admitted_for_me = false
	assert_true(p.appears_full())
	assert_false(p.appears_open())
	p.admitted_count = 3
	assert_false(p.appears_full())
	assert_true(p.appears_open())


func test_unknown_dungeon_id_logs() -> void:
	var s = PB.Snapshot.new()
	var st = s.add_portals()
	st.set_id(1)
	st.set_kind(PB.PortalKind.ENTER)
	st.set_dungeon_id("no_such_dungeon")
	var snap := WorldSnapshot.new()
	SnapshotDecode.fill_world(snap, s, _catalog)
	assert_eq(snap.portals[0].dungeon_id, "no_such_dungeon")
	assert_eq(snap.portals[0].dungeon_name, "", "no fallback name")
	assert_push_error("DataCatalog: unknown id no_such_dungeon")


func test_instance_row_shows_base_level_capacity_admitted_and_closed() -> void:
	var listing = PB.InstanceList.new()
	var info = listing.add_instances()
	info.set_instance(3)
	info.set_m100(125)
	info.set_player_count(2)
	info.set_is_default(false)
	info.set_base_level(10)
	info.set_capacity(4)
	info.set_admitted_count(1)
	info.set_closed(true)
	var rows: Array = SnapshotDecode.instances_from_list(listing)
	assert_eq(rows.size(), 1)
	assert_eq(int(rows[0]["base_level"]), 10)
	assert_eq(int(rows[0]["capacity"]), 4)
	assert_eq(int(rows[0]["admitted_count"]), 1)
	assert_true(bool(rows[0]["closed"]))
	var text := InstanceRowFormat.format(rows[0], _ui)
	assert_string_contains(text, "E10")
	assert_string_contains(text, "1/4")
	assert_string_contains(text, "Closed")
	var open_info: Dictionary = (rows[0] as Dictionary).duplicate()
	open_info["closed"] = false
	var open_text: String = InstanceRowFormat.format(open_info, _ui)
	assert_string_contains(open_text, "E10")
	assert_string_contains(open_text, "1/4")
	assert_eq(open_text.find("Closed"), -1)


func test_client_world_source_fills_portals_from_the_last_snapshot() -> void:
	var client := LobbyClient.new()
	var s = PB.Snapshot.new()
	s.set_tick(7)
	var st = s.add_portals()
	st.set_id(5)
	st.set_x(3.0)
	st.set_y(4.0)
	st.set_kind(PB.PortalKind.ENTER)
	st.set_dungeon_id("hollowmere_vault")
	st.set_closed(false)
	client.last_snapshot = s
	client.last_tick = 7
	var src := ClientWorldSource.new(client, _catalog)
	src.last_tick = 7
	var snap: WorldSnapshot = src.snapshot()
	assert_eq(snap.tick, 7)
	assert_eq(snap.portals.size(), 1)
	assert_eq(snap.portals[0].id, 5)
	assert_eq(snap.portals[0].dungeon_name, "the Hollowmere Vault")
	assert_true(snap.portals[0].appears_open())
	client.free()

func test_repeated_snapshot_logs_an_unknown_id_once() -> void:
	var client := LobbyClient.new()
	client.last_snapshot = _unknown_snapshot("no_such_dungeon")
	client.last_tick = 1
	var src := ClientWorldSource.new(client, _catalog)
	src.last_tick = 1
	for _i in range(5):
		var snap: WorldSnapshot = src.snapshot()
		assert_eq(snap.portals.size(), 1)
		assert_eq(snap.portals[0].dungeon_name, "")
	assert_push_error_count(1)
	client.free()


func test_unknown_id_log_cap_emits_one_suppression_line() -> void:
	for i in range(SnapshotDecode.UNKNOWN_ID_LOG_CAP):
		var snap := WorldSnapshot.new()
		SnapshotDecode.fill_world(snap, _unknown_snapshot("unknown_%d" % i, i + 1), _catalog)
	var extra := WorldSnapshot.new()
	SnapshotDecode.fill_world(extra, _unknown_snapshot("unknown_past_cap", 99), _catalog)
	assert_eq(extra.portals[0].dungeon_name, "")
	var again := WorldSnapshot.new()
	SnapshotDecode.fill_world(again, _unknown_snapshot("unknown_past_cap_2", 100), _catalog)
	assert_push_error("DataCatalog: further unknown ids suppressed")
	assert_push_error_count(SnapshotDecode.UNKNOWN_ID_LOG_CAP + 1)


func test_portal_count_cap_is_enforced() -> void:
	var s = PB.Snapshot.new()
	s.set_tick(3)
	var total: int = SnapshotDecode.MAX_PORTALS_PER_SNAPSHOT + 5
	for i in range(total):
		var st = s.add_portals()
		st.set_id(i + 1)
		st.set_kind(PB.PortalKind.ENTER)
		st.set_dungeon_id("hollowmere_vault")
		st.set_x(float(i))
	var snap := WorldSnapshot.new()
	SnapshotDecode.fill_world(snap, s, _catalog)
	assert_eq(snap.portals.size(), SnapshotDecode.MAX_PORTALS_PER_SNAPSHOT)
	assert_eq(snap.portals[0].id, 1)
	assert_eq(snap.portals[SnapshotDecode.MAX_PORTALS_PER_SNAPSHOT - 1].id, SnapshotDecode.MAX_PORTALS_PER_SNAPSHOT)
	assert_push_error("SnapshotDecode: extra portals dropped")
	# Applying an oversized snapshot again does not log a second time.
	var snap2 := WorldSnapshot.new()
	SnapshotDecode.fill_world(snap2, s, _catalog)
	assert_eq(snap2.portals.size(), SnapshotDecode.MAX_PORTALS_PER_SNAPSHOT)
	assert_push_error_count(1)


func test_host_encoded_snapshot_decodes_on_the_client() -> void:
	_host = LobbyHost.new(SimConfig.new())
	_host.port = 0
	var settings := LobbySettings.new()
	settings.max_players = 4
	assert_eq(_host.apply_settings(settings), OK)
	assert_eq(_host.start(), OK)
	var portal_id: int = _host.sim.spawn_practice_portal("hollowmere_vault")
	assert_gt(portal_id, 0)
	_host.run_tick()
	var bytes: PackedByteArray = _host._encode_snapshot_for([])
	var msg = PB.ServerMessage.new()
	assert_eq(msg.from_bytes(bytes), PB.PB_ERR.NO_ERRORS)
	assert_true(msg.has_snapshot())
	var proto_snap = msg.get_snapshot()
	var client := LobbyClient.new()
	client.last_snapshot = proto_snap
	client.last_tick = proto_snap.get_tick()
	var world_src := ClientWorldSource.new(client, _catalog)
	world_src.last_tick = client.last_tick
	var snap: WorldSnapshot = world_src.snapshot()
	assert_eq(snap.portals.size(), proto_snap.get_portals().size())
	assert_gt(snap.portals.size(), 0)
	var found: PortalSnapshot = null
	for portal in snap.portals:
		if portal.id == portal_id:
			found = portal
			break
	assert_not_null(found)
	var st = null
	for p in proto_snap.get_portals():
		if int(p.get_id()) == portal_id:
			st = p
			break
	assert_not_null(st)
	assert_eq(found.kind, PortalSnapshot.KIND_ENTER)
	assert_eq(found.dungeon_id, String(st.get_dungeon_id()))
	assert_eq(found.dungeon_name, "the Hollowmere Vault")
	assert_almost_eq(found.x, float(st.get_x()), 0.0001)
	assert_almost_eq(found.y, float(st.get_y()), 0.0001)
	assert_almost_eq(found.radius, float(st.get_radius()), 0.0001)
	assert_eq(found.m100, int(st.get_m100()))
	assert_eq(found.base_level, int(st.get_base_level()))
	assert_eq(found.content_level, int(st.get_content_level()))
	assert_eq(found.capacity, int(st.get_capacity()))
	assert_eq(found.admitted_count, int(st.get_admitted_count()))
	assert_eq(found.closed, bool(st.get_closed()))
	assert_eq(found.persistent, bool(st.get_persistent()))
	assert_eq(found.grants_persistent, bool(st.get_grants_persistent()))
	assert_eq(found.expire_tick, int(st.get_expire_tick()))
	client.free()


func test_portal_cap_keeps_exits_and_admitted_entrances() -> void:
	var s = PB.Snapshot.new()
	s.set_tick(4)
	var cap: int = SnapshotDecode.MAX_PORTALS_PER_SNAPSHOT
	for i in range(cap):
		var st = s.add_portals()
		st.set_id(i + 1)
		st.set_kind(PB.PortalKind.ENTER)
		st.set_dungeon_id("hollowmere_vault")
	var leave = s.add_portals()
	leave.set_id(200)
	leave.set_kind(PB.PortalKind.EXIT)
	leave.set_dungeon_id("hollowmere_vault")
	var admitted = s.add_portals()
	admitted.set_id(300)
	admitted.set_kind(PB.PortalKind.ENTER)
	admitted.set_dungeon_id("hollowmere_vault")
	admitted.set_closed(true)
	s.add_admitted_portal_ids(300)
	var snap := WorldSnapshot.new()
	SnapshotDecode.fill_world(snap, s, _catalog)
	assert_eq(snap.portals.size(), cap)
	var ids: Array[int] = []
	for portal in snap.portals:
		ids.append(portal.id)
	assert_eq(ids[0], 200, "exit is kept first")
	assert_eq(ids[1], 300, "admitted entrance is kept next")
	assert_eq(ids[2], 1)
	assert_eq(ids[cap - 1], cap - 2, "lowest-priority extras are dropped")
	assert_false(ids.has(cap - 1))
	assert_false(ids.has(cap))
	var kept_admitted: PortalSnapshot = snap.portals[1]
	assert_true(kept_admitted.admitted_for_me)
	assert_true(kept_admitted.appears_open())
	assert_push_error("SnapshotDecode: extra portals dropped")


func test_host_encoded_snapshot_includes_admitted_portal_ids() -> void:
	_host = LobbyHost.new(SimConfig.new())
	_host.port = 0
	var settings := LobbySettings.new()
	settings.max_players = 4
	assert_eq(_host.apply_settings(settings), OK)
	var portal: PortalSnapshot = _host.sim.portal_by_id(_host.sim.spawn_practice_portal("hollowmere_vault"))
	assert_not_null(portal)
	# Off the packed practice position so the entrance is not persistent and
	# can list this viewer in admitted_portal_ids.
	portal.x += 1.0
	portal.persistent = false
	_host._sync_portal_records()
	var viewer: int = _host.add_local_player()
	_host.run_tick()
	var inst: LobbyHost.HostInstance = _host.instances[0]
	var rec: LobbyHost.PortalRecord = _host._portal_records[_host._portal_key(inst, portal.id)]
	assert_not_null(rec)
	rec.admitted[viewer] = true
	var other: int = _host.add_local_player()
	_host.run_tick()
	var admitted_bytes: PackedByteArray = _host._encode_snapshot_for([], inst, viewer)
	var other_bytes: PackedByteArray = _host._encode_snapshot_for([], inst, other)
	var admitted_msg = PB.ServerMessage.new()
	assert_eq(admitted_msg.from_bytes(admitted_bytes), PB.PB_ERR.NO_ERRORS)
	var other_msg = PB.ServerMessage.new()
	assert_eq(other_msg.from_bytes(other_bytes), PB.PB_ERR.NO_ERRORS)
	var admitted_proto = admitted_msg.get_snapshot()
	var other_proto = other_msg.get_snapshot()
	assert_eq(admitted_proto.get_admitted_portal_ids(), [portal.id] as Array[int])
	assert_eq(other_proto.get_admitted_portal_ids().size(), 0)
	var client := LobbyClient.new()
	client.last_snapshot = admitted_proto
	client.last_tick = admitted_proto.get_tick()
	var src := ClientWorldSource.new(client, _catalog)
	src.last_tick = client.last_tick
	var snap: WorldSnapshot = src.snapshot()
	var found: PortalSnapshot = null
	for p in snap.portals:
		if p.id == portal.id:
			found = p
			break
	assert_not_null(found)
	assert_true(found.admitted_for_me)
	assert_true(found.appears_open())
	client.last_snapshot = other_proto
	client.last_tick = other_proto.get_tick()
	src.last_tick = client.last_tick
	var other_snap: WorldSnapshot = src.snapshot()
	var other_found: PortalSnapshot = null
	for p in other_snap.portals:
		if p.id == portal.id:
			other_found = p
			break
	assert_not_null(other_found)
	assert_false(other_found.admitted_for_me)
	client.free()


func test_session_stop_resets_unknown_id_log_limits() -> void:
	for i in range(SnapshotDecode.UNKNOWN_ID_LOG_CAP):
		var snap := WorldSnapshot.new()
		SnapshotDecode.fill_world(snap, _unknown_snapshot("unknown_%d" % i, i + 1), _catalog)
	var extra := WorldSnapshot.new()
	SnapshotDecode.fill_world(extra, _unknown_snapshot("unknown_past_cap", 99), _catalog)
	var again := WorldSnapshot.new()
	SnapshotDecode.fill_world(again, _unknown_snapshot("unknown_past_cap_2", 100), _catalog)
	var client := LobbyClient.new()
	client.stop()
	var after := WorldSnapshot.new()
	SnapshotDecode.fill_world(after, _unknown_snapshot("after_stop", 101), _catalog)
	assert_eq(after.portals[0].dungeon_name, "")
	assert_push_error("DataCatalog: further unknown ids suppressed")
	assert_push_error("DataCatalog: unknown id after_stop")
	assert_push_error_count(SnapshotDecode.UNKNOWN_ID_LOG_CAP + 2)
	client.free()
