extends SceneTree
## Изолированная проверка камней: раскладка, ограничения, LOD и снимки без генерации мира.
var out := "res://tools/control/runs/rocks"
var camera: Camera3D
var failures := 0
var baseline := ""
var metrics := {}

func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var at := args.find("--out")
	if at >= 0 and at + 1 < args.size(): out = args[at + 1]
	at = args.find("--baseline")
	if at >= 0 and at + 1 < args.size(): baseline = args[at + 1]
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(out))
	root.size = Vector2i(1280, 720)
	call_deferred("_run")


func _check(ok: bool, label: String) -> void:
	print("rock_look: ", "PASS " if ok else "FAIL ", label)
	if not ok: failures += 1


func _fields(side := 32) -> Dictionary:
	var f := {}
	for key in ["biome", "river", "village"]:
		var a := PackedByteArray()
		a.resize(side * side)
		a.fill(Biomes.GRASS if key == "biome" else 0)
		f[key] = a
	for key in ["stony", "forest", "elev", "slope", "dw", "dist_path"]:
		var a := PackedFloat32Array()
		a.resize(side * side)
		a.fill(100.0 if key in ["dw", "dist_path"] else 0.1)
		f[key] = a
	# Производственные поля шумов — Float64, остальные непрерывные поля — Float32.
	for key in ["stony", "forest"]:
		var a := PackedFloat64Array()
		a.resize(side * side)
		a.fill(0.1)
		f[key] = a
	return f


func _scatter(f: Dictionary, seed_num := 17) -> StageVegetation.ObjStore:
	var store := StageVegetation.ObjStore.new(null)
	store.begin_chunk(0, 0, 32, 32)
	RockScatter.place_chunk(seed_num, 0, 0, 32, 32, f, 0, 0, 32, store)
	return store


func _rules() -> void:
	var f := _fields()
	var field := _scatter(f)
	var again := _scatter(f)
	_check(var_to_bytes(field.x) == var_to_bytes(again.x) and var_to_bytes(field.s) == var_to_bytes(again.s), "deterministic placement")
	f.dist_path.fill(1.0)
	var shoulder := _scatter(f)
	_check(shoulder.x.size() > field.x.size() * 2, "road shoulders denser than field")
	f.dist_path.fill(100.0)
	f.elev.fill(0.4)
	f.stony.fill(0.5)
	var mountain := _scatter(f)
	_check(mountain.x.size() > field.x.size() * 2, "mountain patches denser than field")
	var big := 0
	var small := 0
	for s: float in mountain.s:
		if s > 0.65: big += 1
		if s < 0.3: small += 1
	_check(big > 0 and small > big, "large anchors and smaller fragments")
	for key in ["river", "village", "slope", "dw", "dist_path"]:
		var blocked := f.duplicate(true)
		blocked[key].fill(0.0 if key in ["dw", "dist_path"] else (2.0 if key == "slope" else 1))
		_check(_scatter(blocked).x.is_empty(), "exclude " + key)
	_check(RockModels.supported(Vector3.UP) and not RockModels.supported(Vector3(1, 0.2, 0).normalized()), "reject cliffs")
	print("rock_look: field=", field.x.size(), " shoulder=", shoulder.x.size(), " mountain=", mountain.x.size())
	var wet := f.duplicate(true)
	wet.biome.fill(Biomes.SWAMP)
	_check(_scatter(wet).x.size() < mountain.x.size(), "wetland reduces rock density")
	var shifted := f.duplicate(true)
	var neg := StageVegetation.ObjStore.new(null)
	neg.begin_chunk(-32, -32, 0, 0)
	RockScatter.place_chunk(17, -32, -32, 0, 0, shifted, -32, -32, 32, neg)
	_check(not neg.x.is_empty(), "negative world coordinates")
	var road_mask := PackedByteArray()
	road_mask.resize(1024)
	for y in 32: road_mask[y * 32 + 16] = 3
	_check(not RockScatter.clear_path(road_mask, 0, 0, 32, 15.6, 12.0, 2.0) and RockScatter.clear_path(road_mask, 0, 0, 32, 14.0, 12.0, 0.2), "road clearance includes full rock radius")
	f.path = road_mask
	f.dist_path.fill(1.0)
	var roadside := _scatter(f)
	var clear := true
	for o in roadside.x.size():
		clear = clear and RockScatter.clear_path(road_mask, 0, 0, 32, roadside.x[o], roadside.y[o], roadside.s[o])
	_check(clear and not roadside.x.is_empty(), "outer road mask protects anchors and fragments")
	_check(_chunk_pattern(f, false) == _chunk_pattern(f, true), "chunk scheduling order preserves placement")


