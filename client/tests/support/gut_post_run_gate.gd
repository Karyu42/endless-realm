extends GutHookScript
## GUT post-run hook (wired in client/.gutconfig.json as post_run_script).
##
## GUT skips a test script that fails to load or parse (it logs "Ignoring script
## ... because it does not extend GutTest") and still exits 0. This hook makes
## that a failure: it sets exit code 1 when
##   - fewer test scripts ran than there are test_*.gd files under the test dirs, or
##   - GUT logged a warning or error about a script it could not load.
## .github/scripts/check-gut-log.sh scans the log as a backstop.

const CONFIG_PATH := "res://.gutconfig.json"
const LOAD_PROBLEM_MARKERS: Array[String] = [
	"Ignoring script",
	"does not extend GutTest",
	"Failed to load",
	"Parse Error",
	"Could not load",
]


func run() -> void:
	var cfg := _read_config()
	var dirs: Array = cfg.get("dirs", ["res://tests"])
	var prefix: String = cfg.get("prefix", "test_")
	var suffix: String = cfg.get("suffix", ".gd")
	var include_subdirs: bool = cfg.get("include_subdirs", true)

	var on_disk: Array[String] = []
	for d in dirs:
		_collect(str(d), prefix, suffix, include_subdirs, on_disk)
	on_disk.sort()

	var ran: Dictionary = {}
	for s in gut.get_test_collector().get_scripts():
		if s.was_run:
			ran[s.path] = true

	var problems: Array[String] = []
	for p in on_disk:
		if not ran.has(p):
			problems.append("test script not run (failed to load or parse?): %s" % p)
	if ran.size() < on_disk.size():
		problems.append("ran %d of %d test scripts" % [ran.size(), on_disk.size()])

	var lgr = gut.logger
	for entry in lgr.get_warnings() + lgr.get_errors():
		var text := str(entry)
		for m in LOAD_PROBLEM_MARKERS:
			if text.contains(m):
				problems.append("GUT logged: %s" % text.strip_edges())
				break

	print("GUT GATE: %d test_*.gd files, %d ran, GUT warnings %d, GUT errors %d" % [
		on_disk.size(), ran.size(), lgr.get_warnings().size(), lgr.get_errors().size()])
	if problems.is_empty():
		return
	for p in problems:
		printerr("GUT GATE FAILED: " + p)
	set_exit_code(1)


func _read_config() -> Dictionary:
	if not FileAccess.file_exists(CONFIG_PATH):
		return {}
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(CONFIG_PATH))
	return parsed if parsed is Dictionary else {}


func _collect(dir_path: String, prefix: String, suffix: String, recurse: bool, out: Array[String]) -> void:
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return
	for f in dir.get_files():
		if f.begins_with(prefix) and f.ends_with(suffix):
			out.append(dir_path.path_join(f))
	if recurse:
		for sub in dir.get_directories():
			if not sub.begins_with("."):
				_collect(dir_path.path_join(sub), prefix, suffix, recurse, out)
