extends SceneTree
## 8.8: реальная физика через границу стартового окна и точная геометрия потоковых частей.
class TravelWorld extends WorldData:
	func tile_info(_x: float, _z: float) -> Dictionary:
		return {biome = Biomes.GRASS, path = 3, surface = RoadSurface.PACKED}

class TravelGround extends Heightfield:
	func _init(w: WorldData) -> void:
		super(w, false)
	func ground_at(_x: float, _z: float, _raw := false) -> float:
		return 10.0
	func depth_at(_x: float, _z: float, _feet := -INF) -> float:
		return 0.0
	func known(_x: float, _z: float) -> bool:
		return true

var fails := 0


func check(ok: bool, label: String) -> void:
	print(("✓ " if ok else "✗ ") + label)
	fails += int(not ok)


func travel_world() -> TravelWorld:
	var w := TravelWorld.new()
	w.W = 768
	w.H = 768
	w.territory_center = Vector2i(384, 384)
	w.expand_territory(256)
	return w


func driving() -> void:
	var w := travel_world()
	var ground := TravelGround.new(w)
	var original := w.available_rect
	check(not PlayerState.is_passable(w, ground, (original.end.x + 1) * GameConfig.TILE, 384 * GameConfig.TILE),
		"стенд действительно воспроизводит прежнюю непроходимую границу")
	check(not w.open_around(384, 384), "в центре окна нет лишнего расширения")
	var p := PlayerState.new()
	p.x = original.end.x * GameConfig.TILE - 20.0
	p.z = 384 * GameConfig.TILE
	p.feet = 10.0
	var b := BikeRide.park_near(p, -PI * 0.5, w, ground)
	b.mount(p)
	for tick in 600:
		w.open_around(p.x / GameConfig.TILE, p.z / GameConfig.TILE)
		b.step(p, 1.0, 0.0, false, false, 1.0 / 60.0, w, ground)
	check(p.x > (original.end.x + 8) * GameConfig.TILE and not b.crashed,
		"BikeRide.step проезжает бывшую границу под педалями без кнопки расширения")
	var expanded := w.available_rect
	var revision := w.territory_revision
	b.heading = PI * 0.5
	for tick in 900:
		w.open_around(p.x / GameConfig.TILE, p.z / GameConfig.TILE)
		b.step(p, 1.0, 0.0, false, false, 1.0 / 60.0, w, ground)
	check(p.x < original.end.x * GameConfig.TILE - 20.0 and w.available_rect == expanded and w.territory_revision == revision,
		"велосипед возвращается в исходную область, открытая территория сохраняется")
	var foot_world := travel_world()
	var foot_ground := TravelGround.new(foot_world)
	p = PlayerState.new()
	p.x = 384 * GameConfig.TILE
	p.z = original.position.y * GameConfig.TILE + 10.0
	p.feet = 10.0
	for tick in 600:
		foot_world.open_around(p.x / GameConfig.TILE, p.z / GameConfig.TILE)
		p.step(1.0, 0.0, true, false, 0.0, 1.0 / 60.0, foot_world, foot_ground)
	check(p.z < original.position.y * GameConfig.TILE - 10.0, "пешеход проходит границу в другом направлении")
	for at: Vector2 in [Vector2(270, 384), Vector2(498, 384), Vector2(384, 270), Vector2(384, 498), Vector2(498, 498)]:
		var sample := travel_world()
		check(sample.open_around(at.x, at.y) and sample.available_rect.encloses(original)
			and sample.accessible(at.x, at.y, WorldData.TRAVEL_MARGIN), "сосед открывается заранее у %s" % at)
	w.open_around(750, 750)
	check(w.available_rect == Rect2i(0, 0, 768, 768) and not w.open_around(-1, 384)
		and not PlayerState.is_passable(w, ground, 769 * GameConfig.TILE, 384 * GameConfig.TILE),
		"полный план доступен, декоративное продолжение не выдаётся за игровой мир")
	var edge := travel_world()
	edge.territory_center = Vector2i(0, 0)
	edge.available_rect = Rect2i()
	edge.expand_territory(256)
	check(not edge.open_around(1, 1), "внешний край не открывает весь план без движения к соседям")


