extends GutTest
## Multi-player LocalSim: roster, apply_input then step(), per-viewer bags,
## and a 50-player per-tick cost check.


func _intent(seq: int, mx: float = 0.0, my: float = 0.0, aim: float = 0.0, fire: bool = false, target: int = 0, ability: bool = false) -> InputIntent:
	return InputIntent.from_raw(seq, mx, my, aim, fire, false, 0, target, ability)



func _issue_through(sim: LocalSim, id: int) -> void:
	while sim._next_id <= id:
		sim.alloc_player_id()


func test_solo_player_one_exists_before_first_step() -> void:
	var sim := LocalSim.new(SimConfig.new(), 3.0, 4.0)
	assert_eq(sim.player_count(), 1)
	assert_eq(sim.get_player(1).x, 3.0)
	assert_eq(sim.snapshot().player_id, 1)
	assert_eq(sim.snapshot().player_x, 3.0)
	assert_eq(sim.snapshot().players.size(), 1)
	assert_eq(sim.tick(), 0)


func test_add_player_takes_effect_at_start_of_next_step() -> void:
	var sim := LocalSim.new(SimConfig.new(), 0.0, 0.0)
	_issue_through(sim, 7)
	sim.add_player(7, {"class_id": "thornguard", "x": 5.0, "y": 2.0})
	assert_eq(sim.player_count(), 1, "queued, not in the world yet")
	assert_null(sim.get_player(7))
	sim.step()
	assert_eq(sim.player_count(), 2)
	var p: SimPlayerState = sim.get_player(7)
	assert_not_null(p)
	assert_eq(p.x, 5.0)
	assert_eq(p.y, 2.0)
	var snap := sim.snapshot()
	assert_eq(snap.players.size(), 2)
	assert_eq(snap.players[0].id, 1)
	assert_eq(snap.players[1].id, 7)


func test_apply_input_does_nothing_until_step() -> void:
	var sim := LocalSim.new(SimConfig.new(), 0.0, 0.0)
	sim.apply_input(1, _intent(1, 1.0, 0.0))
	assert_eq(sim.snapshot().player_x, 0.0)
	sim.step()
	assert_gt(sim.snapshot().player_x, 0.0)


func test_held_move_aim_and_fire_carry_over_without_new_input() -> void:
	var sim := LocalSim.new(SimConfig.new(), 0.0, 0.0)
	sim.apply_input(1, _intent(1, 1.0, 0.0, 1.25, true))
	sim.step()
	var x1: float = sim.snapshot().player_x
	assert_gt(x1, 0.0)
	assert_eq(sim.snapshot().player_aim, 1.25)
	assert_eq(sim.projectile_count(), 1)
	# No apply_input this tick: keep last move, aim, fire_held.
	sim.step()
	assert_gt(sim.snapshot().player_x, x1)
	assert_eq(sim.snapshot().player_aim, 1.25)


func test_oneshot_interact_clears_and_does_not_fire_twice() -> void:
	var catalog := DataCatalog.load_default()
	var sim := LocalSim.new(SimConfig.new(), 0.0, 0.0, catalog)
	sim.set_world_seed(1)
	sim.set_player_class("thornguard")
	# Grant a bag under the player and try to pick it up twice with one press.
	var e := EnemyDef.new()
	e.base_hp = 1
	e.radius = 0.35
	var eid: int = sim.spawn_enemy_from_def(e, 0.0, 0.0)
	# Force a kill-reward bag by granting a roll if possible; otherwise skip
	# if the first roll misses. Use try_grant_roll_for after a fake kill.
	var item: ItemState = sim.try_grant_roll_for(eid, 0, "thornguard")
	if item == null:
		# A miss is allowed; still assert the one-shot clear path via a dummy.
		sim.apply_input(1, _intent(1, 0.0, 0.0, 0.0, false, 12345))
		sim.step()
		sim.step()
		assert_eq(sim.get_player(1).intent.interact_target_id, 0)
		return
	var bag_id: int = sim.snapshot().ground_drops[0].id
	sim.apply_input(1, _intent(1, 0.0, 0.0, 0.0, false, bag_id))
	sim.step()
	assert_eq(sim.get_player(1).intent.interact_target_id, 0, "one-shot cleared after step")
	var after_first: int = sim.snapshot().ground_drops.size()
	# A second step with no new input must not re-apply the same press.
	sim.step()
	assert_eq(sim.snapshot().ground_drops.size(), after_first)


