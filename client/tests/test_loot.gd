extends GutTest
## Deterministic personal drops, idempotent drop ids, bags and inventory.


func _catalog() -> DataCatalog:
	return DataCatalog.load_default()


func _sim() -> LocalSim:
	var cfg := SimConfig.new()
	cfg.fire_rate_shots_per_s = 0.0
	cfg.move_speed_tiles_per_s = 0.0
	var sim := LocalSim.new(cfg, 0.0, 0.0, _catalog())
	sim.set_world_seed(42)
	sim.set_player_class("thornguard")
	return sim


func test_same_seed_rolls_are_identical() -> void:
	var loot := _catalog().loot
	var scaling := _catalog().scaling
	var a: ItemState = loot.roll_item(7, 3, 1, 0, 10, "boss", "thornguard", scaling)
	var b: ItemState = loot.roll_item(7, 3, 1, 0, 10, "boss", "thornguard", scaling)
	assert_not_null(a, "boss table is 100% to drop")
	assert_not_null(b)
	assert_eq(a.drop_id, LootTables.drop_id(7, 3, 1, 0))
	assert_eq(a.drop_id, b.drop_id)
	assert_eq(a.slot, b.slot)
	assert_eq(a.base_id, b.base_id)
	assert_eq(a.tier, b.tier)
	assert_eq(a.charm_line, b.charm_line)
	assert_eq(a.charm_pct, b.charm_pct)


func test_drop_id_is_idempotent_in_the_sim() -> void:
	var sim := _sim()
	var def := _catalog().enemy("burrmite")
	def.rank = "boss" # 100% table, two rolls
	def.pattern_id = ""
	def.move_speed = 0.0
	var id := sim.spawn_enemy_from_def(def, 1.0, 0.0, 10)
	var first: ItemState = sim.try_grant_roll_for(id, 0)
	assert_not_null(first)
	var bags_after_first: int = sim.ground_drop_count()
	assert_gt(bags_after_first, 0)
	var again: ItemState = sim.try_grant_roll_for(id, 0)
	assert_null(again, "the same drop_id must not be granted twice")
	assert_eq(sim.ground_drop_count(), bags_after_first)
	assert_true(sim.has_granted_drop(LootTables.drop_id(42, id, 1, 0)))


func test_personal_rolls_differ_by_looter_stream() -> void:
	var loot := _catalog().loot
	var scaling := _catalog().scaling
	var a: ItemState = loot.roll_item(7, 3, 1, 0, 10, "boss", "thornguard", scaling)
	var b: ItemState = loot.roll_item(7, 3, 2, 0, 10, "boss", "thornguard", scaling)
	assert_not_null(a)
	assert_not_null(b)
	assert_ne(a.drop_id, b.drop_id)
	# Independent streams: ids always differ; the item itself may coincide
	# by chance, so we only assert identity of the roll against itself.
	var b2: ItemState = loot.roll_item(7, 3, 2, 0, 10, "boss", "thornguard", scaling)
	assert_eq(b.drop_id, b2.drop_id)
	assert_eq(b.slot, b2.slot)
	assert_eq(b.tier, b2.tier)


func test_pickup_moves_bag_into_inventory() -> void:
	var sim := _sim()
	var def := _catalog().enemy("burrmite")
	def.rank = "boss"
	def.pattern_id = ""
	def.move_speed = 0.0
	var id := sim.spawn_enemy_from_def(def, 0.5, 0.0, 10)
	assert_not_null(sim.try_grant_roll_for(id, 0))
	assert_eq(sim.ground_drop_count(), 1)
	var bag_id: int = sim.snapshot().ground_drops[0].id
	var intent := InputIntent.from_raw(1, 0.0, 0.0, 0.0, false, true, 0, bag_id)
	sim.submit_input(intent)
	sim.step()
	assert_eq(sim.ground_drop_count(), 0)
	assert_not_null(sim.inventory().slots[0])
	assert_eq(sim.snapshot().inventory[0].location, ItemState.LOC_INVENTORY)


