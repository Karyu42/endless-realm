class_name LootTables
extends RefCounted
## data/loot.json plus the PCG32 roll (vision §4.2, content-v0.1 §4).
##
## Seed: pcg32_init(mix(instance_seed, enemy_id, drop_index), looter_id).
## The looter is the PCG stream so personal rolls stay independent. Draw order
## for each item roll: chance, slot, weapon class (if weapon), tier offset,
## charm line (if charm), charm 2–10% (if stride/tempo).
##
## drop_id is "drop:{instance_seed}:{enemy_id}:{looter_id}:{drop_index}" and is
## idempotent: granting the same id twice is a no-op. (Vision §8.2's UUIDv7 is
## for later host persistence.)

var tier_rows: Dictionary = {} # row name -> Array[{offset, w}]
var slot_weapon: int = 40
var slot_armor: int = 35
var slot_charm: int = 25
var weapon_own: int = 70
var weapon_other_each: int = 15
var charm_lines: Array = []
var armor_id: String = "wardweave"
var armor_name: String = "Wardweave"
var armor_hp_coef: float = 30.0
var armor_ward_coef: float = 4.0
var charm_id: String = ""
var charm_name: String = ""
var weapons: Dictionary = {} # class_id -> {id, name, base_damage}
var class_order: PackedStringArray = PackedStringArray(["thornguard", "gleamwright", "driftrunner"])
var tables: Dictionary = {}
var rank_tables: Dictionary = {}
var eligibility_range_tiles: float = 10.0
var ground_expiry_ticks: int = 1200
var inventory_slots: int = 8
var glint_kill_boss_mult: int = 30


static func from_json(d: Dictionary) -> LootTables:
	var t := LootTables.new()
	var rows: Variant = d.get("tier_rows", {})
	if rows is Dictionary:
		t.tier_rows = rows
	var sw: Variant = d.get("slot_weights", {})
	if sw is Dictionary:
		t.slot_weapon = int(sw.get("weapon", 40))
		t.slot_armor = int(sw.get("armor", 35))
		t.slot_charm = int(sw.get("charm", 25))
	var ww: Variant = d.get("weapon_class_weights", {})
	if ww is Dictionary:
		t.weapon_own = int(ww.get("own", 70))
		t.weapon_other_each = int(ww.get("other_each", 15))
	var lines: Variant = d.get("charm_lines", [])
	if lines is Array:
		t.charm_lines = lines
	var armor: Variant = d.get("armor", {})
	if armor is Dictionary:
		t.armor_id = String(armor.get("id", "wardweave"))
		t.armor_name = String(armor.get("name", "Wardweave"))
		t.armor_hp_coef = float(armor.get("hp_coef", 30.0))
		t.armor_ward_coef = float(armor.get("ward_coef", 4.0))
	var charm: Variant = d.get("charm", {})
	if charm is Dictionary:
		t.charm_id = String(charm.get("id", ""))
		t.charm_name = String(charm.get("name", ""))
	var wpn: Variant = d.get("weapons", {})
	if wpn is Dictionary:
		t.weapons = wpn
	var order: Variant = d.get("class_order", [])
	if order is Array:
		t.class_order = PackedStringArray()
		for c in order:
			t.class_order.append(String(c))
	var tabs: Variant = d.get("tables", {})
	if tabs is Dictionary:
		t.tables = tabs
	var rt: Variant = d.get("rank_tables", {})
	if rt is Dictionary:
		t.rank_tables = rt
	t.eligibility_range_tiles = float(d.get("eligibility_range_tiles", 10.0))
	t.ground_expiry_ticks = int(d.get("ground_expiry_ticks", 1200))
	t.inventory_slots = int(d.get("inventory_slots", 8))
	t.glint_kill_boss_mult = int(d.get("glint_kill_boss_mult", 30))
	return t


static func drop_id(instance_seed: int, enemy_id: int, looter_id: int, drop_index: int) -> String:
	return "drop:%d:%d:%d:%d" % [instance_seed, enemy_id, looter_id, drop_index]


static func mix_seed(a: int, b: int, c: int) -> int:
	# Same SplitMix-style mix as LocalSim._mix_seed.
	return a * -7046029254386353131 + b * -4658895280553007687 + c * -7723592293110705685


func table_for_rank(rank: String) -> Dictionary:
	if not rank_tables.has(rank):
		return {}
	var tid: String = String(rank_tables[rank])
	var tab: Variant = tables.get(tid)
	if tab is Dictionary:
		return tab
	return {}


func extra_boss_rolls(m100: int) -> int:
	if m100 <= 100:
		return 0
	var tab: Dictionary = table_for_rank("boss")
	if not tab.has("m_extra_step"):
		return 0
	var step: int = int(tab["m_extra_step"])
	if step <= 0:
		return 0
	return int((m100 - 100) / step)


func roll_count(rank: String, m100: int) -> int:
	var tab := table_for_rank(rank)
	if not tab.has("rolls"):
		return 0
	var n: int = int(tab["rolls"])
	if rank == "boss":
		n += extra_boss_rolls(m100)
	return n


