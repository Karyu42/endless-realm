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
	assert_eq(_host.sim.player_ids(), [a, b] as Array[int], "the body lingers")
	_end_lingers()
	assert_eq(_host.sim.player_ids(), [a] as Array[int], "leave applies after the linger")


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
	_end_lingers()
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
	_end_lingers()
	for i in range(LobbyHost.MAX_ABILITY_STASH):
		var id := _host.add_local_player()
		_host.run_tick()
		_host.sim.get_player(id).hp = 0  # a dead body does not linger
		_host.remove_local_player(id)
		_host.run_tick()
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


# --- issued player ids --------------------------------------------------------

func test_rejoin_refuses_an_in_range_id_the_host_never_issued() -> void:
	_host = _new_host()
	var a := _host.add_local_player()
	var b := _host.add_local_player()
	_host.run_tick()
	var token := _host.remove_local_player(b)
	_host.run_tick()
	var key := "local:" + token
	var never := b + 5
	assert_null(_host._find_player(never))
	_host._ability_stash[key]["id"] = never  # same host, same sim, in range, never issued
	var back := _host.add_local_player(null, token)
	assert_ne(back, never, "an id the host never issued is not re-added")
	assert_ne(back, a)
	assert_eq(_host.ability_stash_size(), 0, "the bad entry is dropped")
	_host.run_tick()
	_assert_conservative(back, "refused stash entry")
	assert_null(_host.sim.get_player(never))


func test_real_rejoin_keeps_its_issued_id() -> void:
	_host = _new_host()
	_host.add_local_player()
	var b := _player_mid_cooldown()
	var token := _host.remove_local_player(b)
	_host.run_tick()
	assert_eq(_host.add_local_player(null, token), b)


func test_issued_id_set_stays_bounded() -> void:
	_host = _new_host()
	_host.add_local_player()
	_host.run_tick()
	for i in range(LobbyHost.MAX_ABILITY_STASH + 40):
		var id := _host.add_local_player()
		_host.run_tick()
		_host.remove_local_player(id)
	assert_lte(_host.issued_player_id_count(), LobbyHost.MAX_ABILITY_STASH + _host.players.size())
	# Leaving without a snapshot (remote, no identity) keeps nothing.
	var c := _host._add_player()
	var n := _host.issued_player_id_count()
	_host._leave(c)
	assert_eq(_host.issued_player_id_count(), n - 1)
	_host.stop()
	assert_eq(_host.issued_player_id_count(), 0, "cleared on stop")


## The listen-host player (built-in id 1) is already in the sim before the
## first step, so leaving then takes a snapshot of the ready first-join
## state: the rejoin is ready too. Nothing is gained by it.
func test_listen_host_leave_before_first_tick_rejoins_ready() -> void:
	_host = _new_host()
	var a := _host.add_local_player()
	assert_eq(a, 1)
	assert_eq(_host.tick, 0)
	var token := _host.remove_local_player(a)
	assert_eq(_host.ability_stash_size(), 1, "snapshot taken before the first step")
	assert_eq(_host.add_local_player(null, token), a)
	_host.run_tick()
	_assert_ready(a, "pre-first-tick rejoin")


## Any other local player is not in the sim until the step after their
## join, so leaving before it leaves no snapshot: the rejoin is conservative.
func test_other_local_leave_before_entering_sim_rejoins_conservative() -> void:
	_host = _new_host()
	_host.add_local_player()
	_host.run_tick()
	var b := _host.add_local_player()
	var token := _host.remove_local_player(b)
	var back := _host.add_local_player(null, token)
	_host.run_tick()
	_assert_conservative(back, "pre-sim rejoin")


func test_rejoin_drops_an_unavailable_saved_id() -> void:
	_host = _new_host()
	var live := _host.add_local_player()
	var other := _host.add_local_player()
	_host.run_tick()
	var token := _host.remove_local_player(other)
	_end_lingers()
	_host._ability_stash["local:" + token]["id"] = live
	var fresh := _host.add_local_player(null, token)
	assert_ne(fresh, live)
	assert_eq(_host.ability_stash_size(), 0, "unavailable saved entry dropped")
	assert_false(_host._issued_player_ids.has(other), "unheld issued id pruned")
	var live_token := _host.remove_local_player(live)
	_end_lingers()
	var retry := _host.add_local_player(null, token)
	assert_ne(retry, live, "old token cannot take the id after it becomes available")
	assert_eq(_host.add_local_player(null, live_token), live, "the owner's own token still works")