func _chunk_pattern(f: Dictionary, reverse: bool) -> PackedStringArray:
	var result := PackedStringArray()
	var chunks := [Vector2i(0, 0), Vector2i(16, 0), Vector2i(0, 16), Vector2i(16, 16)]
	if reverse: chunks.reverse()
	for at: Vector2i in chunks:
		var st := StageVegetation.ObjStore.new(null)
		st.begin_chunk(at.x, at.y, at.x + 16, at.y + 16)
		RockScatter.place_chunk(17, at.x, at.y, at.x + 16, at.y + 16, f, 0, 0, 32, st)
		for i in st.x.size(): result.append("%.12f,%.12f,%.12f,%d" % [st.x[i], st.y[i], st.s[i], st.v[i]])
	result.sort()
	return result


func _mesh(mesh: Mesh, at: Vector3, material: Material) -> MeshInstance3D:
	var node := MeshInstance3D.new()
	node.mesh = mesh
	node.material_override = material
	node.position = at
	root.add_child(node)
	return node


func _integration() -> void:
	var w := WorldData.new()
	w.W = 32
	w.H = 32
	w.N = 1024
	w.CS = 32
	w.CW = 1
	w.CH = 1
	w.lake.resize(w.N)
	w.path_mask.resize(w.N)
	w.obj_x = PackedFloat64Array([10.0, 12.0, 14.0])
	w.obj_y = PackedFloat64Array([10.0, 10.0, 10.0])
	w.obj_k = PackedInt32Array([Biomes.T_ROCK, Biomes.T_ROCK, Biomes.T_ROCK])
	w.obj_v = PackedInt32Array([0, 1, 2])
	w.obj_s = PackedFloat64Array([0.1, 1.0, 1.0])
	w.chunks = [PackedInt32Array([0, 1, 2])]
	var h := Heightfield.new()
	h.world = w
	h.hv.resize(w.N)
	h.hv.fill(4.0)
	for y in 32:
		for x in range(14, 32): h.hv[y * 32 + x] = 4.0 + (x - 13) * 8.0
	_check(RockModels.has_seat(h, 48, 40, 1.2) and not RockModels.has_seat(h, 56, 40, 1.2), "footprint on real heightfield")
	var layer := VegetationLayer.new()
	layer.world = w
	layer.heights = h
	for variant in RockModels.VARIANTS:
		var mesh := RockModels.mesh(Vector3(1.3, 0.78, 1.05), 72 + variant, 0.24)
		var mats: Array[ShaderMaterial] = []
		for level in 3:
			var m := ShaderMaterial.new()
			m.shader = preload("res://resources/rock.gdshader")
			m.set_shader_parameter("lod_level", level)
			mats.append(m)
		layer._defs[Biomes.T_ROCK + variant * ForestModels.MODEL_STRIDE] = {crown = mesh, box = mesh.get_aabb(), leaves = [Color.WHITE], crown_mats = mats}
	var built := layer._build_chunk(Vector2i.ZERO)
	var count := 0
	var pebble_y := -INF
	for entry: Dictionary in built.entries:
		count += entry.count
		for n in entry.count:
			if is_equal_approx(entry.cbuf[n * 16 + 3], 40.0): pebble_y = entry.cbuf[n * 16 + 7]
	_check(count == 2 and pebble_y > 3.98, "render rejects cliff and keeps pebble above ground")
	var collisions := ForestObstacles.new(w, h)
	collisions.update(48, 40, PackedFloat32Array(), 0, true)
	_check(collisions.data.size() == ForestObstacles.STRIDE, "only supported large rock blocks player")
	var placement := preload("res://scripts/render/vegetation_placement.gd").new(w, h)
	placement.prepare(48, 40, 24)
	var occupants := 0
	for cell: Array in placement._cells.values(): occupants += cell.size() / 4
	_check(occupants == 2, "rejected cliff rock does not clear plants")
	# Проверяем реальный перенос буферов: у группы мелочи один узел, у валунов три.
	root.add_child(layer)
	layer._apply_chunk(built, 0)
	var small_nodes := 0
	var large_nodes := 0
	var small_shadow := false
	for entry: Dictionary in layer.veg.values():
		if entry.small_rocks:
			small_nodes += entry.nodes.size()
			for node: MultiMeshInstance3D in entry.nodes:
				small_shadow = small_shadow or node.cast_shadow != GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		else: large_nodes += entry.nodes.size()
	_check(small_nodes == 1 and large_nodes == 3 and not small_shadow, "pebbles: one mesh and no shadows; boulders: three LOD")
	# Снимок за краем карты: world.outer отсутствует, доступно только переданное поле.
	var raw := PackedFloat32Array()
	raw.resize(20 * 20)
	raw.fill(4.0 / GameConfig.HS)
	var snapshot := {h = raw, side = 20, x0 = 30, y0 = -2, x = PackedFloat64Array([32.15, 47.85]), y = PackedFloat64Array([8, 8]), k = PackedInt32Array([Biomes.T_ROCK, Biomes.T_ROCK]), v = PackedInt32Array([0, 1]), s = PackedFloat64Array([2, 2])}
	# У стыка снимок и готовая карта имеют одинаковую высоту.
	h.hv.fill(4.0)
	var outer := layer._build_outer_snapshot(Vector2i(2, 0), snapshot)
	_check(outer.outer.x.size() == 2, "outer footprint uses snapshot at both chunk edges")
	var flooded := snapshot.duplicate(true)
	flooded.water = PackedFloat32Array()
	flooded.water.resize(400)
	flooded.water.fill(6.0 / GameConfig.HS)
	_check(layer._build_outer_snapshot(Vector2i(2, 0), flooded).outer.x.is_empty(), "snapshot rejects inland water without live world access")
	layer.free()


