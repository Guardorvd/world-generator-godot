extends SceneTree
## Изолированные виды гор без генерации мира: окно 1 км вокруг высшей точки сида, рельеф трёх версий
## StageRelief (коммиты через git show, считаются в GDScript) и текущий код. Одинаковые камеры и косой свет.
## godot --path . --script res://tools/mountain_compare_look.gd -- [--seed Ущелье] [--versions 064dd48,HEAD]
const OUT := "res://.godot/mountain_compare"
var SIDE := 256
var cam: Camera3D
var node: MeshInstance3D


func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 150)
	if "--snapshots" in OS.get_cmdline_user_args():
		call_deferred("snapshots")
		return
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
	SIDE = int(arg("--side", "256"))
	var tag := arg("--tag", "")
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
	for version: String in arg("--versions", "064dd48,HEAD").split(",", false):
		if version == "-": continue
		var out: Array = []
		OS.execute("git", ["show", version + ":scripts/world/stages/stage_relief.gd"], out)
		var text := str(out[0]).replace("class_name StageRelief", "").replace("var fast := Grid.fast_grid()", "var fast: Object = null")
		var path := OUT.path_join("relief_" + version + ".gd")
		var f := FileAccess.open(path, FileAccess.WRITE)
		f.store_string(text); f.close()
		fields[version] = relief(load(path), w, x0, y0)
		print("FIELD ", version)
	fields["new"] = relief(StageRelief, w, x0, y0)
	if "--full" in OS.get_cmdline_user_args():
		# Мир как в игре: после рек и долин (WorldGenerator._geography), поверхность Heightfield в центрах клеток
		var full := WorldGenerator._geography(seed_text, 768)
		var surface := Heightfield.new(full, false)
		var g := PackedFloat32Array()
		g.resize(SIDE * SIDE)
		for j in SIDE:
			for i in SIDE:
				g[j * SIDE + i] = surface.ground_at((x0 + i + 0.5) * GameConfig.TILE, (y0 + j + 0.5) * GameConfig.TILE)
		fields["game"] = g
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
		overview = [target + Vector3(-560, 330, 560) * SIDE / 256.0, target],
		side = [target + Vector3(620, 120, 160) * SIDE / 256.0, target],
		player = [near, Vector3(target.x, peak * 0.85, target.z)],
		far_n = [target + Vector3(0, 60 - peak * 0.5, -1.0) * Vector3(1, 1, SIDE * 1.6), Vector3(target.x, peak * 0.55, target.z)],
		far_e = [target + Vector3(SIDE * 1.6, 60 - peak * 0.5, 0), Vector3(target.x, peak * 0.55, target.z)],
	}
	for version: String in fields:
		var h: PackedFloat32Array = fields[version]
		node.mesh = mesh(h)
		for view: String in views:
			var eye: Vector3 = views[view][0]
			cam.look_at_from_position(eye, views[view][1], Vector3.UP)
			for k in 4: await process_frame
			await RenderingServer.frame_post_draw
			var file := OUT.path_join("%s_%s_%s%s.png" % [seed_text, view, version, tag])
			root.get_texture().get_image().save_png(file)
			print("SHOT ", file)
	quit()

