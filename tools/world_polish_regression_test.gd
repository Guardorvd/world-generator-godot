extends SceneTree
const Saves = preload("res://scripts/game/save_game.gd")
const Quests = preload("res://scripts/game/quests.gd")
var failures := 0

class CaptureBatch extends MeshBatch:
	var transforms: Array[Transform3D] = []
	func add(_mesh: Mesh, at: Transform3D, _mat: Material) -> void:
		transforms.append(at)

func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 60)
	run.call_deferred()

func check(ok: bool, label: String) -> void:
	print("PASS " if ok else "FAIL ", label)
	failures += int(not ok)

func run() -> void:
	_test_bake_bounds()
	_test_bridges()
	_test_save_mode()
	print("world_polish_regression: ", failures, " failures")
	quit(1 if failures else 0)

func _test_bake_bounds() -> void:
	var w := WorldData.new()
	w.W = 4; w.H = 3; w.N = 12
	var h := Heightfield.new()
	h.world = w
	h.road_refinement = RoadRefinement.new()
	var d := TrailDefinition.new()
	d.points = PackedVector2Array([Vector2.ZERO, Vector2(0, 2)])
	var e := TrailElement.new()
	e.station = 0; e.length = 1
	var zone := {}
	for i in w.N: zone[i] = {}
	var limits := {bake = {plan = {zone = zone}, before = {}, baked = {}, stats = {}}}
	# Invalid tiny fixture stops at validation after collecting the cells, before baking.
	TrailBuilder.bake_without(h, d, [e] as Array[TrailElement], limits)
	var cells: Dictionary = limits.again.cells
	var bounded := not cells.is_empty()
	for key: int in cells:
		bounded = bounded and key >= 0 and key % w.W < w.W - 1 and key / w.W < w.H - 1
	check(bounded, "edge rebake never aliases an out-of-grid coordinate to another row")

func _test_bridges() -> void:
	var batch := CaptureBatch.new()
	var h := Heightfield.new()
	var mat := StandardMaterial3D.new()
	for length in [0.0, 0.001, 4.0]:
		var s := {len = length, ux = 0.0, uz = 0.0, half = 1.0, ax = 0.0, az = 0.0, ay = 0.0, bx = 0.0, bz = 0.0, by = 0.0, arch = 0.0}
		StructuresBuilder.bridge(batch, h, s, mat, mat, mat)
		StructuresBuilder.stone_bridge(batch, h, s, mat, mat, mat)
		StructuresBuilder.planks(batch, h, s, mat, mat, mat)
	StructuresBuilder._deck(batch, Vector3.ZERO, Vector3.ZERO, 1.0, mat)
	StructuresBuilder._deck(batch, Vector3.ZERO, Vector3.UP, 1.0, mat)
	check(batch.transforms.is_empty(), "zero-length and vertical bridge spans produce no degenerate geometry")
	StructuresBuilder._deck(batch, Vector3.ZERO, Vector3(0, 1, 4), 1.0, mat)
	check(batch.transforms.size() == 1 and batch.transforms[0].is_finite() and absf(batch.transforms[0].basis.determinant()) > 0.99,
		"ordinary sloped deck retains a finite invertible basis")
	StructuresBuilder._boxes.clear()

func _test_save_mode() -> void:
	var old_root := RegionStream.root
	var old_saves := Saves.dir
	var folder := "res://.godot/world_polish_%d_%d" % [OS.get_process_id(), Time.get_ticks_usec()]
	RegionStream.root = folder.path_join("regions")
	Saves.dir = folder.path_join("saves")
	var w := WorldData.new()
	w.W = 4; w.H = 4; w.N = 16; w.seed_text = "polish"
	w.region_basis_id = "polish"; w.region_store_leaf = "polish"
	w.outer = OuterLand.new()
	var town := SettlementData.new(10, 10, 0, "Saved town")
	town.id = "region:town"
	var ledger := {regions = {}, settlements = [town]}
	var path := RegionStream.store_dir(w).path_join("ledger.bin")
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	check(RegionStream._write(path, {format = RegionStream.FORMAT, ledger = ledger}) == OK, "isolated regional journal written")
	var state := {format = 1, seed = w.seed_text, signature = GameWorld.save_signature(w), saved_at = 1,
		visited = {town.id: true}, goal = town.id, quest = Quests.new().save_state(),
		player = {x = 40.0, z = 40.0, feet = 0.0, yaw = 0.0, pitch = 0.0, hour = 12.0},
		bike = {x = 40.0, z = 40.0, y = 0.0, heading = 0.0, riding = false}}
	check(Saves.write_slot(state) == OK, "regional progress saved")
	var settings := GameSettings.new()
	for infinite in [false, true, false]:
		settings.infinite_world = infinite
		w.outer.set_ledger({})
		var saved: Dictionary = Saves.read_slot(w.seed_text).data
		check(GameWorld.can_restore(saved, w, settings), "regional save restores with infinite_world=%s" % infinite)
		check(not w.place(town.id).is_empty(), "regional destinations remain available")
	var stream := RegionStream.new()
	stream.world = w
	stream.generation_enabled = false
	stream.queue = [Vector2i(2, 2)]
	stream.update(40, 40)
	check(stream._task == -1 and stream.queue.size() == 1, "disabled infinite mode does not start queued new regions")
	stream.free()
	Saves.delete_seed(w.seed_text)
	DirAccess.remove_absolute(path)
	DirAccess.remove_absolute(path.get_base_dir())
	DirAccess.remove_absolute(RegionStream.root)
	DirAccess.remove_absolute(Saves.dir)
	DirAccess.remove_absolute(folder)
	RegionStream.root = old_root
	Saves.dir = old_saves
