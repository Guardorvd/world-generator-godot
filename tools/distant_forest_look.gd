extends SceneTree
const Far := preload("res://scripts/render/distant_forest.gd")
const Dev := preload("res://tools/control/control.gd")
var camera: Camera3D
var cycle: DayCycle
var vegetation: VegetationLayer
var crowns: Node3D
var world: WorldData
var heights: Heightfield
var out := "res://.godot/far_panorama"
var results: Array = []

func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 600)
	run.call_deferred()

func run() -> void:
	out = Dev.arg("out", out)
	DirAccess.make_dir_recursive_absolute(out)
	root.size = Vector2i(1280, 720)
	RenderingServer.viewport_set_measure_render_time(root.get_viewport_rid(), true)
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	world = WorldGenerator._generate_plan(Dev.arg("seed", "Север-1234"), int(Dev.arg("size", "384")))
	heights = Heightfield.new(world)
	var scene := Node3D.new()
	root.add_child(scene)
	var terrain := MeshInstance3D.new()
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, TerrainBuilder.build_arrays(world, heights))
	terrain.mesh = mesh
	terrain.material_override = TerrainBuilder.new().material(MapBaker.bake(world, 2, true), preload("res://scripts/render/forest_floor.gd").surface_image(world))
	scene.add_child(terrain)
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
	vegetation.settings.flora = 0
	vegetation.setup(world, heights, Models.tree_defs(), Models.grass_mesh())
	crowns = Node3D.new()
	scene.add_child(crowns)
	Far.active = true
	var start := Time.get_ticks_usec()
	var count := 0
	var coarse := 0
	for y in ceili(float(world.H) / PlanTerrain.CELLS):
		for x in ceili(float(world.W) / PlanTerrain.CELLS):
			var batches := Far.plan(world, heights, Vector2i(x, y))
			for entry: Dictionary in batches.f.values(): count += entry.count
			for entry: Dictionary in batches.c.values(): coarse += entry.count
			Far.attach(crowns, batches)
	print("FAR_BUILD ", (Time.get_ticks_usec() - start) / 1000.0, " ms, crowns=", count, " coarse=", coarse)
	camera = Camera3D.new()
	camera.far = 4000
	camera.fov = 65
	scene.add_child(camera)
	var target := Vector3(world.W * 2.0, 0, world.H * 2.0)
	# Aim at the densest real tree chunk, then observe across several hundred metres.
	var best := 0
	for i in world.chunks.size():
		if world.chunks[i].size() > world.chunks[best].size(): best = i
	target.x = (best % world.CW + 0.5) * world.CS * GameConfig.TILE
	target.z = (best / world.CW + 0.5) * world.CS * GameConfig.TILE
	target.y = heights.ground_at(target.x, target.z) + 12.0
	for view in (0 if "--switch-only" in OS.get_cmdline_user_args() else 6):
		var offset: Vector3 = [Vector3(0, 90, -330), Vector3(420, 45, -180), Vector3(-300, 30, -520), Vector3(250, 140, -1000), Vector3(0, 90, -330), Vector3(0, 90, -330)][view]
		var at := target + offset
		at.y = maxf(at.y, heights.ground_at(at.x, at.z) + 40.0)
		camera.look_at_from_position(at, target)
		vegetation.update(at.x, at.z, true)
		cycle.apply([7.5, 12.0, 17.3, 10.0, 21.0, 0.5][view], 0.0)
		# Clear panorama variant deliberately reduces ordinary fog in BOTH comparison arms.
		if "--clear" in OS.get_cmdline_user_args():
			env_node.environment.fog_density *= 0.35
			env_node.environment.fog_height_density = 0.0
		for enabled in [false, true]:
			crowns.visible = enabled
			RenderingServer.global_shader_parameter_set("distant_vegetation", Vector4(vegetation.tree_r, vegetation.tree_r * 0.2, 1400, float(enabled)))
			for frame in 12: await process_frame
			await RenderingServer.frame_post_draw
			root.get_texture().get_image().save_png(out.path_join("%d_%s.png" % [view, "after" if enabled else "before"]))
			var times: Array[float] = []
			var gpu := 0.0
			var previous := Time.get_ticks_usec()
			for frame in 24:
				await process_frame
				var now := Time.get_ticks_usec()
				times.append((now - previous) / 1000.0)
				previous = now
				gpu += RenderingServer.viewport_get_measured_render_time_gpu(root.get_viewport_rid())
				target.x += 0.1 # Same short sideways ride in each pair.
				camera.position.x += 0.1
			times.sort()
			results.append({view = view, enabled = enabled, median_ms = times[12], p95_ms = times[22], gpu_ms = gpu / 24, calls = Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME), primitives = Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME)})
			camera.position.x -= 2.4
			target.x -= 2.4
	# Runtime quality switch (the same calls the pause menu makes): visibility, ranges, global parameters.
	var switches: Array = []
	camera.look_at_from_position(target + Vector3(0, 90, -330), target)
	cycle.apply(12.0, 0.0)
	for step: Array in [["flora", 2], ["flora", 0], ["flora", 1], ["flora", 2], ["draw", 0], ["draw", 2]]:
		if step[0] == "flora": vegetation.set_flora(step[1])
		else: vegetation.set_draw(step[1])
		vegetation.update(camera.position.x, camera.position.z, true)
		for frame in 6: await process_frame
		var nodes := get_nodes_in_group("distant_forest")
		var shown := 0
		for node: MultiMeshInstance3D in nodes:
			if node.visible: shown += 1
		var global: Variant = RenderingServer.global_shader_parameter_get("distant_vegetation")
		if global == null: global = Vector4.ZERO
		var ranges: Array = [nodes[0].visibility_range_begin, nodes[0].visibility_range_end] if not nodes.is_empty() else []
		switches.append({step = step, nodes = nodes.size(), visible = shown, state = [Far.active, Far.far_end, Far.near_begin], fine_range = ranges, calls = Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)})
		print("SWITCH ", JSON.stringify(switches.back()))
	FileAccess.open(out.path_join("switch.json"), FileAccess.WRITE).store_string(JSON.stringify(switches, "\t"))
	FileAccess.open(out.path_join("report.json"), FileAccess.WRITE).store_string(JSON.stringify({adapter = RenderingServer.get_video_adapter_name(), renderer = RenderingServer.get_current_rendering_method(), results = results}, "\t"))
	print(JSON.stringify(results))
	quit()
