extends SceneTree
## Same serialized WorldData + untouched base Heightfield for both source revisions.
const OUT := "res://tools/control/runs/road_relief"
const Snapshot := preload("res://scripts/game/surface_snapshot.gd")
var done := false

func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 600)
	run.call_deferred()

func run() -> void:
	DirAccess.make_dir_recursive_absolute(OUT)
	var baseline := "--baseline" in OS.get_cmdline_user_args()
	var args := OS.get_cmdline_user_args()
	var seed_text := args[args.find("--seed") + 1] if "--seed" in args else "Север-1234"
	var path := OUT.path_join(seed_text + ".fixture.bin")
	var fixture: Dictionary
	var w: WorldData
	var generated_ms := 0.0
	if not FileAccess.file_exists(path):
		var start := Time.get_ticks_usec()
		w = WorldGenerator.generate(seed_text, 256)
		generated_ms = (Time.get_ticks_usec() - start) / 1000.0
		var data := {}
		for name: String in WorldData.CACHE_FIELDS: data[name] = EntityCodec.encode(w.get(name))
		fixture = {world = data, base = Snapshot.capture(Heightfield.new(w, false), "base"), generation_ms = generated_ms}
		FileAccess.open(path, FileAccess.WRITE).store_var(fixture)
	else:
		fixture = FileAccess.open(path, FileAccess.READ).get_var()
		w = WorldCache.new()._restore(fixture.world, true)
	var base := Snapshot.restore(w, fixture.base, "base")
	var rows := []
	var h: Heightfield
	for run_id in 6:
		h = base.copy()
		var start := Time.get_ticks_usec()
		h.finish_paths()
		var ms := (Time.get_ticks_usec() - start) / 1000.0
		rows.append({ms = ms, stages = h.path_timings.duplicate()})
		print("BENCH ", seed_text, " ", run_id, " ", ms)
	var boundary := 0.0
	var boundary_at := Vector2.ZERO
	var r := h.road_refinement
	for key: int in r.patches:
		var cx := key % w.W
		var cz := key / w.W
		for z in RoadRefinement.STRIDE:
			for x in RoadRefinement.STRIDE:
				if (x == 0 and not r.patches.has(key - 1)) or (x == RoadRefinement.DIV and not r.patches.has(key + 1)) or (z == 0 and not r.patches.has(key - w.W)) or (z == RoadRefinement.DIV and not r.patches.has(key + w.W)):
					var p := Vector2((cx + 0.5) * 4 + x, (cz + 0.5) * 4 + z)
					var error := absf(r.patches[key].h[z * RoadRefinement.STRIDE + x] - h.base_ground_at(p.x, p.y))
					if error > boundary: boundary = error; boundary_at = p
	var start := Time.get_ticks_usec()
	var arrays := TerrainBuilder.build_arrays(w, h)
	var mesh_ms := (Time.get_ticks_usec() - start) / 1000.0
	var summary := {seed = seed_text, revision = "before" if baseline else "after", dimensions = [w.W, w.H], generation_ms = fixture.generation_ms, runs = rows, mesh_ms = mesh_ms, vertices = arrays[Mesh.ARRAY_VERTEX].size(), patches = r.patches.size(), boundary_m = boundary, boundary_at = [boundary_at.x, boundary_at.y]}
	FileAccess.open(OUT.path_join(seed_text + ("_before.json" if baseline else "_after.json")), FileAccess.WRITE).store_string(JSON.stringify(summary, "\t"))
	if baseline: FileAccess.open(OUT.path_join(seed_text + "_before_patches.bin"), FileAccess.WRITE).store_var(r.patches)
	print("BENCH SUMMARY ", JSON.stringify(summary))
	done = true
	quit()
