extends GutTest
## LobbyHost portal routing: the interact resolver for portals, dungeon
## instances created from LocalSim transfers, capacity, carried state,
## per-instance views and snapshots, teardown and id ranges.

const PB := preload("res://src/net/proto/protocol_v1_pb.gd")

var _host: LobbyHost
var _rejections: Array = []


var _flag_restore: Dictionary = {}


func after_each() -> void:
	if _host != null and not _flag_restore.is_empty():
		var src: Dictionary = _host.catalog.dungeon("hollowmere_vault").practice_yard_portal
		for k in _flag_restore:
			if _flag_restore[k] == null:
				src.erase(k)
			else:
				src[k] = _flag_restore[k]
	_flag_restore = {}
	if _host != null:
		_host.stop()
		_host = null
	_rejections = []


func _new_host(max_players: int = 4) -> LobbyHost:
	var host := LobbyHost.new(SimConfig.new())
	host.port = 0
	var s := LobbySettings.new()
	s.max_players = max_players
	assert_eq(host.apply_settings(s), OK)
	host.portal_rejected.connect(func(id: int, code: int, reason: String) -> void:
		_rejections.append([id, code, reason]))
	return host


## Test-only change to the host's own packed data (restored after each test).
func _set_practice_flag(key: String, value: Variant) -> void:
	var src: Dictionary = _host.catalog.dungeon("hollowmere_vault").practice_yard_portal
	if not _flag_restore.has(key):
		_flag_restore[key] = src.get(key)
	src[key] = value


## Practice portal in the overworld at its data position (8, 16).
func _open_portal(persistent: bool = false) -> PortalSnapshot:
	var id := _host.sim.spawn_practice_portal("hollowmere_vault")
	var portal := _host.sim.portal_by_id(id)
	# Most lifetime tests use a normal opened entrance: moved off the packed
	# practice position, so the host's data no longer marks it persistent.
	if not persistent:
		portal.x += 1.0
		portal.persistent = false
	return portal


func _join_near_portal(portal: PortalSnapshot) -> int:
	var id := _host.add_local_player()
	_host.run_tick()
	_host.sim.place_player(id, portal.x + 0.5, portal.y)
	return id


func _press(id: int, seq: int, target: int) -> void:
	_host.submit_local_input(id, InputIntent.from_raw(seq, 0.0, 0.0, 0.0, false, true, 0, target))


func _instance_of(id: int) -> LobbyHost.HostInstance:
	return _host._find_player(id).instance


func _enter(id: int, portal: PortalSnapshot, seq: int = 1) -> void:
	_press(id, seq, portal.id)
	_host.run_tick()


# --- resolver ---------------------------------------------------------------

func test_resolver_accepts_live_usable_portal() -> void:
	_host = _new_host()
	var portal := _open_portal()
	var a := _join_near_portal(portal)
	var t: Dictionary = _host._resolve_bag(portal.id, a)
	assert_almost_eq(float(t["x"]), portal.x, 0.0001)
	assert_almost_eq(float(t["y"]), portal.y, 0.0001)


func test_resolver_rejects_unknown_placeholder_and_floor() -> void:
	_host = _new_host()
	var portal := _open_portal()
	var a := _join_near_portal(portal)
	assert_eq(_host._resolve_bag(987654, a), {}, "unknown id")
	var deco := PortalSnapshot.new()
	deco.id = _host.sim._alloc_id()
	deco.x = portal.x
	deco.y = portal.y
	deco.kind = PortalSnapshot.KIND_PLACEHOLDER
	_host.sim.add_portal(deco)
	assert_eq(_host._resolve_bag(deco.id, a), {}, "placeholder is not usable")
	var high := PortalSnapshot.new()
	high.id = _host.sim._alloc_id()
	high.x = portal.x
	high.y = portal.y
	high.kind = PortalSnapshot.KIND_ENTER
	high.dungeon_id = "hollowmere_vault"
	high.m100 = 100
	high.base_level = 10
	high.content_level = 10
	_host.sim.add_portal(high)
	assert_eq(_host._resolve_bag(high.id, a), {}, "below the join floor")


func test_out_of_range_press_does_not_transfer() -> void:
	_host = _new_host()
	var portal := _open_portal()
	var a := _host.add_local_player()
	_host.run_tick()
	_host.sim.place_player(a, portal.x + 5.0, portal.y)
	_enter(a, portal)
	_host.run_tick()
	assert_eq(_host.instances.size(), 1)
	assert_true(_instance_of(a).is_overworld())


# --- transfer ---------------------------------------------------------------

func test_enter_creates_instance_with_locked_seed_and_m() -> void:
	_host = _new_host()
	var portal := _open_portal()
	var a := _join_near_portal(portal)
	var enter_tick := _host.sim.tick()
	_enter(a, portal)
	assert_eq(_host.instances.size(), 2)
	var inst := _instance_of(a)
	assert_false(inst.is_overworld())
	assert_eq(inst.dungeon_id, "hollowmere_vault")
	assert_eq(inst.seed, _host.sim.derived_instance_seed(portal.id, enter_tick))
	assert_eq(inst.m100, portal.m100)
	assert_eq(inst.sim.instance_m100(), portal.m100)
	assert_ne(inst.sim, _host.sim, "own LocalSim")
	assert_not_null(inst.sim.get_player(_host._find_player(a).sim_id))
	assert_eq(_rejections, [])


func test_disallowed_multiplier_is_rejected_clearly() -> void:
	_host = _new_host()
	var yard := _open_portal()
	var a := _join_near_portal(yard)
	# Valid for scaling.json, but outside this lobby's 1.00-1.00 range.
	var portal := PortalSnapshot.new()
	portal.id = _host.sim._alloc_id()
	portal.x = yard.x
	portal.y = yard.y + 0.5
	portal.kind = PortalSnapshot.KIND_ENTER
	portal.dungeon_id = "hollowmere_vault"
	portal.m100 = 150
	portal.base_level = 1
	portal.content_level = 1
	_host.sim.add_portal(portal)
	assert_false(_host.is_m100_allowed(150))
	_enter(a, portal)
	_host.run_tick()
	assert_eq(_host.instances.size(), 1)
	assert_true(_instance_of(a).is_overworld())
	assert_eq(_rejections.size(), 1)
	assert_eq(_rejections[0][0], a)
	assert_eq(_rejections[0][1], PB.ErrorCode.MULTIPLIER_NOT_ALLOWED)


func test_disallowed_multiplier_rejected_at_transfer_too() -> void:
	_host = _new_host()
	var portal := _open_portal()
	var a := _join_near_portal(portal)
	var p := _host._find_player(a)
	var xfer := PortalTransfer.new()
	xfer.player_id = p.sim_id
	xfer.portal_id = portal.id
	xfer.dungeon_id = "hollowmere_vault"
	xfer.m100 = 150
	_host._route_transfer(_host.instances[0], xfer)
	assert_eq(_host.instances.size(), 1)
	assert_eq(_rejections[0][1], PB.ErrorCode.MULTIPLIER_NOT_ALLOWED)


func test_capacity_locked_at_creation_and_enforced() -> void:
	_host = _new_host(2)
	var portal := _open_portal()
	var a := _join_near_portal(portal)
	_enter(a, portal)
	var inst := _instance_of(a)
	assert_eq(inst.capacity, 2)
	var s := _host.settings()
	s.max_players = 4
	assert_eq(_host.apply_settings(s), OK)
	var b := _join_near_portal(portal)
	var c := _join_near_portal(portal)
	_enter(b, portal)
	assert_eq(_instance_of(b), inst, "same portal -> same instance")
	_enter(c, portal)
	_host.run_tick()
	assert_true(_instance_of(c).is_overworld(), "third distinct player refused")
	assert_eq(_rejections.size(), 1)
	assert_eq(_rejections[0][0], c)
	assert_eq(_rejections[0][1], PB.ErrorCode.INSTANCE_FULL)
	assert_eq(inst.capacity, 2, "later max_players changes do not change it")
	# A slot does not reopen because someone left.
	_host.remove_local_player(a)
	_host.run_tick()
	_enter(c, portal, 2)
	_host.run_tick()
	assert_true(_instance_of(c).is_overworld())


func test_carried_focus_and_cooldown_are_not_refreshed() -> void:
	_host = _new_host()
	var portal := _open_portal()
	var a := _join_near_portal(portal)
	_host.sim.set_focus(a, 12.5)
	_host.sim.set_ability_cooldown_ticks(a, 40)
	_enter(a, portal)
	var p := _host._find_player(a)
	var dsim: LocalSim = p.instance.sim
	# The overworld still holds the pre-move copy until its next step.
	assert_almost_eq(dsim.focus(p.sim_id), _host.sim.focus(a), 0.0001)
	assert_eq(dsim.ability_cooldown_ticks(p.sim_id), _host.sim.ability_cooldown_ticks(a))
	assert_lt(dsim.focus(p.sim_id), 20.0, "not refilled to full")
	assert_gt(dsim.ability_cooldown_ticks(p.sim_id), 30, "not reset to ready")
	var cd := dsim.ability_cooldown_ticks(p.sim_id)
	_host.run_tick()
	assert_eq(dsim.ability_cooldown_ticks(p.sim_id), cd - 1, "one dungeon step per host tick")


