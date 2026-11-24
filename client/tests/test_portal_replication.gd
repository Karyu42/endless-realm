extends GutTest
## Client decode of Snapshot.portals and admitted_portal_ids, plus the
## open / closed / full entrance display rules and InstanceList rows.

const PB := preload("res://src/net/proto/protocol_v1_pb.gd")


var _catalog: DataCatalog
var _ui: LobbyUiSettings


func before_each() -> void:
	_catalog = DataCatalog.load_default()
	_ui = LobbyUiSettings.load_default()


func _enter_portal() -> PortalSnapshot:
	var p := PortalSnapshot.new()
	p.kind = PortalSnapshot.KIND_ENTER
	return p


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
