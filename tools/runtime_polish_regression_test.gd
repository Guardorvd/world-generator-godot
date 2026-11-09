extends SceneTree
const V = preload("res://scripts/trails/trail_validation.gd")
const S = preload("res://scripts/trails/trail_standards.gd")
var failures := 0

class SpawnGround extends Heightfield:
	var flooded := false
	func ground_at(_x: float, _z: float, _raw := false) -> float: return 10.0
	func known(_x: float, _z: float) -> bool: return true
	func depth_at(x: float, z: float, _feet := -INF) -> float:
		return 2.0 if flooded or Vector2(x, z).distance_to(Vector2(128, 128)) < 12.0 else 0.0

class ProfileGround extends Heightfield:
	var grade := 0.0
	var drop := 0.0
	func ground_at(_x: float, z: float, _raw := false) -> float:
		var station := 220.0 - z
		return 100.0 + station * grade - drop * clampf(station - 2.0, 0.0, 1.0)

class QuietTerrain extends OuterTerrain:
	func _wanted(_x: float, _z: float, _radius := RADIUS) -> Array[Vector2i]: return []
	func stage_chunk(_key: Vector2i, _built: Dictionary) -> MeshInstance3D: return null

class PendingTerrain extends QuietTerrain:
	func _wanted(_x: float, _z: float, _radius := RADIUS) -> Array[Vector2i]: return [Vector2i(-1, 0)]
	func _build(_key: Vector2i, _snapshot: Variant = null, _prepared_fields := {}) -> Dictionary:
		return {fields = {h = PackedFloat32Array([1.0])}}

func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 90)
	run.call_deferred()

func check(ok: bool, label: String) -> void:
	print("PASS " if ok else "FAIL ", label)
	failures += int(not ok)

func run() -> void:
	_test_spawn()
	_test_slide()
	_test_save_snapshot()
	_test_road_edge()
	_test_speed()
	_test_chunk_retirement()
	await _test_stationary_chunk_retry()
	print("runtime_polish_regression: ", failures, " failures")
	quit(1 if failures else 0)

func _world() -> WorldData:
	var w := WorldData.new()
	w.W = 64; w.H = 64; w.N = 4096
	w.available_rect = Rect2i(0, 0, 64, 64)
	return w

func _test_spawn() -> void:
	var w := _world()
	var h := SpawnGround.new()
	h.world = w
	var town := SettlementData.new(32, 32, 0, "Flooded home")
	var hut := HutData.new()
	hut.x = 32; hut.y = 35; hut.t = "house"
	town.huts.append(hut)
	w.settlements.append(town)
	var p := PlayerState.spawn(w, h)
	check(p != null and PlayerState.is_passable(w, h, p.x, p.z, p.feet, PlayerState.BODY_R),
		"flooded eight spawn candidates fall back to dry unobstructed ground")
	w.settlements.clear()
	p = PlayerState.spawn(w, h)
	check(p != null and h.depth_at(p.x, p.z) == 0.0, "world without settlements also checks its fallback")
	h.flooded = true
	check(PlayerState.spawn(w, h) == null, "fully flooded world reports no safe spawn")
	check(PlayerState.arrive(w, h, {kind = "peak", x = 32.0, y = 32.0}) == null,
		"failed arrival cannot return an unchecked flooded point")
	var loader := WorldLoader.new()
	loader.world = w; loader.heights = h
	loader.prepare_streaming()
	check(not loader.error.is_empty() and loader.chunk_source == null, "loader reports missing safe spawn before prewarming")

func _test_slide() -> void:
	var short_wall := func(x: float, z: float) -> bool: return x < 0.3 or z > 0.45
	var to := PlayerState.slide(short_wall, 0, 0, 1, 1)
	check(to[0] > 0.7 and is_equal_approx(to[1], 1.0), "movement resumes across X after clearing the end of a wall")
	to = PlayerState.slide(func(x: float, z: float) -> bool: return short_wall.call(z, x), 0, 0, 1, 1)
	check(to[1] > 0.7 and is_equal_approx(to[0], 1.0), "movement resumes across Z symmetrically")
	to = PlayerState.slide(func(x: float, _z: float) -> bool: return x < 0.3, 0, 0, 1, 1)
	check(to[0] < 0.3 and is_equal_approx(to[1], 1.0), "continuous wall still blocks crossing while allowing slide")

