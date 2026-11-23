extends GutTest
## content-v0.1 §1 / vision §2 class abilities: cost, cooldown, effects,
## Kindle Pulse cast lock vs fire-hold, one-shot ability_pressed, and
## per-player PCG32 streams.


func _class_sim(class_id: String, x: float = 8.0, y: float = 8.0) -> LocalSim:
	var catalog := DataCatalog.load_default()
	var sim := LocalSim.new(SimConfig.new(), x, y, catalog)
	sim.set_world_seed(1)
	sim.set_player_class(class_id)
	sim.apply_class_motion()
	return sim


func _pid(sim: LocalSim) -> int:
	return sim.snapshot().player_id


func _act(
	sim: LocalSim,
	seq: int,
	ability: bool = false,
	fire_held: bool = false,
	mx: float = 0.0,
	my: float = 0.0,
	aim: float = 0.0
) -> void:
	sim.submit_input(InputIntent.from_raw(seq, mx, my, aim, fire_held, false, 0, 0, ability))
	sim.step()


func _spawn_ticks(sim: LocalSim) -> Array:
	var ticks: Array = []
	for shot in sim.snapshot().projectiles:
		if not ticks.has(shot.spawn_tick):
			ticks.append(shot.spawn_tick)
	ticks.sort()
	return ticks


func test_thorn_ward_cost_cooldown_and_damage_cut() -> void:
	var sim := _class_sim("thornguard")
	var pid: int = _pid(sim)
	assert_almost_eq(sim.focus(pid), 100.0, 0.0)
	_act(sim, 1, true)
	assert_almost_eq(sim.focus(pid), 60.0 + 5.0 * SimConstants.TICK_DT, 1e-6)
	assert_eq(sim.ward_ticks(pid), 59, "60-tick duration, clocked at end of the cast tick")
	assert_eq(sim.ability_cooldown_ticks(pid), 159)
	# 10 contact damage becomes 5 after the ×0.50 cut (already a whole number).
	var def := EnemyDef.new()
	def.aggro_radius = 0.0
	def.leash = 1.0
	def.move_speed = 0.0
	def.wander_speed = 0.0
	def.contact_damage = 10
	def.base_hp = 60
	def.radius = 0.35
	def.pattern_id = ""
	var start_hp: int = sim.snapshot().player_hp
	sim.spawn_enemy_from_def(def, 8.0, 8.0)
	_act(sim, 2)
	assert_eq(sim.snapshot().player_hp, start_hp - 5)
	# On cooldown: a second press is a no-op.
	var focus_mid: float = sim.focus(pid)
	var ward_mid: int = sim.ward_ticks(pid)
	_act(sim, 3, true)
	assert_almost_eq(sim.focus(pid), focus_mid + 5.0 * SimConstants.TICK_DT, 1e-6)
	assert_eq(sim.ward_ticks(pid), ward_mid - 1)


func test_thorn_ward_half_up_cut_and_refresh() -> void:
	var sim := _class_sim("thornguard")
	var pid: int = _pid(sim)
	_act(sim, 1, true)
	var def := EnemyDef.new()
	def.aggro_radius = 0.0
	def.leash = 1.0
	def.move_speed = 0.0
	def.wander_speed = 0.0
	def.contact_damage = 11
	def.base_hp = 60
	def.radius = 0.35
	def.pattern_id = ""
	var start_hp: int = sim.snapshot().player_hp
	sim.spawn_enemy_from_def(def, 8.0, 8.0)
	_act(sim, 2)
	# 11 × 0.50 = 5.5, half-up to 6.
	assert_eq(sim.snapshot().player_hp, start_hp - 6)
	# After the 8 s cooldown, recast refreshes duration and does not stack.
	sim.set_ability_cooldown_ticks(pid, 0)
	sim.set_focus(pid, 100.0)
	_act(sim, 20, true)
	assert_eq(sim.ward_ticks(pid), 59)


