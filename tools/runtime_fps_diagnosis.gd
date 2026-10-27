extends "res://tools/runtime_stutter_probe.gd"
## One world, fixed view for CPU/GPU ablations, then a fast ride.
## No settings/progress writes. -- --out <json> --speed 45
var stages := ["idle_before", "detail_worker", "idle_after", "no_vegetation", "no_shadows", "fast_ride"]
var stage_index := -1
var stage_time := 0.0
var worker := -1
var worker_samples: Array = []
var samples: Array = []
var reports := {}
var fixed_position := Vector3.ZERO
var shadows_were := false
var shadow_settings := {}
var original_materials := {}

func setup() -> void:
	if not Dev.arg("stages").is_empty(): stages = Array(Dev.arg("stages").split(","))
	super.setup()

func _process(dt: float) -> bool:
	if phase in ["boot", "loading"]:
		super._process(dt)
		return false
	if stage_index < 0:
		prepare_ride()
		game.vegetation._finish()
		var p := point_at(0)
		fixed_position = Vector3(p.x, game.heights.ground_at(p.x, p.y) + GameConfig.EYE, p.y)
		shadows_were = game.get_node("Sun").shadow_enabled
		for key in ["directional_shadow_max_distance", "directional_shadow_split_1", "directional_shadow_split_2", "directional_shadow_split_3"]:
			shadow_settings[key] = game.get_node("Sun").get(key)
		for entry: Dictionary in game.vegetation.veg.values():
			for node: MultiMeshInstance3D in entry.nodes: original_materials[node] = node.material_override
		next_stage()
		return false
	var stage: String = stages[stage_index]
	stage_time += dt
	var p := point_at(stage_time * float(Dev.arg("speed", "45"))) if stage == "fast_ride" else Vector2(fixed_position.x, fixed_position.z)
	var ahead := point_at(stage_time * float(Dev.arg("speed", "45")) + 8.0) if stage == "fast_ride" else point_at(8)
	var pos := Vector3(p.x, game.heights.ground_at(p.x, p.y) + GameConfig.EYE, p.y)
	game.camera.look_at_from_position(pos, Vector3(ahead.x, game.heights.ground_at(ahead.x, ahead.y) + GameConfig.EYE, ahead.y))
	var start := Time.get_ticks_usec()
	if stage == "fast_ride": game.stream_coordinator.update(pos)
	var stream_ms := (Time.get_ticks_usec() - start) / 1000.0
	if worker != -1 and WorkerThreadPool.is_task_completed(worker):
		WorkerThreadPool.wait_for_task_completion(worker)
		worker = -1
	if stage == "detail_worker" and worker == -1:
		worker = WorkerThreadPool.add_task(detail_job, true, "FPS diagnosis details")
	var now := Time.get_ticks_usec()
	if stage_time > 2.0:
		samples.append({frame_ms=(now-last)/1000.0, stream_ms=stream_ms,
			gpu_ms=RenderingServer.viewport_get_measured_render_time_gpu(root.get_viewport_rid()),
			render_cpu_ms=RenderingServer.viewport_get_measured_render_time_cpu(root.get_viewport_rid()),
			draw_calls=Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME),
			primitives=Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME)})
	last = now
	if stage_time >= (14.0 if stage == "fast_ride" else 8.0): next_stage()
	return false

func detail_job() -> void:
	# Same live placement and snapshot code; deliberately never upload or move the view.
	var v := game.vegetation
	var t := Time.get_ticks_usec()
	v._fill_lead = Vector2.ZERO
	v._fill_grass(fixed_position.x + 8, fixed_position.z)
	var filled := Time.get_ticks_usec()
	v.snapshots.prepare(-1, v.grass_buf, v._grass_n, v._grass_bounds, v._grass_margin * 2.0, v.stream.clock)
	for kind in v.understory.size():
		var e: Dictionary = v.understory[kind]
		v.snapshots.prepare(kind, e.buf, e.count, AABB(e.low, e.high-e.low) if e.count > 0 else AABB(), v._radius(e.mm.mesh) + e.margin, v.stream.clock)
	worker_samples.append({placement_ms=(filled-t)/1000.0, snapshots_ms=(Time.get_ticks_usec()-filled)/1000.0, grass=v._grass_n})