func _test_save_snapshot() -> void:
	var w := _world()
	w.outer = OuterLand.new()
	w.region_basis_id = "snapshot"; w.region_store_leaf = "snapshot"
	var old_root := RegionStream.root
	RegionStream.root = "res://.godot/polish_snapshot_%d_%d" % [OS.get_process_id(), Time.get_ticks_usec()]
	var key := Vector2i(1, 0)
	var town := SettlementData.new(70, 10, 0, "Before")
	var entry := {rect = Rect2i(64, 0, 1, 1), fields = {h = PackedFloat32Array([7])},
		decor = {settlements = [town], bridges = [], trails = []}, trail_plan = {state = "before"}}
	var stream := RegionStream.new()
	stream.world = w
	stream.ledger = {regions = {key: entry}, settlements = [town]}
	# Hold the writer until after mutations: this deterministically exercises snapshot ownership.
	RegionStream._store_lock.lock()
	stream._persist(key)
	town.name = "After"
	entry.trail_plan.state = "after"
	entry.fields.h[0] = 99
	stream._evict(key)
	RegionStream._store_lock.unlock()
	stream.finish()
	var folder := RegionStream.store_dir(w)
	var stored: Variant = RegionStream._read(folder.path_join("ledger.bin"))
	var good := stored is Dictionary
	if good:
		var saved: Dictionary = stored.ledger
		good = saved.settlements[0].name == "Before" and saved.regions[key].decor.settlements[0].name == "Before" \
			and saved.regions[key].trail_plan.state == "before"
		var fields: Variant = RegionStream._read(folder.path_join(saved.regions[key].field_file))
		good = good and fields is Dictionary and fields.fields.h[0] == 7
	check(good, "background save owns metadata, entity records and pre-eviction fields")
	stream.free()
	for name: String in DirAccess.get_files_at(folder): DirAccess.remove_absolute(folder.path_join(name))
	DirAccess.remove_absolute(folder)
	DirAccess.remove_absolute(RegionStream.root)
	RegionStream.root = old_root

func _test_speed() -> void:
	var h := ProfileGround.new()
	h.world = _world()
	var d := TrailDefinition.new()
	d.id = "polish_slope"
	d.points = PackedVector2Array([Vector2(100, 220), Vector2(100, 40)])
	for slope in [-0.5, -2.0, -10.0]:
		h.grade = slope
		var report := V.measure(h, d)
		var finite: bool = report.scenarios.size() == 3
		for scenario: Dictionary in report.scenarios.values():
			for speed: float in scenario.speeds: finite = finite and is_finite(speed) and speed >= 0.5
		check(finite, "steep descent %s retains finite nonzero speed profiles" % slope)
	h.grade = 0.0; h.drop = 6.0
	var report := V.measure(h, d)
	var limited: bool = report.scenarios.size() == 3
	for scenario: Dictionary in report.scenarios.values():
		var speeds: PackedFloat32Array = scenario.speeds
		limited = limited and speeds[3] * speeds[3] - speeds[2] * speeds[2] <= 2.0 * (S.G + S.PEDAL) + 0.001
	check(limited, "sharp drop does not create gravity acceleration greater than G")

func _test_road_edge() -> void:
	var h := Heightfield.new()
	h.world = _world()
	h.water_level.resize(h.world.N)
	h.water_level.fill(-INF)
	h.structures = [{ax = 1.0, az = 1.0, bx = 12.0, bz = 1.0}]
	var refinement := RoadRefinement.new()
	refinement._heights = h
	refinement._index_structures()
	check(refinement._fit_safe(Vector2(1, 8), Vector2.RIGHT, 0, 0.0, true) == 0
		and refinement._fit_safe(Vector2(8, 1), Vector2.RIGHT, 0, 0.0, true) == 0,
		"bridge protection covers the left and top half cells")
	check(refinement._fit_safe(Vector2(-1, 120), Vector2.RIGHT, 0, 0.0, true) == 0
		and refinement._fit_safe(Vector2(40, 120), Vector2.RIGHT, 0, 0.0, true) == 3,
		"fit checks reject outside samples without wrapping to another row")

func _test_chunk_retirement() -> void:
	var terrain := QuietTerrain.new()
	terrain.world = _world()
	terrain.land = OuterLand.new()
	terrain._task_limit = 0
	var bounded := true
	var peak := 0
	for step in 200:
		var built := {}
		var nodes := {}
		for row in range(-2, 3):
			var key := Vector2i(step, row)
			built[key] = {fields = {h = PackedFloat32Array([step])}}
			nodes[key] = null
		terrain.publish_chunks(built, nodes)
		terrain.update((step + 0.5) * OuterLand.C * GameConfig.TILE, 0.0)
		peak = maxi(peak, terrain.land.chunks.size())
		bounded = bounded and terrain.land.chunks.size() == terrain._nodes.size() and terrain.land.chunks.size() <= 40
	check(bounded, "200 chunk transitions retire distant OuterLand fields (peak=%d)" % peak)
	terrain.free()


func _test_stationary_chunk_retry() -> void:
	var terrain := PendingTerrain.new()
	terrain.world = _world()
	terrain.land = OuterLand.new()
	var key := Vector2i(-1, 0)
	terrain.update(0.0, 0.0)
	terrain.refresh(Rect2i(key * OuterLand.C, Vector2i.ONE * OuterLand.C))
	while not WorkerThreadPool.is_task_completed(terrain._tasks[key].id): await process_frame
	terrain.update(0.0, 0.0)
	check(terrain._tasks.has(key) and not terrain._nodes.has(key), "stale first chunk is rescheduled with a stationary player")
	if terrain._tasks.has(key):
		while not WorkerThreadPool.is_task_completed(terrain._tasks[key].id): await process_frame
		terrain.update(0.0, 0.0)
	check(terrain.land.chunks.has(key), "replacement chunk publishes without a movement threshold")
	terrain.free()
