extends SceneTree
## Снимки гор со слоем детализации и без него, без генерации мира: поля из mountain_detail_test
## (или из mountain_detail_gameplay с --game: поверхность игры после воды и дорог).
## --before <папка> --after <папка> с --game берут высоты, сохранённые settlement_look --surface.
## --lowland <сид> размещает камеру на низком склоне указанного мира.
## Камеры выбираются по рельефу без слоя; x/z, направления, свет и материал одинаковы,
## глаз седока — 1,8 м над землёй своей версии.
## godot --path . --script res://tools/mountain_detail_look.gd -- [--seeds "Ущелье"] [--views close,player] [--game]
const OUT := "res://.godot/mountain_detail"
const N := 768
const SIZE := 256
var cam: Camera3D
var terrain: MeshInstance3D


func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 150)
	call_deferred("run")


func ground(h: PackedFloat32Array, p: Vector2) -> float:
	var q := (p / 4.0).clamp(Vector2.ZERO, Vector2.ONE * (N - 2))
	var x := int(q.x); var y := int(q.y)
	return lerpf(lerpf(h[y*N+x], h[y*N+x+1], q.x-x), lerpf(h[(y+1)*N+x], h[(y+1)*N+x+1], q.x-x), q.y-y) * GameConfig.HS


func mesh(h: PackedFloat32Array, origin: Vector2i) -> ArrayMesh:
	var vertices := PackedVector3Array(); var normals := PackedVector3Array()
	var colors := PackedColorArray(); var indices := PackedInt32Array()
	for y in SIZE:
		for x in SIZE:
			var i := (origin.y+y)*N+origin.x+x
			var v := h[i]*GameConfig.HS
			vertices.append(Vector3((origin.x+x)*4.0, v, (origin.y+y)*4.0))
			var dx := (h[i+1]-h[i-1])*GameConfig.HS/8.0
			var dz := (h[i+N]-h[i-N])*GameConfig.HS/8.0
			normals.append(Vector3(-dx, 1, -dz).normalized())
			colors.append(Color(0.44, 0.49, 0.36) if v < 120 else Color(0.58, 0.56, 0.50))
	for y in SIZE-1:
		for x in SIZE-1:
			var i := y*SIZE+x
			indices.append_array(PackedInt32Array([i, i+1, i+SIZE, i+1, i+SIZE+1, i+SIZE]))
	var arrays := []; arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices; arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_COLOR] = colors; arrays[Mesh.ARRAY_INDEX] = indices
	var result := ArrayMesh.new(); result.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return result


func load_h(file: String) -> PackedFloat32Array:
	if not FileAccess.file_exists(file):
		push_error("нет поля " + file + " (сначала mountain_detail_test)")
		quit(1)
		return PackedFloat32Array()
	var data: Dictionary = FileAccess.open(file, FileAccess.READ).get_var()
	return data.h


func lowland_flank(h: PackedFloat32Array) -> Vector2i:
	var best := -INF
	var chosen := Vector2i(N / 2, N / 2)
	for y in range(60, N - 60, 3):
		for x in range(60, N - 60, 3):
			var i := y * N + x
			var metres := h[i] * GameConfig.HS
			if metres < 13.0 or metres > 28.0: continue
			var grade := Vector2(h[i+2]-h[i-2], h[i+2*N]-h[i-2*N]).length() * GameConfig.HS / 16.0
			if grade < 0.13 or grade > 0.34: continue
			var low := minf(minf(h[i-16], h[i+16]), minf(h[i-16*N], h[i+16*N])) * GameConfig.HS
			if low < 8.0: continue
			var score := -absf(grade - 0.22) * 24.0 - absf(metres - 23.0) * 0.25
			if score > best:
				chosen = Vector2i(x, y)
				best = score
	return chosen


