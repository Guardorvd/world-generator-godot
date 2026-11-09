extends SceneTree
## 16.0: изолированная сцена растительности открытых мест, без генерации мира (~40 с, нужно окно).
## Синтетическая карта 1 км: луг с влажностью от сухого к сырому, дорога через луг, лес с тропой
## (опушки), сырая низина у воды, предгорный склон до скал, полоса степи. Тот же VegetationLayer,
## что в игре. Снимки с высоты велосипедиста (1,5 м) и замер в движении с поворотами камеры.
##   --legacy        «было»: открытые места без сообществ (как до 16.0), тот же код и модели
##   --flora 0|1|2   качество растительности (GameSettings.FLORA_LEVELS), по умолчанию 2
##   --tag <имя>     подпись снимков и замера (.godot/meadow_look/<tag>_*.png, <tag>.json)
##   --compose a,b   склеить снимки двух прогонов попарно (было | стало), без сцены
##   --no-perf       только снимки

const Dev := preload("res://tools/control/control.gd")
const OUT := "res://.godot/meadow_look"
const EYE := 1.5
## Виды: имя, позиция камеры (клетки), направление взгляда (клетки)
const VIEWS := [
	["meadow", Vector2(40, 96), Vector2(110, 120)],
	["forest_trail", Vector2(190.5, 26), Vector2(190.5, 70)],
	["foothill", Vector2(140, 196), Vector2(210, 214)],
	["wet", Vector2(60, 150), Vector2(66, 172)],
	["road", Vector2(10, 140.5), Vector2(80, 140.5)],
]
var world: WorldData
var heights: Heightfield
var veg: VegetationLayer
var camera: Camera3D
var tag := "after"
var phase := -1
var view := 0
var wait := 0
var elapsed := 0.0
var last_us := 0
var frames := PackedFloat32Array()
var gpus := PackedFloat32Array()
var cpus := PackedFloat32Array()
var calls := 0.0
var prims := 0.0
var fill_max := 0.0
var results := {}


func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 120)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT))
	if Dev.arg("compose") != "":
		_compose(Dev.arg("compose").split(","))
		quit()
		return
	call_deferred("setup")


func setup() -> void:
	tag = Dev.arg("tag", "after")
	VegetationLayer.legacy_open = "--legacy" in OS.get_cmdline_user_args()
	RenderingServer.viewport_set_measure_render_time(root.get_viewport_rid(), true)
	Engine.max_fps = 0
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	DisplayServer.window_set_size(Vector2i(1280, 720))
	world = _world()
	heights = Heightfield.new(world, false)
	veg = VegetationLayer.new()
	root.add_child(veg)
	var t0 := Time.get_ticks_usec()
	veg.setup(world, heights, Models.tree_defs(), Models.grass_mesh())
	results.setup_ms = (Time.get_ticks_usec() - t0) / 1000.0
	veg.set_flora(int(Dev.arg("flora", "2")))
	root.add_child(_ground())
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-42, -35, 0)
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 100.0
	root.add_child(sun)
	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	env.environment.background_mode = Environment.BG_COLOR
	env.environment.background_color = Color("a9c4dc")
	env.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.environment.ambient_light_color = Color("e6e5dc")
	env.environment.ambient_light_energy = 0.6
	env.environment.fog_enabled = true
	env.environment.fog_light_color = Color("b9cbdb")
	env.environment.fog_density = 0.0016
	root.add_child(env)
	camera = Camera3D.new()
	camera.fov = 70.0
	camera.far = 800.0
	root.add_child(camera)
	camera.current = true
	results.legacy = VegetationLayer.legacy_open
	results.flora = veg.flora_level
	phase = 0
	_goto(0)


func _goto(v: int) -> void:
	view = v
	var at: Vector2 = VIEWS[v][1] * GameConfig.TILE
	var look: Vector2 = VIEWS[v][2] * GameConfig.TILE
	var y := heights.ground_at(at.x, at.y) + EYE
	camera.look_at_from_position(Vector3(at.x, y, at.y), Vector3(look.x, heights.ground_at(look.x, look.y) + EYE * 0.8, look.y), Vector3.UP)
	var t0 := Time.get_ticks_usec()
	veg.update(at.x, at.y, true)
	fill_max = maxf(fill_max, (Time.get_ticks_usec() - t0) / 1000.0)
	wait = 0