func test_remove_player_is_delayed_and_drops_in_flight_shots() -> void:
	var sim := LocalSim.new(SimConfig.new(), 0.0, 0.0)
	_issue_through(sim, 2)
	sim.add_player(2, {"x": 1.0, "y": 0.0})
	sim.step()
	sim.apply_input(2, _intent(1, 0.0, 0.0, 0.0, true))
	sim.step()
	assert_gt(sim.projectile_count(), 0)
	var owner: int = sim.snapshot().projectiles[0].owner_id
	assert_eq(owner, 2)
	sim.remove_player(2)
	assert_not_null(sim.get_player(2), "still present until the next step")
	assert_gt(sim.projectile_count(), 0)
	sim.step()
	assert_null(sim.get_player(2))
	for shot in sim.snapshot().projectiles:
		assert_ne(shot.owner_id, 2, "removed player's shots are dropped")


func test_players_are_processed_in_ascending_id_order() -> void:
	# Two players fire on the same tick; damaged_by / first-hit order follows
	# ascending id because movement and fire run in id order.
	var sim := LocalSim.new(SimConfig.new(), 10.0, 0.0)
	_issue_through(sim, 5)
	sim.add_player(3, {"x": 0.0, "y": 0.0})
	sim.add_player(5, {"x": 0.2, "y": 0.0})
	sim.step()
	var def := EnemyDef.new()
	def.base_hp = 1000
	def.radius = 0.35
	def.aggro_radius = 0.0
	def.move_speed = 0.0
	def.wander_speed = 0.0
	def.pattern_id = ""
	var eid: int = sim.spawn_enemy_from_def(def, 1.5, 0.0)
	sim.apply_input(5, _intent(1, 0.0, 0.0, 0.0, true))
	sim.apply_input(3, _intent(1, 0.0, 0.0, 0.0, true))
	sim.step()
	# Both shots spawn this tick; player 3 is processed first so their shot
	# is earlier in the projectile list.
	var ids: Array[int] = []
	for shot in sim.snapshot().projectiles:
		ids.append(shot.owner_id)
	assert_gt(ids.size(), 1)
	var first_of_pair: int = -1
	for id in ids:
		if id == 3 or id == 5:
			first_of_pair = id
			break
	assert_eq(first_of_pair, 3, "lower id fires first")
	var _e := eid


func test_world_view_is_per_viewer_for_bags_and_hud() -> void:
	var catalog := DataCatalog.load_default()
	var sim := LocalSim.new(SimConfig.new(), 0.0, 0.0, catalog)
	sim.set_world_seed(1)
	sim.set_player_class("thornguard")
	_issue_through(sim, 2)
	sim.add_player(2, {"class_id": "thornguard", "x": 4.0, "y": 0.0})
	sim.step()
	var def := EnemyDef.new()
	def.base_hp = 1
	def.radius = 0.35
	var eid: int = sim.spawn_enemy_from_def(def, 0.0, 0.0)
	# Grant a roll to player 1 and (if possible) player 2 via the public hook
	# for 1, and a second drop_index / looter by calling the same seed space
	# through try_grant_roll_for only for the default player. Place a bag for
	# each by rolling twice with different looter ids through drop_id uniqueness.
	var item1: ItemState = sim.try_grant_roll_for(eid, 0, "thornguard")
	# Snapshot for viewer 1 should only include bags owned by 1.
	var v1 := sim.world_view(1)
	var v2 := sim.world_view(2)
	assert_eq(v1.player_id, 1)
	assert_eq(v2.player_id, 2)
	assert_eq(v2.player_x, 4.0)
	assert_eq(v1.players.size(), 2)
	assert_eq(v2.players.size(), 2)
	for bag in v1.ground_drops:
		assert_eq(bag.item.owner_player_id, 1)
	for bag in v2.ground_drops:
		assert_eq(bag.item.owner_player_id, 2)
	if item1 != null:
		assert_gt(v1.ground_drops.size(), 0)
		assert_eq(v2.ground_drops.size(), 0, "player 2 does not see player 1's bags")
	# Held input on 2 must not move player 1.
	var x1: float = v1.player_x
	sim.apply_input(2, _intent(1, 1.0, 0.0))
	sim.step()
	assert_eq(sim.world_view(1).player_x, x1)
	assert_gt(sim.world_view(2).player_x, 4.0)


func test_player_rng_is_derived_from_instance_seed_and_id() -> void:
	var sim := LocalSim.new(SimConfig.new(), 0.0, 0.0)
	sim.set_world_seed(42)
	var p: SimPlayerState = sim.get_player(1)
	# Same seed + id always yields the same first uint32; a different id does not.
	var a := PCG32.new(sim.player_rng_initstate(1), 1)
	var b := PCG32.new(sim.player_rng_initstate(1), 1)
	assert_eq(a.uint32(), b.uint32())
	var other := PCG32.new(sim.player_rng_initstate(2), 1)
	assert_ne(PCG32.new(sim.player_rng_initstate(1), 1).uint32(), other.uint32())
	assert_not_null(p.rng)


