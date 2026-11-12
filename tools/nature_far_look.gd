extends SceneTree
## 12.11.2026: изолированная сцена природы на средних и дальних дистанциях (без игровой сцены и стриминга):
## план мира, рельеф одним мешем, настоящая растительность у камеры, дальние кроны и заросли всего плана.
## Виды подбираются по самому миру: открытый холм с высоты седла, предгорье, склон с высоты, морской берег,
## лесистая долина вдали. «Было» — тем же запуском с прежними файлами (--old: копии из git в .godot/nature_old,
## их готовит вызывающий), лист — склейка снимков.
##   godot --path . --script res://tools/nature_far_look.gd -- [--old] [--tag _old] [--views hill,foothill,slope,beach,valley]
##   [--seed Север-1234] [--size 384] [--hour 10] [--measure]
## Прежние файлы для --old (из папки проекта, bash):
##   mkdir -p .godot/nature_old; git show HEAD:resources/terrain.gdshader > .godot/nature_old/terrain.gdshader
##   git show HEAD:resources/distant_forest.gdshader > .godot/nature_old/distant_forest.gdshader
##   git show HEAD:scripts/render/distant_forest.gd | sed 's#res://resources/distant_forest.gdshader#res://.godot/nature_old/distant_forest.gdshader#' > .godot/nature_old/distant_forest.gd
const Dev := preload("res://tools/control/control.gd")
var Far: Script = preload("res://scripts/render/distant_forest.gd")
var camera: Camera3D
var cycle: DayCycle
var vegetation: VegetationLayer
var world: WorldData
var heights: Heightfield
var out := "res://.godot/nature_far"

func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 420)
	run.call_deferred()

func run() -> void:
	var args := OS.get_cmdline_user_args()
	var old := "--old" in args
	var tag := Dev.arg("tag", "_old" if old else "")
	out = Dev.arg("out", out)
	DirAccess.make_dir_recursive_absolute(out)
	root.size = Vector2i(1280, 720)
	RenderingServer.viewport_set_measure_render_time(root.get_viewport_rid(), true)
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	if old: Far = load("res://.godot/nature_old/distant_forest.gd")
	var t0 := Time.get_ticks_msec()
	world = WorldGenerator._generate_plan(Dev.arg("seed", "Север-1234"), int(Dev.arg("size", "384")))
	heights = Heightfield.new(world)
	print("PLAN ", Time.get_ticks_msec() - t0, " ms")
	var scene := Node3D.new()
	root.add_child(scene)
	var terrain := MeshInstance3D.new()
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, TerrainBuilder.build_arrays(world, heights))
	terrain.mesh = mesh
	var mat := TerrainBuilder.new().material(MapBaker.bake(world, 2, true), preload("res://scripts/render/forest_floor.gd").surface_image(world))
	if old: mat.shader = load("res://.godot/nature_old/terrain.gdshader")
	terrain.material_override = mat
	scene.add_child(terrain)
	var water := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(world.W, world.H) * GameConfig.TILE * 3.0
	water.mesh = plane
	water.position = Vector3(world.W, 0, world.H) * GameConfig.TILE * 0.5 + Vector3(0, 0.02, 0)
	var wmat := StandardMaterial3D.new()
	wmat.albedo_color = Color(0.13, 0.27, 0.36)
	wmat.roughness = 0.15
	water.material_override = wmat
	scene.add_child(water)
	var env_node := WorldEnvironment.new()
	var template: Node = load("res://scenes/game_world.tscn").instantiate()
	env_node.environment = template.get_node("WorldEnvironment").environment.duplicate()
	template.free()
	scene.add_child(env_node)
	var sun := DirectionalLight3D.new()
	scene.add_child(sun)
	cycle = DayCycle.new(env_node.environment, sun)
	preload("res://scripts/render/lighting_quality.gd").apply(env_node.environment, sun, 0, true)
	cycle.cloud_cover_override = 0.2
	vegetation = VegetationLayer.new()
	scene.add_child(vegetation)
	vegetation.setup(world, heights, Models.tree_defs(), Models.grass_mesh())
	var crowns := Node3D.new()
	scene.add_child(crowns)
	t0 = Time.get_ticks_usec()
	var counts := {}
	for y in ceili(float(world.H) / PlanTerrain.CELLS):
		for x in ceili(float(world.W) / PlanTerrain.CELLS):
			var batches: Dictionary = Far.plan(world, heights, Vector2i(x, y))
			for part: String in batches:
				for entry: Dictionary in batches[part].values(): counts[part] = counts.get(part, 0) + entry.count
			Far.attach(crowns, batches)
	print("FAR_BUILD ", (Time.get_ticks_usec() - t0) / 1000.0, " ms ", counts)
	camera = Camera3D.new()
	camera.far = 4000
	camera.fov = 65
	scene.add_child(camera)
	var views := Dev.arg("views", "hill,open,foothill,slope,beach,valley").split(",")
	var report := {adapter = RenderingServer.get_video_adapter_name(), old = old, counts = counts, views = []}
	for name in views:
		var pose := _pose(name)
		if pose.is_empty():
			print("VIEW ", name, ": нет места")
			continue
		camera.look_at_from_position(pose.at, pose.target)
		vegetation.update(pose.at.x, pose.at.z, true)
		RenderingServer.global_shader_parameter_set("veg_center", Vector2(pose.at.x, pose.at.z))
		cycle.apply(float(Dev.arg("hour", str(pose.get("hour", 10.0)))), 0.0)
		for frame in 14: await process_frame
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_jpg(out.path_join("%s%s.jpg" % [name, tag]), 0.9)
		var row := {view = name, at = pose.at, calls = Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME),
			primitives = Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME)}
		if "--measure" in args:
			var gpu := 0.0
			for frame in 30:
				await process_frame
				gpu += RenderingServer.viewport_get_measured_render_time_gpu(root.get_viewport_rid())
			row.gpu_ms = gpu / 30.0
		print("VIEW ", JSON.stringify(row))
		report.views.append(row)
	FileAccess.open(out.path_join("report%s.json" % tag), FileAccess.WRITE).store_string(JSON.stringify(report, "\t"))
	quit()