func _process(delta: float) -> bool:
	if phase < 0:
		return false
	if phase == 0:
		veg.update(camera.position.x, camera.position.z, false)
		wait += 1
		if wait < 40:
			return false
		root.get_texture().get_image().save_png(ProjectSettings.globalize_path(OUT).path_join("%s_%s.png" % [tag, VIEWS[view][0]]))
		if view == 0:
			results.instances = _counts()
		if view + 1 < VIEWS.size():
			_goto(view + 1)
			return false
		if "--no-perf" in OS.get_cmdline_user_args():
			return _finish()
		phase = 1
		elapsed = 0.0
		_goto(0)
		last_us = Time.get_ticks_usec()
		return false
	# Замер: езда 12 м/с по лугу вдоль дороги, камера рыскает ±70° (резкие повороты), 8 с.
	elapsed += delta
	var x := 40.0 * GameConfig.TILE + elapsed * 12.0
	var z := 132.0 * GameConfig.TILE
	var yaw := sin(elapsed * 1.7) * 1.2
	var y := heights.ground_at(x, z) + EYE
	camera.look_at_from_position(Vector3(x, y, z), Vector3(x + cos(yaw) * 30.0, y - 1.0, z + sin(yaw) * 30.0), Vector3.UP)
	veg.update(x, z, false)
	if Dev.arg("hide-base") != "":
		# отладка: какие формы стоят кадра (по номеру формы, ближняя и дальняя вместе)
		for e: Dictionary in veg.understory:
			if str(e.base) in Dev.arg("hide-base").split(","):
				e.mm.visible_instance_count = 0
	var now := Time.get_ticks_usec()
	if elapsed > 1.0:
		frames.append((now - last_us) / 1000.0)
		gpus.append(RenderingServer.viewport_get_measured_render_time_gpu(root.get_viewport_rid()))
		cpus.append(RenderingServer.viewport_get_measured_render_time_cpu(root.get_viewport_rid()))
		calls += Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)
		prims += Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME)
	last_us = now
	if elapsed < 9.0:
		return false
	var f := frames.duplicate()
	f.sort()
	var sum := 0.0
	for ms in f:
		sum += ms
	results.moving = {fps = 1000.0 * f.size() / maxf(sum, 0.001), p95_ms = f[int(f.size() * 0.95)], p99_ms = f[int(f.size() * 0.99)],
		gpu_ms = _mean(gpus), cpu_ms = _mean(cpus), draw_calls = calls / f.size(), primitives = prims / f.size(),
		detail_fill_s = veg._detail_seconds, video_mb = Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED) / 1048576.0,
		static_mb = Performance.get_monitor(Performance.MEMORY_STATIC) / 1048576.0}
	results.force_fill_max_ms = fill_max
	results.fill_parts = veg.fill_stats
	return _finish()


func _finish() -> bool:
	print(JSON.stringify(results))
	Dev.save_json(ProjectSettings.globalize_path(OUT).path_join(tag + ".json"), results)
	veg.queue_free()
	quit()
	return true


func _mean(a: PackedFloat32Array) -> float:
	var s := 0.0
	for v in a:
		s += v
	return s / maxf(1.0, a.size())


## Число экземпляров по формам подлеска и травы в первом виде
func _counts() -> Dictionary:
	var out := {grass = veg.grass.visible_instance_count}
	var total := 0
	for n in veg.understory.size():
		var e: Dictionary = veg.understory[n]
		if e.count > 0:
			var m: Mesh = e.mm.mesh
			var a := m.surface_get_arrays(0)
			var tris: int = (a[Mesh.ARRAY_INDEX].size() if a[Mesh.ARRAY_INDEX] != null else a[Mesh.ARRAY_VERTEX].size()) / 3
			out["form_%d%s" % [e.base, "" if n == e.base else "_far"]] = "%d x %d" % [e.count, tris]
			total += e.count * tris
	out.understory_triangles = total
	return out