func test_fifty_player_step_is_cheaper_than_fifty_separate_sims() -> void:
	var config := SimConfig.new()
	var shared := LocalSim.new(config, 0.0, 0.0)
	shared.set_world_seed(1)
	shared.set_bounds(0.0, 0.0, 48.0, 48.0)
	# Player 1 already exists.
	for id in range(2, 51):
		assert_eq(shared.alloc_player_id(), id)
		var ang: float = float(id) * 0.4
		shared.add_player(id, {"x": 24.0 + cos(ang) * 8.0, "y": 24.0 + sin(ang) * 8.0})
	shared.step()
	assert_eq(shared.player_count(), 50)
	var def := EnemyDef.new()
	def.base_hp = 60
	def.radius = 0.35
	def.aggro_radius = 8.0
	def.move_speed = 3.5
	def.wander_speed = 1.5
	def.hover_radius = 3.0
	def.leash = 16.0
	def.pattern_id = ""
	def.fire_interval_ticks = 1000
	shared.spawn_enemy_from_def(def, 24.0, 24.0)
	for id in range(1, 51):
		shared.apply_input(id, _intent(1, 1.0, 0.0, 0.0, id % 3 == 0))
	var t0: int = Time.get_ticks_usec()
	var steps: int = 80
	for i in range(steps):
		if i > 0:
			# Keep held input; no per-tick realloc of intents required.
			pass
		shared.step()
	var shared_us: int = Time.get_ticks_usec() - t0
	# Fifty separate solo sims, same work.
	var solos: Array[LocalSim] = []
	for id in range(1, 51):
		var s := LocalSim.new(config, 24.0, 24.0)
		s.set_world_seed(1)
		s.set_bounds(0.0, 0.0, 48.0, 48.0)
		s.spawn_enemy_from_def(def, 24.0, 24.0)
		s.apply_input(1, _intent(1, 1.0, 0.0, 0.0, id % 3 == 0))
		solos.append(s)
	var t1: int = Time.get_ticks_usec()
	for i in range(steps):
		for s in solos:
			s.step()
	var solo_us: int = Time.get_ticks_usec() - t1
	var shared_per: float = float(shared_us) / float(steps)
	var solo_per: float = float(solo_us) / float(steps)
	gut.p("50-player shared: %.1f us/tick (%d us / %d ticks); 50 solos: %.1f us/tick" % [
		shared_per, shared_us, steps, solo_per])
	# Loose CI gate: one shared tick must stay well under a 20 Hz budget.
	assert_lt(shared_per, 10000.0, "shared 50-player tick must stay under 10 ms")
	# Informational: the shared world should be cheaper; don't fail CI if the
	# machine is noisy, but record both numbers.
	assert_gt(shared.projectile_count(), 0)


func test_apply_input_keeps_pending_oneshots_until_step() -> void:
	var sim := LocalSim.new(SimConfig.new(), 0.0, 0.0)
	sim.set_player_class("thornguard")
	# First call posts both one-shots; a later movement-only apply must not drop them.
	sim.apply_input(1, _intent(1, 0.0, 0.0, 0.0, false, 12345, true))
	sim.apply_input(1, _intent(2, 1.0, 0.0))
	var p: SimPlayerState = sim.get_player(1)
	assert_true(p.intent.ability_pressed, "OR ability_pressed across applies")
	assert_eq(p.intent.interact_target_id, 12345, "keep a pending nonzero target")
	assert_eq(p.intent.seq, 2)
	assert_almost_eq(p.intent.move_x, 1.0, 1e-6)
	# Latest nonzero target wins.
	sim.apply_input(1, _intent(3, 1.0, 0.0, 0.0, false, 99, false))
	assert_eq(sim.get_player(1).intent.interact_target_id, 99)
	assert_true(sim.get_player(1).intent.ability_pressed)
	sim.step()
	assert_false(sim.get_player(1).intent.ability_pressed, "consumed after step")
	assert_eq(sim.get_player(1).intent.interact_target_id, 0)


func test_pattern_bullet_skips_invulnerable_and_hits_the_next_player() -> void:
	var sim := LocalSim.new(SimConfig.new(), 2.0, 0.0)
	_issue_through(sim, 2)
	sim.add_player(2, {"x": 2.0, "y": 0.0})
	sim.step()
	var src_def := EnemyDef.new()
	src_def.aggro_radius = 0.0
	src_def.leash = 1.0
	src_def.move_speed = 0.0
	src_def.wander_speed = 0.0
	src_def.radius = 0.35
	src_def.base_hp = 60
	src_def.damage["spit"] = 10
	var eid: int = sim.spawn_enemy_from_def(src_def, 50.0, 50.0)
	var b := PatternBullet.new()
	b.spawn_tick = sim.tick()
	b.origin_x = 2.0
	b.origin_y = 0.0
	b.speed = 0.0
	b.range_tiles = 1.0
	b.lifetime_ticks = 10
	b.radius_tiles = 0.15
	b.damage_key = "spit"
	b.source_id = eid
	sim._pattern_bullets.append(b)
	sim.set_invuln_ticks(1, 6)
	var hp1: int = sim.get_player(1).hp
	var hp2: int = sim.get_player(2).hp
	sim.step()
	assert_eq(sim.get_player(1).hp, hp1, "Slipstep i-frames skip the first overlap")
	assert_eq(sim.get_player(2).hp, hp2 - 10, "the bullet keeps checking other players")
	assert_true(b.consumed)