func test_other_players_stay_in_overworld() -> void:
	_host = _new_host()
	var portal := _open_portal()
	var a := _join_near_portal(portal)
	var b := _host.add_local_player()
	_host.run_tick()
	_enter(a, portal)
	_host.run_tick()
	assert_true(_instance_of(b).is_overworld())
	assert_eq(_host.sim.player_ids(), [b] as Array[int], "mover left the overworld sim")
	var inst := _instance_of(a)
	assert_eq(inst.sim.player_ids(), [_host._find_player(a).sim_id] as Array[int])
	# Views and snapshots belong to the viewer's instance.
	var va := _host.world_view(a)
	var vb := _host.world_view(b)
	assert_eq(va.player_id, a)
	assert_eq(va.players.size(), 1)
	assert_eq(vb.players.size(), 1)
	assert_eq(vb.portals.size(), 1, "overworld still shows the entrance")
	var ow = PB.ServerMessage.new()
	ow.from_bytes(_host._encode_snapshot_for([]))
	var dn = PB.ServerMessage.new()
	dn.from_bytes(_host._encode_snapshot_for([], inst))
	assert_eq(ow.get_snapshot().get_players().size(), 1)
	assert_eq(ow.get_snapshot().get_players()[0].get_id(), b)
	assert_eq(dn.get_snapshot().get_players().size(), 1)
	assert_eq(dn.get_snapshot().get_players()[0].get_id(), a)


func test_inputs_route_to_players_instance() -> void:
	_host = _new_host()
	var portal := _open_portal()
	var a := _join_near_portal(portal)
	_enter(a, portal)
	_host.run_tick()
	var p := _host._find_player(a)
	var x0: float = p.instance.sim.get_player(p.sim_id).x
	for i in range(5):
		_host.submit_local_input(a, InputIntent.from_raw(10 + i, 1.0, 0.0, 0.0, false))
		_host.run_tick()
	assert_gt(p.instance.sim.get_player(p.sim_id).x, x0)
	assert_almost_eq(p.x, p.instance.sim.get_player(p.sim_id).x, 0.0001)


# --- teardown / ids ---------------------------------------------------------

func _exit_here(id: int, seq: int) -> void:
	var p := _host._find_player(id)
	var exit := PortalSnapshot.new()
	exit.id = p.instance.sim._alloc_id()
	exit.x = p.x
	exit.y = p.y
	exit.kind = PortalSnapshot.KIND_EXIT
	exit.dungeon_id = "hollowmere_vault"
	p.instance.sim.add_portal(exit)
	_press(id, seq, exit.id)
	_host.run_tick()


func _ticks(n: int) -> void:
	for i in range(n):
		_host.run_tick()


func _overworld_bag(owner: int) -> GroundDrop:
	var item := ItemState.new()
	item.owner_player_id = owner
	item.tier = 1
	item.drop_id = "test-bag-%d" % owner
	var bag := GroundDrop.new()
	bag.id = _host.sim._alloc_id()
	bag.item = item
	bag.x = 20.0
	bag.y = 20.0
	bag.t_star = 1
	bag.spawn_tick = _host.sim.tick()
	_host.sim._ground_drops.append(bag)
	return bag


func test_exit_returns_to_overworld_and_instance_waits_while_empty() -> void:
	_host = _new_host()
	var portal := _open_portal()
	var a := _join_near_portal(portal)
	var b := _join_near_portal(portal)
	_enter(a, portal)
	_enter(b, portal)
	var inst := _instance_of(a)
	assert_eq(_instance_of(b), inst)
	_host.remove_local_player(b)
	_host.run_tick()
	_exit_here(a, 5)
	assert_true(_instance_of(a).is_overworld())
	assert_eq(_host._find_player(a).sim_id, a, "back under the lobby id")
	assert_eq(_host.instances.size(), 2, "empty instance is kept for now")
	_host.run_tick()
	assert_eq(_host.sim.player_ids(), [a] as Array[int])


# --- bags per instance ------------------------------------------------------

func test_bags_from_other_instances_are_not_shown() -> void:
	_host = _new_host()
	var portal := _open_portal()
	var a := _join_near_portal(portal)
	var bag := _overworld_bag(a)
	assert_true(_host._bags_by_owner().has(a), "own overworld bag while there")
	_enter(a, portal)
	_host.run_tick()
	var inst := _instance_of(a)
	assert_false(_host._bags_by_owner().has(a), "overworld bag not sent to a viewer in a dungeon")
	for d in _host.world_view(a).ground_drops:
		assert_ne(d.id, bag.id)
	var msg = PB.ServerMessage.new()
	msg.from_bytes(_host._encode_snapshot_for([bag], inst, a))
	assert_eq(msg.get_snapshot().get_bags().size(), 0, "snapshot drops bags of other instances")
	_exit_here(a, 5)
	_host.run_tick()
	assert_eq(_host._bags_by_owner()[a].size(), 1, "shown again back in the overworld")


# --- portal records and lifetimes -------------------------------------------

func test_reentry_returns_to_same_instance_with_progress() -> void:
	_host = _new_host()
	var portal := _open_portal()
	var a := _join_near_portal(portal)
	_enter(a, portal)
	var inst := _instance_of(a)
	var sid := _host._find_player(a).sim_id
	_host.run_tick()
	inst.sim.defeat_all_enemies()
	var alive_before := 0
	for e in inst.sim.world_view(sid).enemies:
		if e.alive:
			alive_before += 1
	var dtick := inst.sim.tick()
	_exit_here(a, 5)
	_ticks(20)
	_host.sim.place_player(a, portal.x + 0.5, portal.y)
	_enter(a, portal, 6)
	assert_eq(_instance_of(a), inst, "same instance, not a fresh one")
	assert_eq(_host.instances.size(), 2)
	assert_eq(_host._find_player(a).sim_id, sid, "same id inside the instance")
	assert_gt(inst.sim.tick(), dtick, "kept stepping while empty")
	var alive_after := 0
	for e in inst.sim.world_view(sid).enemies:
		if e.alive:
			alive_after += 1
	assert_eq(alive_after, alive_before, "defeated enemies stay defeated")


func test_capacity_holds_after_instance_empties_and_closes() -> void:
	_host = _new_host(2)
	var portal := _open_portal()
	var a := _join_near_portal(portal)
	var b := _join_near_portal(portal)
	_enter(a, portal)
	_enter(b, portal)
	_exit_here(a, 5)
	_exit_here(b, 5)
	var s := _host.settings()
	s.max_players = 4
	assert_eq(_host.apply_settings(s), OK)
	var c := _join_near_portal(portal)
	_enter(c, portal)
	_host.run_tick()
	assert_true(_instance_of(c).is_overworld())
	assert_eq(_rejections.back()[1], PB.ErrorCode.INSTANCE_FULL, "empty instance frees no slot")
	_ticks(LobbyHost.EMPTY_INSTANCE_CLOSE_TICKS)
	assert_eq(_host.instances.size(), 1)
	_host.sim.place_player(c, portal.x + 0.5, portal.y)
	_enter(c, portal, 2)
	_host.run_tick()
	assert_true(_instance_of(c).is_overworld(), "teardown frees no slot either")
	assert_eq(_host.instances.size(), 1)


func test_empty_instance_closes_after_60s_not_before() -> void:
	_host = _new_host()
	var portal := _open_portal()
	var a := _join_near_portal(portal)
	_enter(a, portal)
	_exit_here(a, 5)
	_ticks(LobbyHost.EMPTY_INSTANCE_CLOSE_TICKS - 1)
	assert_eq(_host.instances.size(), 2, "still open just before 60 s")
	_host.run_tick()
	assert_eq(_host.instances.size(), 1, "closed at 60 s empty")
	assert_eq(LobbyHost.EMPTY_INSTANCE_CLOSE_TICKS, 60 * SimConstants.TICK_HZ)


func test_closed_entrance_rejects_entry() -> void:
	_host = _new_host()
	var portal := _open_portal()
	var a := _join_near_portal(portal)
	_enter(a, portal)
	_exit_here(a, 5)
	_ticks(LobbyHost.EMPTY_INSTANCE_CLOSE_TICKS)
	_host.sim.place_player(a, portal.x + 0.5, portal.y)
	_rejections = []
	_enter(a, portal, 6)
	_host.run_tick()
	assert_true(_instance_of(a).is_overworld())
	assert_eq(_host.instances.size(), 1)
	assert_eq(_rejections.size(), 1)
	assert_eq(_rejections[0][1], PB.ErrorCode.INSTANCE_NOT_FOUND)
	assert_true(_host._resolve_bag(portal.id, a).is_empty(), "resolver refuses a closed entrance")


