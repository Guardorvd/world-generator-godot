extends SceneTree
const Test := preload("res://tools/vegetation_test.gd")
const Mist := preload("res://scripts/render/local_mist.gd")
const Quality := preload("res://scripts/render/lighting_quality.gd")
var failures := 0

func check(ok: bool, label: String) -> void:
	print(("PASS " if ok else "FAIL ") + label)
	if not ok: failures += 1

func _initialize() -> void:
	run.call_deferred()

func run() -> void:
	var env := Environment.new()
	var sun := DirectionalLight3D.new()
	root.add_child(sun)
	var day := DayCycle.new(env, sun)
	Quality.apply(env, sun, 0, true)
	check(not env.volumetric_fog_enabled, "low quality fallback")
	Quality.apply(env, sun, 1, true)
	check(env.volumetric_fog_enabled == (RenderingServer.get_current_rendering_method() == "forward_plus"), "renderer guard")
	day.apply(7.5, 0.0)
	var morning := day.local_mist
	day.apply(12.0, 0.1)
	check(absf(day.local_mist - morning) < 0.01, "time skip is smoothed")
	for i in 120: day.apply(12.0, 1.0 + i)
	check(day.local_mist < morning * 0.1, "clear noon settles")
	var wet := {biome = Biomes.FOREST, moist = 0.85, elev = 0.1, slope = 0.02}
	check(Mist.suitability(wet) > 0.0, "wet low forest")
	wet.moist = 0.2
	check(Mist.suitability(wet) == 0.0, "dry forest stays clear")
	wet.moist = 0.85
	wet.elev = 0.9
	check(Mist.suitability(wet) == 0.0, "high ridges stay clear")
	var world := Test.fixture(0)
	world.biome.fill(Biomes.FOREST)
	world.moist.fill(0.85)
	var mist := Mist.new()
	root.add_child(mist)
	mist.setup(world, Heightfield.new(world, false))
	# Exercise the node lifecycle even under the headless renderer.
	env.volumetric_fog_enabled = true
	mist.update(Vector3(512, 30, 512), day, 1.0, 1.0)
	check(not mist.patches.is_empty() and mist.patches.size() <= Mist.LIMIT, "bounded local patches")
	var key: Vector2i = mist.patches.keys()[0]
	var position: Vector3 = mist.patches[key].node.position
	mist.update(Vector3(514, 100, 514), day, 0.1, 1.1)
	check(mist.patches[key].node.position == position, "camera height does not move fog")
	mist.update(Vector3(10000, 30, 10000), day, 10.0, 11.1)
	check(mist.patches.is_empty(), "travel releases old patches")
	mist.update(Vector3(512, 30, 512), day, 1.0, 12.1)
	check(mist.patches.has(key) and mist.patches[key].node.position == position, "return recreates the same geography")
	env.volumetric_fog_enabled = false
	mist.update(Vector3(512, 30, 512), day, 1.0, 13.1)
	check(mist.patches.is_empty(), "quality change releases existing volumes")
	_streaming_checks(world, day)
	_geography_checks(world, day)
	var lamp := preload("res://scripts/render/bike_lamp.gd").new()
	root.add_child(lamp)
	for light: Light3D in lamp._lights:
		check(light.light_volumetric_fog_energy == 0.0, "moving lamp has no volumetric trails")
	quit(1 if failures else 0)

func _streaming_checks(world: WorldData, day: DayCycle) -> void:
	var mist := Mist.new()
	root.add_child(mist)
	mist.setup(world, Heightfield.new(world, false))
	day.env.volumetric_fog_enabled = true
	var at := Vector3(168, 30, 168)
	mist.update(at, day, 1.0 / 60.0, 0.0)
	check(mist.patches.has(Vector2i(1, 1)), "nearest site admitted first")
	var budget_ok := true
	for frame in 120:
		var before: int = mist.stats.evaluated
		mist.update(at, day, 1.0 / 60.0, frame / 60.0)
		budget_ok = budget_ok and mist.stats.evaluated - before <= Mist.BUILD_BUDGET
	check(budget_ok, "geography work bounded each frame")
	var updates: int = mist.stats.material_updates
	var count := mist.patches.size()
	for frame in 60: mist.update(at, day, 1.0 / 60.0, 2.0 + frame / 60.0)
	var writes: int = mist.stats.material_updates - updates
	check(writes <= count * 11, "material updates capped near 10 Hz at 60 FPS")
	print("Material batches over 60 frames: %d (previous policy: %d)" % [writes, count * 60])
	# No full fade-out delay after a large camera jump, even at high FPS.
	mist.update(Vector3(840, 30, 840), day, 1.0 / 60.0, 3.0)
	check(mist.patches.has(Vector2i(7, 7)), "teleport admits destination in the same frame")
	var near := true
	for entry: Dictionary in mist.patches.values():
		near = near and entry.point.distance_to(Vector2(840, 840)) <= Mist.RADIUS
	check(near, "teleport removes distant volumes before admission")
	mist.free()

func _geography_checks(world: WorldData, day: DayCycle) -> void:
	var mist := Mist.new()
	root.add_child(mist)
	mist.setup(world, Heightfield.new(world, false))
	world.moist.fill(0.1)
	# A wet pocket off the original grid center must still be found.
	# Probe at (532, 504) in bucket (4,4).
	var cell := Vector2i(532 / 4, 504 / 4)
	world.moist[cell.y * world.W + cell.x] = 0.9
	var site := mist._site(Vector2i(4, 4))
	check(not site.is_empty() and site.point == Vector2(532, 504), "off-center wet pocket is detected")
	check(site == mist._site(Vector2i(4, 4)), "site sampling is deterministic")
	for y in [125, 126]:
		for x in [139, 140]: mist.heights.hv[y * world.W + x] = 76.0
	var slope_site := mist._site(Vector2i(4, 4))
	check(slope_site.size.x < site.size.x and slope_site.size.x >= 48.0, "nearby steep relief narrows the fog footprint")
	# At 10 FPS, dry near cells must not repeatedly reset the queue and starve far ones.
	world.moist.fill(0.1)
	world.moist[126 * world.W + 210] = 0.9
	for frame in 100: mist.update(Vector3(512, 30, 512), day, 0.1, frame * 0.1)
	check(mist.patches.has(Vector2i(7, 4)), "dry foreground cannot starve a wet distant site")
	mist.free()
	world.moist.fill(0.85)
	# Real regional field publication/removal, no procedural generation.
	world.outer = OuterLand.new()
	world.outer.W = world.W
	world.outer.H = world.H
	var fields := {}
	for field in ["h", "elev", "temp", "moist", "slope", "biome", "ocean", "lake"]:
		fields[field] = world.get(field).duplicate()
	fields.river = world.river.duplicate()
	fields.path = world.path_mask.duplicate()
	fields.water_level = world.h.duplicate()
	fields.water_level.fill(-INF)
	var ledger := {regions = {}}
	ledger.regions[Vector2i(3, 0)] = {rect = Rect2i(768, 0, 256, 256), fields = fields}
	world.outer.set_ledger(ledger)
	var regional := Mist.new()
	root.add_child(regional)
	regional.setup(world, Heightfield.new(world, false))
	for frame in 40: regional.update(Vector3(3500, 30, 500), day, 0.1, frame * 0.1)
	check(not regional.patches.is_empty(), "published region supplies fog sites")
	world.outer.set_ledger({regions = {}})
	for frame in 70: regional.update(Vector3(3500, 30, 500), day, 0.1, 4.0 + frame * 0.1)
	check(regional.patches.is_empty(), "evicted regional fields release fog without camera movement")
	regional.free()