# --- HP on re-add -------------------------------------------------------------

func test_dead_local_player_readded_same_tick_stays_dead() -> void:
	_host = _new_host()
	_host.add_local_player()
	var b := _host.add_local_player()
	_host.run_tick()
	_host.sim.get_player(b).hp = 0
	var token := _host.remove_local_player(b)
	assert_eq(_host.add_local_player(null, token), b, "same id, still in the sim")
	assert_eq(_host.sim.get_player(b).hp, 0, "no refill on re-add")
	_host.run_tick()
	assert_eq(_host.sim.get_player(b).hp, 0)


func test_dead_local_player_rejoin_with_other_class_refused_stays_dead() -> void:
	_host = _new_host()
	_host.add_local_player()
	var b := _host.add_local_player("thornguard")
	_host.run_tick()
	_host.sim.get_player(b).hp = 0
	var token := _host.remove_local_player(b)
	assert_eq(_host.add_local_player("gleamwright", token), -1, "class is kept with the character")
	assert_eq(_host.sim.get_player(b).hp, 0)
	assert_eq(_host.sim.get_player(b).class_id, "thornguard")
	assert_eq(_host.add_local_player(null, token), b, "same class still rejoins")
	assert_eq(_host.sim.get_player(b).hp, 0)


func test_damaged_local_player_readded_same_tick_keeps_hp() -> void:
	_host = _new_host()
	_host.add_local_player()
	var b := _host.add_local_player()
	_host.run_tick()
	var sp := _host.sim.get_player(b)
	sp.hp = maxi(1, sp.hp / 3)
	var hp := sp.hp
	var token := _host.remove_local_player(b)
	assert_eq(_host.add_local_player({"hp": 99999}, token), b)
	assert_eq(_host.sim.get_player(b).hp, hp, "re-add keeps the sim's HP")
	_host.run_tick()
	assert_eq(_host.sim.get_player(b).hp, hp)


func test_fresh_join_spawns_with_full_hp() -> void:
	_host = _new_host()
	var a := _host.add_local_player()  # takes over the built-in player 1
	var b := _host.add_local_player()  # a new sim player
	_host.run_tick()
	for id in [a, b]:
		var sp := _host.sim.get_player(id)
		assert_gt(sp.hp, 0)
		assert_eq(sp.hp, _host.sim._current_max_hp(sp), "full HP on a new spawn")



func test_readd_same_tick_keeps_ability_cooldown_and_focus() -> void:
	_host = _new_host()
	var b := _player_mid_cooldown()
	var cd := _host.sim.ability_cooldown_ticks(b)
	var focus := _host.sim.focus(b)
	var token := _host.remove_local_player(b)
	assert_eq(_host.add_local_player(null, token), b)
	assert_eq(_host.sim.ability_cooldown_ticks(b), cd, "cooldown kept")
	assert_almost_eq(_host.sim.focus(b), focus, 1e-6, "Focus kept")
	_host.run_tick()
	assert_eq(_host.sim.ability_cooldown_ticks(b), maxi(cd - 1, 0))