func geometry() -> Dictionary:
	var w := WorldData.new()
	w.W = 130
	w.H = 130
	w.N = w.W * w.H
	for key in ["h", "filled", "slope", "cost", "dist_water"]:
		var values := PackedFloat32Array()
		values.resize(w.N)
		w.set(key, values)
	w.h.fill(0.1)
	w.cost.fill(1.0)
	w.dist_water.fill(100.0)
	for key in ["ocean", "lake", "river", "biome", "path_mask"]:
		var values := PackedByteArray()
		values.resize(w.N)
		w.set(key, values)
	w.biome.fill(Biomes.GRASS)
	w.trails = [{kind = "road", pts = [{x = 4.5, y = 64.5, w = 0.9}, {x = 125.5, y = 64.5, w = 0.9}]}]
	for x in range(4, 126): w.path_mask[64 * w.W + x] = 3
	RoadSurface.run(w)
	var heights := Heightfield.new(w)
	var arrays := TerrainBuilder.build_arrays(w, heights)
	var before := var_to_bytes(arrays)
	var pieces := PlanTerrain.partition(arrays)
	var slots := [Mesh.ARRAY_VERTEX, Mesh.ARRAY_NORMAL, Mesh.ARRAY_TEX_UV, Mesh.ARRAY_TEX_UV2, Mesh.ARRAY_COLOR]
	var source_ids := {}
	var positions: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	for id in positions.size(): source_ids[positions[id]] = id
	var triangles := {}
	var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	for at in range(0, indices.size(), 3): triangles[Vector3i(indices[at], indices[at + 1], indices[at + 2])] = 0
	var valid := true
	var total := 0
	for piece: Array in pieces.values():
		var remap := PackedInt32Array()
		for id in piece[Mesh.ARRAY_VERTEX].size():
			var original: int = source_ids[piece[Mesh.ARRAY_VERTEX][id]]
			remap.append(original)
			for slot: int in slots: valid = valid and piece[slot][id] == arrays[slot][original]
		var local: PackedInt32Array = piece[Mesh.ARRAY_INDEX]
		for at in range(0, local.size(), 3):
			var triangle := Vector3i(remap[local[at]], remap[local[at + 1]], remap[local[at + 2]])
			valid = valid and triangles.has(triangle)
			triangles[triangle] = triangles.get(triangle, 0) + 1
			total += 3
	for count: int in triangles.values(): valid = valid and count == 1
	check(valid and total == indices.size(), "каждый исходный треугольник присутствует ровно один раз, все атрибуты совпадают")
	check(pieces.size() == 9 and not heights.road_refinement.patches.is_empty(),
		"метровое полотно дороги разделено между соседними частями без повторной триангуляции")
	check(var_to_bytes(arrays) == before, "подготовка частей не меняет рельеф, нормали и дорожное покрытие")
	return pieces


## 9.0: старт готовит только ближнюю землю, очередь берёт сначала части впереди по ходу.
## Ряд частей вдоль x; игрок едет на +x, хотя часть -2 к нему чуть ближе, чем часть 2.
func ahead_first(arrays: Array) -> void:
	var row := {}
	for k in range(-3, 4):
		row[Vector2i(k, 0)] = arrays
	var stream := PlanTerrain.new()
	root.add_child(stream)
	stream.setup(row, StandardMaterial3D.new())
	stream.update(96, 128, true, true, PlanTerrain.SIDE)
	check(stream.nodes.size() == 3 and stream.pending.size() == 4, "старт сразу готовит только ближнюю землю")
	stream.update(128, 128)
	check(stream.nodes.has(Vector2i(2, 0)) and not stream.nodes.has(Vector2i(-2, 0)), "сначала догружается земля впереди")
	stream.queue_free()


func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 300)
	call_deferred("run")


func run() -> void:
	Grid.allow_fast = not OS.get_cmdline_user_args().has("--gdscript")
	driving()
	var pieces := geometry()
	var before := var_to_bytes(pieces)
	var stream := PlanTerrain.new()
	root.add_child(stream)
	stream.setup(pieces, StandardMaterial3D.new())
	stream.update(256, 256, false, false)
	check(stream.nodes.is_empty() and not stream.pending.is_empty(), "занятый кадр откладывает передачу рельефа")
	stream.update(256, 256)
	check(stream.nodes.size() == 1, "в кадр передаётся не больше одной части рельефа")
	stream.update(256, 256, true)
	check(stream.nodes.size() == pieces.size(), "перенос/старт сразу готовит видимую землю")
	stream.update(10000, 10000)
	check(stream.nodes.is_empty(), "дальние GPU-меши выгружаются")
	await process_frame
	stream.update(256, 256, false, false)
	stream.update(10000, 10000)
	check(stream.nodes.is_empty() and stream.pending.is_empty(), "перенос отменяет устаревшую очередь загрузки")
	stream.update(256, 256, true)
	check(stream.nodes.size() == pieces.size() and var_to_bytes(stream.chunks) == before,
		"возвращение восстанавливает те же поверхности из CPU-кэша")
	stream.queue_free()
	await process_frame
	ahead_first(pieces.values()[0])
	print("continuation_test: %s" % ("OK" if fails == 0 else str(fails)))
	quit(1 if fails else 0)