func test_kindle_pulse_heals_self_and_allies_without_overheal() -> void:
	var sim := _class_sim("gleamwright")
	var pid: int = _pid(sim)
	# 25% of 140 = 35, half-up. Start at 100 so the heal is visible.
	sim.place_ally(pid, 8.0, 8.0, 100, 140)
	sim.place_ally(2, 10.0, 8.0, 80, 140)
	sim.place_ally(3, 20.0, 8.0, 80, 140)
	_act(sim, 1, true)
	assert_eq(sim.snapshot().player_hp, 135)
	assert_eq(sim.ally_hp(2), 115)
	assert_eq(sim.ally_hp(3), 80, "out of the 4-tile radius")
	assert_eq(sim.ally_ability_heals(pid), 1)
	assert_almost_eq(sim.focus(pid), 40.0 + 5.0 * SimConstants.TICK_DT, 1e-6)
	# Can't overheal.
	_act(sim, 2)  # wait; still on cooldown
	sim.set_ability_cooldown_ticks(pid, 0)
	sim.set_focus(pid, 100.0)
	sim.place_ally(pid, 8.0, 8.0, 140, 140)
	_act(sim, 3, true)
	assert_eq(sim.snapshot().player_hp, 140)


func test_kindle_pulse_cast_lock_golden_fire_schedule() -> void:
	# content-v0.1 §1: Gleamwright 2.5/s holds from tick 0 and casts on tick 14.
	# Volleys on 0 and 8; the shot due on 16 is blocked (lock 14–18, block_end 19)
	# and fires on 19, then 27, 35, with no catch-up burst.
	var sim := _class_sim("gleamwright")
	var seen: Array = []
	for i in range(36):
		_act(sim, i + 1, i == 14, true)
		for tick in _spawn_ticks(sim):
			if not seen.has(tick):
				seen.append(tick)
	seen.sort()
	assert_eq_deep(seen, [0, 8, 19, 27, 35])
	assert_false(sim.is_fire_blocked())
	# The lock itself lasted 5 ticks; after tick 18 it has expired.
	assert_eq(sim.snapshot().tick, 36)


func test_slipstep_blinks_in_move_or_aim_and_blocks_on_walls() -> void:
	var sim := _class_sim("driftrunner")
	var pid: int = _pid(sim)
	_act(sim, 1, true, false, 1.0, 0.0)
	var after_walk_blink: float = 8.0 + 6.0 * SimConstants.TICK_DT + 4.0
	assert_almost_eq(sim.snapshot().player_x, after_walk_blink, 1e-9)
	assert_almost_eq(sim.snapshot().player_y, 8.0, 1e-9)
	assert_almost_eq(sim.focus(pid), 70.0 + 5.0 * SimConstants.TICK_DT, 1e-6)
	assert_eq(sim.invuln_ticks(pid), 5, "6-tick i-frames, clocked at end of the blink tick")
	# Standing still uses aim. Recast after cooldown.
	sim.set_ability_cooldown_ticks(pid, 0)
	sim.set_focus(pid, 100.0)
	_act(sim, 2, true, false, 0.0, 0.0, -PI / 2.0)
	assert_almost_eq(sim.snapshot().player_x, after_walk_blink, 1e-9)
	assert_almost_eq(sim.snapshot().player_y, 4.0, 1e-9)
	# Sealed arena wall: stop at the last free point inside the bound + radius.
	var walled := _class_sim("driftrunner", 14.0, 8.0)
	walled.set_bounds(0.0, 0.0, 16.0, 16.0)
	_act(walled, 1, true, false, 1.0, 0.0)
	var r: float = walled.config().player_radius_tiles
	assert_almost_eq(walled.snapshot().player_x, 16.0 - r, 1e-4)
	# A blocking tile mid-path stops in the last free tile.
	var tiled := _class_sim("driftrunner", 8.0, 8.0)
	tiled.set_blocking_tile(11, 8, true)
	_act(tiled, 1, true, false, 1.0, 0.0)
	assert_lt(tiled.snapshot().player_x, 11.0)
	assert_gt(tiled.snapshot().player_x, 10.0 - 1e-6)


