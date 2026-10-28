extends SceneTree
const Fixture := preload("res://tools/vegetation_test.gd")
var fails := 0

class ProbeLayer extends VegetationLayer:
	var gate := Semaphore.new()
	var hold := false
	var commits := 0
	var invalid_commits := 0
	func _fill_details(px: float, pz: float, lead: Vector2, epoch: int, clock: float, immediate := false) -> void:
		if hold and not immediate:
			gate.wait()
		super._fill_details(px, pz, lead, epoch, clock, immediate)
	func _apply_grass(immediate := false) -> void:
		if not immediate and _detail_epoch != _epoch:
			invalid_commits += 1
		commits += 1
		super._apply_grass(immediate)

func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 300)
	run.call_deferred()

func check(ok: bool, label: String) -> void:
	print(("OK " if ok else "FAIL ") + label)
	if not ok:
		fails += 1

func run() -> void:
	Engine.max_fps = 60
	var w := Fixture.fixture(0)
	w.biome.fill(Biomes.GRASS)
	w.obj_x.append(245.0)
	w.obj_y.append(128.0)
	w.obj_k.append(Biomes.T_CACTUS)
	w.obj_v.append(0)
	w.obj_s.append(1.0)
	w.obj_count = 1
	w.chunks[(128 / w.CS) * w.CW + 245 / w.CS].append(0)
	var h := Heightfield.new(w, false)
	var veg := ProbeLayer.new()
	veg.settings = GameSettings.new()
	veg.settings.draw = 0
	root.add_child(veg)
	veg.setup(w, h, Models.tree_defs(), Models.grass_mesh())
	veg.update(512, 512, true, 1.0 / 60.0)
	check(veg.grass.visible_instance_count == veg._grass_n, "Initial force publishes a complete snapshot")
	for entry: Dictionary in veg.understory:
		check(entry.node.visibility_range_end == 0.0, "Understory distance is controlled per instance, not by batch center")
	veg.hold = true
	veg.update(632, 512, false, 1.0 / 60.0)
	check(veg._task != -1 and veg._tree_task != -1, "Trees and detail preparation use independent tasks")
	var cactus_key := Vector3i(15, 8, Biomes.T_CACTUS)
	var before_clock := veg.stream.clock
	for i in 5:
		await process_frame
		veg.update(632, 512, false, 1.0 / 60.0, false)
	check(not veg.veg.has(cactus_key) and veg.stream.clock > before_clock, "Reserved frames defer GPU work while keeping shader time and background preparation active")
	for i in 120:
		await process_frame
		veg.update(632, 512, false, 1.0 / 60.0)
		if veg.veg.has(cactus_key):
			break
	check(veg.veg.has(cactus_key) and veg._task != -1, "A delayed grass task does not block cactus/tree uploads")
	if veg.veg.has(cactus_key):
		var node: MultiMeshInstance3D = veg.veg[cactus_key].nodes[0]
		check(node.material_override.get_shader_parameter("stream_birth") > 0.0, "Opaque models use the same temporal reveal as cutout crowns")
	var previous_commits := veg.commits
	veg.refresh(Rect2i(0, 0, 1, 1))
	veg.hold = false
	veg.gate.post()
	for i in 240:
		await process_frame
		if WorkerThreadPool.is_task_completed(veg._task):
			break
	var furthest := -INF
	for i in veg._grass_n:
		furthest = maxf(furthest, veg.grass_buf[i * VegetationLayer.STRIDE + 3])
	check(furthest > 632 + veg.grass_r + 20, "The real worker fills the forward corridor beyond the current grass circle")
	veg.update(632, 512, false, 1.0 / 60.0)
	check(veg.commits == previous_commits and veg.invalid_commits == 0, "Region changes reject obsolete detail results")
	var route_start := veg.commits
	var previous: PackedFloat32Array = veg.snapshots.displayed[-1]
	var continuity := true
	for i in 90:
		await process_frame
		var before := veg.commits
		veg.update(632.0 + (i + 1) * 45.0 / 60.0, 512, false, 1.0 / 60.0)
		if veg.commits != before:
			var old := {}
			for at in range(0, previous.size(), 20):
				old[veg.Snapshots.key(previous, at)] = previous[at + 19]
			var current: PackedFloat32Array = veg.snapshots.displayed[-1]
			for at in range(0, current.size(), 20):
				var id := veg.Snapshots.key(current, at)
				var alpha := veg.Snapshots.opacity(current[at + 19], veg.stream.clock)
				var expected := veg.Snapshots.opacity(old[id], veg.stream.clock) if old.has(id) else 0.0
				continuity = continuity and absf(alpha - expected) < 0.00001
			previous = current
	check(veg.commits > route_start + 1 and continuity, "Repeated real worker snapshots at 45 m/s preserve shared, incoming and outgoing opacity")
	veg.update(800, 800, true, 1.0 / 60.0)
	check(veg._task == -1 and veg._tree_task == -1 and veg._pending.is_empty() and veg._queued.is_empty(), "Teleport joins both workers and clears queued data")
	check(veg._fill_lead == Vector2.ZERO and veg.stream.velocity == Vector2.ZERO, "Teleport resets prediction")
	check(veg.grass.visible_instance_count == veg._grass_n, "Teleport replaces outgoing history instead of retaining the old location")
	veg.free()
	await process_frame
	print("vegetation_stream_integration_test: %d failures" % fails)
	quit(1 if fails else 0)