func test_class_change_rejoin_in_overworld_never_refills_or_switches() -> void:
	_host = _new_host()
	var b := _player_mid_cooldown()
	var sp := _host.sim.get_player(b)
	sp.hp = 50
	var cd := _host.sim.ability_cooldown_ticks(b)
	var focus := _host.sim.focus(b)
	var token := _host.remove_local_player(b)
	# Same tick: the body is still in the sim.
	assert_eq(_host.add_local_player("gleamwright", token), -1, "no class change in the Wilds")
	sp = _host.sim.get_player(b)
	assert_eq(sp.class_id, "thornguard", "class not changed in place")
	assert_eq(sp.hp, 50)
	assert_eq(_host.sim.ability_cooldown_ticks(b), cd)
	assert_almost_eq(_host.sim.focus(b), focus, 1e-6)
	assert_eq(_host.add_local_player("", token), b, "an unnamed class keeps the character's")
	sp = _host.sim.get_player(b)
	assert_eq(sp.class_id, "thornguard")
	assert_eq(sp.hp, 50, "no HP refill")
	assert_eq(_host.sim.ability_cooldown_ticks(b), cd, "no cooldown refill")
	assert_almost_eq(_host.sim.focus(b), focus, 1e-6, "no Focus refill")
	assert_eq(_host._find_player(b).class_id, sp.class_id, "host class record follows the sim")
	# After the body has left the sim, a rejoin still keeps class and HP.
	token = _host.remove_local_player(b)
	_end_lingers()
	assert_null(_host.sim.get_player(b))
	assert_eq(_host.add_local_player("gleamwright", token), -1)
	assert_eq(_host.add_local_player(null, token), b)
	_host.run_tick()
	sp = _host.sim.get_player(b)
	assert_eq(sp.class_id, "thornguard")
	assert_lte(sp.hp, 50, "the rejoin keeps the HP it left with")
	assert_gt(_host.sim.ability_cooldown_ticks(b), 0, "cooldown still running")
	assert_eq(_host._find_player(b).class_id, "thornguard")


func test_overworld_leave_lingers_and_rejoin_keeps_hp_focus_cooldown() -> void:
	_host = _new_host()
	var b := _player_mid_cooldown()
	_host.sim.get_player(b).hp = 30
	var token := _host.remove_local_player(b)
	_host.run_tick()
	_host.run_tick()
	var sp := _host.sim.get_player(b)
	assert_not_null(sp, "the body lingers in the Wilds")
	assert_true(_host._find_player(b).is_lingering())
	var cd := _host.sim.ability_cooldown_ticks(b)
	var focus := _host.sim.focus(b)
	assert_eq(_host.add_local_player(null, token), b, "a rejoin inside the linger cancels the leave")
	sp = _host.sim.get_player(b)
	assert_eq(sp.hp, 30, "no HP refill")
	assert_eq(_host.sim.ability_cooldown_ticks(b), cd, "no cooldown refill")
	assert_almost_eq(_host.sim.focus(b), focus, 1e-6, "no Focus refill")
	assert_false(_host._find_player(b).is_lingering())
	# After the linger, the rejoin is a new body that still keeps the HP.
	token = _host.remove_local_player(b)
	_end_lingers()
	assert_null(_host.sim.get_player(b))
	assert_eq(_host.add_local_player(null, token), b)
	_host.run_tick()
	assert_lte(_host.sim.get_player(b).hp, 30, "no HP refill after the linger")
	assert_gt(_host.sim.ability_cooldown_ticks(b), 0)


# --- class validation on seating --------------------------------------------

class RefusingAddSim extends LocalSim:
	var refuse_next_add: bool = false

	func add_player(id: int, character: Variant = null) -> bool:
		if refuse_next_add:
			refuse_next_add = false
			return false
		return super.add_player(id, character)


func _host_with_refusing_sim() -> LobbyHost:
	var host := _new_host()
	var stub := RefusingAddSim.new(SimConfig.new(), 0.0, 0.0, host.catalog)
	stub.remove_player(1)
	stub.set_bounds(0.0, 0.0, host.arena_size, host.arena_size)
	stub.set_world_seed(host.instance_seed)
	stub.set_lobby_settings(host.settings())
	host.sim = stub
	host.instances[0].sim = stub
	return host


func test_local_add_with_unknown_class_leaves_no_seat_or_issued_id() -> void:
	_host = _new_host()
	var first := _host.add_local_player()
	_host.run_tick()
	var seats := _host.players.size()
	var issued := _host.issued_player_id_count()
	assert_eq(_host.add_local_player("no_such_class"), -1)
	assert_eq(_host.add_local_player(""), -1)
	assert_eq(_host.add_local_player({"class_id": "bogus_class"}), -1)
	assert_eq(_host.add_local_player({"class": ""}), -1)
	assert_eq(_host.players.size(), seats)
	assert_eq(_host.issued_player_id_count(), issued)
	assert_eq(_host.sim.get_player(first).class_id, LobbyHost.DEFAULT_CLASS_ID)
	assert_eq(_host.ability_stash_size(), 0)


