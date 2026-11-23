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
	var intent := InputIntent.from_raw(1, 0.0, 0.0, 0.0, false, true, 0)
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
	# Pick all bags up (they stack at the same tile).
	for n in range(8):
		sim.submit_input(InputIntent.from_raw(n + 1, 0.0, 0.0, 0.0, false, true, 0))
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
