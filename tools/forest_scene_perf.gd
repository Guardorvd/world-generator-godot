extends SceneTree
## Изолированный смешанный лес (дуб, берёза, сосна, 4 силуэта, разные размеры) на всей карте 1 км, без генерации мира.
## Камера стоит 5 с, потом едет 16 м/с. Печатает FPS, draw calls, GPU мс. Нужно окно. --density 1.0 --out <json>
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
var gpus := PackedFloat32Array()
var cpus := PackedFloat32Array()
var primitives := 0.0
var calls := 0.0
var phase := 0
var EYE := 32.0
var shot_done := false
var results := {}


func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 90)
	call_deferred("setup")


func setup() -> void:
	RenderingServer.viewport_set_measure_render_time(root.get_viewport_rid(), true)
	Engine.max_fps = 0
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	DisplayServer.window_set_size(Vector2i(1280, 720))
	world = _forest(float(Dev.arg("density", "1.0")))
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
	sun.shadow_enabled = not ("--noshadow" in OS.get_cmdline_user_args())
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
	EYE = float(Dev.arg("eye", "32"))
	last_us = Time.get_ticks_usec()
	results.objects = world.obj_count
	results.layer = layer.resource_path
	results.renderer = RenderingServer.get_current_rendering_method()


func _forest(density: float) -> WorldData:
	var w: WorldData = Test.fixture(0)
	w.biome.fill(Biomes.FOREST)
	var rng := RandomNumberGenerator.new()
	rng.seed = 77
	var kinds := [Biomes.T_OAK, Biomes.T_OAK, Biomes.T_BIRCH, Biomes.T_PINE, Biomes.T_PINE]
	for y in range(8, 248):
		for x in range(8, 248):
			var n := int(density) + (1 if rng.randf() < density - floorf(density) else 0)
			for i in n:
				var o := w.obj_x.size()
				w.obj_x.append(x + rng.randf())
				w.obj_y.append(y + rng.randf())
				w.obj_k.append(kinds[rng.randi() % kinds.size()])
				w.obj_v.append(rng.randi() % 4)
				w.obj_s.append(0.45 + rng.randf() * 1.1)
				w.chunks[(y / w.CS) * w.CW + x / w.CS].append(o)
	w.obj_count = w.obj_x.size()
	return w


func _process(delta: float) -> bool:
	if camera == null:
		return false
	elapsed += delta
	var z := 340.0 + maxf(0.0, elapsed - 5.0) * 16.0
	var gpu := RenderingServer.viewport_get_measured_render_time_gpu(root.get_viewport_rid())
	var cpu := RenderingServer.viewport_get_measured_render_time_cpu(root.get_viewport_rid())
	camera.look_at_from_position(Vector3(512, EYE, z), Vector3(512, EYE - 12.0, z + 80), Vector3.UP)
	var t0 := Time.get_ticks_usec()
	veg.update(512.0, z, false)
	if Dev.arg("hide") != "":
		for i in Dev.arg("hide").split(","):
			veg.understory[int(i)].mm.visible_instance_count = 0
	if Dev.arg("hidelod") != "":
		for key: Vector3i in veg.veg:
			for node: MultiMeshInstance3D in veg.veg[key].nodes:
				if node.get_meta("level", -1) == int(Dev.arg("hidelod")):
					node.visible = false
	if Dev.arg("nograss") != "":
		veg.grass.visible_instance_count = 0
	if "--nodetails" in OS.get_cmdline_user_args():
		veg.grass.visible_instance_count = 0
		for e: Dictionary in veg.understory:
			e.mm.visible_instance_count = 0
	var upload_ms := (Time.get_ticks_usec() - t0) / 1000.0
	var now := Time.get_ticks_usec()
	if elapsed > 2.0:
		frames.append((now - last_us) / 1000.0)
		submit.append(upload_ms)
		gpus.append(gpu)
		cpus.append(cpu)
		primitives += Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME)
		calls += Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)
	last_us = now
	if elapsed >= 4.5 and not shot_done and Dev.arg("shot") != "":
		shot_done = true
		var img := root.get_texture().get_image()
		img.save_png(ProjectSettings.globalize_path("res://").path_join(Dev.arg("shot")))
	if phase == 0 and elapsed >= 5.0:
		results.still = stats()
		results.nodes = _node_stats()
		phase = 1
		frames.clear()
		submit.clear()
		gpus.clear()
		cpus.clear()
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
		primitives = primitives / f.size(), gpu_ms = _mean(gpus), cpu_ms = _mean(cpus), draw_calls = calls / f.size(), batches = veg.veg.size()}


func _mean(a: PackedFloat32Array) -> float:
	var s := 0.0
	for v in a:
		s += v
	return s / maxf(1.0, a.size())


func _node_stats() -> Dictionary:
	var out := {}
	var chunks := {}
	for key: Vector3i in veg.veg:
		chunks[Vector2i(key.x, key.y)] = true
		for node: MultiMeshInstance3D in veg.veg[key].nodes:
			var l := "L%d" % node.get_meta("level", -1)
			out[l] = out.get(l, 0) + 1
	out.chunks = chunks.size()
	out.grass = veg.grass.visible_instance_count
	var under := []
	for e: Dictionary in veg.understory:
		var m: Mesh = e.mm.mesh
		var a := m.surface_get_arrays(0)
		var tris: int = (a[Mesh.ARRAY_INDEX].size() if a[Mesh.ARRAY_INDEX] != null else a[Mesh.ARRAY_VERTEX].size()) / 3
		under.append("%d x %d = %d (cap %d, shadow %d)" % [e.count, tris, e.count * tris, e.cap, e.node.cast_shadow])
	out.understory = under
	return out
