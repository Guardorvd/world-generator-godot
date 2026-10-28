extends "res://tools/trail_world_test.gd"
## No world generation: audit the two natural regions recorded by the single world run.
const AUDIT := "res://tools/control/runs/trail_region_recorded"
const RECORDED := "res://tools/control/runs/trail_world/region_store/b5b13ec093bd2920332f6521"
const RegionalTrails := preload("res://scripts/world/region_trails.gd")
const Preparation := preload("res://scripts/world/region_preparation.gd")
var frame_max := 0.0

func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 180)
	run.call_deferred()

func source_world() -> WorldData:
	var w := WorldData.new()
	w.W = 768
	w.H = 768
	w.N = w.W * w.H
	w.seed_text = "Север-1234"
	w.seed_num = WGRandom.hash_string(w.seed_text)
	for slot: String in WorldGenerator.NOISE_SLOTS: w.noise[slot] = Simplex.new(WorldGenerator.noise_rng(w.seed_num, slot))
	for owner in [w.geology, w.climate, w.civil]:
		for property: Dictionary in owner.get_property_list():
			var value: Variant = owner.get(property.name)
			if value is GridBuffer2D.Float32 or value is GridBuffer2D.Byte or value is GridBuffer2D.Int32: value.resize()
	w.h.fill(0.2)
	w.dist_water.fill(30)
	w.biome.fill(Biomes.GRASS)
	w.outer = OuterLand.new()
	w.outer.W = w.W
	w.outer.H = w.H
	return w

func read_recording() -> Dictionary:
	var file := FileAccess.open_compressed(RECORDED + "/ledger.bin", FileAccess.READ, FileAccess.COMPRESSION_ZSTD)
	var ledger: Dictionary = file.get_var().ledger
	ledger.settlements = EntityCodec.settlements(ledger.settlements)
	for key: Vector2i in ledger.regions:
		var e: Dictionary = ledger.regions[key]
		e.decor.settlements = EntityCodec.settlements(e.decor.settlements)
		file = FileAccess.open_compressed(RECORDED + "/%d_%d.region" % [key.x, key.y], FileAccess.READ, FileAccess.COMPRESSION_ZSTD)
		e.fields = file.get_var().fields
	return ledger

