class_name DataCatalog
extends RefCounted
## Loads the shared data pack. Editor and export both read `res://data/*.json`
## (synced from repo-root `data/`). The repo-root path is a fallback for tests
## or a checkout that has not been synced yet.

const PACKED_DATA_DIR := "res://data"


static func repo_root() -> String:
	var client_dir := ProjectSettings.globalize_path("res://").rstrip("/")
	return client_dir.path_join("..").simplify_path()


static func load_default() -> DataCatalog:
	if FileAccess.file_exists(PACKED_DATA_DIR.path_join("enemies.json")) \
			and FileAccess.file_exists(PACKED_DATA_DIR.path_join("patterns.json")):
		return load_from(PACKED_DATA_DIR)
	return load_from(repo_root().path_join("data"))


static func load_from(data_dir: String) -> DataCatalog:
	var cat := DataCatalog.new()
	cat.patterns = {}
	cat.enemies = {}
	cat.classes = {}
	cat.abilities = {}
	cat._load_patterns(data_dir.path_join("patterns.json"))
	cat._load_enemies(data_dir.path_join("enemies.json"))
	cat._load_classes(data_dir.path_join("classes.json"))
	cat._load_abilities(data_dir.path_join("abilities.json"))
	cat.scaling = SimScaling.from_json(DataCatalog._read_json(data_dir.path_join("scaling.json")))
	cat.loot = LootTables.from_json(DataCatalog._read_json(data_dir.path_join("loot.json")))
	cat.report_unknown_ids()
	return cat


var patterns: Dictionary = {} # String -> PatternDef
var enemies: Dictionary = {} # String -> EnemyDef
var classes: Dictionary = {} # String -> ClassDef
var abilities: Dictionary = {} # String -> AbilityDef
var scaling: SimScaling = SimScaling.new()
var loot: LootTables = LootTables.new()


## Merge an extra { "patterns": [...] } file, used for fixtures-only defs.
func load_patterns_file(path: String) -> void:
	_load_patterns(path)


func pattern(id: String) -> PatternDef:
	return patterns.get(id, null) as PatternDef


func enemy(id: String) -> EnemyDef:
	return enemies.get(id, null) as EnemyDef


func class_def(id: String) -> ClassDef:
	return classes.get(id, null) as ClassDef


func ability(id: String) -> AbilityDef:
	return abilities.get(id, null) as AbilityDef


func _load_patterns(path: String) -> void:
	var d := _read_json(path)
	if d.is_empty():
		return
	var list: Variant = d.get("patterns", [])
	if list is Array:
		for item in list:
			if item is Dictionary:
				var p := PatternDef.from_json(item)
				if p.id != "":
					patterns[p.id] = p


func _load_enemies(path: String) -> void:
	var d := _read_json(path)
	if d.is_empty():
		return
	var list: Variant = d.get("enemies", [])
	if list is Array:
		for item in list:
			if item is Dictionary:
				var e := EnemyDef.from_json(item)
				if e.id != "":
					enemies[e.id] = e


func _load_classes(path: String) -> void:
	var d := _read_json(path)
	if d.is_empty():
		return
	var list: Variant = d.get("classes", [])
	if list is Array:
		for item in list:
			if item is Dictionary:
				var c := ClassDef.from_json(item)
				if c.id != "":
					classes[c.id] = c


func _load_abilities(path: String) -> void:
	var d := _read_json(path)
	if d.is_empty():
		return
	var list: Variant = d.get("abilities", [])
	if list is Array:
		for item in list:
			if item is Dictionary:
				var a := AbilityDef.from_json(item)
				if a.id != "":
					abilities[a.id] = a


static func _read_json(path: String) -> Dictionary:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		push_warning("DataCatalog: cannot read %s" % path)
		return {}
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	if parsed is Dictionary:
		return parsed
	push_warning("DataCatalog: invalid JSON at %s" % path)
	return {}


func unknown_reference_ids() -> PackedStringArray:
	var ids: PackedStringArray = PackedStringArray()
	var seen: Dictionary = {}
	var tables: Dictionary = loot.tables if loot != null else {}
	var rows: Dictionary = loot.tier_rows if loot != null else {}
	var ranks: Dictionary = loot.rank_tables if loot != null else {}
	for rank in ranks.keys():
		var tid: String = String(ranks[rank])
		if not tables.has(tid):
			if not seen.has(tid):
				ids.append(tid)
				seen[tid] = true
	for tid in tables.keys():
		var tab: Variant = tables[tid]
		if tab is Dictionary:
			var row: String = String(tab.get("row", ""))
			if row != "" and not rows.has(row):
				if not seen.has(row):
					ids.append(row)
					seen[row] = true
	var weapons: Dictionary = loot.weapons if loot != null else {}
	var weapon_ids: Dictionary = {}
	for cid in weapons.keys():
		var class_key: String = String(cid)
		if not classes.has(class_key):
			if not seen.has(class_key):
				ids.append(class_key)
				seen[class_key] = true
		var w: Variant = weapons[cid]
		if w is Dictionary:
			var wid: String = String(w.get("id", ""))
			if wid != "":
				weapon_ids[wid] = true
	if loot != null:
		for cid in loot.class_order:
			var class_key: String = String(cid)
			if class_key != "" and not classes.has(class_key) and not seen.has(class_key):
				ids.append(class_key)
				seen[class_key] = true
	for cid in classes.keys():
		var def: ClassDef = classes[cid] as ClassDef
		if def == null:
			continue
		if def.weapon_id != "" and not weapon_ids.has(def.weapon_id):
			if not seen.has(def.weapon_id):
				ids.append(def.weapon_id)
				seen[def.weapon_id] = true
		if def.ability_id != "" and not abilities.has(def.ability_id):
			if not seen.has(def.ability_id):
				ids.append(def.ability_id)
				seen[def.ability_id] = true
	for aid in abilities.keys():
		var adef: AbilityDef = abilities[aid] as AbilityDef
		if adef == null:
			continue
		for mid in adef.missing_effect_ids():
			if not seen.has(mid):
				ids.append(mid)
				seen[mid] = true
	return ids


func report_unknown_ids() -> void:
	for id in unknown_reference_ids():
		push_error("DataCatalog: unknown id %s" % id)
