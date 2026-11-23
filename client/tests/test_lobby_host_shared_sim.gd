extends GutTest
## LobbyHost on one shared LocalSim: roster, classes, per-viewer views and
## bags, and interact wired to the sim's bags.

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


func _bag(owner: int, x: float, y: float, tier: int = 1) -> GroundDrop:
	var item := ItemState.new()
	item.owner_player_id = owner
	item.tier = tier
	item.drop_id = "test-%d-%d" % [owner, _host.sim._ground_drops.size()]
	var bag := GroundDrop.new()
	bag.id = _host.sim._alloc_id()
	bag.item = item
	bag.x = x
	bag.y = y
	bag.t_star = 1
	bag.spawn_tick = _host.sim.tick()
	_host.sim._ground_drops.append(bag)
	return bag


func _press(id: int, seq: int, target: int) -> void:
	_host.submit_local_input(id, InputIntent.from_raw(seq, 0.0, 0.0, 0.0, false, false, 0, target))


func _inventory_count(id: int) -> int:
	var n := 0
	for it in _host.sim.get_player(id).inventory.slots:
		if it != null:
			n += 1
	return n


# --- roster / classes -------------------------------------------------------

func test_one_shared_sim_for_all_players() -> void:
	_host = _new_host()
	var a := _host.add_local_player()
	var b := _host.add_local_player()
	_host.run_tick()
	assert_eq(_host.sim.player_ids(), [a, b] as Array[int])
	assert_eq(_host.sim.tick(), _host.tick)
	_host.remove_local_player(b)
	_host.run_tick()
	assert_eq(_host.sim.player_ids(), [a] as Array[int], "leave applies at the next step")


func test_newest_accepted_seq_is_applied_once_per_tick() -> void:
	_host = _new_host()
	var a := _host.add_local_player()
	_host.run_tick()
	_host.submit_local_input(a, InputIntent.from_raw(1, 1.0, 0.0, 0.0, false))
	_host.submit_local_input(a, InputIntent.from_raw(2, 0.0, 1.0, 0.0, false))
	_host.submit_local_input(a, InputIntent.from_raw(2, -1.0, 0.0, 0.0, false))  # duplicate seq
	var x0 := _host.sim.get_player(a).x
	_host.run_tick()
	var sp := _host.sim.get_player(a)
	assert_eq(sp.applied_seq, 2)
	assert_almost_eq(sp.x, x0, 1e-9, "only the newest accepted frame moved the player")


func test_local_player_class_is_passed_through() -> void:
	_host = _new_host()
	var a := _host.add_local_player("gleamwright")
	var b := _host.add_local_player({"class_id": "driftrunner", "x": 3.0, "y": 4.0})
	_host.run_tick()
	assert_eq(_host.sim.get_player(a).class_id, "gleamwright")
	assert_eq(_host.sim.get_player(b).class_id, "driftrunner")
	assert_eq(_host.world_view(a).ability_id, "kindle_pulse")


func test_remote_and_null_players_get_default_class() -> void:
	_host = _new_host()
	var local := _host.add_local_player()
	var remote := _host._add_player().id  # Hello path
	_host.run_tick()
	assert_eq(_host.sim.get_player(local).class_id, LobbyHost.DEFAULT_CLASS_ID)
	assert_eq(_host.sim.get_player(remote).class_id, LobbyHost.DEFAULT_CLASS_ID)


## Runs ticks until this player's ability is off cooldown with full Focus.
func _wait_ability_ready(ids: Array) -> void:
	for i in range(2000):
		var ready := true
		for id in ids:
			if _host.sim.ability_cooldown_ticks(id) > 0 or _host.sim.focus(id) < float(_host.sim.focus_max(id)):
				ready = false
		if ready:
			return
		_host.run_tick()
	fail_test("ability never became ready")