func test_nonpersistent_entrance_never_yields_fresh_instance() -> void:
	_host = _new_host()
	var portal := _open_portal()
	var a := _join_near_portal(portal)
	var first_index := 0
	_enter(a, portal)
	first_index = _instance_of(a).index
	_exit_here(a, 5)
	_ticks(LobbyHost.EMPTY_INSTANCE_CLOSE_TICKS)
	var c := _join_near_portal(portal)
	# Even a transfer the sim already queued cannot restart it.
	var xfer := PortalTransfer.new()
	xfer.player_id = c
	xfer.portal_id = portal.id
	xfer.dungeon_id = "hollowmere_vault"
	xfer.m100 = 100
	_host._route_transfer(_host.instances[0], xfer)
	assert_eq(_host.instances.size(), 1)
	assert_true(_instance_of(c).is_overworld())
	assert_eq(_host._next_instance_index, first_index + 1, "no new instance id was used")


func test_entrance_closes_to_new_players_after_its_lifetime() -> void:
	_host = _new_host()
	var portal := _open_portal()
	var a := _join_near_portal(portal)
	_enter(a, portal)
	var rec: LobbyHost.PortalRecord = _host._portal_records.values()[0]
	_ticks(_host._entrance_lifetime_ticks(rec))
	var c := _join_near_portal(portal)
	_rejections = []
	_enter(c, portal)
	_host.run_tick()
	assert_true(_instance_of(c).is_overworld())
	assert_eq(_rejections[0][1], PB.ErrorCode.INSTANCE_NOT_FOUND)


func test_opener_id_is_the_source_world_id() -> void:
	_host = _new_host()
	var portal := _open_portal()
	var a := _join_near_portal(portal)
	_enter(a, portal)
	var inst := _instance_of(a)
	var rec: LobbyHost.PortalRecord = _host._portal_records.values()[0]
	assert_eq(inst.sim._opener_id, a, "overworld id of the opener")
	assert_ne(inst.sim._opener_id, _host._find_player(a).sim_id)
	assert_eq(rec.opener_source_id, a)
	assert_eq(rec.opener_lobby_id, a)


func test_id_space_exhaustion_refuses_instance() -> void:
	_host = _new_host()
	var portal := _open_portal()
	var a := _join_near_portal(portal)
	assert_false(LocalSim.new(SimConfig.new()).set_id_floor(LocalSim.MAX_ENTITY_ID))
	_host._next_instance_index = LocalSim.MAX_ENTITY_ID / LobbyHost.INSTANCE_ID_BLOCK
	_enter(a, portal)
	_host.run_tick()
	assert_eq(_host.instances.size(), 1)
	assert_true(_instance_of(a).is_overworld())
	assert_eq(_rejections[0][1], PB.ErrorCode.INSTANCE_NOT_FOUND)
	assert_string_contains(_rejections[0][2], "id space")


# --- reject reasons ---------------------------------------------------------

func test_unknown_dungeon_is_instance_not_found() -> void:
	_host = _new_host()
	var portal := _open_portal()
	var a := _join_near_portal(portal)
	var xfer := PortalTransfer.new()
	xfer.player_id = a
	xfer.portal_id = portal.id
	xfer.dungeon_id = "no_such_dungeon"
	xfer.m100 = 100
	_host._route_transfer(_host.instances[0], xfer)
	assert_eq(_host.instances.size(), 1)
	assert_eq(_rejections[0][1], PB.ErrorCode.INSTANCE_NOT_FOUND)


func test_join_floor_reject_is_reported() -> void:
	_host = _new_host()
	var yard := _open_portal()
	var a := _join_near_portal(yard)
	var high := PortalSnapshot.new()
	high.id = _host.sim._alloc_id()
	high.x = yard.x
	high.y = yard.y
	high.kind = PortalSnapshot.KIND_ENTER
	high.dungeon_id = "hollowmere_vault"
	high.m100 = 100
	high.base_level = 10
	high.content_level = 10
	_host.sim.add_portal(high)
	_enter(a, high)
	_host.run_tick()
	assert_true(_instance_of(a).is_overworld())
	assert_eq(_rejections.size(), 1)
	assert_eq(_rejections[0][0], a)
	assert_string_contains(_rejections[0][2], "join floor")


func test_remote_player_gets_error_message_on_reject() -> void:
	_host = _new_host()
	assert_eq(_host.start(), OK)
	var ws := WebSocketPeer.new()
	assert_eq(ws.connect_to_url("ws://127.0.0.1:%d/ws" % _host.port), OK)
	var pump := func(pred: Callable) -> bool:
		for i in range(500):
			_host.run_tick()
			ws.poll()
			if pred.call():
				return true
			OS.delay_msec(10)
		return false
	assert_true(pump.call(func() -> bool: return ws.get_ready_state() == WebSocketPeer.STATE_OPEN))
	var hello = PB.ClientMessage.new()
	hello.new_hello().set_protocol_version(SimConstants.PROTOCOL_VERSION)
	ws.send(hello.to_bytes())
	assert_true(pump.call(func() -> bool: return _host.players.size() == 1 and _host.players[0].in_sim))
	var p: LobbyHost.HostPlayer = _host.players[0]
	var portal := PortalSnapshot.new()
	portal.id = _host.sim._alloc_id()
	portal.x = p.x
	portal.y = p.y
	portal.kind = PortalSnapshot.KIND_ENTER
	portal.dungeon_id = "hollowmere_vault"
	portal.m100 = 150
	portal.base_level = 1
	portal.content_level = 1
	_host.sim.add_portal(portal)
	assert_true(_host._resolve_bag(portal.id, p.id).is_empty())
	var code := [-1]
	assert_true(pump.call(func() -> bool:
		while ws.get_available_packet_count() > 0:
			var m = PB.ServerMessage.new()
			if m.from_bytes(ws.get_packet()) == PB.PB_ERR.NO_ERRORS and m.has_error():
				code[0] = m.get_error().get_code()
		return code[0] != -1), "remote gets an Error")
	assert_eq(code[0], PB.ErrorCode.MULTIPLIER_NOT_ALLOWED)
	ws.close()


func test_ids_unique_across_instances() -> void:
	_host = _new_host()
	var portal := _open_portal()
	var a := _join_near_portal(portal)
	_enter(a, portal)
	for i in range(3):
		_host.run_tick()
	var inst := _instance_of(a)
	var dungeon_ids := {}
	var v: WorldSnapshot = inst.sim.world_view(_host._find_player(a).sim_id)
	for e in v.enemies:
		dungeon_ids[e.id] = true
	for pl in v.players:
		dungeon_ids[pl.id] = true
	for pt in v.portals:
		dungeon_ids[pt.id] = true
	assert_gt(dungeon_ids.size(), 0)
	for id in dungeon_ids:
		assert_true(int(id) >= LobbyHost.INSTANCE_ID_BLOCK, "dungeon ids sit in its own block")
	# Overworld ids keep counting below that block.
	var b := _host.add_local_player()
	assert_lt(b, LobbyHost.INSTANCE_ID_BLOCK)
	assert_false(dungeon_ids.has(b))
	assert_eq(_host.sim.alloc_player_id() < LobbyHost.INSTANCE_ID_BLOCK, true)


func test_loadtest_spread_over_instances() -> void:
	_host = _new_host(8)
	_host.loadtest_instances = 3
	_host._create_loadtest_instance(0)
	_host._create_loadtest_instance(1)
	var ids: Array[int] = []
	for i in range(6):
		var p := _host._add_player()
		ids.append(p.id)
	_host.run_tick()
	_host.run_tick()
	var per := {}
	for id in ids:
		var inst := _instance_of(id)
		per[inst.index] = int(per.get(inst.index, 0)) + 1
	assert_eq(per.size(), 3)
	for k in per:
		assert_eq(per[k], 2)


# --- persistent practice entrance -------------------------------------------

func test_practice_portal_has_persistent_data_flag() -> void:
	_host = _new_host()
	var id := _host.sim.spawn_practice_portal("hollowmere_vault")
	assert_true(_host.sim.portal_by_id(id).persistent)
	assert_false(PortalSnapshot.new().persistent, "ordinary entrances default to non-persistent")


func test_persistent_door_admits_new_player_after_lifetime() -> void:
	_host = _new_host()
	var portal := _open_portal(true)
	var a := _join_near_portal(portal)
	_enter(a, portal)
	var inst := _instance_of(a)
	_ticks(LobbyHost.ENTRANCE_LIFETIME_TICKS + 1)
	var b := _join_near_portal(portal)
	_enter(b, portal)
	assert_eq(_instance_of(b), inst, "new admission after normal expiry")
	assert_eq(_rejections.size(), 0)


