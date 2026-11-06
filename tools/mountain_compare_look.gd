extends SceneTree
## Изолированные виды гор без генерации мира: окно 1 км вокруг высшей точки сида, рельеф трёх версий
## StageRelief (коммиты через git show, считаются в GDScript) и текущий код. Одинаковые камеры и косой свет.
## godot --path . --script res://tools/mountain_compare_look.gd -- [--seed Ущелье] [--versions 064dd48,HEAD]
const OUT := "res://.godot/mountain_compare"
const SIDE := 256
var cam: Camera3D
var node: MeshInstance3D


func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 150)
	call_deferred("run")


func arg(name: String, fallback: String) -> String:
	var a := OS.get_cmdline_user_args()
	var i := a.find(name)
	return a[i + 1] if i >= 0 and i + 1 < a.size() else fallback


func relief(script: Script, w: WorldData, x0: int, y0: int) -> PackedFloat32Array:
	var raw: PackedFloat32Array = script.raw_rect(w, x0, y0, SIDE, SIDE, script != StageRelief)
	for i in raw.size():
		raw[i] = StageRelief.normalize(raw[i]) * GameConfig.HS
	return raw


func mesh(h: PackedFloat32Array) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for z in SIDE - 1:
		for x in SIDE - 1:
			for p: Vector2i in [Vector2i(x, z), Vector2i(x + 1, z), Vector2i(x, z + 1), Vector2i(x + 1, z), Vector2i(x + 1, z + 1), Vector2i(x, z + 1)]:
				var v := h[p.y * SIDE + p.x]
				st.set_color(Color(0.42, 0.47, 0.36) if v < 120.0 else Color(0.62, 0.6, 0.56))
				st.add_vertex(Vector3(p.x * 4.0, v, p.y * 4.0))
	st.generate_normals()
	return st.commit()


func run() -> void:
	DirAccess.make_dir_recursive_absolute(OUT)
	var seed_text := arg("--seed", "Ущелье")
	var w := WorldData.new()
	w.W = 768; w.H = 768; w.N = 768 * 768
	w.seed_text = seed_text
	w.seed_num = WGRandom.hash_string(seed_text)
	for key: String in WorldGenerator.NOISE_SLOTS:
		w.noise[key] = Simplex.new(WorldGenerator.noise_rng(w.seed_num, key))
	StageRelief.run(w)
	var top := 0
	for i in w.N:
		if w.h[i] > w.h[top]: top = i
	var x0 := clampi(top % 768 - SIDE / 2, 0, 768 - SIDE)
	var y0 := clampi(top / 768 - SIDE / 2, 0, 768 - SIDE)
	var fields := {}
	for version: String in arg("--versions", "064dd48,HEAD").split(","):
		var out: Array = []
		OS.execute("git", ["show", version + ":scripts/world/stages/stage_relief.gd"], out)
		var text := str(out[0]).replace("class_name StageRelief", "").replace("var fast := Grid.fast_grid()", "var fast: Object = null")
		var path := OUT.path_join("relief_" + version + ".gd")
		var f := FileAccess.open(path, FileAccess.WRITE)
		f.store_string(text); f.close()
		fields[version] = relief(load(path), w, x0, y0)
		print("FIELD ", version)
	fields["new"] = relief(StageRelief, w, x0, y0)
	root.size = Vector2i(1280, 720)
	var scene := Node3D.new()
	root.add_child(scene)
	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	env.environment.background_mode = Environment.BG_COLOR
	env.environment.background_color = Color(0.62, 0.75, 0.88)
	env.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.environment.ambient_light_color = Color(0.7, 0.75, 0.85)
	env.environment.ambient_light_energy = 0.35
	scene.add_child(env)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-22, -70, 0)
	sun.light_energy = 1.6
	sun.shadow_enabled = true
	scene.add_child(sun)
	cam = Camera3D.new(); cam.fov = 55; cam.far = 8000
	scene.add_child(cam)
	node = MeshInstance3D.new()
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true; mat.roughness = 1.0
	node.material_override = mat
	scene.add_child(node)
	var c := SIDE * 2.0
	var peak: float = fields["new"][(top / 768 - y0) * SIDE + top % 768 - x0]
	var target := Vector3((top % 768 - x0) * 4.0, peak * 0.7, (top / 768 - y0) * 4.0)
	var low := INF
	for v: PackedFloat32Array in fields.values():
		low = minf(low, v[(SIDE - 2) * SIDE + 2])
	var ground := func(x: float, z: float) -> float:
		var hs := -INF
		for v: PackedFloat32Array in fields.values():
			hs = maxf(hs, v[clampi(roundi(z / 4.0), 0, SIDE - 1) * SIDE + clampi(roundi(x / 4.0), 0, SIDE - 1)])
		return hs
	var foot := Vector2(target.x, target.z) + Vector2(-1, 1).normalized() * 380.0
	var near := Vector3(foot.x, ground.call(foot.x, foot.y) + 1.8, foot.y)
	var views := {
		overview = [target + Vector3(-560, 330, 560), target],
		side = [target + Vector3(620, 120, 160), target],
		player = [near, Vector3(target.x, peak * 0.85, target.z)],
	}
	for version: String in fields:
		var h: PackedFloat32Array = fields[version]
		node.mesh = mesh(h)
		for view: String in views:
			var eye: Vector3 = views[view][0]
			cam.look_at_from_position(eye, views[view][1], Vector3.UP)
			for k in 4: await process_frame
			await RenderingServer.frame_post_draw
			var file := OUT.path_join("%s_%s_%s.png" % [seed_text, view, version])
			root.get_texture().get_image().save_png(file)
			print("SHOT ", file)
	quit()
