extends GutTest
## LobbyHost Hearth instance: a permanent safe zone with its own sim, its
## own id block, and a persistent two-way gate to the south edge of the Wilds.

const PB := preload("res://src/net/proto/protocol_v1_pb.gd")

var _host: LobbyHost


func after_each() -> void:
	if _host != null:
		_host.stop()
		_host = null


func _new_host() -> LobbyHost:
	var host := LobbyHost.new(SimConfig.new())
	host.port = 0
	return host


func _joined() -> int:
	var a := _host.add_local_player()
	_host.run_tick()
	return a


func _stand_on(psim: LocalSim, sim_id: int, gate_id: int) -> void:
	var gate := psim.portal_by_id(gate_id)
	var sp := psim.get_player(sim_id)
	sp.x = gate.x
	sp.y = gate.y


## Ticks until the gate pair accepts this character again (the player keeps
## away from the gates meanwhile).
func _wait_gate_cooldown(p: LobbyHost.HostPlayer) -> void:
	while _host.tick < p.gate_ready_tick:
		_host.run_tick()


func test_hearth_is_a_separate_town_zone_without_combat() -> void:
	_host = _new_host()
	var h := _host.hearth
	assert_not_null(h)
	assert_true(h.is_hearth())
	assert_false(h.is_overworld())
	assert_false(h.is_dungeon())
	assert_true(_host.instances[0].is_overworld())
	assert_false(_host.instances.has(h), "kept out of the dungeon and Wilds list")
	assert_ne(h.sim, _host.sim)
	assert_true(h.sim.is_town())
	assert_eq(h.sim.zone_id(), LocalSim.ZONE_HEARTH)
	assert_false(_host.sim.is_town(), "the Wilds are not town")
	assert_eq(h.sim.enemy_count(), 0)
	_host.run_tick()
	assert_eq(h.sim.player_ids(), [] as Array[int], "no built-in player once stepped")
	assert_eq(h.sim.enemy_count(), 0, "nothing spawns there")


func test_two_way_gate_pair_is_persistent_on_the_wilds_south_edge() -> void:
	_host = _new_host()
	var wg := _host.sim.portal_by_id(_host._wilds_gate_id)
	var hg := _host.hearth.sim.portal_by_id(_host._hearth_gate_id)
	assert_not_null(wg)
	assert_not_null(hg)
	assert_true(wg.persistent and hg.persistent)
	assert_almost_eq(wg.x, _host.arena_size * 0.5, 0.001)
	assert_gt(wg.y, _host.arena_size * 0.9, "on the south edge")
	assert_eq(_host.sim.portals().size(), 1, "no other portal added to the Wilds")
	for i in range(LobbyHost.EMPTY_INSTANCE_CLOSE_TICKS + 5):
		_host.run_tick()
	assert_not_null(_host.sim.portal_by_id(_host._wilds_gate_id), "never expires")
	assert_not_null(_host.hearth.sim.portal_by_id(_host._hearth_gate_id))


func test_walking_through_the_gate_crosses_both_ways() -> void:
	_host = _new_host()
	var a := _joined()
	var p := _host._find_player(a)
	_stand_on(_host.sim, a, _host._wilds_gate_id)
	_host.run_tick()
	assert_eq(p.instance, _host.hearth, "walked into the Hearth")
	assert_ne(p.sim_id, a, "own id inside the Hearth sim")
	assert_gte(p.sim_id, _host.hearth.index * LobbyHost.INSTANCE_ID_BLOCK)
	assert_lt(p.sim_id, (_host.hearth.index + 1) * LobbyHost.INSTANCE_ID_BLOCK)
	_host.run_tick()
	assert_null(_host.sim.get_player(a), "the Wilds body is gone")
	assert_eq(_host.hearth.sim.player_ids(), [p.sim_id] as Array[int])
	assert_almost_eq(p.x, LobbyHost.HEARTH_ARRIVAL.x, 0.5)
	assert_almost_eq(p.y, LobbyHost.HEARTH_ARRIVAL.y, 0.5)
	_host.run_tick()
	assert_eq(p.instance, _host.hearth, "arrival is clear of the gate, no bounce")
	var hearth_id := p.sim_id
	_wait_gate_cooldown(p)
	_stand_on(_host.hearth.sim, p.sim_id, _host._hearth_gate_id)
	_host.run_tick()
	assert_true(p.instance.is_overworld(), "walked back out to the Wilds")
	assert_eq(p.sim_id, a, "the Wilds id is the lobby id")
	assert_gt(p.y, _host.arena_size * 0.8, "back at the south edge")
	_host.run_tick()
	assert_true(p.instance.is_overworld(), "no bounce back in")
	assert_null(_host.hearth.sim.get_player(hearth_id))
	_wait_gate_cooldown(p)
	_stand_on(_host.sim, a, _host._wilds_gate_id)
	_host.run_tick()
	assert_eq(p.sim_id, hearth_id, "the same Hearth id on re-entry")


