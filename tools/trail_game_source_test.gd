extends SceneTree
const Source := preload("res://scripts/lab/trail_lab_game_source.gd")
const GI := preload("res://scripts/trails/trail_generation_input.gd")
const Job := preload("res://scripts/lab/trail_lab_world_job.gd")
const Terrain := preload("res://scripts/lab/trail_lab_terrain.gd")
const Adapter := preload("res://scripts/lab/trail_lab_input.gd")
var failures := 0
func check(ok: bool, message: String) -> void:
	print("PASS " if ok else "FAIL ", message)
	if not ok: failures += 1
func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 90)
	var input := GI.new()
	input.size = Vector2i(160, 160)
	for key in ["heights", "water", "rivers", "forbidden"]:
		var values = input.get(key)
		values.resize(160 * 160)
		input.set(key, values)
	for z in 160:
		for x in 160: input.heights[z * 160 + x] = 80 + x * 0.3
	input.water[30 * 160 + 30] = 1
	input.rivers[40 * 160 + 40] = 1
	input.forbidden[50 * 160 + 50] = 1
	input.existing_paths = [{points = PackedVector2Array([Vector2(300, 200), Vector2(300, 600)]), half_width = 4.0}]
	input.provenance = {source = "Trail Lab", game_seed = "roundtrip"}
	var path := "res://.godot/trail_game_source_test.res"
	check(ResourceSaver.save(input, path) == OK, "snapshot saved")
	var loaded := Source.open(path)
	check(loaded.has("input") and loaded.input.fingerprint() == input.fingerprint(), "snapshot roundtrip preserves all layers and limits")
	var strict := Source.terrain(input)
	var dry := Source.terrain(input, true)
	check(strict.water[40 * 160 + 40] == 1 and dry.water[40 * 160 + 40] == 0, "dry rivers require explicit experiment")
	check(dry.water[30 * 160 + 30] == 1 and dry.water[50 * 160 + 50] == 1, "experiment keeps water and infrastructure protected")
	Terrain.publish_world(strict)
	Terrain.use_window(Vector2i(16, 16))
	var window := Adapter.snapshot()
	check(window.heights[0] == input.heights[16 * 160 + 16] and window.earthwork_limits == input.earthwork_limits, "window retains absolute heights and earthwork limits")
	check(window.blocked(Vector2(40 - 16 + 0.5, 40 - 16 + 0.5) * 4), "river protection survives crop")
	check(window.blocked(Vector2(300, 300) - Vector2(64, 64)), "exact existing road survives crop")
	var reference := GI.new()
	for key in ["size", "heights", "water", "rivers", "forbidden", "existing_paths", "river_policy"]: reference.set(key, window.get(key))
	var equivalent := true
	for z in range(-1, 514, 7):
		for x in range(-1, 514, 7):
			if reference.blocked(Vector2(x, z)) != window.blocked(Vector2(x, z)): equivalent = false
	check(equivalent, "spatial road index matches exact exclusion, including edges and out-of-bounds")
	var scout := preload("res://scripts/lab/trail_lab_scout_job.gd").new(strict)
	check(not scout._dry(Vector2i(75, 80)), "scout sees exact road exclusions even without a pre-rasterized road mask")
	var timed := input.duplicate(true)
	timed.provenance.source_ms = 123.0
	timed.provenance.stages_ms = {roads = 12.0}
	check(Source.terrain(timed).input.fingerprint() == strict.input.fingerprint(), "runtime timings do not change project source identity")
	check(not Job.new(0, 0, {snapshot_path = path}).run().has("error"), "snapshot opens through background job")
	check(Job.new(0, 0, {snapshot_path = "res://project.godot"}).run().has("error"), "invalid snapshot produces explicit refusal")
	quit(1 if failures else 0)
