extends SceneTree
## Контролируемая роща из 441 дерева: одинаковые свет, камера, тени и геометрия.
const Dev := preload("res://tools/control/control.gd")
const Test := preload("res://tools/vegetation_test.gd")
const Impostors := preload("res://tools/impostor_layer.gd")
var out := ""


func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 180)
	call_deferred("evaluate")


func evaluate() -> void:
	out = Dev.out_dir()
	Engine.max_fps = 0
	DisplayServer.window_set_size(Vector2i(1280, 720))
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	var game: GameWorld = load("res://scenes/game_world.tscn").instantiate()
	root.add_child(game)
	game.paused = true
	var w := Test.fixture(0)
	for y in 21:
		for x in 21:
			var o := w.obj_x.size()
			var tx := (422.0 + x * 9.0 + WGRandom.hash2(x, y, 651) * 3.0) / GameConfig.TILE
			var tz := (512.0 + y * 9.0 + WGRandom.hash2(x, y, 652) * 3.0) / GameConfig.TILE
			w.obj_x.append(tx)
			w.obj_y.append(tz)
			w.obj_k.append([Biomes.T_OAK, Biomes.T_BIRCH, Biomes.T_PINE][(x + y) % 3])
			w.obj_v.append((x + y * 2) % 3)
			w.obj_s.append(0.8 + WGRandom.hash2(x, y, 653) * 0.65)
			w.chunks[(int(tz) / w.CS) * w.CW + int(tx) / w.CS].append(o)
	w.obj_count = w.obj_x.size()
	game.world = w
	game.heights = Heightfield.new(w, false)
	GameWorld._defs = Models.tree_defs()
	GameWorld._grass_mesh = Models.grass_mesh()
	var plane := PlaneMesh.new()
	plane.size = Vector2(1600, 1600)
	game.get_node("Terrain").mesh = plane
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color("747c58")
	game.get_node("Terrain").material_override = mat
	var ground := game.heights.ground_at(512, 512)
	game.get_node("Terrain").position = Vector3(512, ground, 512)
	var layer := Impostors.install(game)
	var target := Vector3(512, ground + 4, 550)
	var cases := []
	for distance in [70.0, 160.0, 260.0]:
		cases.append({name = "forest_%d" % distance, pos = Vector3(512, ground + 3, 512 - distance), target = target})
	cases.append({name = "elevated", pos = Vector3(512, ground + 80, 352), target = target})
	var results := {renderer = RenderingServer.get_current_rendering_method(), gpu = RenderingServer.get_video_adapter_name(), cases = []}
	for view: Dictionary in cases:
		if Dev.arg("case") != "" and view.name != Dev.arg("case"):
			continue
		game.camera.look_at_from_position(view.pos, view.target, Vector3.UP)
		layer.update(view.pos.x, view.pos.z, true)
		for distance in [100000.0, 180.0, 80.0]:
			layer.set_distance(distance)
			for i in 18:
				await process_frame
			await RenderingServer.frame_post_draw
			var name := "%s_%s" % [view.name, "mesh" if distance > 1000 else str(int(distance))]
			root.get_texture().get_image().save_png(out.path_join(name + ".png"))
			var times := PackedFloat32Array()
			var calls := 0.0
			var start := Time.get_ticks_usec()
			var last := start
			while Time.get_ticks_usec() - start < 3000000 or times.size() < 20:
				await process_frame
				var now := Time.get_ticks_usec()
				times.append((now - last) / 1000.0)
				last = now
				calls += Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)
			var total := 0.0
			for ms in times:
				total += ms
			times.sort()
			var result := {view = view.name, camera = str(view.pos), target = str(view.target), distance = distance, fps = times.size() * 1000.0 / total, p99_ms = times[int(times.size() * 0.99)], calls = calls / times.size()}
			results.cases.append(result)
			print(JSON.stringify(result))
	Dev.save_json(out.path_join("evaluation.json"), results)
	quit()