func test_persistent_instance_survives_empty_and_keeps_state_on_reentry() -> void:
	_host = _new_host()
	_set_practice_flag("reset_when_empty", false)
	var portal := _open_portal(true)
	var a := _join_near_portal(portal)
	_enter(a, portal)
	var inst := _instance_of(a)
	_host.run_tick()
	inst.sim.defeat_all_enemies()
	var sid := _host._find_player(a).sim_id
	var enemies_before := inst.sim.world_view(sid).enemies.size()
	var rec: LobbyHost.PortalRecord = _host._portal_records.values()[0]
	rec.cleared = true
	_exit_here(a, 5)
	_ticks(LobbyHost.EMPTY_INSTANCE_CLOSE_TICKS + 10)
	assert_eq(_host.instances.size(), 2, "persistent instance kept while empty")
	assert_false(rec.closed)
	assert_true(rec.cleared)
	_host.sim.place_player(a, portal.x + 0.5, portal.y)
	_enter(a, portal, 6)
	assert_eq(_instance_of(a), inst)
	assert_eq(_host._find_player(a).sim_id, sid)
	assert_true(rec.cleared, "record and live sim progress retained")
	assert_eq(inst.sim.world_view(sid).enemies.size(), enemies_before)
	for e in inst.sim.world_view(sid).enemies:
		assert_false(e.alive, "defeated enemy is not recreated")
	assert_eq(_host._next_instance_index, inst.index + 1)


func test_persistent_capacity_counts_occupants_and_keeps_reentry_ids() -> void:
	_host = _new_host(2)
	_set_practice_flag("reset_when_empty", false)
	var portal := _open_portal(true)
	var a := _join_near_portal(portal)
	var b := _join_near_portal(portal)
	_enter(a, portal)
	var inst := _instance_of(a)
	var aid := _host._find_player(a).sim_id
	_enter(b, portal)
	var s := _host.settings()
	s.max_players = 4
	assert_eq(_host.apply_settings(s), OK)
	var c := _join_near_portal(portal)
	_enter(c, portal)
	assert_true(_instance_of(c).is_overworld())
	assert_eq(_rejections.back()[1], PB.ErrorCode.INSTANCE_FULL)
	_exit_here(a, 5)
	_enter(c, portal, 2)
	assert_eq(_instance_of(c), inst, "leaving frees a persistent-door slot")
	# Previously admitted players also need an occupant slot.
	_host.sim.place_player(a, portal.x + 0.5, portal.y)
	_enter(a, portal, 6)
	assert_true(_instance_of(a).is_overworld())
	assert_eq(_rejections.back()[1], PB.ErrorCode.INSTANCE_FULL)
	_exit_here(b, 5)
	_enter(a, portal, 7)
	assert_eq(_instance_of(a), inst)
	assert_eq(_host._find_player(a).sim_id, aid, "re-entry id kept")
	var rec: LobbyHost.PortalRecord = _host._portal_records.values()[0]
	assert_eq(rec.admitted.size(), 3, "history kept beyond occupant capacity")


# --- persistent entrance: state, lifetime, data source ----------------------

## Walks `id` through every vault room (activating their spawns), then
## defeats everything and lets the sim cull it.
func _clear_vault(id: int) -> int:
	var p := _host._find_player(id)
	var dsim: LocalSim = p.instance.sim
	for at in [Vector2(23.0, 6.0), Vector2(40.0, 6.0)]:
		dsim.place_player(p.sim_id, at.x, at.y)
		_host.run_tick()
	var spawned := dsim.enemy_count()
	dsim.defeat_all_enemies()
	_ticks(3)
	return spawned


func _enter_persistent(id: int, portal: PortalSnapshot, seq: int) -> void:
	_host.sim.place_player(id, portal.x + 0.5, portal.y)
	_enter(id, portal, seq)


func test_persistent_never_respawns_after_clear_exit_and_long_empty() -> void:
	_host = _new_host()
	_set_practice_flag("reset_when_empty", false)
	var portal := _open_portal(true)
	var a := _join_near_portal(portal)
	_enter(a, portal)
	var inst := _instance_of(a)
	assert_gt(_clear_vault(a), 0, "rooms spawned their enemies once")
	assert_eq(inst.sim.enemy_count(), 0)
	var drops := inst.sim.ground_drops().size()
	var seq := 10
	for cycle in range(3):
		_exit_here(a, seq)
		seq += 1
		_ticks(LobbyHost.EMPTY_INSTANCE_CLOSE_TICKS * 2)
		_enter_persistent(a, portal, seq)
		seq += 1
		assert_eq(_instance_of(a), inst, "same instance after a long empty spell")
		assert_eq(_clear_vault(a), 0, "walking the rooms again spawns nothing")
		assert_eq(inst.sim.enemy_count(), 0, "no enemies respawn")
		assert_eq(inst.sim.ground_drops().size(), drops, "no new drops")


func test_persistent_late_arrivals_get_nothing_after_clear() -> void:
	_host = _new_host()
	_set_practice_flag("reset_when_empty", false)
	var portal := _open_portal(true)
	var a := _join_near_portal(portal)
	_enter(a, portal)
	var inst := _instance_of(a)
	_clear_vault(a)
	var drops := inst.sim.ground_drops().size()
	# A fresh local player and a remote-style join (new id each time).
	var b := _join_near_portal(portal)
	var r := _host._add_player()
	_host.run_tick()
	_host.sim.place_player(r.id, portal.x + 0.5, portal.y)
	for id in [b, r.id]:
		var xp_before: int = _host.sim.get_player(id).xp_tenths
		if id == r.id:
			_host._queue_input(r, 3, 0.0, 0.0, 0.0, false, portal.id)  # as a remote frame
			_host.run_tick()
		else:
			_enter(id, portal, 3)
		assert_eq(_instance_of(id), inst)
		_clear_vault(id)
		var pp := _host._find_player(id)
		assert_eq(inst.sim.get_player(pp.sim_id).xp_tenths, xp_before, "no XP from a cleared instance")
		for bag in inst.sim.ground_drops():
			assert_ne(bag.item.owner_player_id, pp.sim_id, "no rewards for a late arrival")
	assert_eq(inst.sim.ground_drops().size(), drops)
	assert_eq(inst.sim.enemy_count(), 0)


func test_persistent_is_not_rebuilt_by_settings_and_reopens_after_restart() -> void:
	_host = _new_host()
	_set_practice_flag("reset_when_empty", false)
	var portal := _open_portal(true)
	var a := _join_near_portal(portal)
	_enter(a, portal)
	var inst := _instance_of(a)
	var rec: LobbyHost.PortalRecord = _host._portal_records.values()[0]
	_exit_here(a, 5)
	for mp in [3, 7, 2]:
		var s := _host.settings()
		s.max_players = mp
		s.m100_min = 90
		s.m100_max = 110
		assert_eq(_host.apply_settings(s), OK)
		_ticks(5)
	assert_same(_host._portal_records.values()[0], rec)
	assert_same(rec.instance, inst)
	assert_eq(_host.instances.size(), 2)
	_enter_persistent(a, portal, 6)
	assert_same(_instance_of(a), inst)
	_host.stop()
	assert_eq(_host._portal_records.size(), 0, "record freed on stop")
	assert_eq(_host.instances.size(), 1, "instance freed on stop")
	# Restarting the same host reopens the door as a fresh record.
	assert_eq(_host.start(), OK)
	var portal2 := _open_portal(true)
	var b := _join_near_portal(portal2)
	_enter(b, portal2)
	var inst2 := _instance_of(b)
	assert_false(inst2.is_overworld(), "door open after restart")
	var rec2: LobbyHost.PortalRecord = _host._portal_records.values()[0]
	assert_ne(rec2, rec, "fresh record")
	assert_false(rec2.closed)
	assert_eq(_host.instances.size(), 2)


func test_persistent_flag_comes_only_from_host_data() -> void:
	_host = _new_host()
	var practice := _open_portal(true)
	practice.persistent = false  # display copy; the host ignores it
	var fake := PortalSnapshot.new()
	fake.id = _host.sim._alloc_id()
	fake.x = 30.0
	fake.y = 30.0
	fake.kind = PortalSnapshot.KIND_ENTER
	fake.dungeon_id = "hollowmere_vault"
	fake.m100 = 100
	fake.base_level = 1
	fake.content_level = 1
	fake.persistent = true  # not the packed practice entrance
	_host.sim.add_portal(fake)
	_host.run_tick()
	var by_portal := {}
	for rec: LobbyHost.PortalRecord in _host._portal_records.values():
		by_portal[rec.portal_id] = rec.persistent
	assert_true(by_portal[practice.id], "packed practice entrance is persistent")
	assert_false(by_portal[fake.id], "a flag on any other portal is ignored")
	assert_false("persistent" in PortalTransfer.new(), "transfers cannot carry it")
	# The fake one keeps normal lifetimes: it expires for new players.
	_ticks(LobbyHost.ENTRANCE_LIFETIME_TICKS)
	var c := _host.add_local_player()
	_host.run_tick()
	_host.sim.place_player(c, fake.x + 0.5, fake.y)
	_rejections = []
	_enter(c, fake)
	_host.run_tick()
	assert_true(_instance_of(c).is_overworld())
	assert_eq(_rejections[0][1], PB.ErrorCode.INSTANCE_NOT_FOUND)


func test_nonpersistent_portal_still_expires() -> void:
	_host = _new_host()
	var portal := _open_portal()
	var a := _join_near_portal(portal)
	_ticks(LobbyHost.ENTRANCE_LIFETIME_TICKS)
	_enter(a, portal)
	_host.run_tick()
	assert_true(_instance_of(a).is_overworld())
	assert_eq(_rejections[0][1], PB.ErrorCode.INSTANCE_NOT_FOUND)