func _time_scatter(builder: Callable, f: Dictionary, side: int) -> Dictionary:
	var count := 0
	var start := Time.get_ticks_usec()
	for cy in range(0, side, 16):
		for cx in range(0, side, 16):
			var st := StageVegetation.ObjStore.new(null)
			st.begin_chunk(cx, cy, cx + 16, cy + 16)
			builder.call(17, cx, cy, cx + 16, cy + 16, f, 0, 0, side, st)
			count += st.x.size()
	return {ms = (Time.get_ticks_usec() - start) / 1000.0, objects = count, object_buffer_bytes = count * 32}


func _time_models(builder: Callable) -> float:
	var start := Time.get_ticks_usec()
	for variant in RockModels.VARIANTS: builder.call(Vector3(1.3, 0.78, 1.05), 72 + variant, 0.24)
	return (Time.get_ticks_usec() - start) / 1000.0


func _benchmark() -> void:
	if baseline.is_empty(): return
	var old_scatter: Script = load(baseline.path_join("scatter.gd"))
	var old_models: Script = load(baseline.path_join("models.gd"))
	if old_scatter == null or old_models == null:
		_check(false, "baseline scripts available")
		return
	var f := _fields(128)
	for y in 128:
		for x in 128:
			var i := y * 128 + x
			f.elev[i] = 0.4 if x > 63 else 0.1
			f.slope[i] = 1.4 if x > 111 else (0.45 if x > 63 else 0.08)
			f.stony[i] = sin(x * 0.14 + y * 0.09) * 0.35 + 0.15
			f.forest[i] = sin(y * 0.13) * 0.4
			f.dist_path[i] = absf(x - 24)
			if y < 8: f.biome[i] = Biomes.SHALLOW
			elif y > 100 and x < 64: f.biome[i] = Biomes.SWAMP
	var old_ms: Array[float] = []
	var new_ms: Array[float] = []
	var old_model_ms: Array[float] = []
	var new_model_ms: Array[float] = []
	var old_result := {}
	var new_result := {}
	# Одинаковые поля, три чередующихся выборки; медиана подавляет разовый шум.
	for trial in 3:
		old_result = _time_scatter(Callable(old_scatter, "place_chunk"), f, 128)
		new_result = _time_scatter(RockScatter.place_chunk, f, 128)
		old_ms.append(old_result.ms)
		new_ms.append(new_result.ms)
		old_model_ms.append(_time_models(Callable(old_models, "mesh")))
		new_model_ms.append(_time_models(RockModels.mesh))
	old_ms.sort()
	new_ms.sort()
	old_model_ms.sort()
	new_model_ms.sort()
	old_result.ms = old_ms[1]
	new_result.ms = new_ms[1]
	metrics = {fixture = "128x128 mixed terrain, 16-cell chunks, seed 17; median of 3", scatter_before = old_result, scatter_after = new_result, six_models_before_ms = old_model_ms[1], six_models_after_ms = new_model_ms[1]}
	print("rock_look benchmark: ", JSON.stringify(metrics))
	FileAccess.open(out.path_join("metrics.json"), FileAccess.WRITE).store_string(JSON.stringify(metrics, "\t"))