func test_ability_press_casts_on_host_path_without_setting_class() -> void:
	_host = _new_host()
	var a := _host.add_local_player()  # no class given
	var remote := _host._add_player().id
	_host.run_tick()
	_wait_ability_ready([a, remote])
	var it := InputIntent.from_raw(1, 0.0, 0.0, 0.0, false)
	it.ability_pressed = true
	_host.submit_local_input(a, it)
	_host._queue_input(_host._find_player(remote), 1, 0.0, 0.0, 0.0, false, 0, true)
	_host.run_tick()
	assert_gt(_host.sim.ward_ticks(a), 0, "local press cast Thorn Ward")
	assert_gt(_host.sim.ward_ticks(remote), 0, "remote press cast Thorn Ward")
	assert_eq(_host.ability_presses, 2)


func test_local_first_join_can_cast_once_in_the_sim() -> void:
	_host = _new_host()
	_host.add_local_player()
	var b := _host.add_local_player()  # not in the sim until the next step
	var it := InputIntent.from_raw(1, 0.0, 0.0, 0.0, false)
	it.ability_pressed = true
	_host.submit_local_input(b, it)
	_host.run_tick()
	assert_eq(_host.sim.ward_ticks(b), 0, "joins at this step, press waits")
	_host.run_tick()
	assert_gt(_host.sim.ward_ticks(b), 0, "a first join is ready")


func test_remote_press_on_join_cannot_cast() -> void:
	_host = _new_host()
	_host.add_local_player()
	var r := _host._add_player()  # Hello path
	_host._queue_input(r, 1, 0.0, 0.0, 0.0, false, 0, true)
	_host.run_tick()
	_host.run_tick()
	assert_eq(_host.sim.ward_ticks(r.id), 0, "remote joins start on cooldown with no Focus")


func test_sim_only_allies_are_not_host_players() -> void:
	_host = _new_host()
	_host.apply_settings(_settings_with_max(2))
	var a := _host.add_local_player()
	_host.run_tick()
	while _host.sim._next_id <= 2:
		_host.sim.alloc_player_id()
	_host.sim.place_ally(2, 1.0, 1.0, 50, 100)
	var b := _host.add_local_player()
	assert_ne(b, 2, "ally id is not reused")
	assert_eq(_host.players.size(), 2, "ally does not count toward max_players")
	assert_eq(_host.add_local_player(), -1, "cap counts host players only")
	_host.run_tick()
	var v := _host.world_view(a)
	var ids: Array[int] = []
	for ps in v.players:
		ids.append(ps.id)
	assert_eq(ids, [a, 2, b] as Array[int], "ally is in the shared world view")
	var msg = PB.ServerMessage.new()
	msg.from_bytes(_host._encode_snapshot())
	var stubs: Array[int] = []
	for st in msg.get_snapshot().get_players():
		stubs.append(st.get_id())
	assert_eq(stubs, [a, b] as Array[int], "no Snapshot stub for the ally")
	assert_null(_host.world_view(2), "no host view for the ally")


func _settings_with_max(n: int) -> LobbySettings:
	var s := LobbySettings.new()
	s.max_players = n
	return s


func test_standin_bullets_only_with_emitters() -> void:
	_host = _new_host()
	assert_eq(_host.start(), OK)
	_host.add_local_player()
	for i in range(30):
		_host.run_tick()
	assert_eq(_host.bullets.live_bullets(), 0)
	assert_eq(_host.bullets.emitters_x.size(), 0)


# --- world_view ---------------------------------------------------------------

func test_world_view_copies_every_snapshot_field() -> void:
	_host = _new_host()
	var a := _host.add_local_player("thornguard")
	var b := _host.add_local_player()
	_host.run_tick()
	_bag(a, 1.0, 1.0)
	_bag(b, 2.0, 2.0)
	_host.run_tick()
	var src := _host.sim.world_view(a)
	var v := _host.world_view(a)
	var n := 0
	for prop in src.get_property_list():
		if prop["usage"] & PROPERTY_USAGE_SCRIPT_VARIABLE == 0:
			continue
		n += 1
		var want: Variant = src.get(prop["name"])
		var got: Variant = v.get(prop["name"])
		if want is Array:
			assert_eq((got as Array).size(), (want as Array).size(), String(prop["name"]))
			assert_ne(is_same(got, want), true, "%s is a copy" % prop["name"])
		else:
			assert_eq(got, want, String(prop["name"]))
	assert_gt(n, 20, "walked the script fields")
	assert_eq(v.ground_drops.size(), 1, "only the viewer's own bags")
	assert_eq(v.ground_drops[0].item.owner_player_id, a)
	assert_eq(v.players.size(), 2)


