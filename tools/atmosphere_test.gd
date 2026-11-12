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
	var lamp := preload("res://scripts/render/bike_lamp.gd").new()
	root.add_child(lamp)
	for light: Light3D in lamp._lights:
		check(light.light_volumetric_fog_energy == 0.0, "moving lamp has no volumetric trails")
	quit(1 if failures else 0)