func test_persistent_long_session_stays_bounded() -> void:
	_host = _new_host(8)
	_set_practice_flag("reset_when_empty", false)
	var portal := _open_portal(true)
	var a := _join_near_portal(portal)
	_enter(a, portal)
	var inst := _instance_of(a)
	_clear_vault(a)
	var rec: LobbyHost.PortalRecord = _host._portal_records.values()[0]
	var drops := inst.sim.ground_drops().size()
	var seq := 20
	for cycle in range(150):
		# The regular rotates out and back in; a newcomer joins, enters,
		# fires a bit and leaves the lobby.
		_exit_here(a, seq)
		seq += 1
		var n := _join_near_portal(portal)
		_enter(n, portal, 1)
		for k in range(4):
			_host.submit_local_input(n, InputIntent.from_raw(2 + k, 1.0, 0.0, 0.0, true))
			_host.run_tick()
		_host.remove_local_player(n)
		_ticks(10)
		_enter_persistent(a, portal, seq)
		seq += 1
	_ticks(100)
	assert_same(_instance_of(a), inst)
	assert_eq(_host.instances.size(), 2)
	assert_eq(_host._portal_records.size(), 1)
	assert_eq(inst.sim.enemy_count(), 0)
	assert_eq(inst.sim.ground_drops().size(), drops)
	assert_lt(inst.sim.projectiles().size(), 50, "projectiles expire")
	assert_lte(rec.admitted.size(), _host.players.size(), "admitted only holds lobby players")
	assert_lte(rec.sim_ids.size(), _host.players.size())
	# The allocator is a high-water mark; there is no per-id-ever set.
	var names := {}
	for item in inst.sim.get_property_list():
		names[String(item.name)] = true
	assert_false(names.has("_skipped_ids"))
	assert_false(names.has("_player_id_set"), "no per-id-ever set")
	assert_lte(inst.sim._ability_by_player.size(), inst.sim.player_count())
	assert_lte(inst.sim.player_ids().size(), 1)


# --- practice vault: no lasting rewards, reset when empty --------------------

func _grant_inside(id: int) -> ItemState:
	var p := _host._find_player(id)
	var sp := p.instance.sim.get_player(p.sim_id)
	sp.xp_tenths += 70
	sp.pending_glint += 3
	var item := ItemState.new()
	item.owner_player_id = p.sim_id
	item.tier = 2
	item.drop_id = "practice-test-item"
	assert_true(sp.inventory.add(item))
	return item


func _progress(id: int) -> Dictionary:
	var sp := _host.sim.get_player(id)
	return {"level": sp.level, "xp": sp.xp_tenths, "glint": sp.pending_glint,
			"items": sp.inventory.live_items().size(), "riftstone": sp.pending_riftstone}


func test_practice_vault_rewards_are_reverted_on_exit() -> void:
	_host = _new_host()
	var portal := _open_portal(true)
	var a := _join_near_portal(portal)
	var before := _progress(a)
	_enter(a, portal)
	assert_false(_instance_of(a).grants_persistent)
	_grant_inside(a)
	_exit_here(a, 5)
	assert_true(_instance_of(a).is_overworld())
	assert_eq(_progress(a), before, "XP, currency and items gained inside are reverted")
	_ticks(2)
	assert_eq(_progress(a), before)
	assert_false(_host._bags_by_owner().has(a), "no practice bags outside")


func test_practice_vault_reverts_after_reset_cycles() -> void:
	_host = _new_host()
	var portal := _open_portal(true)
	var a := _join_near_portal(portal)
	var before := _progress(a)
	var seq := 5
	var sims := {}
	var index := -1
	for cycle in range(3):
		_enter_persistent(a, portal, seq)
		seq += 1
		var inst := _instance_of(a)
		if index < 0:
			index = inst.index
		assert_eq(inst.index, index, "one practice instance id")
		sims[inst.sim] = true
		assert_gt(_clear_vault(a), 0, "reset rebuilt the rooms")
		_grant_inside(a)
		_exit_here(a, seq)
		seq += 1
		assert_eq(_progress(a), before)
	assert_eq(sims.size(), 3, "rebuilt on each entry after it emptied")
	assert_eq(_host.instances.size(), 2)


func test_practice_vault_leave_and_rejoin_reverts() -> void:
	_host = _new_host()
	var portal := _open_portal(true)
	var a := _join_near_portal(portal)
	var before := _progress(a)
	_enter(a, portal)
	_grant_inside(a)
	var token := _host.remove_local_player(a)
	_host.run_tick()
	assert_eq(_host.instances.size(), 2, "the practice instance stays")
	var b := _host.add_local_player(null, token)
	assert_eq(b, a)
	_host.run_tick()
	assert_eq(_progress(b), before, "a rejoin does not keep practice gains")


func test_practice_vault_offers_no_onward_portals() -> void:
	_host = _new_host()
	var portal := _open_portal(true)
	var a := _join_near_portal(portal)
	_enter(a, portal)
	var p := _host._find_player(a)
	var xfer := PortalTransfer.new()
	xfer.player_id = p.sim_id
	xfer.portal_id = portal.id
	xfer.dungeon_id = "hollowmere_vault"
	xfer.m100 = 100
	_host._route_transfer(p.instance, xfer)
	assert_eq(_instance_of(a), p.instance)
	assert_eq(_host.instances.size(), 2)
	assert_eq(_rejections.back()[1], PB.ErrorCode.INSTANCE_NOT_FOUND)


func test_normal_portal_keeps_rewards() -> void:
	_host = _new_host()
	var portal := _open_portal()
	var a := _join_near_portal(portal)
	var before := _progress(a)
	_enter(a, portal)
	assert_true(_instance_of(a).grants_persistent)
	_grant_inside(a)
	_exit_here(a, 5)
	var after := _progress(a)
	assert_true(after["level"] > before["level"] or after["xp"] == before["xp"] + 70, "XP kept")
	assert_eq(after["glint"], before["glint"] + 3)
	assert_eq(after["items"], before["items"] + 1)


func test_reward_and_reset_flags_come_only_from_host_data() -> void:
	_host = _new_host()
	var practice := _open_portal(true)
	var fake := PortalSnapshot.new()
	fake.id = _host.sim._alloc_id()
	fake.x = 30.0
	fake.y = 30.0
	fake.kind = PortalSnapshot.KIND_ENTER
	fake.dungeon_id = "hollowmere_vault"
	fake.m100 = 100
	fake.base_level = 1
	fake.content_level = 1
	fake.persistent = true
	fake.grants_persistent = false  # packed claim is ignored; host data decides
	_host.sim.add_portal(fake)
	_host.run_tick()
	var recs := {}
	for rec: LobbyHost.PortalRecord in _host._portal_records.values():
		recs[rec.portal_id] = rec
	assert_false(recs[practice.id].grants_persistent)
	assert_true(recs[practice.id].reset_when_empty)
	assert_true(recs[fake.id].grants_persistent, "real dungeon data grants")
	assert_false(recs[fake.id].reset_when_empty)
	assert_false("persistent" in PortalTransfer.new())
	assert_false("reset_when_empty" in PortalTransfer.new())
	# Reset is never enabled unless host data says the instance grants nothing.
	_host.stop()
	_host = _new_host()
	_set_practice_flag("grants_persistent", true)
	var p2 := _open_portal(true)
	_host.run_tick()
	var rec2: LobbyHost.PortalRecord = _host._portal_records.values()[0]
	assert_eq(rec2.portal_id, p2.id)
	assert_false(rec2.reset_when_empty)


# --- content §2.5 practice vault contract -------------------------------------

func _exit_portals(sim: LocalSim) -> int:
	var n := 0
	for pt in sim.portals():
		if pt.kind == PortalSnapshot.KIND_EXIT:
			n += 1
	return n


func _placeholders(sim: LocalSim) -> int:
	var n := 0
	for pt in sim.portals():
		if pt.kind == PortalSnapshot.KIND_PLACEHOLDER:
			n += 1
	return n


## 1. One entrance and one instance id; no expiry, no empty close.
func test_practice_one_instance_id_for_host_lifetime() -> void:
	_host = _new_host()
	var portal := _open_portal(true)
	var a := _join_near_portal(portal)
	_enter(a, portal)
	var index := _instance_of(a).index
	var next := _host._next_instance_index
	_exit_here(a, 5)
	_ticks(LobbyHost.ENTRANCE_LIFETIME_TICKS + LobbyHost.EMPTY_INSTANCE_CLOSE_TICKS)
	assert_eq(_host.instances.size(), 2, "never closed for being empty")
	var b := _join_near_portal(portal)
	_enter(b, portal)
	assert_eq(_instance_of(b).index, index, "same instance id after the lifetime")
	assert_eq(_host._next_instance_index, next, "no second instance")
	assert_eq(_host._portal_records.size(), 1)
	assert_eq(_rejections.size(), 0)