func test_hotkey_equips_armor_and_raises_max_hp() -> void:
	var loot := _catalog().loot
	var scaling := _catalog().scaling
	# Search a few indices for an armor drop so the test does not depend on
	# one particular stream output, then grant that index in the sim.
	var sim := _sim()
	var def := _catalog().enemy("burrmite")
	def.rank = "boss"
	def.pattern_id = ""
	var id := sim.spawn_enemy_from_def(def, 0.5, 0.0, 10)
	var armor_index: int = -1
	for i in range(16):
		var trial: ItemState = loot.roll_item(42, id, 1, i, 10, "boss", "thornguard", scaling)
		if trial != null and trial.slot == ItemState.SLOT_ARMOR:
			armor_index = i
			break
	assert_gt(armor_index, -1, "expected an armor roll in 16 boss rolls")
	# Consume earlier indices so ids stay consistent, then grant the armor one.
	for i in range(armor_index):
		sim.try_grant_roll_for(id, i)
	var armor: ItemState = sim.try_grant_roll_for(id, armor_index)
	assert_not_null(armor)
	assert_eq(armor.slot, ItemState.SLOT_ARMOR)
	# Pick all bags up (they stack at the same tile). The client sends the
	# auto-selected bag id; the sim does not pick the nearest bag itself.
	var bag_ids: Array[int] = []
	for bag in sim.snapshot().ground_drops:
		bag_ids.append(bag.id)
	for n in range(bag_ids.size()):
		sim.submit_input(InputIntent.from_raw(n + 1, 0.0, 0.0, 0.0, false, true, 0, bag_ids[n]))
		sim.step()
	var inv := sim.inventory()
	var slot_i: int = -1
	for i in range(inv.slot_count):
		if inv.slots[i] != null and inv.slots[i].slot == ItemState.SLOT_ARMOR:
			slot_i = i
			break
	assert_gt(slot_i, -1)
	var before: int = sim.snapshot().player_max_hp
	sim.submit_input(InputIntent.from_raw(20, 0.0, 0.0, 0.0, false, false, slot_i + 1))
	sim.step()
	assert_not_null(sim.inventory().equipped_armor)
	assert_gt(sim.snapshot().player_max_hp, before)


func test_ground_bags_expire_after_sixty_seconds() -> void:
	var sim := _sim()
	var def := _catalog().enemy("burrmite")
	def.rank = "boss"
	def.pattern_id = ""
	var id := sim.spawn_enemy_from_def(def, 0.5, 0.0, 10)
	assert_not_null(sim.try_grant_roll_for(id, 0))
	assert_eq(sim.ground_drop_count(), 1)
	# 60 s = 1200 ticks. The bag was granted at tick 0; expire on the 1200th step.
	for i in range(1201):
		sim.submit_input(InputIntent.from_raw(i + 1, 0.0, 0.0, 0.0, false))
		sim.step()
	assert_eq(sim.ground_drop_count(), 0)

func _grant_bag_at(sim: LocalSim, x: float, y: float = 0.0) -> GroundDrop:
	var def := _catalog().enemy("burrmite")
	def.rank = "boss"
	def.pattern_id = ""
	def.move_speed = 0.0
	var id := sim.spawn_enemy_from_def(def, x, y, 10)
	assert_not_null(sim.try_grant_roll_for(id, 0))
	assert_eq(sim.ground_drop_count(), 1)
	return sim.snapshot().ground_drops[0]


func test_prompt_and_accept_ranges_come_from_data() -> void:
	var s := _catalog().scaling
	assert_eq(s.interact_prompt_range_tiles, 1.5)
	assert_eq(s.interact_accept_range_tiles, 2.0)
	assert_eq(s.practice_yard_content_level, 1)
	assert_true(s.in_prompt_range(1.5))
	assert_false(s.in_prompt_range(1.51))
	assert_true(s.in_accept_range(1.51))
	assert_true(s.in_accept_range(2.0))
	assert_false(s.in_accept_range(2.01))


func test_zero_target_id_does_not_auto_select() -> void:
	var sim := _sim()
	_grant_bag_at(sim, 0.5)
	# 0 means no interact. The sim must not pick the nearest bag.
	sim.submit_input(InputIntent.from_raw(1, 0.0, 0.0, 0.0, false, true, 0, 0))
	sim.step()
	assert_eq(sim.ground_drop_count(), 1)
	assert_null(sim.inventory().slots[0])