func next_stage() -> void:
	if worker != -1:
		WorkerThreadPool.wait_for_task_completion(worker)
		worker = -1
	if stage_index >= 0:
		var report := {}
		for key in ["frame_ms", "stream_ms", "gpu_ms", "render_cpu_ms", "draw_calls", "primitives"]:
			var values: Array = samples.map(func(r: Dictionary): return r[key])
			values.sort()
			var total := 0.0
			for value: float in values: total += value
			report[key] = {mean=total/maxi(1,values.size()), p99=values[int(values.size()*0.99)], max=values[-1]}
		report.fps = 1000.0/report.frame_ms.mean
		var materials := {}
		var tree_nodes := 0
		for entry: Dictionary in game.vegetation.veg.values():
			for node: MultiMeshInstance3D in entry.nodes:
				tree_nodes += 1
				materials[node.material_override.get_instance_id()] = true
		report.tree_nodes = tree_nodes
		report.tree_materials = materials.size()
		reports[stages[stage_index]] = report
		print("DIAG ", stages[stage_index], " ", JSON.stringify(report))
		if not Dev.arg("capture").is_empty():
			root.get_texture().get_image().save_png(Dev.arg("capture") + "_" + stages[stage_index] + ".png")
	stage_index += 1
	if stage_index == stages.size():
		Dev.save_json(Dev.abs_dir(Dev.arg("out", "res://tools/control/runs/fps_diagnosis.json")), {reports=reports, workers=worker_samples, gpu=RenderingServer.get_video_adapter_name(), cpu=OS.get_processor_name(), draw=game.vegetation.draw_level, viewport=str(root.size), speed=float(Dev.arg("speed", "45"))})
		game.vegetation._finish()
		quit(0)
		return
	game.vegetation.visible = stages[stage_index] != "no_vegetation"
	game.get_node("Sun").shadow_enabled = shadows_were and stages[stage_index] != "no_shadows"
	game.get_node("WorldEnvironment").environment.ssao_enabled = shadows_were and stages[stage_index] != "no_shadows"
	for key: String in shadow_settings: game.get_node("Sun").set(key, shadow_settings[key])
	if stages[stage_index] == "legacy_render":
		game.get_node("Sun").directional_shadow_max_distance = 900.0
		game.get_node("Sun").directional_shadow_split_1 = 0.04
		game.get_node("Sun").directional_shadow_split_2 = 0.13
		game.get_node("Sun").directional_shadow_split_3 = 0.35
	if stages[stage_index] in ["old_shadow_range", "shared_old_shadows"]:
		var defaults := DirectionalLight3D.new()
		for key: String in shadow_settings: game.get_node("Sun").set(key, 220.0 if key == "directional_shadow_max_distance" else defaults.get(key))
		defaults.free()
	var shared := {}
	for node: MultiMeshInstance3D in original_materials:
		var mat: ShaderMaterial = original_materials[node]
		if stages[stage_index] in ["shared_materials", "shared_old_shadows"]:
			# Forced initial tree upload has stamp 0: identical opaque state, only resource identity differs.
			var key := str(node.multimesh.mesh.get_instance_id()) + ":" + str(mat.get_shader_parameter("lod_level")) + ":" + str(mat.get_shader_parameter("fade_far"))
			if not shared.has(key): shared[key] = mat
			node.material_override = shared[key]
		else:
			node.material_override = mat.duplicate() if stages[stage_index] == "legacy_render" else mat
	stage_time = 0.0
	samples.clear()
	last = Time.get_ticks_usec()