## Native before/after captures from mountain_relief_test --snapshot. A whole
## map in clay, then the actual surface/material/vegetation on a common crop.
func snapshots() -> void:
	var dir := "res://.godot/mountain_structure"
	var seed_text := arg("--seed", "Ущелье")
	var focus := arg("--focus", "before")
	var output_seed := seed_text + ("_new_focus" if focus == "after" else "")
	var pair := {}
	for v: String in ["before", "after"]:
		var file := FileAccess.open(dir.path_join(seed_text + "_" + v + ".bin"), FileAccess.READ)
		if file == null: push_error("Missing native snapshot " + v); quit(1); return
		pair[v] = file.get_var()
	if "--preview-new" in OS.get_cmdline_user_args():
		var preview := preload("res://tools/mountain_detail_test.gd").world(seed_text)
		StageRelief.run(preview)
		pair.after.raw = preview.h
	root.size = Vector2i(1280, 720)
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	var scene := Node3D.new(); root.add_child(scene)
	var env := WorldEnvironment.new(); env.environment = Environment.new()
	env.environment.background_mode = Environment.BG_COLOR
	env.environment.background_color = Color("b4c6d3")
	env.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.environment.ambient_light_color = Color.WHITE
	env.environment.ambient_light_energy = 0.38
	scene.add_child(env)
	var sun := DirectionalLight3D.new(); sun.rotation_degrees = Vector3(-32, -58, 0); sun.light_energy = 1.35
	scene.add_child(sun)
	cam = Camera3D.new(); cam.fov = 60; cam.far = 12000; scene.add_child(cam)
	node = MeshInstance3D.new(); scene.add_child(node)
	var clay := StandardMaterial3D.new(); clay.albedo_color = Color("96938b"); clay.roughness = 1.0
	var top: int = pair[focus].metrics.top_cell
	var peak := Vector2(top % 768, top / 768) * 4.0 + Vector2(2, 2)
	# One shared geographic target for the pair; --focus chooses which summit.
	var target := Vector3(peak.x, maxf(pair.before.raw[top], pair.after.raw[top]) * GameConfig.HS * 0.65, peak.y)
	var origin := Vector2i(clampi(top % 768 - 192, 0, 384), clampi(top / 768 - 192, 0, 384))
	var panorama := target + Vector3(-820, 430, 820)
	if focus == "after":
		panorama = target + Vector3(820 if peak.x < 1536 else -820, 430, 820 if peak.y < 1536 else -820)
	var near_xy := peak + Vector2(-320, 230)
	near_xy = near_xy.clamp(Vector2(20, 20), Vector2(3030, 3030))
	var ground_index := clampi(int(near_xy.y / 4), 0, 767) * 768 + clampi(int(near_xy.x / 4), 0, 767)
	var near_y := maxf(pair.before.raw[ground_index], pair.after.raw[ground_index]) * GameConfig.HS + 1.8
	var views := {panorama = [panorama, target], side = [target + Vector3(900, 130, 180), target],
		player = [Vector3(near_xy.x, near_y, near_xy.y), target],
		map = [Vector3(1536, 4500, 1535), Vector3(1536, 0, 1536)]}
	if focus == "after":
		views.side[0] = target + Vector3(900 if peak.x < 1536 else -900, 130, 180 if peak.y < 1536 else -180)
	var camera_record := {focus = focus, top_cell = top, neutral = views,
		player_height = "1.8 m above each surface at the same x/z", game = {}}
	var builder := TerrainBuilder.new()
	var shader_source: Array = []
	if OS.execute("git", ["show", "8b41708:resources/terrain.gdshader"], shader_source) != 0:
		push_error("Baseline terrain material unavailable"); quit(1); return
	var baseline_shader := Shader.new(); baseline_shader.code = str(shader_source[0])
	for version: String in ["before", "after"]:
		var data: Dictionary = pair[version]
		# Early numeric captures did not encode EntityRecords. These lists are
		# unused by this terrain/vegetation renderer; never deserialize object IDs.
		for key: String in ["settlements", "sites", "lakes", "bridges", "tunnels"]:
			if not data.world[key].is_empty() and not data.world[key][0] is Dictionary:
				data.world[key] = []
		var w := WorldCache.new()._restore(data.world, false)
		if w == null: push_error("Invalid world capture"); quit(1); return
		var surface := preload("res://scripts/game/surface_snapshot.gd").restore(w, data.surface, "final")
		var arrays: Array
		var terrain: ArrayMesh
		if "--environment-only" not in OS.get_cmdline_user_args():
			var raw_surface := Heightfield.new()
			raw_surface.world = w; raw_surface.hv = data.raw.duplicate()
			for i in raw_surface.hv.size(): raw_surface.hv[i] *= GameConfig.HS
			arrays = TerrainBuilder.build_arrays(w, raw_surface)
			terrain = ArrayMesh.new(); terrain.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
			node.mesh = terrain; node.material_override = clay
			for view: String in views:
				cam.projection = Camera3D.PROJECTION_ORTHOGONAL if view == "map" else Camera3D.PROJECTION_PERSPECTIVE
				cam.size = 3300
				var eye: Vector3 = views[view][0]
				if view == "player": eye.y = data.raw[ground_index] * GameConfig.HS + 1.8
				cam.look_at_from_position(eye, views[view][1], Vector3.UP)
				await shot(dir, output_seed + "_clay_" + view + "_" + version)
			# A plain grayscale height map uses the same absolute scale in both versions.
			var heightmap := Image.create(768, 768, false, Image.FORMAT_RGB8)
			for z in 768:
				for x in 768:
					var value: float = clampf(data.raw[z * 768 + x] * GameConfig.HS / 320.0, 0.0, 1.0)
					heightmap.set_pixel(x, z, Color(value, value, value))
			heightmap.save_png(dir.path_join(output_seed + "_height_" + version + ".png"))
		if "--clay-only" in OS.get_cmdline_user_args(): continue
		arrays = TerrainBuilder.build_arrays(w, surface, Rect2i(origin, Vector2i(383, 383)))
		terrain = ArrayMesh.new(); terrain.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays); node.mesh = terrain
		var base := Image.create(768, 768, false, Image.FORMAT_RGB8)
		for z in 768:
			for x in 768:
				var rgb: Array = Biomes.LIST[w.biome[z * 768 + x]].color
				base.set_pixel(x, z, Color8(rgb[0], rgb[1], rgb[2]))
		var floor_image := preload("res://scripts/render/forest_floor.gd").surface_image(w)
		node.material_override = builder.material(base, floor_image)
		if version == "before": node.material_override.shader = baseline_shader
		var vegetation := VegetationLayer.new(); scene.add_child(vegetation)
		vegetation.setup(w, surface, Models.tree_defs(), Models.grass_mesh(), floor_image)
		# Each rider shot is on an actual road in its own world, nearest the same mountain.
		var road := peak; var direction := Vector2(1, 0); var best := INF
		for route: Dictionary in w.trails:
			if route.kind == "animal": continue
			for k in range(2, route.pts.size() - 3, 3):
				var p := Vector2(route.pts[k].x, route.pts[k].y)
				if not Rect2i(origin + Vector2i(12, 12), Vector2i(360, 360)).has_point(Vector2i(p)): continue
				var score := (p * 4 - peak).length() + absf(w.elev[int(p.y) * 768 + int(p.x)] * GameConfig.HS - target.y) * 2
				if score < best:
					best = score; road = p * 4
					direction = (Vector2(route.pts[k+2].x, route.pts[k+2].y) - p).normalized()
		var eye := Vector3(road.x, surface.ground_at(road.x, road.y) + 1.8, road.y)
		var ahead := road + direction * 65
		var game_views := {panorama = [target + Vector3(-420, 220, 420), target],
			rider = [eye, Vector3(ahead.x, surface.ground_at(ahead.x, ahead.y) + 2.0, ahead.y)]}
		camera_record.game[version] = game_views
		for view: String in game_views:
			cam.projection = Camera3D.PROJECTION_PERSPECTIVE
			cam.look_at_from_position(game_views[view][0], game_views[view][1], Vector3.UP)
			vegetation.update(cam.position.x, cam.position.z, true)
			await shot(dir, output_seed + "_game_" + view + "_" + version)
		vegetation.queue_free(); await process_frame
		surface.weaken_world()
	for view: String in ["clay_panorama", "clay_side", "clay_map", "clay_player", "game_panorama", "game_rider", "height"]:
		if "--clay-only" in OS.get_cmdline_user_args() and view.begins_with("game_"): continue
		if "--environment-only" in OS.get_cmdline_user_args() and not view.begins_with("game_"): continue
		var panel_height := 640 if view == "height" else 360
		var sheet := Image.create(1280, panel_height, false, Image.FORMAT_RGBA8)
		for k in 2:
			var v: String = ["before", "after"][k]
			var img := Image.load_from_file(dir.path_join(output_seed + "_" + view + "_" + v + ".png"))
			img.convert(Image.FORMAT_RGBA8); img.resize(640, panel_height, Image.INTERPOLATE_LANCZOS)
			sheet.blit_rect(img, Rect2i(0, 0, 640, panel_height), Vector2i(k * 640, 0))
		sheet.save_png(dir.path_join(output_seed + "_" + view + "_pair.png"))
	FileAccess.open(dir.path_join(output_seed + "_cameras.json"), FileAccess.WRITE).store_string(JSON.stringify(camera_record, "\t"))
	quit()

func shot(dir: String, name_text: String) -> void:
	for frame in 5: await process_frame
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png(dir.path_join(name_text + ".png"))
	print("SHOT ", name_text)