func run() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(AUDIT))
	RegionStream.root = AUDIT + "/store"
	var w := source_world()
	var original := read_recording()
	# Synthetic control is explicitly separate from the two recorded natural regions.
	var control := preload("res://tools/trail_region_test.gd").fixture(41)
	original.regions[control.key] = control.ledger.regions[control.key]
	original.trails.append_array(control.ledger.trails)
	w.outer.set_ledger(original)
	var h := Heightfield.new(w, false)
	h.road_refinement = RoadRefinement.from_patches({}, w.H)
	var terrain := OuterTerrain.new()
	root.add_child(terrain)
	terrain.setup(w, h)
	var vegetation := VegetationLayer.new()
	root.add_child(vegetation)
	vegetation.setup(w, h, Models.tree_defs(), Models.grass_mesh())
	var stream := RegionStream.new()
	root.add_child(stream)
	stream.setup(w, h, terrain, vegetation)
	stream.ledger = original
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-50, -35, 0)
	light.shadow_enabled = true
	root.add_child(light)
	var environment := WorldEnvironment.new()
	environment.environment = Environment.new()
	environment.environment.background_mode = Environment.BG_COLOR
	environment.environment.background_color = Color(0.5, 0.65, 0.8)
	environment.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.environment.ambient_light_energy = 0.6
	root.add_child(environment)
	var camera := Camera3D.new()
	root.add_child(camera)
	camera.current = true
	var reports := []
	var found := 0
	for key: Vector2i in [Vector2i(3, 1), Vector2i(4, 1), Vector2i(-1, 0)]:
		var out := {}
		var source: Dictionary = EntityCodec.copy(stream.ledger)
		source.regions[key].erase("trail_plan")
		var edge_before := PackedFloat32Array()
		for z in range(258, 510):
			edge_before.append(RegionStream.snapshot_ground(w, h, source.regions, 4096.0, (z + 0.5) * GameConfig.TILE))
		var started := Time.get_ticks_msec()
		var material := stream._road_mat
		var task := WorkerThreadPool.add_task(func() -> void:
			out.ledger = source
			out.trail = Preparation.prepare_trails(w, key, source)
			out.chunks = {}
			var r := Preparation.rect_for(key).grow(1)
			for cy in range(floori(float(r.position.y) / OuterLand.C), floori(float(r.end.y - 1) / OuterLand.C) + 1):
				for cx in range(floori(float(r.position.x) / OuterLand.C), floori(float(r.end.x - 1) / OuterLand.C) + 1):
					var chunk := Vector2i(cx, cy)
					out.chunks[chunk] = terrain._build(chunk, source)
			var view := preload("res://scripts/game/navigation_snapshot.gd").capture(h, false)
			view.world.outer.set_ledger(source)
			var t := Time.get_ticks_msec()
			out.decor = RegionStream.build_decor(w, view, key, source.regions[key], material)
			out.trail.stats.decor_ms = Time.get_ticks_msec() - t
			out.trail_started = started
			out.trail_deadline = started + RegionalTrails.BUDGET_MS
			out.ready = true)
		while not WorkerThreadPool.is_task_completed(task):
			var t := Time.get_ticks_usec()
			await process_frame
			frame_max = maxf(frame_max, (Time.get_ticks_usec() - t) / 1000.0)
		WorkerThreadPool.wait_for_task_completion(task)
		stream._key = key
		stream._publishing = {done = out, pending_keys = out.chunks.keys(), nodes = {}}
		var at := Vector2(Preparation.rect_for(key).get_center()) * GameConfig.TILE
		while not stream._publishing.is_empty():
			var t := Time.get_ticks_usec()
			stream.update(at.x, at.y)
			await process_frame
			frame_max = maxf(frame_max, (Time.get_ticks_usec() - t) / 1000.0)
		var plan: Dictionary = stream.ledger.regions[key].trail_plan
		print("RECORDED ", key, " ", plan.state, "/", plan.verdict, " ", plan.get("reason", ""), " rejections=", plan.get("rejected", {}), " ", plan.stats)
		var seam := 0.0
		for z in range(258, 510): seam = maxf(seam, absf(edge_before[z - 258] - h.ground_at(4096.0, (z + 0.5) * GameConfig.TILE)))
		check(seam < 0.00001, "trail leaves the published region boundary unchanged: %.6f m" % seam)
		if plan.state == "found":
			found += 1
			var kit: Array[TrailDefinition] = [StageTrailPlan.unpack(plan.access.inbound), StageTrailPlan.unpack(plan.definition), StageTrailPlan.unpack(plan.access.outbound)]
			var loaded := WorldLoader.new()
			loaded.world = w
			loaded.heights = h
			ride(loaded, kit)
			joints(h, kit)
			var nav = preload("res://scripts/game/road_navigation.gd").new()
			nav.build(w, h)
			var components := [nav.component_near(kit[0].points[0]), nav.component_near(kit[1].points[0]), nav.component_near(kit[1].points[-1]), nav.component_near(kit[2].points[-1])]
			check(components[0] >= 0 and components.all(func(c: int) -> bool: return c == components[0]), "regional access, trail and exit share the available navigation component: %s" % str(components))
			var worst := 0.0
			var samples := 0
			for chunk: Vector2i in out.chunks:
				var arrays: Array = out.chunks[chunk].arrays
				if arrays.is_empty(): continue
				var pos: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
				var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
				var shift := Vector3(terrain._center(chunk).x, 0, terrain._center(chunk).y)
				for i in range(0, indices.size(), 87):
					var mid := (pos[indices[i]] + pos[indices[i + 1]] + pos[indices[i + 2]]) / 3.0 + shift
					if not plan.zone.has_point(Vector2i(Vector2(mid.x, mid.z) / GameConfig.TILE)): continue
					worst = maxf(worst, absf(mid.y - h.ground_at(mid.x, mid.z)))
					samples += 1
			check(samples > 0 and worst < 0.005, "regional visible mesh equals collision/support: %d probes %.6f m" % [samples, worst])
			var point := kit[1].point_at(kit[1].route_length() * 0.5)
			var target := Vector3(point.x, h.ground_at(point.x, point.y) + 0.3, point.y)
			camera.look_at_from_position(target + Vector3(18, 15, 20), target)
			var trees := 0
			var rocks := 0
			var plant_error := 0.0
			var center := Vector2i((point / (WorldData.CHUNK_SIZE * GameConfig.TILE)).floor())
			for dz in range(-1, 2):
				for dx in range(-1, 2):
					var built := vegetation._build_outer(center + Vector2i(dx, dz))
					for e: Dictionary in built.entries:
						var rock: bool = e.kind % ForestModels.MODEL_STRIDE == Biomes.T_ROCK
						var buffer: PackedFloat32Array = e.cbuf if rock else e.get("tbuf", PackedFloat32Array())
						var stride := 16 if rock else 12
						for i in range(0, buffer.size(), stride):
							var scale := Vector3(buffer[i], buffer[i + 4], buffer[i + 8]).length()
							plant_error = maxf(plant_error, absf(buffer[i + 7] + (scale * 0.08 if rock else 0.1) - h.ground_at(buffer[i + 3], buffer[i + 11])))
							if rock: rocks += 1
							else: trees += 1
					vegetation._apply_chunk(built)
			check(plant_error < 0.005, "regional trees and stones seated: %d / %d; error %.6f m" % [trees, rocks, plant_error])
			for frame in 3: await process_frame
			await RenderingServer.frame_post_draw
			preload("res://tools/shot_util.gd").save_png(root, AUDIT, "region_%d_%d" % [key.x, key.y])
		stream.finish()
		var before := hash(stream.ledger.regions[key].fields)
		var searches := TrailScout.runs
		stream._evict(key)
		stream._load_fields(key)
		w.outer.set_ledger(stream.ledger)
		check(hash(stream.ledger.regions[key].fields) == before and Preparation.prepare_trails(w, key, stream.ledger) == plan and TrailScout.runs == searches, "recorded region unload/return: same plan and surface, no search or accumulation")
		reports.append({region = str(key), state = plan.state, verdict = plan.verdict, stats = plan.stats})
	check(found > 0, "synthetic control publishes and rides a kit; natural none results remain explicit")
	print("RECORDED maximum preparation/publication frame interval %.2f ms; show max %.2f ms" % [frame_max, stream.stats.show_ms])
	check(frame_max < 100.0, "off-thread preparation and staged publication: no frame >= 100 ms")
	stream.queue_free()
	terrain.queue_free()
	vegetation.queue_free()
	light.queue_free()
	environment.queue_free()
	camera.queue_free()
	await process_frame
	await deep_cut()
	FileAccess.open(AUDIT + "/metrics.json", FileAccess.WRITE).store_string(JSON.stringify({regions = reports, maximum_frame_ms = frame_max, checks = checks, failures = failures}, "\t"))
	print("trail_region_recorded: %d failures / %d checks" % [failures, checks])
	quit(1 if failures else 0)

