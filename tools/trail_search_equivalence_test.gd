extends SceneTree
const Terrain := preload("res://scripts/lab/trail_lab_terrain.gd")
const Scout := preload("res://scripts/lab/trail_lab_scout.gd")
func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self,90)
	run.call_deferred()
## Prepare the reference with git show 48f5953:scripts/lab/trail_lab_scout.gd > .godot/trail_scout_reference.gd
func run() -> void:
	if not FileAccess.file_exists("res://.godot/trail_scout_reference.gd"):
		printerr("Prepare .godot/trail_scout_reference.gd from commit 48f5953 before this comparison")
		quit(1)
		return
	Terrain.generate_world(7)
	var baseline = load("res://.godot/trail_scout_reference.gd")
	var start := Time.get_ticks_usec()
	var old: Array = baseline.find(7).duplicate(true)
	var before_ms := (Time.get_ticks_usec()-start)/1000.0
	start = Time.get_ticks_usec()
	var current := Scout.find(7)
	var after_ms := (Time.get_ticks_usec()-start)/1000.0
	var same := var_to_bytes(old) == var_to_bytes(current)
	var report := {same_candidates = same, count = current.size(), before_ms = before_ms, after_ms = after_ms, search = Scout.stats}
	var file := FileAccess.open("res://.godot/search_equivalence.json",FileAccess.WRITE)
	file.store_string(JSON.stringify(report,"  "))
	print("EQUIVALENCE ", JSON.stringify(report))
	quit(0 if same else 1)