## 2. Next entry after it empties rebuilds trash, boss and exit.
func _bosses_alive(sim: LocalSim) -> int:
	var n := 0
	for e in sim._enemies:
		if e.is_boss() and e.hp > 0:
			n += 1
	return n


func test_practice_reset_rebuilds_trash_boss_and_exit() -> void:
	_host = _new_host()
	var portal := _open_portal(true)
	var a := _join_near_portal(portal)
	_enter(a, portal)
	var inst := _instance_of(a)
	assert_false(inst.sim.boss_defeated())
	var p := _host._find_player(a)
	inst.sim.place_player(p.sim_id, 40.0, 6.0)
	_ticks(2)
	assert_eq(_bosses_alive(inst.sim), 1, "Warden is up")
	assert_gt(_clear_vault(a), 0)
	_ticks(3)
	assert_true(inst.sim.boss_defeated(), "Warden down")
	assert_eq(_exit_portals(inst.sim), 1, "cleared: exit open")
	var rec: LobbyHost.PortalRecord = _host._portal_records.values()[0]
	rec.cleared = true
	var old_sim := inst.sim
	_exit_here(a, 5)
	_enter_persistent(a, portal, 6)
	assert_same(_instance_of(a), inst)
	assert_ne(inst.sim, old_sim, "slice rebuilt")
	assert_false(inst.sim.boss_defeated(), "Warden state reset")
	assert_eq(_exit_portals(inst.sim), 0, "exit closed again")
	assert_false(rec.cleared, "cleared flag reset")
	p = _host._find_player(a)
	inst.sim.place_player(p.sim_id, 40.0, 6.0)
	_ticks(2)
	assert_eq(_bosses_alive(inst.sim), 1, "Warden back")
	assert_gt(_clear_vault(a), 0, "trash back")
	assert_gt(p.sim_id, old_sim.alloc_player_id() - 2, "ids keep counting up in the block")
	assert_lt(p.sim_id, (inst.index + 1) * LobbyHost.INSTANCE_ID_BLOCK)


## 3. Nothing gained inside survives, and every carried progression field
## (including currencies added to PlayerCarry later) is covered.
func test_practice_grants_nothing_for_every_carry_field() -> void:
	_host = _new_host()
	var portal := _open_portal(true)
	var a := _join_near_portal(portal)
	var before := _progress(a)
	_enter(a, portal)
	_grant_inside(a)
	var fields := _host._progression_fields(PlayerCarry.new())
	for prop in PlayerCarry.new().get_property_list():
		if prop["usage"] & PROPERTY_USAGE_SCRIPT_VARIABLE == 0:
			continue
		var key: String = prop["name"]
		if key in ["player_id", "hp", "aim", "ability", "last_interact_seq"]:
			continue
		assert_true(fields.has(key), "%s is restored on the way out" % key)
	_exit_here(a, 5)
	assert_eq(_progress(a), before)
	assert_false(_host._bags_by_owner().has(a))


## 4. What was brought in passes through unchanged; join snapshots stay.
func test_practice_carry_in_passes_through() -> void:
	_host = _new_host()
	var portal := _open_portal(true)
	var a := _join_near_portal(portal)
	var keep := _host.add_local_player()
	var token := _host.remove_local_player(keep)
	_host.run_tick()
	var stash := _host.ability_stash_size()
	var sp := _host.sim.get_player(a)
	sp.xp_tenths += 40
	sp.pending_glint += 5
	var item := ItemState.new()
	item.owner_player_id = a
	item.drop_id = "outside-item"
	sp.inventory.add(item)
	sp.hp = maxi(1, sp.hp - 3)
	_host.sim.set_focus(a, 22.0)
	_host.sim.set_ability_cooldown_ticks(a, 60)
	var before := _progress(a)
	var hp := sp.hp
	_enter(a, portal)
	var p := _host._find_player(a)
	var d := p.instance.sim
	assert_eq(d.get_player(p.sim_id).xp_tenths, before["xp"])
	assert_eq(d.get_player(p.sim_id).pending_glint, before["glint"])
	assert_eq(d.get_player(p.sim_id).inventory.live_items().size(), before["items"])
	assert_eq(d.get_player(p.sim_id).hp, hp, "HP not refilled")
	assert_lt(d.focus(p.sim_id), 23.0, "Focus not refilled")
	assert_gt(d.ability_cooldown_ticks(p.sim_id), 50, "cooldown not reset")
	_exit_here(a, 5)
	assert_eq(_progress(a), before, "outside gains kept exactly")
	assert_eq(_host.ability_stash_size(), stash, "join snapshots untouched")
	assert_ne(token, "")


## 5. Capacity counts current occupants; no rule 8 lifetime applies.
func test_practice_capacity_counts_occupants() -> void:
	_host = _new_host(2)
	var portal := _open_portal(true)
	var a := _join_near_portal(portal)
	var b := _join_near_portal(portal)
	_enter(a, portal)
	_enter(b, portal)
	var inst := _instance_of(a)
	var s := _host.settings()
	s.max_players = 4
	assert_eq(_host.apply_settings(s), OK)
	var c := _join_near_portal(portal)
	_enter(c, portal)
	assert_eq(_rejections.back()[1], PB.ErrorCode.INSTANCE_FULL)
	_exit_here(a, 5)
	_ticks(LobbyHost.ENTRANCE_LIFETIME_TICKS)
	_enter(c, portal, 2)
	assert_same(_instance_of(c), inst, "slot freed; no entrance lifetime")


## 6 (and §6.1 rules 6 / 6a): nothing is rebuilt under a living or
## lingering player; an instance with only dead players is rebuilt.
func test_practice_no_reset_under_living_or_lingering_player() -> void:
	_host = _new_host()
	var portal := _open_portal(true)
	var a := _join_near_portal(portal)
	var b := _join_near_portal(portal)
	var c := _join_near_portal(portal)
	_enter(a, portal)
	var inst := _instance_of(a)
	var sim0 := inst.sim
	_enter(b, portal)
	assert_same(inst.sim, sim0, "a living player inside: no rebuild")
	_exit_here(b, 5)
	_host.remove_local_player(a)  # leaves from inside: lingers
	_host.run_tick()
	_enter(c, portal)
	assert_same(inst.sim, sim0, "no rebuild during the linger")
	_exit_here(c, 5)
	_ticks(LobbyHost.LINGER_TICKS)
	_host.sim.place_player(b, portal.x + 0.5, portal.y)
	_enter(b, portal, 6)
	assert_ne(inst.sim, sim0, "rebuilt once nobody living or lingering is inside")
	# A player who dies inside leaves (with the restore); the next entry
	# then rebuilds, since nobody living is inside.
	var sim1 := inst.sim
	var pb := _host._find_player(b)
	inst.sim.get_player(pb.sim_id).hp = 0
	_host.run_tick()
	assert_true(_instance_of(b).is_overworld())
	_host.sim.place_player(c, portal.x + 0.5, portal.y)
	_enter(c, portal, 6)
	assert_ne(inst.sim, sim1)


# --- practice instances: items never leave their owner -----------------------

func _owned_item(id: int, did: String) -> ItemState:
	var item := ItemState.new()
	item.owner_player_id = id
	item.tier = 1
	item.drop_id = did
	assert_true(_host.sim.get_player(id).inventory.add(item))
	return item


func _sp(id: int) -> SimPlayerState:
	var p := _host._find_player(id)
	return p.instance.sim.get_player(p.sim_id)


func _ids_of(id: int) -> Array:
	var out := []
	for it in _sp(id).inventory.live_items():
		out.append(it.drop_id)
	return out


## Every drop_id held by any player or lying anywhere, across instances.
func _all_item_ids() -> Array:
	var out := []
	for inst in _host.instances:
		for pid in inst.sim.player_ids():
			for it in inst.sim.get_player(pid).inventory.live_items():
				out.append(it.drop_id)
		for bag in inst.sim.ground_drops():
			out.append(bag.item.drop_id)
	return out


func _assert_unique(ids: Array) -> void:
	var seen := {}
	for d in ids:
		assert_false(seen.has(d), "item %s exists once" % d)
		seen[d] = true


func _two_in_practice() -> Array:
	var portal := _open_portal(true)
	var a := _join_near_portal(portal)
	var b := _join_near_portal(portal)
	_owned_item(a, "a-sword")
	_owned_item(b, "b-sword")
	_enter(a, portal)
	_enter(b, portal, 1)
	return [portal, a, b]


func test_practice_drop_is_refused() -> void:
	_host = _new_host()
	var t := _two_in_practice()
	var a: int = t[1]
	var inst := _instance_of(a)
	# Something moves A's item to the ground (any sim path): undone at once.
	var inv := _sp(a).inventory
	var idx := inv.slots.find(inv.live_items()[0])
	var item: ItemState = inv.take_slot(idx)
	var bag := GroundDrop.new()
	bag.id = inst.sim._alloc_id()
	bag.item = item
	bag.x = _sp(a).x
	bag.y = _sp(a).y
	inst.sim._ground_drops.append(bag)
	_host.run_tick()
	assert_true(_ids_of(a).has("a-sword"), "item stays with its owner")
	assert_eq(inst.sim.ground_drops().size(), 0, "no pile left behind")
	_assert_unique(_all_item_ids())