func item_chance_pct(rank: String) -> int:
	var tab := table_for_rank(rank)
	if not tab.has("item_chance"):
		return 0
	return SimScaling.round_half_up(float(tab["item_chance"]) * 100.0)


func charm_hp_coef() -> float:
	for line in charm_lines:
		if line is Dictionary and String(line.get("id", "")) == "hp":
			return float(line.get("coef", 0.0))
	return 0.0


## One personal item roll, or null on a miss. Always consumes the chance draw.
func roll_item(
	instance_seed: int,
	enemy_id: int,
	looter_id: int,
	drop_index: int,
	content_level: int,
	rank: String,
	looter_class: String,
	scaling: SimScaling
) -> ItemState:
	var rng := PCG32.new(mix_seed(instance_seed, enemy_id, drop_index), looter_id)
	var chance: int = item_chance_pct(rank)
	if int(rng.uint32() % 100) >= chance:
		return null
	var item := ItemState.new()
	item.drop_id = drop_id(instance_seed, enemy_id, looter_id, drop_index)
	item.owner_player_id = looter_id
	item.content_level = content_level
	item.pending = true
	item.location = ItemState.LOC_GROUND
	item.slot = _roll_slot(rng)
	match item.slot:
		ItemState.SLOT_WEAPON:
			_fill_weapon(item, rng, looter_class)
		ItemState.SLOT_ARMOR:
			item.base_id = armor_id
			item.display_base = armor_name
		ItemState.SLOT_CHARM:
			_fill_charm(item, rng)
	item.tier = _roll_tier(rng, content_level, rank)
	return item


func _roll_slot(rng: PCG32) -> String:
	var i: int = _weighted(rng, [slot_weapon, slot_armor, slot_charm])
	match i:
		0:
			return ItemState.SLOT_WEAPON
		1:
			return ItemState.SLOT_ARMOR
		_:
			return ItemState.SLOT_CHARM


func _fill_weapon(item: ItemState, rng: PCG32, looter_class: String) -> void:
	var others: PackedStringArray = PackedStringArray()
	for c in class_order:
		if c != looter_class:
			others.append(c)
	var weights: Array[int] = [weapon_own]
	for _i in range(others.size()):
		weights.append(weapon_other_each)
	var pick: int = _weighted(rng, weights)
	var cid: String = looter_class
	if pick > 0 and pick <= others.size():
		cid = others[pick - 1]
	var w: Variant = weapons.get(cid, {})
	if w is Dictionary:
		item.base_id = String(w.get("id", cid))
		item.display_base = String(w.get("name", item.base_id))
	else:
		item.base_id = cid
		item.display_base = cid


func _fill_charm(item: ItemState, rng: PCG32) -> void:
	item.base_id = charm_id
	item.display_base = charm_name
	if charm_lines.is_empty():
		return
	var weights: Array[int] = []
	for line in charm_lines:
		if line is Dictionary:
			weights.append(int(line.get("w", 0)))
		else:
			weights.append(0)
	var i: int = _weighted(rng, weights)
	if i < 0 or i >= charm_lines.size() or not (charm_lines[i] is Dictionary):
		return
	var line: Dictionary = charm_lines[i]
	item.charm_line = String(line.get("id", ""))
	if line.has("pct_min") and line.has("pct_max"):
		var lo: int = int(line.get("pct_min", 2))
		var hi: int = int(line.get("pct_max", 10))
		var span: int = maxi(1, hi - lo + 1)
		item.charm_pct = lo + int(rng.uint32() % span)


func _roll_tier(rng: PCG32, content_level: int, rank: String) -> int:
	var tab := table_for_rank(rank)
	var row_name: String = String(tab.get("row", ""))
	var row: Variant = tier_rows.get(row_name, [])
	var weights: Array[int] = []
	var offsets: Array[int] = []
	if row is Array:
		for entry in row:
			if entry is Dictionary:
				offsets.append(int(entry.get("offset", 0)))
				weights.append(int(entry.get("w", 0)))
	var t_star: int = 0
	if content_level > 0:
		t_star = int(content_level / 5)
	var off: int = 0
	if not weights.is_empty():
		var i: int = _weighted(rng, weights)
		off = offsets[i]
	return maxi(0, t_star + off)


func _weighted(rng: PCG32, weights: Array) -> int:
	var total: int = 0
	for w in weights:
		total += int(w)
	if total <= 0:
		return 0
	var roll: int = int(rng.uint32() % total)
	var acc: int = 0
	for i in range(weights.size()):
		acc += int(weights[i])
		if roll < acc:
			return i
	return weights.size() - 1


func glint_for_kill(content_level: int, rank: String, scaling: SimScaling) -> int:
	# vision §5: ceil(m(E)) per eligible player, boss ×30.
	var g: int = int(ceil(scaling.m(content_level)))
	if rank == "boss":
		g *= glint_kill_boss_mult
	return g
