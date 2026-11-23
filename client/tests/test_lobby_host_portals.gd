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
func _open_portal() -> PortalSnapshot:
	var id := _host.sim.spawn_practice_portal("hollowmere_vault")
	return _host.sim.portal_by_id(id)


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

func test_empty_dungeon_is_torn_down_on_exit_and_leave() -> void:
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
	assert_eq(_host.instances.size(), 2, "still occupied")
	var pa := _host._find_player(a)
	var exit := PortalSnapshot.new()
	exit.id = inst.sim._alloc_id()
	exit.x = pa.x
	exit.y = pa.y
	exit.kind = PortalSnapshot.KIND_EXIT
	exit.dungeon_id = "hollowmere_vault"
	inst.sim.add_portal(exit)
	_press(a, 5, exit.id)
	_host.run_tick()
	assert_true(_instance_of(a).is_overworld())
	assert_eq(pa.sim_id, a, "back under the lobby id")
	assert_eq(_host.instances.size(), 1, "empty dungeon torn down")
	assert_false(_host._instance_by_portal.has(inst.portal_key))
	_host.run_tick()
	assert_eq(_host.sim.player_ids(), [a] as Array[int])


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