func test_practice_give_is_refused() -> void:
	_host = _new_host()
	var t := _two_in_practice()
	var a: int = t[1]
	var b: int = t[2]
	var inv := _sp(a).inventory
	var item: ItemState = inv.take_slot(inv.slots.find(inv.live_items()[0]))
	_sp(b).inventory.add(item)
	_host.run_tick()
	assert_true(_ids_of(a).has("a-sword"))
	assert_false(_ids_of(b).has("a-sword"), "hand-off undone")
	_assert_unique(_all_item_ids())


func test_practice_pickup_of_others_item_is_refused() -> void:
	_host = _new_host()
	var t := _two_in_practice()
	var a: int = t[1]
	var b: int = t[2]
	var inst := _instance_of(a)
	# The host refuses the press, and the sim refuses the pickup itself.
	var bag := GroundDrop.new()
	bag.id = inst.sim._alloc_id()
	var foreign := ItemState.new()
	foreign.owner_player_id = _host._find_player(b).sim_id
	foreign.drop_id = "foreign"
	bag.item = foreign
	bag.x = _sp(b).x
	bag.y = _sp(b).y
	inst.sim._ground_drops.append(bag)
	assert_true(_host._resolve_bag(bag.id, b).is_empty(), "host refuses the press")
	assert_false(inst.sim.item_transfers_allowed())
	_host.run_tick()
	assert_false(_ids_of(b).has("foreign"))
	assert_false(_ids_of(a).has("foreign"))


func test_practice_shared_container_deposit_is_refused() -> void:
	_host = _new_host()
	var t := _two_in_practice()
	var a: int = t[1]
	var b: int = t[2]
	# Any interact target other than the exit (containers, players, bags)
	# is refused in a practice instance.
	assert_true(_host._resolve_bag(_host._find_player(b).sim_id, a).is_empty())
	assert_true(_host._resolve_bag(123456789, a).is_empty())
	_exit_here(a, 5)  # the exit itself still works
	assert_true(_instance_of(a).is_overworld())
	assert_true(_ids_of(a).has("a-sword"))


func test_practice_spawns_no_loot_bags() -> void:
	_host = _new_host()
	var portal := _open_portal(true)
	var a := _join_near_portal(portal)
	_enter(a, portal)
	var inst := _instance_of(a)
	var e := EnemyState.new()
	e.id = inst.sim._alloc_id()
	e.x = 1.0
	e.y = 1.0
	e.content_level = 1
	for i in range(20):
		assert_null(inst.sim._try_grant_roll(e, _host._find_player(a).sim_id, i, "thornguard", inst.sim.tick()))
	assert_eq(inst.sim.ground_drops().size(), 0, "no bags spawn at all")
	# A normal instance still drops bags.
	var normal := LocalSim.new(SimConfig.new(), 16.0, 16.0, _host.catalog)
	var made := 0
	for i in range(50):
		if normal._try_grant_roll(e, 1, i, "thornguard", 0) != null:
			made += 1
	assert_eq(normal.ground_drops().size(), made)


func test_practice_no_duplicate_after_any_exit_path() -> void:
	_host = _new_host()
	var t := _two_in_practice()
	var portal: PortalSnapshot = t[0]
	var a: int = t[1]
	var b: int = t[2]
	# Exit portal.
	var inv := _sp(a).inventory
	_sp(b).inventory.add(inv.take_slot(inv.slots.find(inv.live_items()[0])))
	_exit_here(a, 5)
	_assert_unique(_all_item_ids())
	_host.run_tick()
	_assert_unique(_all_item_ids())
	# Death.
	_enter_persistent(a, portal, 6)
	inv = _sp(a).inventory
	_sp(b).inventory.add(inv.take_slot(inv.slots.find(inv.live_items()[0])))
	_sp(a).hp = 0
	_host.run_tick()
	assert_true(_instance_of(a).is_overworld())
	_assert_unique(_all_item_ids())
	# Disconnect from inside.
	_host.run_tick()
	var inv_b := _sp(b).inventory
	_host.sim.place_player(a, portal.x + 0.5, portal.y)
	var token := _host.remove_local_player(b)
	_host.run_tick()
	_assert_unique(_all_item_ids())
	assert_eq(inv_b.live_items().size() >= 0, true)
	assert_ne(token, "")


func test_practice_death_restores() -> void:
	_host = _new_host()
	var portal := _open_portal(true)
	var a := _join_near_portal(portal)
	_owned_item(a, "a-ring")
	var before := _progress(a)
	_enter(a, portal)
	_grant_inside(a)
	_sp(a).hp = 0
	_host.run_tick()
	assert_true(_instance_of(a).is_overworld(), "death leaves the practice instance")
	assert_eq(_progress(a), before)
	assert_gt(_host.sim.get_player(a).hp, 0)
	assert_true(_ids_of(a).has("a-ring"))


func test_practice_reconnect_restores() -> void:
	_host = _new_host()
	var portal := _open_portal(true)
	var a := _join_near_portal(portal)
	_owned_item(a, "a-ring")
	var before := _progress(a)
	_enter(a, portal)
	_grant_inside(a)
	var token := _host.remove_local_player(a)
	_ticks(LobbyHost.LINGER_TICKS + 1)
	var back := _host.add_local_player(null, token)
	_host.run_tick()
	assert_eq(back, a)
	assert_eq(_progress(a), before, "reconnect after the linger restores")
	assert_true(_ids_of(a).has("a-ring"))
	_assert_unique(_all_item_ids())


func test_practice_piles_wiped_on_reset() -> void:
	_host = _new_host()
	var portal := _open_portal(true)
	var a := _join_near_portal(portal)
	_enter(a, portal)
	var inst := _instance_of(a)
	var bag := GroundDrop.new()
	bag.id = inst.sim._alloc_id()
	var item := ItemState.new()
	item.drop_id = "pile"
	bag.item = item
	inst.sim._ground_drops.append(bag)
	_exit_here(a, 5)
	_enter_persistent(a, portal, 6)
	assert_eq(inst.sim.ground_drops().size(), 0, "reset leaves no piles")
	assert_false(_all_item_ids().has("pile"))


# --- death, carry HP, save snapshot, riftstone --------------------------------

func _inside(id: int) -> SimPlayerState:
	var p := _host._find_player(id)
	return p.instance.sim.get_player(p.sim_id)


func test_carry_with_zero_hp_never_means_full_hp() -> void:
	var sim := LocalSim.new(SimConfig.new())
	var pid: int = 1  # LocalSim's built-in player
	var carry := PlayerCarry.from_sim(sim.get_player(pid), null)
	carry.hp = 0
	sim.apply_carried_player(carry, 1.0, 1.0)
	assert_eq(sim.get_player(pid).hp, 0)
	carry.hp = -5
	sim.apply_carried_player(carry, 1.0, 1.0)
	assert_eq(sim.get_player(pid).hp, 0)
	carry.hp = 3
	sim.apply_carried_player(carry, 1.0, 1.0)
	assert_eq(sim.get_player(pid).hp, 3)


func test_death_inside_practice_goes_to_hearth_with_entry_state() -> void:
	_host = _new_host()
	var portal := _open_portal(true)
	var a := _join_near_portal(portal)
	_host.sim.get_player(a).hp = 7
	var before := _progress(a)
	_enter(a, portal)
	_grant_inside(a)
	_inside(a).hp = 0
	_host.run_tick()
	assert_true(_instance_of(a).is_overworld())
	var sp := _host.sim.get_player(a)
	assert_eq(sp.hp, 7, "entry HP, not full and not dead")
	assert_eq(_progress(a), before)


func test_dead_occupant_at_reset_is_not_revived() -> void:
	_host = _new_host()
	var portal := _open_portal(true)
	var a := _join_near_portal(portal)
	_host.sim.get_player(a).hp = 6
	_enter(a, portal)
	var inst := _instance_of(a)
	var rec: LobbyHost.PortalRecord = _host._portal_records.values()[0]
	_inside(a).hp = 0
	assert_true(_host._reset_instance(rec))
	assert_true(_instance_of(a).is_overworld(), "dead occupant leaves")
	assert_eq(_host.sim.get_player(a).hp, 6)
	for p in _host.players:
		assert_ne(p.instance, inst, "no one revived inside")


func test_effective_character_uses_entry_snapshot_inside_practice() -> void:
	_host = _new_host()
	var portal := _open_portal(true)
	var a := _join_near_portal(portal)
	var outside := _host.effective_character(a)
	assert_not_null(outside)
	var before := _progress(a)
	_enter(a, portal)
	_grant_inside(a)
	_inside(a).pending_riftstone += 5
	var eff := _host.effective_character(a)
	assert_eq(eff.xp_tenths, before["xp"])
	assert_eq(eff.pending_glint, before["glint"])
	assert_eq(eff.pending_riftstone, before["riftstone"])
	assert_eq(eff.inventory.live_items().size(), before["items"])
	assert_ne(eff.inventory, _inside(a).inventory, "a copy, not live state")
	assert_null(_host.effective_character(999999))


