extends SceneTree
## Синтетический густой лес: GPU + подгрузка при движении. Нужен запуск с окном.
## --copies 4|8 --out <json>; --layer <скрипт> позволяет сравнить другую реализацию.
## --models <скрипт> позволяет сравнить библиотеку моделей при одинаковой сцене.

const Test := preload("res://tools/vegetation_test.gd")
const Dev := preload("res://tools/control/control.gd")
var veg: Node3D
var camera: Camera3D
var world: WorldData
var elapsed := 0.0
var last_us := 0
var frames := PackedFloat32Array()
var submit := PackedFloat32Array()
var primitives := 0.0
var calls := 0.0
var phase := 0
var results := {}


func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 180)
	call_deferred("setup")


func setup() -> void:
	Engine.max_fps = 0
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	DisplayServer.window_set_size(Vector2i(1280, 720))
	world = Test.fixture(int(Dev.arg("copies", "4")))
	var h := Heightfield.new(world, false)
	var layer: Script = load(Dev.arg("layer", "res://scripts/render/vegetation_layer.gd"))
	veg = layer.new()
	root.add_child(veg)
	var models: Script = load(Dev.arg("models", "res://scripts/render/models.gd"))
	veg.setup(world, h, models.tree_defs(), Models.grass_mesh())
	veg.update(512.0, 340.0, true)
	var ground := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(1024, 1024)
	ground.mesh = plane
	ground.position = Vector3(512, 25.8, 512)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.3, 0.45, 0.2)
	ground.material_override = mat
	root.add_child(ground)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-55, -30, 0)
	sun.shadow_enabled = true
	root.add_child(sun)
	var sky := WorldEnvironment.new()
	sky.environment = Environment.new()
	sky.environment.background_mode = Environment.BG_COLOR
	sky.environment.background_color = Color(0.5, 0.65, 0.85)
	sky.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	sky.environment.ambient_light_color = Color.WHITE
	sky.environment.ambient_light_energy = 0.5
	root.add_child(sky)
	camera = Camera3D.new()
	camera.far = 500
	root.add_child(camera)
	camera.current = true
	last_us = Time.get_ticks_usec()
	results.objects = world.obj_count
	results.layer = layer.resource_path
	results.renderer = RenderingServer.get_current_rendering_method()


func _process(delta: float) -> bool:
	if camera == null:
		return false
	elapsed += delta
	var z := 340.0 + maxf(0.0, elapsed - 5.0) * 16.0
	camera.look_at_from_position(Vector3(512, 32, z), Vector3(512, 29, z + 80), Vector3.UP)
	var t0 := Time.get_ticks_usec()
	veg.update(512.0, z, false)
	var upload_ms := (Time.get_ticks_usec() - t0) / 1000.0
	var now := Time.get_ticks_usec()
	if elapsed > 2.0:
		frames.append((now - last_us) / 1000.0)
		submit.append(upload_ms)
		primitives += Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME)
		calls += Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)
	last_us = now
	if phase == 0 and elapsed >= 5.0:
		results.still = stats()
		phase = 1
		frames.clear()
		submit.clear()
		primitives = 0.0
		calls = 0.0
	if elapsed < 12.0:
		return false
	results.moving = stats()
	print(JSON.stringify(results))
	var path := Dev.arg("out")
	if path != "":
		Dev.save_json(Dev.abs_dir(path), results)
	veg.queue_free()
	quit()
	return true


func stats() -> Dictionary:
	var f := frames.duplicate()
	f.sort()
	var u := submit.duplicate()
	u.sort()
	var sum := 0.0
	for ms in f:
		sum += ms
	return {fps = 1000.0 * f.size() / maxf(sum, 0.001), p99_ms = f[int(f.size() * 0.99)],
		submit_p99_ms = u[int(u.size() * 0.99)], submit_max_ms = u[-1],
		primitives = primitives / f.size(), draw_calls = calls / f.size(), batches = veg.veg.size()}