func _shot(name: String, from: Vector3, target: Vector3) -> void:
	camera.look_at_from_position(from, target)
	RenderingServer.global_shader_parameter_set("veg_center", Vector2(from.x, from.z))
	for i in 5: await process_frame
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png(out.path_join(name + ".png"))


func _habitat(mat: ShaderMaterial) -> void:
	mat = mat.duplicate()
	mat.set_shader_parameter("albedo_color", Color.WHITE)
	for node in root.get_children():
		if node is MeshInstance3D: node.hide()
	var f := _fields()
	var w := WorldData.new()
	w.W = 32
	w.H = 32
	w.N = 1024
	w.CS = 16
	w.CW = 2
	w.CH = 2
	w.lake.resize(w.N)
	w.path_mask.resize(w.N)
	var h := Heightfield.new()
	h.world = w
	h.hv.resize(w.N)
	for y in 32:
		for x in 32:
			var i := y * 32 + x
			f.dist_path[i] = absf(x - 5)
			f.elev[i] = 0.4 if x > 19 else 0.1
			f.slope[i] = 0.38 if x > 19 else 0.05
			f.stony[i] = sin(x * 0.3 + y * 0.22) * 0.25 + 0.3
			h.hv[i] = 4.0 + maxf(0, x - 19) * 1.5
			w.path_mask[i] = 3 if x == 5 else 0
	var st := StageVegetation.ObjStore.new(w)
	for cy in 2:
		for cx in 2:
			st.begin_chunk(cx * 16, cy * 16, cx * 16 + 16, cy * 16 + 16)
			RockScatter.place_chunk(17, cx * 16, cy * 16, cx * 16 + 16, cy * 16 + 16, f, 0, 0, 32, st)
	w.obj_x = st.x
	w.obj_y = st.y
	w.obj_k = st.k
	w.obj_v = st.v
	w.obj_s = st.s
	w.chunks = []
	for list: Array in st.chunk_lists: w.chunks.append(PackedInt32Array(list))
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	for y in 31:
		for x in 31:
			for offset: Vector2i in [Vector2i.ZERO, Vector2i.RIGHT, Vector2i.DOWN, Vector2i.RIGHT, Vector2i.ONE, Vector2i.DOWN]:
				var p := Vector2i(x, y) + offset
				surface.set_color(Color(0.43, 0.38, 0.29) if x == 5 else (Color(0.36, 0.37, 0.3) if x > 19 else Color(0.31, 0.38, 0.23)))
				surface.add_vertex(Vector3((p.x + 0.5) * 4, h.hv[p.y * 32 + p.x], (p.y + 0.5) * 4))
	surface.generate_normals()
	var ground := StandardMaterial3D.new()
	ground.vertex_color_use_as_albedo = true
	_mesh(surface.commit(), Vector3.ZERO, ground)
	var layer := VegetationLayer.new()
	layer.world = w
	layer.heights = h
	for variant in RockModels.VARIANTS:
		var mesh := RockModels.mesh(Vector3(1.3, 0.78, 1.05), 72 + variant, 0.24)
		layer._defs[Biomes.T_ROCK + variant * ForestModels.MODEL_STRIDE] = {crown = mesh, box = mesh.get_aabb(), leaves = [Color(0.62, 0.59, 0.54)]}
	var visible := 0
	for cy in 2:
		for cx in 2:
			var built := layer._build_chunk(Vector2i(cx, cy))
			for entry: Dictionary in built.entries:
				var mm := MultiMesh.new()
				mm.transform_format = MultiMesh.TRANSFORM_3D
				mm.use_colors = true
				mm.mesh = layer._defs[entry.kind].crown
				mm.instance_count = entry.count
				mm.buffer = entry.cbuf
				var node := MultiMeshInstance3D.new()
				node.multimesh = mm
				node.material_override = mat
				root.add_child(node)
				visible += entry.count
	_check(visible > 50, "actual chunk buffers in habitat " + str(visible))
	layer.free()
	await _shot("rock_roadside", Vector3(22, 6, 84), Vector3(29, 4.3, 54))
	await _shot("rock_mountain", Vector3(69, 11, 86), Vector3(98, 13, 60))


