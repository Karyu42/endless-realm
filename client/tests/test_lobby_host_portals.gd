extends GutTest
## LobbyHost portal routing: the interact resolver for portals, dungeon
## instances created from LocalSim transfers, capacity, carried state,
## per-instance views and snapshots, teardown and id ranges.

const PB := preload("res://src/net/proto/protocol_v1_pb.gd")

var _host: LobbyHost
var _rejections: Array = []


func after_each() -> void:
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


## Practice portal in the overworld at its data position (8, 16).
func _open_portal(persistent: bool = false) -> PortalSnapshot:
	var id := _host.sim.spawn_practice_portal("hollowmere_vault")
	var portal := _host.sim.portal_by_id(id)
	# Most lifetime tests use a normal opened entrance; persistent-door
	# tests opt into the packed practice entrance policy explicitly.
	portal.persistent = persistent
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