func test_targeted_pickup_at_prompt_range() -> void:
	var sim := _sim()
	var bag := _grant_bag_at(sim, 1.5)
	sim.submit_input(InputIntent.from_raw(1, 0.0, 0.0, 0.0, false, true, 0, bag.id))
	sim.step()
	assert_eq(sim.ground_drop_count(), 0)
	assert_not_null(sim.inventory().slots[0])


func test_accept_range_allows_a_targeted_pickup() -> void:
	var sim := _sim()
	var bag := _grant_bag_at(sim, 2.0)
	# A bag at 1.5–2.0 is never prompted, so a bare press must not pick it up.
	sim.submit_input(InputIntent.from_raw(1, 0.0, 0.0, 0.0, false, true, 0, 0))
	sim.step()
	assert_eq(sim.ground_drop_count(), 1)
	# A targeted request (latency tolerance) is accepted up to 2.0 tiles.
	sim.submit_input(InputIntent.from_raw(2, 0.0, 0.0, 0.0, false, true, 0, bag.id))
	sim.step()
	assert_eq(sim.ground_drop_count(), 0)
	assert_not_null(sim.inventory().slots[0])


func test_targeted_interact_beyond_tolerance_is_dropped_silently() -> void:
	var sim := _sim()
	var bag := _grant_bag_at(sim, 2.25)
	sim.submit_input(InputIntent.from_raw(1, 0.0, 0.0, 0.0, false, true, 0, bag.id))
	sim.step()
	assert_eq(sim.ground_drop_count(), 1, "out-of-range target must be ignored, with no error")
	assert_null(sim.inventory().slots[0])


func test_unknown_or_foreign_interact_target_is_dropped_silently() -> void:
	var sim := _sim()
	var bag := _grant_bag_at(sim, 0.5)
	sim.submit_input(InputIntent.from_raw(1, 0.0, 0.0, 0.0, false, true, 0, 999999))
	sim.step()
	assert_eq(sim.ground_drop_count(), 1)
	assert_null(sim.inventory().slots[0])
	bag.item.owner_player_id = 2
	assert_eq(sim.snapshot().ground_drops.size(), 0)
	sim.submit_input(InputIntent.from_raw(2, 0.0, 0.0, 0.0, false, true, 0, bag.id))
	sim.step()
	assert_eq(sim.ground_drop_count(), 1)
	assert_null(sim.inventory().slots[0])


func test_interact_press_applies_at_most_once_per_seq() -> void:
	var sim := _sim()
	var bag := _grant_bag_at(sim, 0.5)
	# Fill the inventory so the first press is consumed but does not pick up.
	for i in range(sim.inventory().slot_count):
		assert_true(sim.inventory().add(ItemState.new()))
	sim.submit_input(InputIntent.from_raw(1, 0.0, 0.0, 0.0, false, true, 0, bag.id))
	sim.step()
	assert_eq(sim.ground_drop_count(), 1)
	assert_true(sim.inventory().take_slot(0) != null)
	# Same seq again must not apply, even though a slot is now free.
	sim.submit_input(InputIntent.from_raw(1, 0.0, 0.0, 0.0, false, true, 0, bag.id))
	sim.step()
	assert_eq(sim.ground_drop_count(), 1)
	# A new seq applies once.
	sim.submit_input(InputIntent.from_raw(2, 0.0, 0.0, 0.0, false, true, 0, bag.id))
	sim.step()
	assert_eq(sim.ground_drop_count(), 0)