## Камера по самому миру: ищется подходящая клетка и направление взгляда с наибольшим числом нужных клеток.
func _pose(name: String) -> Dictionary:
	var best := -INF
	var pick := {}
	var tile := GameConfig.TILE
	for j in range(24, world.H - 24, 12):
		for i in range(24, world.W - 24, 12):
			var k := j * world.W + i
			var bi: int = world.biome[k]
			var e: float = world.elev[k]
			var score := -INF
			var lift := 2.6
			var reach := 140
			match name:
				"hill":
					if bi not in [Biomes.GRASS, Biomes.STEPPE] or e < 0.08 or e > 0.3 or world.path_mask[k] != 0: continue
					score = e * 2.0
					reach = 110
				"foothill":
					if bi not in [Biomes.GRASS, Biomes.STEPPE, Biomes.TUNDRA, Biomes.ROCK] or e < 0.3 or e > 0.46: continue
					score = e
					lift = 3.0
					reach = 160
				"open":
					if bi not in [Biomes.GRASS, Biomes.STEPPE] or e < 0.1 or e > 0.35: continue
					score = e
					lift = 14.0
					reach = 190
				"slope":
					if bi not in [Biomes.GRASS, Biomes.STEPPE, Biomes.FOREST, Biomes.TAIGA] or e < 0.2: continue
					score = e
					lift = 45.0
					reach = 200
				"beach":
					if bi != Biomes.BEACH or world.dist_ocean[k] > 2.0: continue
					score = 1.0
					reach = 40
				"valley":
					if e < 0.25: continue
					score = e
					lift = 25.0
					reach = 250
			if score == -INF: continue
			# Лучшее направление: открытые клетки (или берег) вдоль луча, земля не выше камеры.
			for dir in 16:
				var a := dir * TAU / 16.0
				var d := Vector2(cos(a), sin(a))
				var good := 0.0
				var blocked := false
				for s in range(4, reach, 4):
					var c := Vector2i(Vector2(i, j) + d * s)
					if not Rect2i(0, 0, world.W, world.H).has_point(c): break
					var q := c.y * world.W + c.x
					if world.elev[q] > e + lift / GameConfig.HS + 0.01 * s / 40.0: blocked = true
					match name:
						"beach": good += 1.0 if world.biome[q] == Biomes.BEACH else 0.0
						"valley": good += 1.0 if world.biome[q] in [Biomes.FOREST, Biomes.TAIGA] else 0.0
						"open": good += 1.0 if world.biome[q] in [Biomes.GRASS, Biomes.STEPPE, Biomes.TUNDRA, Biomes.SAVANNA] else -0.5
						_: good += 1.0 if world.biome[q] in [Biomes.GRASS, Biomes.STEPPE, Biomes.TUNDRA, Biomes.SAVANNA] else 0.3
				if blocked and name != "beach": continue
				var total := score * 40.0 + good
				if total > best:
					best = total
					var at := Vector3(i * tile, 0, j * tile)
					at.y = heights.ground_at(at.x, at.z) + lift
					var far := Vector2(i, j) + d * reach * 0.8
					var target := Vector3(far.x * tile, 0, far.y * tile)
					target.y = heights.ground_at(target.x, target.z) + (1.0 if name == "beach" else 0.0)
					if name in ["hill", "foothill", "beach"]: target.y = maxf(target.y, at.y - reach * tile * 0.08)
					pick = {at = at, target = target, hour = 17.0 if name == "valley" else 10.0}
	return pick
