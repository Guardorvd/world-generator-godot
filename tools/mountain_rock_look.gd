extends SceneTree
## Изолированный стенд скалистых вершин (07.11.2026), без генерации мира: синтетический массив 640 м
## (скальный пояс, осыпь под ним, пологое плечо, вершина, тропа), настоящие материал рельефа,
## RockScatter, модели камней и выходов, раскладка VegetationLayer, препятствия велосипеда.
## «Было» — terrain.gdshader и rock_scatter.gd из коммита BASE (git show) в том же запуске.
## Снимки — пары было|стало в .godot/mountain_rock_look/<вид>.png. Нужно окно (без --headless).
## Ключи: -- --base <коммит> (по умолчанию версия до скальных выходов), -- --rules-only (без снимков).
const OUT := "res://.godot/mountain_rock_look"
const N := 160
const CS := 16
const Surface := preload("res://scripts/world/mountain_surface.gd")
var base_rev := "cb4622c"
var failures := 0
var camera: Camera3D
var scene: Node3D


func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 150)
	var args := OS.get_cmdline_user_args()
	var at := args.find("--base")
	if at >= 0 and at + 1 < args.size(): base_rev = args[at + 1]
	run.call_deferred()


func check(ok: bool, label: String) -> void:
	print("PASS " if ok else "FAIL ", label)
	failures += int(not ok)


## Высоты массива, м, в узлах клеток (как Heightfield.hv): купол, скальный пояс 118–140 м, гребень, ложбины.
func relief() -> PackedFloat32Array:
	var hv := PackedFloat32Array()
	hv.resize(N * N)
	for y in N:
		for x in N:
			var dx := x - 80.0
			var dy := (y - 76.0) * 1.15
			var ang := atan2(dy, dx)
			var r := sqrt(dx * dx + dy * dy) + 4.0 * sin(ang * 5.0 + 0.7) + 2.5 * sin(ang * 11.0)
			# Пологий купол (осыпной склон), скальный пояс 55 м на 40 м по радиусу, вершина.
			var h := 150.0 * exp(-pow(r / 70.0, 2.0)) + 55.0 * (1.0 - smoothstep(30.0, 40.0, r)) + 35.0 * exp(-pow(r / 14.0, 2.0))
			h += 4.0 * sin(x * 0.11 + y * 0.07) + 2.5 * sin(x * 0.23 - y * 0.19)
			hv[y * N + x] = h
	return hv


func fields(hv: PackedFloat32Array) -> Dictionary:
	var f := {biome = PackedByteArray(), river = PackedByteArray(), village = PackedByteArray(), path = PackedByteArray(),
		elev = PackedFloat32Array(), slope = PackedFloat32Array(), moist = PackedFloat32Array(), dw = PackedFloat32Array(),
		dist_path = PackedFloat32Array(), forest = PackedFloat64Array(), stony = PackedFloat64Array()}
	for key: String in f: f[key].resize(N * N)
	for i in N * N: f.elev[i] = hv[i] / GameConfig.HS
	for y in N:
		for x in N:
			var i := y * N + x
			var gx: float = f.elev[y * N + mini(N - 1, x + 1)] - f.elev[y * N + maxi(0, x - 1)]
			var gy: float = f.elev[mini(N - 1, y + 1) * N + x] - f.elev[maxi(0, y - 1) * N + x]
			f.slope[i] = sqrt(gx * gx + gy * gy) * 0.5 * 60.0
			# Влажность: вогнутые ложбины сырее, плюс медленные пятна.
			var lap := 0.0
			for o: Vector2i in [Vector2i(-2, 0), Vector2i(2, 0), Vector2i(0, -2), Vector2i(0, 2)]:
				lap += hv[clampi(y + o.y, 0, N - 1) * N + clampi(x + o.x, 0, N - 1)]
			lap = lap * 0.25 - hv[i]
			f.moist[i] = clampf(0.42 + lap * 0.06 + 0.12 * sin(x * 0.09 + 1.3) * sin(y * 0.08), 0.0, 1.0)
			var e: float = f.elev[i]
			f.biome[i] = Biomes.PEAK if e > 0.86 else (Biomes.ROCK if e > 0.3 else (Biomes.TUNDRA if e > 0.2 else Biomes.GRASS))
			f.dw[i] = 100.0
			f.dist_path[i] = absf(x - 112.0)
			f.path[i] = 3 if x == 112 else 0
			f.forest[i] = -0.6
			f.stony[i] = 0.25 + 0.3 * sin(x * 0.17 + y * 0.05) * sin(y * 0.13)
	f.rock = Surface.field(f.elev, f.slope, f.moist)
	return f