# --- interact -------------------------------------------------------------------

func test_in_range_own_bag_is_accepted_once() -> void:
	_host = _new_host()
	var a := _host.add_local_player()
	_host.run_tick()
	var sp := _host.sim.get_player(a)
	var bag := _bag(a, sp.x + 1.0, sp.y)
	_press(a, 1, bag.id)
	_press(a, 1, bag.id)  # same seq again
	_host.run_tick()
	assert_eq(_host.interact_validator.accepted, 1)
	assert_eq(_inventory_count(a), 1, "picked up into the sim inventory")
	assert_eq(_host.world_view(a).ground_drops.size(), 0)
	_press(a, 2, bag.id)  # bag is gone now
	_host.run_tick()
	assert_eq(_host.interact_validator.accepted, 1)
	assert_eq(_inventory_count(a), 1)


func test_other_players_bag_is_dropped_silently() -> void:
	_host = _new_host()
	var a := _host.add_local_player()
	var b := _host.add_local_player()
	_host.run_tick()
	var sp := _host.sim.get_player(a)
	var bag := _bag(b, sp.x, sp.y)
	_press(a, 1, bag.id)
	_host.run_tick()
	assert_eq(_host.interact_validator.accepted, 0)
	assert_eq(_host.interact_validator.dropped_unknown, 1)
	assert_eq(_inventory_count(a), 0)
	assert_eq(_host.sim.ground_drop_count(), 1, "bag stays on the ground")


func test_out_of_range_bag_is_dropped_silently() -> void:
	_host = _new_host()
	var a := _host.add_local_player()
	_host.run_tick()
	var sp := _host.sim.get_player(a)
	var r := _host.interact_validator.max_range_tiles()
	var bag := _bag(a, sp.x + r + 0.5, sp.y)
	_press(a, 1, bag.id)
	_host.run_tick()
	assert_eq(_host.interact_validator.accepted, 0)
	assert_eq(_host.interact_validator.dropped_range, 1)
	assert_eq(_inventory_count(a), 0)


# --- Snapshot.bags ----------------------------------------------------------------

func test_snapshot_bags_are_per_viewer() -> void:
	_host = _new_host()
	var a := _host.add_local_player()
	var b := _host.add_local_player()
	_host.run_tick()
	var bag := _bag(a, 1.5, 2.25)
	var by_owner := _host._bags_by_owner()
	assert_false(by_owner.has(b))
	var msg = PB.ServerMessage.new()
	assert_eq(msg.from_bytes(_host._encode_snapshot_for(by_owner[a])), PB.PB_ERR.NO_ERRORS)
	var bags = msg.get_snapshot().get_bags()
	assert_eq(bags.size(), 1)
	assert_eq(bags[0].get_id(), bag.id)
	assert_eq(bags[0].get_owner_player_id(), a)
	assert_almost_eq(bags[0].get_x(), 1.5, 1e-6)
	assert_eq(bags[0].get_t_star(), 1)
	assert_eq(bags[0].get_spawn_tick(), bag.spawn_tick)
	var shared = PB.ServerMessage.new()
	shared.from_bytes(_host._encode_snapshot())
	assert_eq(shared.get_snapshot().get_bags().size(), 0, "shared bytes carry no bags")


# --- ability state across leave / rejoin ------------------------------------------

func _cast(id: int, seq: int) -> void:
	var it := InputIntent.from_raw(seq, 0.0, 0.0, 0.0, false)
	it.ability_pressed = true
	_host.submit_local_input(id, it)


func _assert_conservative(id: int, why: String) -> void:
	var cd_max := _host.sim.world_view(id).ability_cooldown_max
	assert_gt(cd_max, 0)
	assert_eq(_host.sim.ability_cooldown_ticks(id), cd_max, "%s: full cooldown" % why)
	assert_almost_eq(_host.sim.focus(id), 0.0, 1e-6, "%s: no Focus" % why)