func test_hosted_riftstone_reverts_in_practice_and_stays_from_real_vault() -> void:
	_host = _new_host()
	var practice := _open_portal(true)
	var a := _join_near_portal(practice)
	_host.sim.get_player(a).pending_riftstone = 4
	_enter(a, practice)
	_inside(a).pending_riftstone += 5
	_exit_here(a, 5)
	assert_true(_instance_of(a).is_overworld())
	assert_eq(_host.sim.get_player(a).pending_riftstone, 4, "practice: outside value kept")
	var real := _open_portal(false)
	_host.sim.place_player(a, real.x + 0.5, real.y)
	_enter(a, real, 7)
	assert_true(_instance_of(a).grants_persistent)
	_inside(a).pending_riftstone += 5
	_exit_here(a, 9)
	assert_eq(_host.sim.get_player(a).pending_riftstone, 9, "real vault keeps it")


func test_practice_strips_copies_and_unlabelled_items() -> void:
	_host = _new_host()
	var portal := _open_portal(true)
	var a := _join_near_portal(portal)
	var before := _progress(a)
	_enter(a, portal)
	var sp := _inside(a)
	var own: Array[ItemState] = sp.inventory.live_items()
	if not own.is_empty():
		assert_true(sp.inventory.add(own[0].duplicate_item()))
	var blank := ItemState.new()
	blank.tier = 3
	assert_true(sp.inventory.add(blank))
	_host.run_tick()
	assert_eq(_inside(a).inventory.live_items().size(), before["items"], "only what was brought in")


# --- host-issued player ids ---------------------------------------------------

func test_host_refuses_to_place_an_id_it_never_issued() -> void:
	_host = _new_host()
	var portal := _open_portal()
	var a := _join_near_portal(portal)
	_enter(a, portal)
	var inst := _instance_of(a)
	var p := _host._find_player(a)
	var real_id := p.sim_id
	_exit_here(a, 5)
	var forged := real_id + 3
	assert_false(_host._move_player(p, inst, forged, inst.arrival_x, inst.arrival_y), "unissued dungeon id")
	assert_true(_instance_of(a).is_overworld())
	assert_null(inst.sim.get_player(forged))
	assert_false(_host._move_player(p, _host.instances[0], a + 7, 1.0, 1.0), "unissued overworld id")
	# The id the dungeon sim issued and the entrance record maps to this player still works.
	_host.sim.place_player(a, portal.x + 0.5, portal.y)
	_enter(a, portal, 7)
	assert_same(_instance_of(a), inst)
	assert_eq(_host._find_player(a).sim_id, real_id)


func test_rejoin_refuses_a_stash_id_the_host_never_issued() -> void:
	_host = _new_host()
	_host.add_local_player()
	_host.run_tick()
	var forged := 424242
	_host._ability_stash["local:forged"] = {"id": forged, "cooldown": 0, "focus": 0.0, "left_tick": 0}
	_host._ability_stash_order.append("local:forged")
	var p := _host._add_player(null, "local:forged")
	assert_ne(p.id, forged, "fresh id, not the claimed one")
	assert_null(_host.sim.get_player(forged))
	# A stash entry the host wrote from this sim is honoured.
	var b := _host.add_local_player()
	_host.run_tick()
	_host._leave(_host._find_player(b), "local:real")
	_host.run_tick()
	var back := _host._add_player(null, "local:real")
	assert_eq(back.id, b)


# --- dungeon configuration from host data ---------------------------------------

func _assert_configured(inst: LobbyHost.HostInstance, grants: bool) -> void:
	var def: DungeonDef = _host.catalog.dungeon(inst.dungeon_id)
	assert_not_null(def)
	assert_same(inst.sim._dungeon, def, "configured from the host's own dungeon data")
	assert_eq(inst.sim.instance_m100(), inst.m100)
	assert_eq(inst.sim.instance_base_level(), inst.created_from.base_level)
	assert_eq(inst.sim.grants_persistent(), grants)
	assert_eq(inst.grants_persistent, grants)
	assert_false(inst.sim.boss_defeated())
	assert_false(inst.sim.arena_sealed())


func test_hosted_vault_instance_is_configured_from_host_data() -> void:
	_host = _new_host()
	var portal := _open_portal()
	portal.grants_persistent = false  # a packed claim; host data decides
	var a := _join_near_portal(portal)
	_enter(a, portal)
	var inst := _instance_of(a)
	assert_false(inst.is_overworld())
	_assert_configured(inst, true)


## Host data saying false wins over a packed true (fails closed).
func test_host_data_without_grants_wins_over_packed_claim() -> void:
	_host = _new_host()
	var def: DungeonDef = _host.catalog.dungeon("hollowmere_vault")
	var saved := def.grants_persistent
	def.grants_persistent = false
	var portal := _open_portal()
	portal.grants_persistent = true
	var a := _join_near_portal(portal)
	_enter(a, portal)
	def.grants_persistent = saved
	_assert_configured(_instance_of(a), false)


func test_practice_reset_configures_the_rebuilt_sim() -> void:
	_host = _new_host()
	var portal := _open_portal(true)
	var a := _join_near_portal(portal)
	_enter(a, portal)
	var inst := _instance_of(a)
	_assert_configured(inst, false)
	var old := inst.sim
	var p := _host._find_player(a)
	var w: EnemyState = null
	inst.sim.place_player(p.sim_id, 40.0, 6.0)
	_ticks(2)
	for e in inst.sim._enemies:
		if e.is_boss():
			w = e
	assert_not_null(w)
	inst.sim.hurt_enemy(w.id, 1, p.sim_id)
	assert_true(inst.sim.arena_sealed())
	_exit_here(a, 5)
	_enter_persistent(a, portal, 6)
	assert_same(_instance_of(a), inst)
	assert_ne(inst.sim, old, "rebuilt")
	_assert_configured(inst, false)


## Host placement into a sealed arena must land outside the door, and must
## not raise the encounter's n_peak. Relies on LocalSim's sealed-arena
## placement guard; pending until that guard is on this branch.
func test_host_placement_into_sealed_arena_lands_outside() -> void:
	_host = _new_host()
	if not LocalSim.new(SimConfig.new()).has_method("_should_relocate_sealed_placement"):
		pending("needs LocalSim sealed-arena placement guard")
		return
	var portal := _open_portal(true)
	var a := _join_near_portal(portal)
	_enter(a, portal)
	var inst := _instance_of(a)
	var pa := _host._find_player(a)
	inst.sim.place_player(pa.sim_id, 40.0, 6.0)
	_ticks(2)
	var w: EnemyState = null
	for e in inst.sim._enemies:
		if e.is_boss():
			w = e
	inst.sim.hurt_enemy(w.id, 1, pa.sim_id)
	assert_true(inst.sim.arena_sealed())
	var peak := inst.sim.boss_n_peak()
	var b := _join_near_portal(portal)
	var pb := _host._find_player(b)
	var bid := inst.sim.alloc_player_id()
	assert_true(_host._move_player(pb, inst, bid, 40.0, 6.0, true))
	inst.sim.get_player(pa.sim_id).hp = 9999
	_ticks(3)
	assert_lt(inst.sim.get_player(bid).x, 34.0, "placed outside the sealed door")
	assert_eq(inst.sim.boss_n_peak(), peak, "n_peak unchanged")


func test_rule_7_activity_tracks_received_input_frames_through_the_host() -> void:
	_host = _new_host()
	# A normal entrance (not the packed practice door) grants persistent rewards
	# and routes the player into their own instance sim.
	var portal := _open_portal()
	var pid: int = _join_near_portal(portal)
	_enter(pid, portal)
	var hp := _host._find_player(pid)
	assert_false(hp.instance.is_overworld())
	assert_true(hp.instance.grants_persistent)
	var sim: LocalSim = hp.instance.sim
	var sid: int = hp.sim_id
	var sp := sim.get_player(sid)
	assert_not_null(sp)
	sp.x = 36.0
	sp.y = 6.0
	sp.prev_x = sp.x
	sp.prev_y = sp.y
	_host.run_tick()
	var wid: int = 0
	for e in sim.snapshot().enemies:
		if e.def_id == "tallow_warden":
			wid = e.id
			break
	assert_gt(wid, 0, "Warden spawned")
	# One received frame, then silence. seq 1 was the enter press.
	_host.submit_local_input(pid, InputIntent.from_raw(2, 0.0, 0.0, 0.0, true))
	_host.run_tick()
	sim.hurt_enemy(wid, 200, sid)
	var window: int = LocalSim.NON_IDLE_WINDOW_TICKS
	for _i in range(window + 2):
		_host.run_tick()
		var p := sim.get_player(sid)
		if p != null:
			p.hp = maxi(p.hp, 200)
	sim.hurt_enemy(wid, sim.get_enemy(wid).hp, sid)
	_host.run_tick()
	assert_true(sim.boss_defeated())
	assert_eq(sim.get_player(sid).pending_glint, 0)
	assert_eq(sim.get_player(sid).pending_riftstone, 0)