func test_remote_join_with_unknown_class_is_refused() -> void:
	_host = _new_host()
	_host.add_local_player()
	_host.run_tick()
	var seats := _host.players.size()
	var issued := _host.issued_player_id_count()
	assert_null(_host._add_player("no_such_class"))
	assert_eq(_host.players.size(), seats, "no seat")
	assert_eq(_host.issued_player_id_count(), issued, "no issued id")

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
	assert_true(pump.call(func() -> bool:
		return not _host._conns.is_empty() 				and _host._conns[0].ws.get_ready_state() == WebSocketPeer.STATE_OPEN
	), "connection accepted")
	var c: LobbyHost.HostConn = _host._conns[0]
	assert_null(_host._try_remote_join(c, "bogus_class"))
	# Read the Error before the next tick's close_pending path closes the socket.
	var code := [-1]
	for i in range(30):
		c.ws.poll()
		ws.poll()
		while ws.get_available_packet_count() > 0:
			var m = PB.ServerMessage.new()
			if m.from_bytes(ws.get_packet()) == PB.PB_ERR.NO_ERRORS and m.has_error():
				code[0] = m.get_error().get_code()
		if code[0] != -1:
			break
		OS.delay_msec(10)
	assert_eq(code[0], PB.ErrorCode.JOIN_REFUSED, "remote gets JOIN_REFUSED")
	assert_eq(_host.players.size(), seats, "nothing is created")
	assert_eq(_host.issued_player_id_count(), issued)
	ws.close()


func test_player_1_with_empty_or_unknown_class_gets_the_default() -> void:
	_host = _new_host()
	var id := _host.add_local_player("")
	assert_eq(id, 1)
	assert_eq(_host.sim.get_player(1).class_id, LobbyHost.DEFAULT_CLASS_ID)
	assert_eq(_host._find_player(1).class_id, LobbyHost.DEFAULT_CLASS_ID)
	_host.stop()

	_host = _new_host()
	assert_eq(_host.add_local_player({"class_id": ""}), 1)
	assert_eq(_host.sim.get_player(1).class_id, LobbyHost.DEFAULT_CLASS_ID)
	_host.stop()

	_host = _new_host()
	assert_eq(_host.add_local_player({"class_id": "no_such_class"}), 1)
	assert_eq(_host.sim.get_player(1).class_id, LobbyHost.DEFAULT_CLASS_ID)
	assert_eq(_host.issued_player_id_count(), 1)


func test_valid_class_still_seats_local_and_remote() -> void:
	_host = _new_host()
	var a := _host.add_local_player("gleamwright")
	var b := _host.add_local_player({"class_id": "driftrunner"})
	var remote := _host._add_player()
	assert_eq(a, 1)
	assert_gt(b, 0)
	assert_not_null(remote)
	_host.run_tick()
	assert_eq(_host.sim.get_player(a).class_id, "gleamwright")
	assert_eq(_host.sim.get_player(b).class_id, "driftrunner")
	assert_eq(_host.sim.get_player(remote.id).class_id, LobbyHost.DEFAULT_CLASS_ID)
	assert_eq(_host.players.size(), 3)
	assert_eq(_host.issued_player_id_count(), 3)


func test_add_player_false_rolls_back_seat_and_issued_id() -> void:
	_host = _host_with_refusing_sim()
	var a := _host.add_local_player()
	assert_eq(a, 1)
	_host.run_tick()
	var seats := _host.players.size()
	var issued := _host.issued_player_id_count()
	(_host.sim as RefusingAddSim).refuse_next_add = true
	assert_eq(_host.add_local_player("gleamwright"), -1)
	assert_eq(_host.players.size(), seats, "no ghost seat")
	assert_eq(_host.issued_player_id_count(), issued, "issued id rolled back")
	assert_eq(_host.sim.get_player(a).class_id, LobbyHost.DEFAULT_CLASS_ID)
	var b := _host.add_local_player("gleamwright")
	assert_gt(b, 0, "a later valid add still works")
	_host.run_tick()
	assert_eq(_host.sim.get_player(b).class_id, "gleamwright")


## Runs the host past the disconnect linger so leaving bodies are gone.
func _end_lingers() -> void:
	for i in range(LobbyHost.LINGER_TICKS + 1):
		_host.run_tick()