## A local player b who has cast once and is mid-cooldown with Focus spent.
func _player_mid_cooldown() -> int:
	_host.add_local_player()
	var b := _host.add_local_player()
	_host.run_tick()
	_wait_ability_ready([b])
	_cast(b, 1)
	_host.run_tick()
	assert_gt(_host.sim.ability_cooldown_ticks(b), 0, "on cooldown")
	assert_lt(_host.sim.focus(b), float(_host.sim.focus_max(b)), "Focus spent")
	return b


func test_leave_clears_sim_ability_entry() -> void:
	_host = _new_host()
	var a := _host.add_local_player()
	var b := _host.add_local_player()
	_host.run_tick()
	assert_true(_host.sim._ability_by_player.has(b))
	_host.remove_local_player(b)
	_host.run_tick()
	assert_false(_host.sim._ability_by_player.has(b))
	assert_true(_host.sim._ability_by_player.has(a))


func _assert_ready(id: int, why: String) -> void:
	assert_eq(_host.sim.ability_cooldown_ticks(id), 0, "%s: cooldown 0" % why)
	assert_almost_eq(_host.sim.focus(id), float(_host.sim.focus_max(id)), 1e-6, "%s: full Focus" % why)
	assert_eq(_host.sim.focus_max(id), 100)


func test_local_first_join_is_ready() -> void:
	_host = _new_host()
	var a := _host.add_local_player()  # first player, takes over sim player 1
	_assert_ready(a, "first local join (in the sim at once)")
	var b := _host.add_local_player("gleamwright")
	_host.run_tick()
	_assert_ready(a, "first local join")
	_assert_ready(b, "second local join")


func test_remote_join_is_conservative() -> void:
	_host = _new_host()
	_host.add_local_player()
	var r := _host._add_player().id  # remote Hello path
	_host.run_tick()
	_assert_conservative(r, "remote join")


func test_listen_host_first_join_is_ready() -> void:
	var gs: Node = load("res://src/session/game_session.gd").new()
	var cfg := LobbyConfig.new()
	cfg.ws_port = 0
	assert_eq(gs.start_host(cfg, "127.0.0.1"), OK)
	var host: LobbyHost = gs.lobby_host
	var pid: int = gs.local_player_id
	host.run_tick()
	assert_eq(host.sim.ability_cooldown_ticks(pid), 0, "listen-host: cooldown 0")
	assert_almost_eq(host.sim.focus(pid), 100.0, 1e-6, "listen-host: 100 Focus")
	gs._teardown_net()
	gs.free()


func test_rejoin_decays_cooldown_and_regens_focus_by_elapsed_ticks() -> void:
	_host = _new_host()
	var b := _player_mid_cooldown()
	var cd := _host.sim.ability_cooldown_ticks(b)
	var focus := _host.sim.focus(b)
	var per_tick := _host.sim.focus_regen_per_s(b) * SimConstants.TICK_DT
	assert_gt(per_tick, 0.0, "regen rate from class data")
	var left := _host.tick
	var token := _host.remove_local_player(b)
	assert_ne(token, "")
	for i in range(9):
		_host.run_tick()
	assert_eq(_host.add_local_player(null, token), b, "same id back")
	_host.run_tick()  # joins at this step; restored right after it
	var elapsed := _host.tick - left
	assert_eq(elapsed, 10)
	assert_eq(_host.sim.ability_cooldown_ticks(b), cd - elapsed, "cooldown decayed by host ticks")
	assert_almost_eq(_host.sim.focus(b), focus + per_tick * elapsed, 1e-6, "Focus regen over host ticks")
	assert_eq(_host.ability_stash_size(), 0, "token is single use")


func test_long_absence_floors_cooldown_and_caps_focus() -> void:
	_host = _new_host()
	var b := _player_mid_cooldown()
	var cd := _host.sim.ability_cooldown_ticks(b)
	var token := _host.remove_local_player(b)
	for i in range(cd + 500):
		_host.run_tick()
	assert_eq(_host.add_local_player(null, token), b)
	_host.run_tick()
	assert_eq(_host.sim.ability_cooldown_ticks(b), 0, "floored at 0")
	assert_almost_eq(_host.sim.focus(b), float(_host.sim.focus_max(b)), 1e-6, "capped at max Focus")