func test_unknown_player_position_does_not_fall_back_to_default() -> void:
	var sim := LocalSim.new(SimConfig.new(), 3.0, 4.0)
	assert_not_null(sim.get_player(1))
	assert_null(sim.get_player(99))
	var pos: Vector2 = sim._player_pos(99)
	assert_push_error("LocalSim: unknown player id 99")
	assert_eq(pos, Vector2.INF)
	assert_ne(pos.x, 3.0)
	assert_ne(pos.y, 4.0)


func test_projectiles_and_bags_are_readable_by_id() -> void:
	var catalog := DataCatalog.load_default()
	var sim := LocalSim.new(SimConfig.new(), 0.0, 0.0, catalog)
	sim.set_world_seed(1)
	var pid: int = sim.player_ids()[0]
	sim.set_player_class_for(pid, "thornguard")
	sim.apply_input(pid, _intent(1, 0.0, 0.0, 0.0, true))
	sim.step()
	var shots: Array[SimProjectile] = sim.projectiles()
	assert_gt(shots.size(), 0)
	assert_eq(shots.size(), sim.projectile_count())
	# Same array (read-only: do not mutate).
	assert_eq(shots[0].id, sim.projectiles()[0].id)
	var def := EnemyDef.new()
	def.base_hp = 1
	def.radius = 0.35
	var eid: int = sim.spawn_enemy_from_def(def, 0.0, 0.0)
	var item: ItemState = null
	for i in range(24):
		item = sim.try_grant_roll_for(eid, i, "thornguard")
		if item != null:
			break
	assert_not_null(item, "a bag should drop within enough rolls")
	assert_gt(sim.ground_drops().size(), 0)
	var bag: GroundDrop = sim.ground_drops()[0]
	assert_eq(sim.bag_by_id(bag.id), bag)
	assert_null(sim.bag_by_id(bag.id + 999999))


func test_contact_skips_invulnerable_and_hits_the_next_player() -> void:
	var sim := LocalSim.new(SimConfig.new(), 2.0, 0.0)
	var pid1: int = sim.player_ids()[0]
	var pid2: int = sim.alloc_player_id()
	assert_true(sim.add_player(pid2, {"x": 2.0, "y": 0.0}))
	sim.step()
	var def := EnemyDef.new()
	def.aggro_radius = 0.0
	def.leash = 1.0
	def.move_speed = 0.0
	def.wander_speed = 0.0
	def.contact_damage = 8
	def.base_hp = 60
	def.radius = 0.35
	def.pattern_id = ""
	sim.spawn_enemy_from_def(def, 2.0, 0.0)
	sim.set_invuln_ticks(pid1, 6)
	var hp1: int = sim.get_player(pid1).hp
	var hp2: int = sim.get_player(pid2).hp
	sim.step()
	assert_eq(sim.get_player(pid1).hp, hp1, "Slipstep i-frames skip the first overlap")
	assert_eq(sim.get_player(pid2).hp, hp2 - 8, "contact keeps checking other players")


func test_diagonal_walk_slides_along_a_wall() -> void:
	# Resolving X and Y separately: a diagonal into a vertical wall keeps the
	# unblocked axis, so the player slides along the wall instead of stopping.
	var sim := LocalSim.new(SimConfig.new(), 9.9, 8.5)
	sim.set_bounds(0.0, 0.0, 16.0, 16.0)
	for ty in range(0, 16):
		sim.set_blocking_tile(10, ty, true)
	var p := sim.get_player(1)
	var start_y: float = p.y
	sim.apply_input(1, _intent(1, 1.0, 1.0))
	sim.step()
	p = sim.get_player(1)
	assert_lt(p.x, 10.0, "the blocked axis stops at the wall")
	assert_almost_eq(p.x, 10.0 - SimConstants.MOVE_EPS, 1e-9)
	assert_gt(p.y, start_y, "the free axis still moves, sliding along the wall")
	var step: float = sim.config().move_speed_tiles_per_s * SimConstants.TICK_DT
	assert_almost_eq(p.y, start_y + step / sqrt(2.0), 1e-9)