func test_dead_or_lingering_players_do_not_cross() -> void:
	_host = _new_host()
	_host.add_local_player()
	var b := _joined()
	var pb := _host._find_player(b)
	_stand_on(_host.sim, b, _host._wilds_gate_id)
	_host.sim.get_player(b).hp = 0
	_host.run_tick()
	assert_true(pb.instance.is_overworld(), "a dead body does not cross")
	_host.sim.get_player(b).hp = 10
	_host.remove_local_player(b)
	_host.run_tick()
	assert_true(pb.is_lingering())
	assert_true(pb.instance.is_overworld(), "a lingering body does not cross")


func test_hearth_allows_class_change_checks_and_keeps_the_rest_in_place() -> void:
	_host = _new_host()
	var a := _joined()
	var p := _host._find_player(a)
	assert_false(_host.sim.class_change_allowed(a, "gleamwright"), "locked in the Wilds")
	assert_true(_host.place_in_hearth_for_test(a))
	_host.run_tick()
	assert_true(_host.hearth.sim.class_change_allowed(p.sim_id, "gleamwright"), "town allows it")
	# Joins still land in the Wilds (routing into the Hearth is a follow-up).
	var b := _host.add_local_player()
	assert_true(_host._find_player(b).instance.is_overworld())


func test_hearth_viewer_snapshot_and_listing() -> void:
	_host = _new_host()
	var a := _host.add_local_player()
	var b := _joined()
	assert_true(_host.place_in_hearth_for_test(a))
	_host.run_tick()
	var hs = PB.ServerMessage.new()
	hs.from_bytes(_host._encode_snapshot_for([], _host.hearth))
	assert_eq(hs.get_snapshot().get_players().size(), 1)
	assert_eq(hs.get_snapshot().get_players()[0].get_id(), a, "lobby id on the wire")
	var ws = PB.ServerMessage.new()
	ws.from_bytes(_host._encode_snapshot_for([]))
	assert_eq(ws.get_snapshot().get_players().size(), 1)
	assert_eq(ws.get_snapshot().get_players()[0].get_id(), b)
	var lst = PB.ServerMessage.new()
	lst.from_bytes(_host._encode_instance_list(_host._find_player(b)))
	var found := false
	for info in lst.get_instance_list().get_instances():
		if info.get_instance() == _host.hearth.index:
			found = true
			assert_false(info.get_is_default())
	assert_true(found, "the Hearth is listed for a Wilds viewer")


func test_leave_and_linger_in_the_hearth() -> void:
	_host = _new_host()
	_host.add_local_player()
	var b := _joined()
	var pb := _host._find_player(b)
	assert_true(_host.place_in_hearth_for_test(b))
	_host.run_tick()
	var sid := pb.sim_id
	var token := _host.remove_local_player(b)
	assert_true(pb.is_lingering())
	_host.run_tick()
	assert_not_null(_host.hearth.sim.get_player(sid), "the body lingers in the Hearth")
	assert_eq(_host.add_local_player(null, token), b, "resumes in place")
	assert_eq(pb.instance, _host.hearth)
	_host.remove_local_player(b)
	for i in range(LobbyHost.LINGER_TICKS + 2):
		_host.run_tick()
	assert_null(_host.hearth.sim.get_player(sid))
	assert_false(_host.hearth.sim_ids.has(b), "mapping dropped when the player leaves")
	assert_false(_host.place_in_hearth_for_test(b), "no such player")


func test_gate_press_routes_like_walking() -> void:
	_host = _new_host()
	var a := _joined()
	var p := _host._find_player(a)
	_stand_on(_host.sim, a, _host._wilds_gate_id)
	var xfer := PortalTransfer.new()
	xfer.kind = PortalTransfer.KIND_EXIT
	xfer.player_id = a
	xfer.portal_id = _host._wilds_gate_id
	_host._route_transfer(_host.instances[0], xfer)
	assert_eq(p.instance, _host.hearth)
	var back := PortalTransfer.new()
	back.kind = PortalTransfer.KIND_EXIT
	back.player_id = p.sim_id
	back.portal_id = _host._hearth_gate_id
	_wait_gate_cooldown(p)
	_stand_on(_host.hearth.sim, p.sim_id, _host._hearth_gate_id)
	_host._route_transfer(_host.hearth, back)
	assert_true(p.instance.is_overworld())
	assert_gt(p.y, _host.arena_size * 0.8, "to the south edge, not the old stand-in")


