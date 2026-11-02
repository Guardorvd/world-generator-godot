extends SceneTree
const Terrain := preload("res://scripts/lab/trail_lab_terrain.gd")
const Sites := preload("res://scripts/lab/trail_lab_sites.gd")
const B := preload("res://scripts/lab/trail_lab_builder.gd")
const F := preload("res://tools/trail_lab_fixture.gd")
const Scout := preload("res://scripts/lab/trail_lab_scout.gd")
func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 180)
	run.call_deferred()
func run() -> void:
	var result := {}
	var start := Time.get_ticks_usec()
	Sites.generate_world(7)
	result.world_ms = (Time.get_ticks_usec() - start) / 1000.0
	result.geography = Terrain.world_info.duplicate(true)
	result.search = Scout.stats.duplicate(true)
	if Sites.sites.size() > 1:
		start = Time.get_ticks_usec()
		Sites.select(1)
		result.project_ms = (Time.get_ticks_usec() - start) / 1000.0
		result.project = B.stats.duplicate(true)
		start = Time.get_ticks_usec()
		var prepared := F.prepare(Sites.routes(), true, "generated")
		result.preparation_ms = (Time.get_ticks_usec() - start) / 1000.0
		result.preparation = prepared.timings
		result.errors = Array(prepared.errors)
		if prepared.heights != null:
			start = Time.get_ticks_usec()
			TerrainBuilder.build_arrays(prepared.heights.world, prepared.heights)
			result.mesh_ms = (Time.get_ticks_usec() - start) / 1000.0
	var args := OS.get_cmdline_user_args()
	var path := args[0] if not args.is_empty() else "res://.godot/trail_profile.json"
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(JSON.stringify(result, "  "))
	print("PROFILE ", JSON.stringify({world_ms = result.world_ms, search_ms = result.search.ms, project_ms = result.get("project_ms"), preparation_ms = result.get("preparation_ms"), mesh_ms = result.get("mesh_ms"), stages = result.get("preparation"), sites = Sites.sites.size()}))
	quit()
