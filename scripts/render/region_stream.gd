class_name RegionStream
extends Node3D
## 13.9: соседние области в игре. Ближайшая к игроку неготовая область за краем плана готовится
## в задаче WorkerThreadPool (по одной): заготовка, реки, поселения, дороги, закрепление в журнале.
## Готовая область передаётся в существующую загрузку: OuterLand берёт её клетки (рельеф кусков,
## высоты, вода, растительность), а здесь в главном потоке собираются вода, дороги, мосты и дома.
## Порядок подготовки зависит от пути игрока, но закреплённое потом не перестраивается.

const Regions := preload("res://scripts/world/region_preparation.gd")
const TILE := GameConfig.TILE
const HS := GameConfig.HS
const REACH := OuterTerrain.RADIUS + 400.0 # м: области ближе готовятся заранее, до того как их видно
const ROAD_LIFT := 0.06                     # м: полотно над рельефом без мерцания
const ROAD_COLOR := Color8(0x9c, 0x88, 0x66)

var world: WorldData
var heights: Heightfield
var terrain: OuterTerrain
var vegetation: VegetationLayer
var ledger := {}
var failed := {}        # области, которые не удалось подготовить: остаются внешним рельефом
var fires: Array = []   # костры поселений областей (как SettlementsBuilder.build)
var windows: Array = [] # материалы окон, ночью ярче
var _task := -1
var _out := {}
var _key := Vector2i.ZERO
var _road_mat: StandardMaterial3D


func setup(w: WorldData, h: Heightfield, t: OuterTerrain, v: VegetationLayer) -> void:
	world = w
	heights = h
	terrain = t
	vegetation = v
	_road_mat = SettlementsBuilder.mat(ROAD_COLOR)
	_road_mat.cull_mode = BaseMaterial3D.CULL_DISABLED # направление ленты зависит от хода дороги


## Каждый кадр: забрать готовую область или начать следующую. true — область добавлена в этом кадре.
func update(x: float, z: float) -> bool:
	if _task != -1:
		if not WorkerThreadPool.is_task_completed(_task):
			return false
		WorkerThreadPool.wait_for_task_completion(_task)
		_task = -1
		_apply(_key, _out.get("r", {}))
		return true
	var key: Variant = _next(x, z)
	if key == null:
		return false
	_key = key
	_out = {}
	var out := _out
	var snapshot := ledger
	var w := world
	_task = WorkerThreadPool.add_task(func() -> void: out.r = prepare_region(w, key, snapshot), false, "Область")
	return false


func finish() -> void:
	if _task != -1:
		WorkerThreadPool.wait_for_task_completion(_task)
		_task = -1


func _exit_tree() -> void:
	finish()


## Подготовить и закрепить одну область (в фоне). Река без допустимого русла не принимается:
## тогда область готовится без входящих рек, и вода кончается у её границы.
static func prepare_region(w: WorldData, key: Vector2i, current: Dictionary) -> Dictionary:
	var r := Regions.prepare(w, key, current)
	var network := Regions.prepare_rivers(r)
	var batch := Regions.finish_neighbors(w, [r], [network])
	var dropped := 0
	if not batch.ready:
		dropped = r.river_inputs.size()
		r.river_inputs = []
		network = Regions.prepare_rivers(r)
		batch = Regions.finish_neighbors(w, [r], [network])
		if not batch.ready:
			return {ready = false, reason = batch.reason}
	var roads := Regions.prepare_roads(w, [r], batch, current)
	var done := Regions.commit(current, [r], [network], batch, roads)
	done.roads = roads
	done.dropped_rivers = dropped
	if done.ready:
		done.water = water_arrays(done.ledger.regions[key])
	return done


## Ближайшая к игроку область за краем плана, ещё не закреплённая; null — все в REACH готовы
func _next(x: float, z: float) -> Variant:
	var p := Vector2(x, z) / TILE
	var reach := REACH / TILE
	var size := WorldData.REGION_SIZE
	var plan := Rect2i(0, 0, world.W, world.H)
	var regions: Dictionary = ledger.get("regions", {})
	var best: Variant = null
	var distance := INF
	for ky in range(floori((p.y - reach) / size), floori((p.y + reach) / size) + 1):
		for kx in range(floori((p.x - reach) / size), floori((p.x + reach) / size) + 1):
			var key := Vector2i(kx, ky)
			var rect := Regions.rect_for(key)
			if rect.intersects(plan) or regions.has(key) or failed.has(key):
				continue
			var d := p.distance_to(p.clamp(Vector2(rect.position), Vector2(rect.end)))
			if d <= reach and d < distance:
				distance = d
				best = key
	return best