## Синтетический мир: 256 × 256 клеток (1 км)
func _world() -> WorldData:
	var w := WorldData.new()
	w.W = 256
	w.H = 256
	w.N = w.W * w.H
	w.CS = WorldData.CHUNK_SIZE
	w.CW = w.W / w.CS
	w.CH = w.H / w.CS
	w.seed_num = 4821
	for key in ["h", "filled", "elev", "temp", "moist", "slope", "dist_water"]:
		var a := PackedFloat32Array()
		a.resize(w.N)
		w.set(key, a)
	for key in ["biome", "ocean", "lake", "river", "path_mask"]:
		var a := PackedByteArray()
		a.resize(w.N)
		w.set(key, a)
	for c in w.CW * w.CH:
		w.chunks.append(PackedInt32Array())
	for y in w.H:
		for x in w.W:
			var k := y * w.W + x
			# Предгорье: подъём к юго-востоку, выше 0,4 — скалы
			var hill := smoothstep(140.0, 250.0, float(x)) * smoothstep(150.0, 250.0, float(y))
			var hollow := exp(-pow((y - 167.0) / 7.0, 2.0)) * smoothstep(10.0, 30.0, float(x)) * (1.0 - smoothstep(110.0, 130.0, float(x)))
			var e := 0.06 + 0.42 * hill - 0.025 * hollow + 0.01 * sin(x * 0.11) * cos(y * 0.07)
			w.elev[k] = e
			w.h[k] = e
			w.filled[k] = e
			w.temp[k] = 0.55
			w.moist[k] = clampf(0.35 + 0.004 * x * (1.0 - hill) + 0.5 * hollow - 0.15 * hill, 0.1, 0.95)
			w.dist_water[k] = 0.5 + absf(y - 167.0) * 0.6 if x > 15 and x < 125 else 30.0
			var b := Biomes.GRASS
			if x >= 150 and x < 230 and y >= 16 and y < 124:
				b = Biomes.FOREST
			elif e > 0.4:
				b = Biomes.ROCK
			elif x < 60 and y >= 200:
				b = Biomes.STEPPE
			w.biome[k] = b
			if y == 140 and x < 150:
				w.path_mask[k] = 3 # дорога через луг
			if x == 190 and y >= 16 and y < 124:
				w.path_mask[k] = 2 # тропа через лес
	for k in w.N:
		var x := k % w.W
		var y := k / w.W
		var gx := (w.elev[y * w.W + mini(w.W - 1, x + 1)] - w.elev[y * w.W + maxi(0, x - 1)]) * 30.0
		var gy := (w.elev[mini(w.H - 1, y + 1) * w.W + x] - w.elev[maxi(0, y - 1) * w.W + x]) * 30.0
		w.slope[k] = sqrt(gx * gx + gy * gy)
	# Лес: дуб, берёза, сосна; редкие деревья и кусты на лугу (как Biomes «Луга»)
	var rng := RandomNumberGenerator.new()
	rng.seed = 77
	var kinds := [Biomes.T_OAK, Biomes.T_OAK, Biomes.T_BIRCH, Biomes.T_PINE]
	for y in w.H:
		for x in w.W:
			var b := w.biome[y * w.W + x]
			var p := 0.55 if b == Biomes.FOREST else (0.012 if b == Biomes.GRASS else 0.0)
			if absf(x - 190.5) < 1.2 and b == Biomes.FOREST:
				p = 0.0
			if rng.randf() >= p:
				continue
			var o := w.obj_x.size()
			w.obj_x.append(x + rng.randf())
			w.obj_y.append(y + rng.randf())
			w.obj_k.append(kinds[rng.randi() % kinds.size()] if b == Biomes.FOREST else [Biomes.T_OAK, Biomes.T_BIRCH, Biomes.T_BUSH][rng.randi() % 3])
			w.obj_v.append(rng.randi() % 4)
			w.obj_s.append(0.6 + rng.randf() * 0.8)
			w.chunks[(y / w.CS) * w.CW + x / w.CS].append(o)
	w.obj_count = w.obj_x.size()
	return w


## Рельеф: меш по высотам клеток, цвет — биом
func _ground() -> MeshInstance3D:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var step := 2
	for y in range(0, world.H - step, step):
		for x in range(0, world.W - step, step):
			for c: Vector2i in [Vector2i(0, 0), Vector2i(step, 0), Vector2i(step, step), Vector2i(0, 0), Vector2i(step, step), Vector2i(0, step)]:
				var px := (x + c.x + 0.5) * GameConfig.TILE
				var pz := (y + c.y + 0.5) * GameConfig.TILE
				var b: Array = Biomes.LIST[world.biome[(y + c.y) * world.W + x + c.x]].color
				st.set_color(Color(b[0] / 255.0, b[1] / 255.0, b[2] / 255.0) * 0.8)
				st.set_normal(Vector3.UP)
				st.add_vertex(Vector3(px, heights.ground_at(px, pz) - 0.02, pz))
	st.generate_normals()
	var node := MeshInstance3D.new()
	node.mesh = st.commit()
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.roughness = 1.0
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	node.material_override = mat
	return node


## Было | стало: снимки двух прогонов рядом, по виду на файл
func _compose(tags: PackedStringArray) -> void:
	var dir := ProjectSettings.globalize_path(OUT)
	for v: Array in VIEWS:
		var a := Image.load_from_file(dir.path_join("%s_%s.png" % [tags[0], v[0]]))
		var b := Image.load_from_file(dir.path_join("%s_%s.png" % [tags[1], v[0]]))
		if a == null or b == null:
			continue
		a.resize(640, 360)
		b.resize(640, 360)
		var out := Image.create(1288, 360, false, a.get_format())
		out.fill(Color.WHITE)
		out.blit_rect(a, Rect2i(0, 0, 640, 360), Vector2i(0, 0))
		out.blit_rect(b, Rect2i(0, 0, 640, 360), Vector2i(648, 0))
		out.save_png(dir.path_join("compare_%s.png" % v[0]))
	print("composed")