func test_matched_rejoin_before_the_leave_is_stepped() -> void:
	_host = _new_host()
	var b := _player_mid_cooldown()
	var cd := _host.sim.ability_cooldown_ticks(b)
	var focus := _host.sim.focus(b)
	var token := _host.remove_local_player(b)
	assert_eq(_host.add_local_player(null, token), b)
	assert_eq(_host.sim.ability_cooldown_ticks(b), cd, "no host time elapsed")
	assert_almost_eq(_host.sim.focus(b), focus, 1e-6)


func test_remote_reconnect_does_not_reset_cooldown_or_refill_focus() -> void:
	_host = _new_host()
	_host.add_local_player()
	var c := LobbyHost.HostConn.new()
	c.player = _host._add_player()
	var r := c.player.id
	_host.run_tick()
	_wait_ability_ready([r])
	_host._queue_input(c.player, 1, 0.0, 0.0, 0.0, false, 0, true)
	_host.run_tick()
	var cd := _host.sim.ability_cooldown_ticks(r)
	var focus := _host.sim.focus(r)
	assert_gt(cd, 0)
	_host._drop_player(c)  # disconnect
	_host.run_tick()
	var r2 := _host._add_player().id  # reconnect: new Hello
	_host.run_tick()
	assert_ne(r2, r)
	assert_gte(_host.sim.ability_cooldown_ticks(r2), cd - 1, "cooldown not reset")
	assert_lte(_host.sim.focus(r2), focus, "Focus not refilled")
	_host._queue_input(_host._find_player(r2), 1, 0.0, 0.0, 0.0, false, 0, true)
	_host.run_tick()
	assert_eq(_host.sim.ward_ticks(r2), 0, "cannot cast right after reconnecting")


func test_rejoin_after_eviction_starts_conservative() -> void:
	_host = _new_host()
	var b := _player_mid_cooldown()
	var token := _host.remove_local_player(b)
	_host.run_tick()
	for i in range(LobbyHost.MAX_ABILITY_STASH):
		var id := _host.add_local_player()
		_host.run_tick()
		_host.remove_local_player(id)
	assert_eq(_host.ability_stash_size(), LobbyHost.MAX_ABILITY_STASH, "bounded")
	var back := _host.add_local_player(null, token)
	assert_ne(back, b, "evicted token is not a match")
	_host.run_tick()
	_assert_conservative(back, "evicted rejoin")


func test_spoofed_local_rejoin_cannot_take_state() -> void:
	_host = _new_host()
	var b := _player_mid_cooldown()
	var token := _host.remove_local_player(b)
	_host.run_tick()
	var fresh := _host.add_local_player()  # no token: a first join, never b's state
	assert_ne(fresh, b)
	_host.run_tick()
	_assert_ready(fresh, "new local player")
	_host.remove_local_player(fresh)
	for guess in [str(b), "local:" + token, token.substr(0, 16), token.to_upper()]:
		var id := _host.add_local_player(null, guess)
		assert_ne(id, b, "guess %s does not get the id" % guess)
		_host.run_tick()
		_assert_conservative(id, "spoofed rejoin")
		_host.remove_local_player(id)
	assert_eq(_host.add_local_player(null, token), b, "the real token still works")


func test_ability_stash_is_cleared_on_close() -> void:
	_host = _new_host()
	var b := _player_mid_cooldown()
	var token := _host.remove_local_player(b)
	assert_eq(_host.ability_stash_size(), 1)
	_host.stop()
	assert_eq(_host.ability_stash_size(), 0)
	var again := _host.add_local_player(null, token)
	assert_ne(again, b)
	_host.run_tick()
	_assert_conservative(again, "token from before stop()")


func test_player_ids_never_collide_with_sim_entities() -> void:
	_host = _new_host()
	var a := _host.add_local_player()
	_host.run_tick()
	var e := _host.sim.spawn_enemy("burrmite", 5.0, 5.0)
	var b := _host.add_local_player()
	_host.run_tick()
	_bag(a, 1.0, 1.0)
	var ids := {}
	for id in [a, b, e]:
		assert_false(ids.has(id), "id %d reused" % id)
		ids[id] = true
	assert_gt(b, e, "player id taken from the shared allocator")

