extends SceneTree
## Published region snapshots only: no geography, route generation or live OuterLand reads.
const Fixture := preload("res://tools/vegetation_test.gd")
const Placement := preload("res://scripts/render/vegetation_placement.gd")
const Floor := preload("res://scripts/render/forest_floor.gd")
var failures := 0

func check(ok: bool, label: String) -> void:
	print("REGION NATURE ", "PASS " if ok else "FAIL ", label)
	if not ok: failures += 1

func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 60)
	var w: WorldData = Fixture.fixture(0)
	w.seed_num = 4821
	var h := Heightfield.new(w, false)
	var rect := Rect2i(256, 0, 256, 256)
	var f := {}
	for name in ["h", "elev", "slope", "dw", "moist", "light"]:
		var values := PackedFloat32Array()
		values.resize(w.N)
		values.fill(0.1 if name in ["h", "elev"] else (50.0 if name == "dw" else 0.6))
		f[name] = values
	for name in ["ocean", "river", "lake", "village", "path", "biome"]:
		var values := PackedByteArray()
		values.resize(w.N)
		f[name] = values
	var local := {kind = "trail", pts = [], surf = PackedByteArray()}
	var trail := {kind = "trail", pts = [], surf = PackedByteArray()}
	for y in range(60, 196):
		local.pts.append({x = 14.5, y = y + 0.5, w = 0.6})
		trail.pts.append({x = 270.5, y = y + 0.5, w = 0.6})
		local.surf.append(RoadSurface.FOREST)
		trail.surf.append(RoadSurface.FOREST)
		f.path[y * 256 + 14] = 2
	f.dist_path = StageVegetation.path_clearance(256, 256, [local])
	var regions := {Vector2i(1, 0): {rect = rect, fields = f, decor = {trails = [trail]}}}
	var batch := {x = PackedFloat64Array(), y = PackedFloat64Array(), k = PackedInt32Array(), s = PackedFloat64Array()}
	for y in range(63, 193, 3):
		batch.x.append(270.98)
		batch.y.append(y + 0.3)
		batch.k.append(Biomes.T_OAK)
		batch.s.append(1.2)
	var batches := [{x = w.obj_x, y = w.obj_y, k = w.obj_k, s = w.obj_s}, batch]
	var p := Placement.new(w, h)
	p.regions = regions
	p.canopy_rect = rect
	p.outer_canopy = Floor.canopy_image(rect, batches)
	p.prepare(1082, 512, 400)
	p.prepare_outer(batches, 1082, 512, 400)
	check(not p.region_clear(1082, 514), "полотно защищено по расстоянию")
	check(p.region_clear(1083.9, 514), "обочина в той же дорожной клетке доступна подлеску")
	check(p.ground_clear(1088, 514, 0.3), "региональное размещение не отсекается границей стартового плана")
	check(absf(p.ground_at(1088, 514) - RegionStream.snapshot_ground(w, h, regions, 1088, 514)) < 0.00001, "подлесок читает поверхность меша региона")
	var road := RoadObstacles.new(w)
	road.sync_regions(regions, p, batches)
	var image := Image.create(256, 256, false, Image.FORMAT_RGBA8)
	var pairs := road.around(1082, 512, 300)
	road.begin_fill(h, image, pairs)
	var results := []
	var roots := 0
	for i in range(0, pairs.size(), 2):
		var o := road.pick(h, image, pairs[i], pairs[i + 1])
		results.append(o)
		if not o.is_empty() and o.kind == RoadObstacles.ROOT: roots += 1
	check(not pairs.is_empty() and roots > 0, "существующий маршрут региона получает корни от реальных региональных деревьев")
	var loaded := RoadObstacles.new(w)
	loaded.sync_regions(regions.duplicate(), p, batches)
	var again := []
	for i in range(0, pairs.size(), 2): again.append(loaded.pick(h, image, pairs[i], pairs[i + 1]))
	check(var_to_bytes(results) == var_to_bytes(again), "повторная загрузка региона сохраняет раскладку и владельцев")
	road.sync_regions({}, p)
	check(road.around(1082, 512, 300).is_empty() and road._cache.is_empty(), "выгрузка удаляет региональные маршруты и кандидаты")
	print("REGION NATURE DONE failures=", failures, " roots=", roots)
	quit(1 if failures else 0)
