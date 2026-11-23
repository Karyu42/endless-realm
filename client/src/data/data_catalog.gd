class_name DataCatalog
extends RefCounted
## Loads the shared data/ pack from the repo root (sibling of client/).

var patterns: Dictionary = {} # String -> PatternDef
var enemies: Dictionary = {} # String -> EnemyDef


static func repo_root() -> String:
	var client_dir := ProjectSettings.globalize_path("res://").rstrip("/")
	return client_dir.path_join("..").simplify_path()


static func load_default() -> DataCatalog:
	return load_from(repo_root())


static func load_from(root: String) -> DataCatalog:
	var cat := DataCatalog.new()
	cat._load_patterns(root.path_join("data/patterns.json"))
	cat._load_enemies(root.path_join("data/enemies.json"))
	return cat


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