func scatter(script: Script, f: Dictionary, reverse := false) -> StageVegetation.ObjStore:
	var st := StageVegetation.ObjStore.new(null)
	var order: Array[Vector2i] = []
	for cy in N / CS:
		for cx in N / CS: order.append(Vector2i(cx, cy))
	if reverse: order.reverse()
	for c in order:
		st.begin_chunk(c.x * CS, c.y * CS, c.x * CS + CS, c.y * CS + CS)
		script.place_chunk(29, c.x * CS, c.y * CS, c.x * CS + CS, c.y * CS + CS, f, 0, 0, N, st)
	return st


func world_of(st: StageVegetation.ObjStore, f: Dictionary) -> WorldData:
	var w := WorldData.new()
	w.W = N
	w.H = N
	w.N = N * N
	w.CS = CS
	w.CW = N / CS
	w.CH = N / CS
	w.lake.resize(w.N)
	w.path_mask = f.path.duplicate()
	var lists: Array = []
	for c in w.CW * w.CH: lists.append([])
	for o in st.x.size():
		var c := floori(st.y[o] / CS) * w.CW + floori(st.x[o] / CS)
		lists[c].append(o)
	w.obj_x = st.x
	w.obj_y = st.y
	w.obj_k = st.k
	w.obj_v = st.v
	w.obj_s = st.s
	w.chunks = []
	for list: Array in lists: w.chunks.append(PackedInt32Array(list))
	return w