func test_gate_refuses_a_character_for_the_cooldown_after_any_crossing() -> void:
	_host = _new_host()
	var a := _joined()
	var p := _host._find_player(a)
	_stand_on(_host.sim, a, _host._wilds_gate_id)
	_host.run_tick()
	assert_same(p.instance, _host.hearth, "crossed in")
	var crossed := _host.tick
	# Straight back onto the Hearth gate: refused, and not moved.
	_stand_on(_host.hearth.sim, p.sim_id, _host._hearth_gate_id)
	var x := _host.hearth.sim.get_player(p.sim_id).x
	var y := _host.hearth.sim.get_player(p.sim_id).y
	while _host.tick < crossed + LobbyHost.GATE_COOLDOWN_TICKS - 1:
		_host.run_tick()
		assert_same(p.instance, _host.hearth, "refused during the cooldown")
	assert_almost_eq(p.x, x, 0.01, "a refusal does not move the player")
	assert_almost_eq(p.y, y, 0.01)
	# A gate press is refused the same way.
	var xfer := PortalTransfer.new()
	xfer.kind = PortalTransfer.KIND_EXIT
	xfer.player_id = p.sim_id
	xfer.portal_id = _host._hearth_gate_id
	_host._route_transfer(_host.hearth, xfer)
	assert_same(p.instance, _host.hearth, "a press is refused too")
	_host.run_tick()
	assert_true(p.instance.is_overworld(), "allowed again after the cooldown")
	var out := _host.tick
	assert_eq(out, crossed + LobbyHost.GATE_COOLDOWN_TICKS)
	# The other direction has the same cooldown.
	_stand_on(_host.sim, a, _host._wilds_gate_id)
	_host.run_tick()
	assert_true(p.instance.is_overworld(), "the Wilds gate refuses too")


func test_cooldown_is_per_character() -> void:
	_host = _new_host()
	var a := _joined()
	var b := _joined()
	_stand_on(_host.sim, a, _host._wilds_gate_id)
	_host.run_tick()
	_stand_on(_host.sim, b, _host._wilds_gate_id)
	_host.run_tick()
	assert_same(_host._find_player(b).instance, _host.hearth, "another character is not held back")


func test_no_damage_to_players_in_the_hearth() -> void:
	_host = _new_host()
	_host.add_local_player()
	var a := _joined()
	var p := _host._find_player(a)
	assert_true(_host.place_in_hearth_for_test(a))
	_host.run_tick()
	var hs := _host.hearth.sim
	var sp := hs.get_player(p.sim_id)
	var hp := sp.hp
	# A hostile source placed on top of the player (none exist there normally).
	var e := hs.spawn_enemy("burrmite", sp.x, sp.y)
	assert_gt(e, 0)
	for i in range(40):
		_host.run_tick()
	assert_eq(hs.get_player(p.sim_id).hp, hp, "no damage from any source in the Hearth")
	assert_gt(_host.hearth.sim.player_ids().size(), 0)


func test_fire_and_abilities_work_in_the_hearth_and_spend_focus() -> void:
	_host = _new_host()
	_host.add_local_player()
	var a := _joined()
	var b := _joined()
	var pa := _host._find_player(a)
	var pb := _host._find_player(b)
	assert_true(_host.place_in_hearth_for_test(a))
	assert_true(_host.place_in_hearth_for_test(b))
	_host.run_tick()
	var hs := _host.hearth.sim
	var hp_b := hs.get_player(pb.sim_id).hp
	hs.set_focus(pa.sim_id, float(hs.focus_max(pa.sim_id)))
	hs.set_ability_cooldown_ticks(pa.sim_id, 0)
	var focus := hs.focus(pa.sim_id)
	_host.submit_local_input(a, InputIntent.from_raw(1, 0.0, 0.0, 0.0, true, false, 0, 0, true))
	_host.run_tick()
	assert_lt(hs.focus(pa.sim_id), focus, "the ability spends Focus")
	assert_gt(hs.ability_cooldown_ticks(pa.sim_id), 0, "and starts its cooldown")
	for i in range(1, 30):
		_host.submit_local_input(a, InputIntent.from_raw(1 + i, 0.0, 0.0, 0.0, true, false, 0, 0))
		_host.run_tick()
	assert_eq(hs.get_player(pb.sim_id).hp, hp_b, "no PvP")