func deep_cut() -> void:
	var site := preload("res://tools/trail_lab_fixture.gd").site()
	var d := TrailDefinition.new()
	d.id = "site_route"
	d.kind = "mountain"
	d.width = 3.0
	d.surface = RoadSurface.DIRT
	d.earthwork = 1.0
	d.auto_bank = 1.0
	d.shaping = TrailShaping.preset("mountain")
	d.shaping.grade_limit = 0.06
	d.shaping.strength = 1.0
	d.shaping.end_fade = 4.0
	for k in 65: d.points.append(Vector2(108.5, 84.5).lerp(Vector2(172.5, 84.5), k / 64.0))
	var got := site.prepare([d] as Array[TrailDefinition])
	check(got.errors.is_empty(), "deep cut prepared by the shared builder")
	if not got.errors.is_empty(): return
	var depth: float = got.heights.road_refinement.trail_shaping.site_route.max_cut
	check(depth > 4.0, "deep cut exceeds 4 m without a depth rejection: %.2f m" % depth)
	var lab = load("res://scenes/trail_lab.tscn").instantiate()
	root.add_child(lab)
	lab.set_physics_process(false)
	lab.set_process(false)
	lab.ground_kind = "site"
	check(lab.rebuild([d] as Array[TrailDefinition], -1, got), "deep cut rendered from the accepted surface")
	lab.editor.visible = false
	lab.hud_panel.visible = false
	lab.markers.visible = false
	lab.survey_markers.visible = false
	for child in lab.get_children():
		if child is CanvasLayer: child.visible = false
	var target := Vector3(140.5, got.heights.ground_at(140.5, 84.5) + 0.2, 84.5)
	lab.camera.look_at_from_position(target + Vector3(-15, 12, 18), target)
	for frame in 3: await process_frame
	await RenderingServer.frame_post_draw
	preload("res://tools/shot_util.gd").save_png(root, AUDIT, "deep_cut")
	lab.queue_free()
	await process_frame
