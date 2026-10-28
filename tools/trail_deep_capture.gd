extends "res://tools/trail_region_recorded_test.gd"
## Focused visual correction: the first deep-cut view hid the excavation behind its near slope.
func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 60)
	run.call_deferred()

func run() -> void:
	var primitive := BoxMesh.new()
	primitive.size = Vector3(2, 3, 4)
	var transform := Transform3D(Basis.from_euler(Vector3(0.2, 0.6, -0.1)).scaled(Vector3(1.3, 0.7, 2.0)), Vector3(20, 5, 30))
	var batch := MeshBatch.new()
	batch.add(primitive, transform, StandardMaterial3D.new())
	var node := batch.build("Check")
	var arrays: Array = node.get_child(0).mesh.surface_get_arrays(0)
	var original: PackedVector3Array = primitive.get_mesh_arrays()[Mesh.ARRAY_VERTEX]
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var worst := 0.0
	for i in vertices.size(): worst = maxf(worst, vertices[i].distance_to(transform * original[i]))
	check(vertices.size() == original.size() and worst < 0.00001, "MeshBatch cached CPU geometry preserves transformed primitive vertices")
	node.free()
	var site := preload("res://tools/trail_lab_fixture.gd").site()
	var d := TrailDefinition.new()
	d.id = "site_route"
	d.kind = "mountain"
	d.width = 3.0
	d.surface = RoadSurface.DIRT
	d.earthwork = 1.0
	d.shaping = TrailShaping.preset("mountain")
	d.shaping.grade_limit = 0.06
	d.shaping.strength = 1.0
	d.shaping.end_fade = 4.0
	for i in 65: d.points.append(Vector2(108.5, 84.5).lerp(Vector2(172.5, 84.5), i / 64.0))
	var ready := site.prepare([d] as Array[TrailDefinition])
	check(ready.errors.is_empty(), "deep surface built by production chain")
	if not ready.errors.is_empty(): quit(1); return
	var h: Heightfield = ready.heights
	var station := 0.0
	var depth := 0.0
	for i in 65:
		var at := d.point_at(i)
		var cut := site.ground_at(at) - h.ground_at(at.x, at.y)
		if cut > depth: depth = cut; station = i
	check(depth > 4.0, "deepest axis cut %.2f m at %.0f m" % [depth, station])
	var point := d.point_at(station)
	var target := Vector3(point.x, h.ground_at(point.x, point.y) + 0.2, point.y)
	var lab = load("res://scenes/trail_lab.tscn").instantiate()
	root.add_child(lab)
	lab.set_process(false)
	lab.set_physics_process(false)
	lab.ground_kind = "site"
	check(lab.rebuild([d] as Array[TrailDefinition], -1, ready), "deep excavation displayed from final triangles")
	for child in lab.get_children():
		if child is CanvasLayer: child.visible = false
	lab.editor.visible = false
	lab.markers.visible = false
	lab.survey_markers.visible = false
	lab.reset_ride(station, 0.0)
	for tick in 20: lab.controller.ride(1.0 / 60.0, lab.player, lab.bike, h.world, h, 0, 0, false, false, false)
	lab.view.snap(lab.bike)
	lab.view.draw(1.0)
	var wheel_gap := 0.0
	for wheel: Node3D in [lab.view.front_wheel, lab.view.rear_wheel]:
		var p := wheel.global_position
		wheel_gap = maxf(wheel_gap, absf(p.y - BikeRide.WHEEL_R - h.ground_at(p.x, p.z)))
	check(wheel_gap < 0.05, "settled bike view matches wheel contact: %.4f m" % wheel_gap)
	var w := h.world
	w.obj_x = PackedFloat64Array()
	w.obj_y = PackedFloat64Array()
	w.obj_k = PackedInt32Array()
	w.obj_v = PackedInt32Array()
	w.obj_s = PackedFloat64Array()
	w.CW = ceili(float(w.W) / w.CS)
	w.CH = ceili(float(w.H) / w.CS)
	var chunks: Array[PackedInt32Array] = []
	chunks.resize(w.CW * w.CH)
	for side: float in [-1, 1]:
		for offset: float in [4, 6, 9, 12]:
			for along: float in [-7, 0, 7]:
				var pos := point + Vector2(along, side * offset)
				var at := w.obj_x.size()
				w.obj_x.append(pos.x / GameConfig.TILE)
				w.obj_y.append(pos.y / GameConfig.TILE)
				w.obj_k.append(Biomes.T_OAK if along == 0 else Biomes.T_ROCK)
				w.obj_v.append(0)
				w.obj_s.append(0.8 if along == 0 else 0.35)
				var chunk := Vector2i((pos / (w.CS * GameConfig.TILE)).floor())
				chunks[chunk.y * w.CW + chunk.x].append(at)
	w.chunks = chunks
	w.obj_count = w.obj_x.size()
	var vegetation := VegetationLayer.new()
	root.add_child(vegetation)
	vegetation.setup(w, h, Models.tree_defs(), Models.grass_mesh())
	var trees := 0
	var rocks := 0
	var changed_trees := 0
	var seat_error := 0.0
	for cy in w.CH:
		for cx in w.CW:
			if w.chunks[cy * w.CW + cx].is_empty(): continue
			var built := vegetation._build_chunk(Vector2i(cx, cy))
			for e: Dictionary in built.entries:
				var rock: bool = e.kind % ForestModels.MODEL_STRIDE == Biomes.T_ROCK
				var buffer: PackedFloat32Array = e.cbuf if rock else e.tbuf
				var stride := 16 if rock else 12
				for i in range(0, buffer.size(), stride):
					var x := buffer[i + 3]
					var z := buffer[i + 11]
					var scale := Vector3(buffer[i], buffer[i + 4], buffer[i + 8]).length()
					seat_error = maxf(seat_error, absf(buffer[i + 7] + (scale * 0.08 if rock else 0.1) - h.ground_at(x, z)))
					if rock: rocks += 1
					else:
						trees += 1
						changed_trees += int(absf(site.ground_at(Vector2(x, z)) - h.ground_at(x, z)) > 0.1)
			vegetation._apply_chunk(built)
	check(trees > 0 and changed_trees > 0 and rocks > 0 and seat_error < 0.005, "trees/rocks on reshaped land: %d trees (%d changed), %d seated rocks, max %.6f m" % [trees, changed_trees, rocks, seat_error])
	lab.camera.current = true
	lab.camera.fov = 55
	var offsets := {deep_overhead = Vector3(-7, 17, 8), deep_along = Vector3(-15, 8, 2), deep_side = Vector3(0, 10, 14)}
	for name: String in offsets:
		lab.camera.look_at_from_position(target + offsets[name], target)
		for frame in 3: await process_frame
		await RenderingServer.frame_post_draw
		preload("res://tools/shot_util.gd").save_png(root, AUDIT, name)
	vegetation.queue_free()
	lab.queue_free()
	await process_frame
	print("trail_deep_capture: %d failures / %d checks" % [failures, checks])
	quit(1 if failures else 0)