func test_slipstep_invuln_drops_damage_for_six_ticks() -> void:
	var sim := _class_sim("driftrunner")
	var def := EnemyDef.new()
	def.aggro_radius = 0.0
	def.leash = 1.0
	def.move_speed = 0.0
	def.wander_speed = 0.0
	def.contact_damage = 8
	def.base_hp = 60
	def.radius = 0.35
	def.pattern_id = ""
	# Blink onto the enemy. Contact would apply on the blink tick without i-frames.
	sim.spawn_enemy_from_def(def, 12.0, 8.0)
	var hp: int = sim.snapshot().player_hp
	_act(sim, 1, true, false, 1.0, 0.0)
	assert_eq(sim.snapshot().player_hp, hp)
	for i in range(5):
		_act(sim, 2 + i)
		assert_eq(sim.snapshot().player_hp, hp, "invuln through tick %d" % (i + 1))
	_act(sim, 10)
	assert_eq(sim.snapshot().player_hp, hp - 8, "damage resumes after 6 ticks")


func test_ability_pressed_is_consumed_and_does_not_cast_twice() -> void:
	var sim := _class_sim("thornguard")
	var pid: int = _pid(sim)
	sim.submit_input(InputIntent.from_raw(1, 0.0, 0.0, 0.0, false, false, 0, 0, true))
	sim.step()
	assert_eq(sim.ward_ticks(pid), 59)
	assert_almost_eq(sim.focus(pid), 60.0 + 5.0 * SimConstants.TICK_DT, 1e-6)
	# Leave the same intent in place, but restore cost and cooldown so a
	# second apply would succeed if ability_pressed were still set.
	sim.set_focus(pid, 100.0)
	sim.set_ability_cooldown_ticks(pid, 0)
	sim.step()
	assert_almost_eq(sim.focus(pid), 100.0, 1e-6)
	assert_eq(sim.ward_ticks(pid), 58, "duration ticked down, not refreshed")


func test_ability_rng_is_per_player_and_derived_from_instance_seed() -> void:
	var catalog := DataCatalog.load_default()
	var a := LocalSim.new(SimConfig.new(), 0.0, 0.0, catalog)
	var b := LocalSim.new(SimConfig.new(), 0.0, 0.0, catalog)
	a.set_world_seed(42)
	b.set_world_seed(42)
	var a1: int = a.ability_rng_uint32(1)
	var b1: int = b.ability_rng_uint32(1)
	assert_eq(a1, b1, "same instance seed and player id")
	var a2: int = a.ability_rng_uint32(2)
	assert_ne(a2, a1, "streams differ by player id")
	# Reseeding the instance restores the stream.
	a.set_world_seed(42)
	assert_eq(a.ability_rng_uint32(1), a1)
	assert_eq(a.ability_rng_uint32(2), a2)


func test_insufficient_focus_and_seq_zero_are_no_ops() -> void:
	var sim := _class_sim("thornguard")
	var pid: int = _pid(sim)
	sim.set_focus(pid, 10.0)
	_act(sim, 1, true)
	assert_eq(sim.ward_ticks(pid), 0)
	assert_almost_eq(sim.focus(pid), 10.0 + 5.0 * SimConstants.TICK_DT, 1e-6)
	sim.set_focus(pid, 100.0)
	sim.submit_input(InputIntent.from_raw(0, 0.0, 0.0, 0.0, false, false, 0, 0, true))
	sim.step()
	assert_eq(sim.ward_ticks(pid), 0)
	# The failed low-focus press already consumed seq 1; a new seq can cast.
	_act(sim, 2, true)
	assert_gt(sim.ward_ticks(pid), 0)
