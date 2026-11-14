extends SceneTree
## A small coast across the plan seam. The outer mesh has deliberately different heights
## from the edge of the plan and uses a snapshot with no committed regions.
const Far := preload("res://scripts/render/distant_forest.gd")
const Fixture := preload("res://tools/vegetation_test.gd")
const TILE := GameConfig.TILE
const C := OuterLand.C
const SIDE := C + 3
var failures := 0


class ForestNoise extends Simplex:
	func fbm(_x: float, _y: float, _oct: int, _lac: float = 2.0, _gain: float = 0.5) -> float:
		return 0.15


func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 50)
	run.call_deferred()


func check(condition: bool, message: String) -> void:
	if condition: return
	printerr(message)
	failures += 1


func run() -> void:
	var w := Fixture.fixture(0)
	w.noise.forest = ForestNoise.new()
	while StageVegetation.world_cover(w.seed_num) < 0.0:
		w.seed_num += 1
	var heights := Heightfield.new(w, false)
	var terrain := OuterTerrain.new()
	root.add_child(terrain)
	terrain.setup(w, heights)
	var key := Vector2i(-1, 0)
	var origin := key * C
	var fields := _fields(origin)
	var built := terrain._compute(key, {}, fields)
	var mesh := terrain.stage_chunk(key, built)
	check(mesh != null, "The outer coast publishes a terrain mesh")
	_check_outer(w, key, built)
	_check_plan(w, heights)
	print("distant_vegetation_test: %d errors" % failures)
	quit(1 if failures > 0 else 0)


static func _fields(origin: Vector2i) -> Dictionary:
	var f := {}
	for field in ["h", "elev", "slope", "dist", "dw", "temp", "moist", "light"]:
		f[field] = PackedFloat32Array()
		f[field].resize(SIDE * SIDE)
	for field in ["biome", "path", "river"]:
		f[field] = PackedByteArray()
		f[field].resize(SIDE * SIDE)
	f.dist.fill(10.0)
	f.dw.fill(5.0)
	f.moist.fill(0.64)
	f.light.fill(0.76)
	for j in SIDE:
		for i in SIDE:
			var n := j * SIDE + i
			var cell := origin + Vector2i(i - 1, j - 1)
			var h := (10.0 + 0.16 * i + 0.28 * j) / GameConfig.HS
			f.biome[n] = Biomes.FOREST if j < 34 else Biomes.TUNDRA
			if cell.x < -52:
				f.biome[n] = Biomes.SHALLOW
				h = -0.1
			elif cell.x == -39:
				f.biome[n] = Biomes.LAKE # An inland water surface above sea level.
			elif cell.x == -28:
				f.river[n] = 1
			elif cell.x == -16:
				f.path[n] = 1
			f.h[n] = h
			f.elev[n] = maxf(0.0, h)
	return f


func _check_outer(w: WorldData, key: Vector2i, built: Dictionary) -> void:
	var vertices: PackedVector3Array = built.arrays[Mesh.ARRAY_VERTEX]
	var counts := {p = 0, f = 0, c = 0, s = 0}
	for part: String in built.crowns:
		var clusters: Dictionary = built.crowns[part]
		for batch in clusters:
			var entry: Dictionary = clusters[batch]
			var center := (Vector2(batch.x, batch.y) + Vector2.ONE * 0.5) * Far.SIDE
			var buf: PackedFloat32Array = entry.buffer
			counts[part] += entry.count
			for n in range(0, buf.size(), 20):
				var p := center + Vector2(buf[n + 3], buf[n + 11])
				var cell := Vector2i((p / TILE).floor())
				var local := cell - key * C + Vector2i.ONE
				var index := local.y * SIDE + local.x
				check(not Rect2i(0, 0, w.W, w.H).has_point(cell), "Outer vegetation stays outside the plan")
				check(Far.outer_dry(built.fields, index), "Outer vegetation avoids wet cells and paths")
				if part == "p" or part == "f" or part == "c":
					var expected := _mesh_height(vertices, p / TILE - Vector2(key * C) - Vector2.ONE * 0.5)
					var base := buf[n + 7] if part == "p" else buf[n + 7] + buf[n + 5] * buf[n + 17]
					check(absf(base - expected) < 0.002, "Outer plant base matches the rendered surface")
	var scrub_models := 0
	for batch: Vector3i in built.crowns.p:
		if batch.z >= Far.Form.SCRUB_BUSH: scrub_models += built.crowns.p[batch].count
	check(counts.p > scrub_models and counts.f > 0 and counts.s + scrub_models > 0,
		"The coast exercises trees, open-land plants and supplementary instances: %s, scrub models %d" % [counts, scrub_models])


static func _mesh_height(vertices: PackedVector3Array, grid: Vector2) -> float:
	var cell := Vector2i(grid.floor())
	var uv := grid - Vector2(cell)
	var a := cell.y * (C + 1) + cell.x
	var b := a + 1
	var c := a + C + 1
	var d := c + 1
	if uv.x + uv.y <= 1.0:
		return vertices[a].y * (1.0 - uv.x - uv.y) + vertices[b].y * uv.x + vertices[c].y * uv.y
	return vertices[d].y * (uv.x + uv.y - 1.0) + vertices[c].y * (1.0 - uv.x) + vertices[b].y * (1.0 - uv.y)


func _check_plan(w: WorldData, heights: Heightfield) -> void:
	w.biome.fill(Biomes.GRASS)
	for j in range(2, 62, 2):
		for i in range(2, 62, 2):
			var o := w.obj_x.size()
			w.obj_x.append(i + 0.5)
			w.obj_y.append(j + 0.5)
			var kind := Biomes.T_PINE if i % 4 == 0 else Biomes.T_OAK
			w.obj_k.append(kind)
			w.obj_v.append(j % 9)
			w.obj_s.append(1.0)
			w.chunks[(j / w.CS) * w.CW + i / w.CS].append(o)
	var batches := Far.plan(w, heights, Vector2i.ZERO, false)
	var models := _count(batches.p)
	var crowns := _count(batches.f)
	check(models + crowns == w.obj_x.size(), "A dry tree has exactly one representation in the near part of LOD3")
	var model_share := float(models) / maxf(models + crowns, 1.0)
	check(absf(model_share - Far.PLANT_SHARE) < 0.05, "Around 80 percent of dry trees receive LOD3 geometry")
	var node := Node3D.new()
	root.add_child(node)
	Far.attach(node, batches)
	for child: MultiMeshInstance3D in node.get_children():
		if child.get_meta("far_lod") != Far.PLANT: continue
		var instance := child.multimesh.get_instance_transform(0)
		var world_pos := child.to_global(instance.origin)
		check(world_pos.x >= 0.0 and world_pos.z >= 0.0 and world_pos.x < C * TILE and world_pos.z < C * TILE,
			"LOD3 MultiMesh is positioned at its own cell")
		check(not child.cast_shadow and child.visibility_range_end >= Far.far_end, "Tree LOD3 reaches the far limit without shadow casters")


static func _count(clusters: Dictionary) -> int:
	var total := 0
	for batch: Dictionary in clusters.values():
		total += batch.count
	return total