func run() -> void:
	DirAccess.make_dir_recursive_absolute(OUT)
	var old_scatter: Script = null
	var old_shader: Shader = null
	var output: Array = []
	if OS.execute("git", ["show", base_rev + ":scripts/world/rock_scatter.gd"], output) == 0:
		var source := str(output[0]).replace("class_name RockScatter", "").replace("store: StageVegetation.ObjStore", "store")
		FileAccess.open(OUT.path_join("rock_scatter_before.gd"), FileAccess.WRITE).store_string(source)
		old_scatter = load(OUT.path_join("rock_scatter_before.gd"))
	output.clear()
	if OS.execute("git", ["show", base_rev + ":resources/terrain.gdshader"], output) == 0:
		old_shader = Shader.new()
		old_shader.code = str(output[0])
	# Freeze seating and rendering too; otherwise a baseline with outcrops silently used new poses.
	var old_layer: Script
	for pair: Array in [["rock_models.gd", "scripts/render/rock_models.gd"], ["vegetation_layer.gd", "scripts/render/vegetation_layer.gd"]]:
		output.clear()
		if OS.execute("git", ["show", base_rev + ":" + pair[1]], output) != 0: continue
		var source := str(output[0]).replace("class_name RockModels", "").replace("class_name VegetationLayer", "")
		if pair[0] == "vegetation_layer.gd":
			source = source.replace("extends Node3D", "extends Node3D\nconst PriorRockModels := preload(\"res://.godot/mountain_rock_look/rock_models_before.gd\")").replace("RockModels.", "PriorRockModels.")
		FileAccess.open(OUT.path_join(pair[0].replace(".gd", "_before.gd")), FileAccess.WRITE).store_string(source)
	old_layer = load(OUT.path_join("vegetation_layer_before.gd"))
	check(old_scatter != null and old_shader != null and old_layer != null, "baseline " + base_rev + " available")
	if old_scatter == null or old_shader == null or old_layer == null:
		quit(1)
		return
	var hv := relief()
	var f := fields(hv)
	var h := Heightfield.new()
	var st_after := scatter(RockScatter, f)
	var w := world_of(st_after, f)
	h.world = w
	h.hv = hv
	# Правила: повтор, порядок чанков, тропа, выходы только где есть опора, ни одного висящего края.
	var again := scatter(RockScatter, f, true)
	var a := PackedStringArray()
	var b := PackedStringArray()
	for o in st_after.x.size(): a.append("%.9f %.9f %.9f %d" % [st_after.x[o], st_after.y[o], st_after.s[o], st_after.v[o]])
	for o in again.x.size(): b.append("%.9f %.9f %.9f %d" % [again.x[o], again.y[o], again.s[o], again.v[o]])
	a.sort()
	b.sort()
	check(a == b, "deterministic and independent of chunk order")
	var outcrops := 0
	var seated := 0
	var floating := 0
	var on_path := 0
	var steep_boulders := 0
	var sample := func(px: float, pz: float) -> Vector2: return Vector2(h.ground_at(px, pz), h.depth_at(px, pz))
	for o in st_after.x.size():
		var rs: float = st_after.s[o] * 1.2
		if RockModels.is_outcrop(st_after.v[o]):
			outcrops += 1
			if not RockScatter.clear_path(f.path, 0, 0, N, st_after.x[o], st_after.y[o], st_after.s[o] * RockScatter.OUTCROP_CLEAR): on_path += 1
			var seat := RockModels.seat(h, st_after.x[o] * 4.0, st_after.y[o] * 4.0, rs, st_after.v[o])
			if seat.x == INF: continue
			seated += 1
			var up := Vector3(seat.y, seat.z, seat.w)
			var basis := RockModels.outcrop_transform(st_after.x[o] * 4.0, st_after.y[o] * 4.0, rs, up, seat.x).basis
			for n in 40:
				var off := basis * Vector3(cos(n * TAU / 40.0) * RockModels.OUTCROP_R, RockModels.OUTCROP_ANCHOR_Y, sin(n * TAU / 40.0) * RockModels.OUTCROP_R)
				var g: Vector2 = sample.call(st_after.x[o] * 4.0 + off.x, st_after.y[o] * 4.0 + off.z)
				if seat.x + off.y > g.x + 0.15: floating += 1
		elif RockModels.seat(h, st_after.x[o] * 4.0, st_after.y[o] * 4.0, rs, st_after.v[o]).x != INF:
			if RockModels.normal_at(h, st_after.x[o] * 4.0, st_after.y[o] * 4.0).y < 0.74: steep_boulders += 1
	print("ROCKS after=", st_after.x.size(), " outcrops=", outcrops, " seated=", seated)
	check(outcrops > 20 and seated > outcrops / 3, "a supported outcrop population remains on the cliff band")
	check(floating == 0, "outcrop base ring stays at or below ground (40 points)")
	check(on_path == 0, "outcrops keep clear of the trail")
	check(steep_boulders == 0, "ordinary boulders keep their support rule")
	var obstacles := ForestObstacles.new(w, h)
	var ring := 0
	for o in st_after.x.size():
		if RockModels.is_outcrop(st_after.v[o]) and RockModels.seat(h, st_after.x[o] * 4.0, st_after.y[o] * 4.0, st_after.s[o] * 1.2, st_after.v[o]).x != INF:
			obstacles.update(st_after.x[o] * 4.0, st_after.y[o] * 4.0, PackedFloat32Array(), 0, true)
			ring = obstacles.data.size() / ForestObstacles.STRIDE
			break
	check(ring > 0, "seated outcrop blocks the bike")
	var st_before: StageVegetation.ObjStore = scatter(old_scatter, f) if old_scatter != null else null
	if "--rules-only" in OS.get_cmdline_user_args() or st_before == null:
		quit(1 if failures else 0)
		return
	print("ROCKS before=", st_before.x.size())
	await shots(f, hv, h, w, world_of(st_before, f), old_shader, old_layer)
	print("MOUNTAIN ROCK LOOK ", failures, " failures")
	quit(1 if failures else 0)