func _run() -> void:
	_rules()
	_integration()
	_benchmark()
	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	env.environment.background_mode = Environment.BG_COLOR
	env.environment.background_color = Color(0.55, 0.65, 0.73)
	env.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.environment.ambient_light_color = Color(0.8, 0.86, 1.0)
	env.environment.ambient_light_energy = 0.5
	root.add_child(env)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-36, -25, 0)
	sun.shadow_enabled = true
	root.add_child(sun)
	var plane := PlaneMesh.new()
	plane.size = Vector2(160, 160)
	var ground := StandardMaterial3D.new()
	ground.albedo_color = Color(0.27, 0.32, 0.20)
	_mesh(plane, Vector3(0, -0.07, 0), ground)
	var mat := ShaderMaterial.new()
	mat.shader = preload("res://resources/rock.gdshader")
	mat.set_shader_parameter("albedo_color", Color(0.62, 0.59, 0.54))
	mat.set_shader_parameter("fade_far", 330.0)
	mat.set_shader_parameter("fade_len", 40.0)
	for variant in RockModels.VARIANTS:
		var mesh := RockModels.mesh(Vector3(1.3, 0.78, 1.05), 72 + variant, 0.24)
		var levels := ForestModels.lod_meshes(mesh)
		var triangles: Array[int] = []
		for level: Mesh in levels:
			triangles.append(level.surface_get_arrays(0)[Mesh.ARRAY_INDEX].size() / 3)
		_check(triangles[0] > triangles[1] and triangles[1] > triangles[2], "LOD budgets " + str(variant) + " " + str(triangles))
		_mesh(mesh, Vector3((variant % 3 - 1) * 3.5, 0, -(variant / 3) * 3.7), mat)
	camera = Camera3D.new()
	camera.fov = 51.0
	root.add_child(camera)
	await _shot("rock_models", Vector3(8.5, 7, 11.5), Vector3(0, 0, -1.7))
	await _shot("rock_detail", Vector3(2.1, 1.4, 2.8), Vector3(0, 0.35, 0))
	await _habitat(mat)
	print("rock_look: failures=", failures, " screenshots=", out)
	quit(0 if failures == 0 else 1)
