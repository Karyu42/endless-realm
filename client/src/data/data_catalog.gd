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
	cat._load_patterns(data_dir.path_join("patterns.json"))
	cat._load_enemies(data_dir.path_join("enemies.json"))
	return cat


var patterns: Dictionary = {} # String -> PatternDef
var enemies: Dictionary = {} # String -> EnemyDef


func pattern(id: String) -> PatternDef:
	return patterns.get(id, null) as PatternDef


func enemy(id: String) -> EnemyDef:
	return enemies.get(id, null) as EnemyDef


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