func shots(f: Dictionary, hv: PackedFloat32Array, h: Heightfield, w_after: WorldData, w_before: WorldData, old_shader: Shader, old_layer: Script) -> void:
	root.size = Vector2i(1280, 720)
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	RenderingServer.viewport_set_measure_render_time(root.get_viewport_rid(), true)
	RenderingServer.global_shader_parameter_set("cloud_shadow", Vector4.ZERO)
	scene = Node3D.new()
	root.add_child(scene)
	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	env.environment.background_mode = Environment.BG_COLOR
	env.environment.background_color = Color("a9c4d8")
	env.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.environment.ambient_light_color = Color("d4dfeb")
	env.environment.ambient_light_energy = 0.55
	env.environment.fog_enabled = true
	env.environment.fog_light_color = Color("b8cad8")
	env.environment.fog_density = 0.0007
	scene.add_child(env)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-34, -58, 0)
	sun.light_energy = 1.3
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 400.0
	scene.add_child(sun)
	camera = Camera3D.new()
	camera.fov = 68
	camera.far = 4000
	scene.add_child(camera)
	var base := Image.create(N, N, false, Image.FORMAT_RGB8)
	var forest := Image.create(N, N, false, Image.FORMAT_RGBA8)
	for y in N:
		for x in N:
			var i := y * N + x
			var rgb: Array = Biomes.LIST[f.biome[i]].color
			base.set_pixel(x, y, Color8(rgb[0], rgb[1], rgb[2]))
			forest.set_pixel(x, y, Color(0, 0, f.moist[i], f.rock[i] / 255.0))
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, TerrainBuilder.build_arrays(w_after, h))
	var builder := TerrainBuilder.new()
	var defs := Models.tree_defs()
	var rock_defs := {}
	for key: int in defs:
		if key % ForestModels.MODEL_STRIDE == Biomes.T_ROCK: rock_defs[key] = defs[key]
	# Камеры по самому массиву: луч от вершины на юго-восток, на нём круча, осыпь и плечо.
	var top := Vector2(80, 76) * 4.0
	var dir := Vector2(0.55, 0.83).normalized()
	var cliff_at := top
	var steepest := 0.0
	for r in range(20, 300, 2):
		var pt := top + dir * r
		var n := RockModels.normal_at(h, pt.x, pt.y)
		if n.y < 1.0 - steepest:
			steepest = 1.0 - n.y
			cliff_at = pt
	var g := func(pt: Vector2, above: float) -> Vector3: return Vector3(pt.x, h.ground_at(pt.x, pt.y) + above, pt.y)
	var side := Vector2(-dir.y, dir.x)
	var views := {
		far = [g.call(top + dir * 560 + side * 160, 170.0), g.call(top + dir * 40, 0.0)],
		face = [g.call(cliff_at + dir * 110 + side * 45, 22.0), g.call(cliff_at - dir * 10, 4.0)],
		talus = [g.call(cliff_at + dir * 34 + side * 8, 2.2), g.call(cliff_at - dir * 2, 6.0)],
		shoulder = [g.call(cliff_at - dir * 62 + side * 25, 1.8), g.call(cliff_at - dir * 150 - side * 30, 5.0)],
		rider = [g.call(Vector2(112.5 * 4.0, cliff_at.y + 70.0), 1.8), g.call(Vector2(112.5 * 4.0, cliff_at.y - 10.0), 1.0)],
	}
	# Ближний вид на скальный выход у кручи (вид «было» показывает то же место без него).
	var near_outcrop := cliff_at
	var best := INF
	for o in w_after.obj_x.size():
		if not RockModels.is_outcrop(w_after.obj_v[o]): continue
		var at := Vector2(w_after.obj_x[o], w_after.obj_y[o]) * 4.0
		if RockModels.seat(h, at.x, at.y, w_after.obj_s[o] * 1.2, w_after.obj_v[o]).x == INF: continue
		if at.distance_to(cliff_at) < best:
			best = at.distance_to(cliff_at)
			near_outcrop = at
	views.outcrop = [g.call(near_outcrop + dir * 10 + side * 5, 3.0), g.call(near_outcrop, 1.2)]
	var images := {}
	for version in ["before", "after"]:
		var mat := builder.material(base.duplicate(), forest)
		if version == "before": mat.shader = old_shader
		var terrain := MeshInstance3D.new()
		terrain.mesh = mesh
		terrain.material_override = mat
		scene.add_child(terrain)
		var w: WorldData = w_before if version == "before" else w_after
		h.world = w
		var layer: Node3D = old_layer.new() if version == "before" else VegetationLayer.new()
		var rocks := layer
		scene.add_child(rocks)
		layer.setup(w, h, rock_defs, Models.grass_mesh(), forest)
		var instances := 0
		var outcrop_instances := 0
		for cy in w.CH:
			for cx in w.CW:
				var built: Dictionary = layer._build_chunk(Vector2i(cx, cy))
				for entry: Dictionary in built.entries:
					instances += entry.count
					if entry.kind >= VegetationLayer.OUTCROP_MODEL: outcrop_instances += entry.count
				layer._apply_chunk(built)
		print("RENDER ", version, " instances=", instances, " outcrops=", outcrop_instances)
		for view: String in views:
			camera.look_at_from_position(views[view][0], views[view][1], Vector3.UP)
			RenderingServer.global_shader_parameter_set("veg_center", Vector2(camera.position.x, camera.position.z))
			for frame in 4: await process_frame
			var started := Time.get_ticks_usec()
			for frame in 8: await process_frame
			var frame_ms := (Time.get_ticks_usec() - started) / 8000.0
			await RenderingServer.frame_post_draw
			var img := root.get_texture().get_image()
			img.convert(Image.FORMAT_RGBA8)
			img.resize(640, 360, Image.INTERPOLATE_LANCZOS)
			images[view + version] = img
			print("SHOT ", view, " ", version, " frame_ms=", snappedf(frame_ms, 0.1), " draw_calls=", RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME),
				" primitives=", RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_PRIMITIVES_IN_FRAME))
		# Travel through both production LOD transition bands, with actual GPU timings.
		var cpu := 0.0; var gpu := 0.0; var frames := 0; var peak_ms := 0.0
		var started := Time.get_ticks_usec()
		var last := started
		while Time.get_ticks_usec() - started < 3000000:
			var t := (Time.get_ticks_usec() - started) / 3000000.0
			camera.look_at_from_position(g.call(near_outcrop + dir * lerpf(210.0, 25.0, t) + side * 8, 3.0), g.call(near_outcrop, 1.0))
			RenderingServer.global_shader_parameter_set("veg_center", Vector2(camera.position.x, camera.position.z))
			await process_frame
			var now := Time.get_ticks_usec()
			peak_ms = maxf(peak_ms, (now - last) / 1000.0); last = now
			cpu += RenderingServer.viewport_get_measured_render_time_cpu(root.get_viewport_rid())
			gpu += RenderingServer.viewport_get_measured_render_time_gpu(root.get_viewport_rid())
			frames += 1
		print("MOTION ", version, " frames=", frames, " render_cpu_ms=", cpu / frames, " gpu_ms=", gpu / frames, " peak_frame_ms=", peak_ms)
		terrain.queue_free()
		rocks.queue_free()
		await process_frame
	h.world = w_after
	for view: String in views:
		var sheet := Image.create(1280, 360, false, Image.FORMAT_RGBA8)
		sheet.blit_rect(images[view + "before"], Rect2i(0, 0, 640, 360), Vector2i.ZERO)
		sheet.blit_rect(images[view + "after"], Rect2i(0, 0, 640, 360), Vector2i(640, 0))
		sheet.save_png(OUT.path_join(view + ".png"))
	print("SHEETS ", ProjectSettings.globalize_path(OUT))