func _apply(key: Vector2i, done: Dictionary) -> void:
	if not done.get("ready", false):
		failed[key] = true
		push_warning("Область %s не подготовлена: %s" % [key, done.get("reason", "")])
		return
	ledger = done.ledger
	world.outer.set_ledger(ledger)
	var rect := Regions.rect_for(key)
	terrain.refresh(rect.grow(2))
	vegetation.refresh(rect.grow(2))
	var node := Node3D.new()
	node.name = "Region_%d_%d" % [key.x, key.y]
	add_child(node)
	var water := WaterBuilder._flat_mesh(done.water, WaterBuilder._material(), "Water")
	if water != null:
		water.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		node.add_child(water)
	var roads: Dictionary = done.roads
	var ribbons := _road_arrays(roads.trails)
	if not ribbons.is_empty():
		var mesh := ArrayMesh.new()
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, ribbons)
		var mi := MeshInstance3D.new()
		mi.name = "Roads"
		mi.mesh = mesh
		mi.material_override = _road_mat
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		node.add_child(mi)
	StructuresBuilder.build(node, heights, heights.add_outer_bridges(roads.bridges))
	# Тот же сборщик домов, что у плана: временный мир только со списком поселений области.
	var places := WorldData.new()
	places.seed_num = world.seed_num ^ (key.x * 73856093) ^ (key.y * 19349663)
	places.settlements = roads.settlements
	var built := SettlementsBuilder.build(node, places, heights)
	fires.append_array(built.fires)
	windows.append(built.windows)


## Плоская вода области: квадрат на каждую мокрую клетку, углы — средний уровень соседних мокрых
## клеток, поэтому поверхность непрерывна и вдоль русла понижается без ступенек.
static func water_arrays(region: Dictionary) -> Array:
	var rect: Rect2i = region.rect
	var f: Dictionary = region.fields
	var W := rect.size.x
	var H := rect.size.y
	var wet := func(x: int, y: int) -> bool:
		if x < 0 or y < 0 or x >= W or y >= H:
			return false
		var i := y * W + x
		return (f.river[i] != 0 or f.lake[i] != 0) and is_finite(f.water_level[i])
	var corner := PackedFloat32Array()
	corner.resize((W + 1) * (H + 1))
	for y in H + 1:
		for x in W + 1:
			var sum := 0.0
			var n := 0
			for d: Vector2i in [Vector2i(-1, -1), Vector2i(0, -1), Vector2i(-1, 0), Vector2i(0, 0)]:
				if wet.call(x + d.x, y + d.y):
					sum += f.water_level[(y + d.y) * W + x + d.x]
					n += 1
			corner[y * (W + 1) + x] = sum / n if n > 0 else 0.0
	var pos := PackedVector3Array()
	for y in H:
		for x in W:
			if not wet.call(x, y):
				continue
			var v := func(cx: int, cy: int) -> Vector3:
				return Vector3((rect.position.x + cx) * TILE, maxf(0.0, corner[cy * (W + 1) + cx]) * HS, (rect.position.y + cy) * TILE)
			var a: Vector3 = v.call(x, y)
			var b: Vector3 = v.call(x + 1, y)
			var c: Vector3 = v.call(x, y + 1)
			var d: Vector3 = v.call(x + 1, y + 1)
			pos.append_array([a, b, c, b, d, c])
	return WaterBuilder._arrays(pos)


## Полотно дорог области лентой над рельефом: точки каждые ~2 м, края по ширине дороги.
func _road_arrays(trails: Array) -> Array:
	var pos := PackedVector3Array()
	var nor := PackedVector3Array()
	for trail: Dictionary in trails:
		var pts: Array = trail.pts
		var line: Array[Vector2] = []
		var widths: Array[float] = []
		for k in pts.size():
			var p := Vector2(pts[k].x, pts[k].y) * TILE
			if k > 0:
				var q := line.back() as Vector2
				var steps := maxi(1, ceili(q.distance_to(p) / 2.0))
				for s in range(1, steps):
					line.append(q.lerp(p, float(s) / steps))
					widths.append(float(pts[k].w) * TILE * 0.5)
			line.append(p)
			widths.append(float(pts[k].w) * TILE * 0.5)
		if line.size() < 2:
			continue
		var left := PackedVector3Array()
		var right := PackedVector3Array()
		for k in line.size():
			var along := (line[mini(k + 1, line.size() - 1)] - line[maxi(k - 1, 0)]).normalized()
			var side := along.orthogonal() * widths[k]
			var l := line[k] + side
			var r := line[k] - side
			left.append(Vector3(l.x, heights.surface_at(l.x, l.y, INF) + ROAD_LIFT, l.y))
			right.append(Vector3(r.x, heights.surface_at(r.x, r.y, INF) + ROAD_LIFT, r.y))
		for k in line.size() - 1:
			pos.append_array([left[k], right[k], left[k + 1], left[k + 1], right[k], right[k + 1]])
	if pos.is_empty():
		return []
	nor.resize(pos.size())
	nor.fill(Vector3.UP)
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = pos
	arrays[Mesh.ARRAY_NORMAL] = nor
	return arrays