func test_practice_yard_forces_level_one_rewards() -> void:
	# A high content_level and a boss rank must not change yard rewards:
	# killXP(1) = 10.0 (100 tenths), Glint ceil(m(1)) = 1, loot at T* = 0.
	var cfg := SimConfig.new()
	cfg.move_speed_tiles_per_s = 0.0
	cfg.fire_rate_shots_per_s = 20.0
	cfg.projectile_speed_tiles_per_s = 14.0
	cfg.projectile_range_tiles = 20.0
	cfg.projectile_lifetime_ticks_override = 40
	cfg.player_projectile_damage = 10
	var sim := LocalSim.new(cfg, 0.0, 0.0, _catalog())
	sim.set_world_seed(42)
	sim.set_player_class("thornguard")
	sim.set_practice_yard(true)
	var def := _catalog().enemy("burrmite")
	def.rank = "boss"
	def.pattern_id = ""
	def.move_speed = 0.0
	def.wander_speed = 0.0
	def.contact_damage = 0
	var yard_e: int = _catalog().scaling.practice_yard_content_level
	assert_eq(yard_e, 1)
	sim.spawn_enemy_from_def(def, 2.0, 0.0, 20)
	var snap := sim.snapshot()
	assert_eq(snap.enemies[0].content_level, yard_e)
	assert_eq(_catalog().scaling.t_star(snap.enemies[0].content_level), 0)
	var death_tick: int = -1
	for i in range(20):
		sim.submit_input(InputIntent.from_raw(i + 1, 0.0, 0.0, 0.0, true))
		sim.step()
		if sim.enemy_count() == 0:
			death_tick = i
			break
	assert_gt(death_tick, -1, "yard Burrmite at E=1 should die like a level-1 enemy")
	assert_eq(sim.xp_tenths(), 100)
	assert_eq(sim.pending_glint(), 1)
	assert_eq(sim.player_level(), 1)
	for bag in sim.snapshot().ground_drops:
		assert_eq(bag.t_star, 0)
		assert_eq(bag.item.content_level, 1)


func test_golden_boss_rolls_are_stable() -> void:
	# Fixed seed/enemy/looter/index → slot/base/tier/line. Captured from
	# data/loot.json so a draw-order change or a host reimplementation fails.
	var loot := _catalog().loot
	var scaling := _catalog().scaling
	var expected: Array = [
		["charm", "ember_charm", 4, "ward", 0],
		["charm", "ember_charm", 4, "hp", 0],
		["armor", "wardweave", 4, "", 0],
		["armor", "wardweave", 5, "", 0],
		["armor", "wardweave", 5, "", 0],
	]
	for i in range(expected.size()):
		var item: ItemState = loot.roll_item(7, 3, 1, i, 20, "boss", "thornguard", scaling)
		assert_not_null(item, "golden roll %d should drop" % i)
		assert_eq(item.slot, expected[i][0], "roll %d slot" % i)
		assert_eq(item.base_id, expected[i][1], "roll %d base" % i)
		assert_eq(item.tier, expected[i][2], "roll %d tier" % i)
		assert_eq(item.charm_line, expected[i][3], "roll %d line" % i)
		assert_eq(item.charm_pct, expected[i][4], "roll %d pct" % i)


func test_bags_are_owner_only() -> void:
	var sim := _sim()
	var bag := _grant_bag_at(sim, 0.5)
	assert_eq(sim.snapshot().ground_drops.size(), 1)
	bag.item.owner_player_id = 2
	assert_eq(sim.snapshot().ground_drops.size(), 0)
	assert_eq(sim.ground_drop_count(), 1)
	sim.submit_input(InputIntent.from_raw(1, 0.0, 0.0, 0.0, false, true, 0, bag.id))
	sim.step()
	assert_eq(sim.ground_drop_count(), 1)
	assert_null(sim.inventory().slots[0])


func test_full_inventory_leaves_the_bag_on_the_ground() -> void:
	var sim := _sim()
	var bag := _grant_bag_at(sim, 0.5)
	for i in range(sim.inventory().slot_count):
		assert_true(sim.inventory().add(ItemState.new()))
	assert_true(sim.inventory().is_full())
	sim.submit_input(InputIntent.from_raw(1, 0.0, 0.0, 0.0, false, true, 0, bag.id))
	sim.step()
	assert_eq(sim.ground_drop_count(), 1)
	assert_eq(bag.item.location, ItemState.LOC_GROUND)


func test_inventory_slot_bounds() -> void:
	var inv := PlayerInventory.new(8)
	assert_false(inv.add(null))
	assert_null(inv.take_slot(-1))
	assert_null(inv.take_slot(8))
	assert_false(inv.equip_from_slot(99))
	for i in range(8):
		assert_true(inv.add(ItemState.new()))
	assert_true(inv.is_full())
	assert_false(inv.add(ItemState.new()))