func run() -> void:
	var a := OS.get_cmdline_user_args()
	var seeds: Array = ["Вальхейм 3", "Север-1234", "Ущелье"]
	if a.has("--seeds"): seeds = a[a.find("--seeds") + 1].split(",", false)
	var only: Array = []
	if a.has("--views"): only = a[a.find("--views") + 1].split(",", false)
	var game := a.has("--game")
	var before := a[a.find("--before") + 1] if game and a.has("--before") else ""
	var after := a[a.find("--after") + 1] if game and a.has("--after") else ""
	var lowland := a[a.find("--lowland") + 1] if a.has("--lowland") else ""
	root.size = Vector2i(1280, 720)
	var scene := Node3D.new(); root.add_child(scene)
	var env := WorldEnvironment.new(); env.environment = Environment.new()
	env.environment.background_mode = Environment.BG_COLOR
	env.environment.background_color = Color(0.62, 0.75, 0.88)
	env.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.environment.ambient_light_color = Color(0.7, 0.75, 0.85)
	env.environment.ambient_light_energy = 0.4; scene.add_child(env)
	var sun := DirectionalLight3D.new(); sun.rotation_degrees = Vector3(-22, -70, 0)
	sun.light_energy = 1.6; sun.shadow_enabled = false; scene.add_child(sun)
	cam = Camera3D.new(); cam.fov = 68; cam.far = 8000; scene.add_child(cam)
	terrain = MeshInstance3D.new(); scene.add_child(terrain)
	var mat := StandardMaterial3D.new(); mat.vertex_color_use_as_albedo = true
	mat.roughness = 1.0; terrain.material_override = mat
	for seed_text: String in seeds:
		var h := load_h(before.path_join(seed_text + ".bin") if not before.is_empty() else OUT.path_join(seed_text + "_off.bin"))
		if h.is_empty(): return
		var low := seed_text == lowland
		var top := 0
		if low:
			var hill := lowland_flank(h)
			top = hill.y * N + hill.x
		else:
			for i in h.size():
				if h[i] > h[top]: top = i
		var origin := Vector2i(clampi(top%N-SIZE/2, 1, N-SIZE-2), clampi(top/N-SIZE/2, 1, N-SIZE-2))
		var peak := Vector3((top%N)*4.0, h[top]*GameConfig.HS, (top/N)*4.0)
		# Точка на склоне 12–45 % без слоя, ближайшая к 180 м на юго-запад от вершины
		var wanted := Vector2(peak.x, peak.z) + Vector2(-180, 180)
		var best := INF; var flank := Vector2(peak.x, peak.z)
		if not low:
			for y in range(origin.y+24, origin.y+SIZE-24):
				for x in range(origin.x+24, origin.x+SIZE-24):
					var i := y*N+x
					var g := Vector2(h[i+1]-h[i-1], h[i+N]-h[i-N])*GameConfig.HS/8.0
					if g.length() < 0.12 or g.length() > 0.45 or h[i] < 0.2: continue
					var p := Vector2(x, y)*4.0; var d := p.distance_squared_to(wanted)
					if d < best: best = d; flank = p
		var fi := int(flank.y/4)*N+int(flank.x/4)
		var downhill := Vector2(h[fi-1]-h[fi+1], h[fi-N]-h[fi+N]).normalized()
		for version: String in ["off", "on"]:
			var source := before if version == "off" else after
			var field := load_h(source.path_join(seed_text + ".bin") if not source.is_empty() else OUT.path_join(seed_text + ("_game_" if game else "_") + version + ".bin"))
			if field.is_empty(): return
			terrain.mesh = mesh(field, origin)
			var rider := Vector3(flank.x, ground(field, flank)+1.8, flank.y)
			var contour := Vector2(-downhill.y, downhill.x)
			var across := (contour+downhill*0.6).normalized()
			var views := {
				overview=[peak+Vector3(-500, 300, 500), peak*Vector3(1, 0.65, 1)],
				slope=[peak+Vector3(-60, 40, 420), peak+Vector3(0, -60, 0)],
				close=[rider+Vector3(0, 15, 0), rider+Vector3(downhill.x, -0.1, downhill.y)*100],
				player=[rider, rider+Vector3(across.x, -0.10, across.y)*120],
				uphill=[rider, rider+Vector3(-downhill.x, 0.25, -downhill.y)*120],
			}
			for view: String in views:
				if not only.is_empty() and not only.has(view): continue
				cam.look_at_from_position(views[view][0], views[view][1], Vector3.UP)
				for k in 4: await process_frame
				await RenderingServer.frame_post_draw
				var file := OUT.path_join(seed_text+"_"+view+("_game" if game else "")+"_"+version+".png")
				root.get_texture().get_image().save_png(file); print("SHOT ", file)
	quit()
