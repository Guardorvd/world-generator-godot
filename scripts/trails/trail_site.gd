class_name TrailSite
extends RefCounted
## Trail Lab: сохранённая площадка — прямоугольник уже подготовленного игрового мира (из кэша, без генерации).
## Хранит готовую поверхность и только те поля WorldData, которые читают сборка трассы и движение; координаты
## локальные (клетка 0, 0 — угол участка), мировой адрес — origin и WorldData.world_origin.
##
## Подготовлено заранее и не пересчитывается: рельеф с руслами и полотном существующих путей (Heightfield.hv после
## RoadBed и выемок туннелей), уровни воды и ленты рек, мосты и туннели, метровая сетка полотна существующих путей
## с покрытиями (RoadRefinement.patches), карта покрытий клеток. Гидрология обрезанного участка не считается.
## Считается при добавлении трассы, только для неё: полотно по её линии (RoadBed, кроме углов готовых патчей),
## метровые патчи вокруг неё (RoadRefinement с остальными путями как соседями), покрытие, формирование рельефа
## и земляные элементы (TrailBuilder). Исходная площадка неизменяема: каждая сборка — на свежей копии (prepare).
##
## Участок = рабочий прямоугольник (work: здесь можно строить трассы) + запас данных вокруг (margin клеток):
## в запасе лежат продолжения путей, сооружения и рельеф, которые нужны сборке и виду, но трассу туда не ставить.

const FORMAT := 1
const MAGIC := "WTS1"
const EXT := ".tsite"
const DIR := "res://resources/trails/sites"
const TILE := GameConfig.TILE
const DIV := RoadRefinement.DIV
const STRIDE := RoadRefinement.STRIDE
## Поля клеток WorldData, которые читают потребители лаборатории, и кто их читает. Остальное (сток, водоразделы,
## дождь, стоимость пути, растительность, места) сборке трассы и велосипеду не нужно и не копируется.
const CELL_FIELDS := {
	filled = "уровень озёр: Heightfield.lake_level, WaterBuilder",
	lake = "озёра: Heightfield.lake_level, WaterBuilder",
	ocean = "море: клетки ниже уровня моря (вид и справка tile_info)",
	river_area = "коридор рек: river_cells(), tile_info.river",
	dist_water = "защита берега: RoadBed, RoadRefinement, TrailBuilder",
	slope = "покрытие новой трассы (RoadSurface.pick), tile_info",
	biome = "покрытие новой трассы, скорость и тряска вне пути (tile_info)",
	elev = "tile_info",
	temp = "tile_info",
	moist = "tile_info",
	path_mask = "клетки путей: разметка новой трассы, tile_info",
	road_surface = "покрытие клетки пути: tile_info, контакт вне метровой сетки",
}

var title := ""
## Источник: seed_text, seed_num, plan, size, cache (формат и ключи слоёв), files (путь -> SHA-256 файла кэша)
var source := {}
var origin := Vector2i.ZERO    # мировая клетка локальной (0, 0)
var size := Vector2i.ZERO      # клеток вместе с запасом
var work := Rect2i()           # рабочий прямоугольник, локальные клетки
var cells := {}                # CELL_FIELDS -> обрезанные массивы
var trails: Array = []         # куски существующих путей (локальные клетки), с готовым surf
var bridges := PackedInt32Array() # пары a, b — локальные номера клеток (защита концов для новой трассы)
var tunnels := PackedInt32Array()
var settlements := PackedVector2Array() # локальные клетки поселений рядом (покрытие дороги, развилки)
var hv := PackedFloat32Array()
var hv_raw := PackedFloat32Array()
var water_level := PackedFloat32Array()
var ribbons: Array = []        # куски лент рек в локальных метрах, как Heightfield.ribbons
var structures: Array = []     # мосты и туннели в локальных метрах, как Heightfield.structures
var patches := {}              # метровая сетка полотна: локальный квадрат -> {h, color, uv, surface, road}
var image := {}                # кусок текстуры рельефа мира {w, h, f, data} или пусто
## Демонстрационная трасса: points — мировые метры (опорные точки), width, kind, surface, elements
var demo := {}
## Выборки источника для проверки: x, z (мировые метры), values (PROBE на точку), near_road (1 — у пути)
var reference := {}
var _template: Heightfield
var _frozen := PackedByteArray()

## Что меряет probe: опора и земля, вода, контакт колеса с полотном, покрытие клетки и кочка RoadBump.
const PROBE := ["ground", "support", "depth", "surface", "weight", "across", "cell_surface", "bump"]


## Вырезать участок из подготовленного мира (WorldData из кэша + Heightfield после finish_paths, как в игре).
## rect — рабочий прямоугольник в мировых клетках, margin — запас клеток вокруг. {site} или {errors}.
static func cut(w: WorldData, h: Heightfield, rect: Rect2i, margin: int, view := {}) -> Dictionary:
	var errors := PackedStringArray()
	var data := rect.grow(margin)
	var area := w.available_rect if w.available_rect.has_area() else Rect2i(0, 0, w.W, w.H)
	if rect.size.x < 16 or rect.size.y < 16 or margin < 4:
		errors.append("рабочий прямоугольник меньше 16 клеток или запас меньше 4")
	if not area.encloses(data):
		errors.append("неподдерживаемая граница: участок с запасом %s выходит за стартовую область %s" % [data, area])
	if h.road_refinement == null or h.water_level.size() != w.N:
		errors.append("мир не подготовлен: нет воды или метровой сетки полотна (нужен finish_paths)")
	if not errors.is_empty():
		return {errors = errors}
	var o := Vector2(data.position) * TILE
	var box := Rect2(o, Vector2(data.size) * TILE)
	var kept: Array[int] = []
	for k in h.structures.size():
		var s: Dictionary = h.structures[k]
		var foot := structure_foot(s)
		if not foot.intersects(box):
			continue
		if not box.encloses(foot):
			errors.append("неполное сооружение: %s у клетки (%d, %d) пересекает границу участка" % [
				"туннель" if s.tunnel else "мост", floori(s.ax / TILE), floori(s.az / TILE)])
		kept.append(k)
	if not errors.is_empty():
		return {errors = errors}
	var site := TrailSite.new()
	site.origin = data.position
	site.size = data.size
	site.work = Rect2i(rect.position - data.position, rect.size)
	site.source = {world_origin = w.world_origin, seed_text = w.seed_text, seed_num = w.seed_num, plan = w.W, size = WorldGenerator.START_SIZE}
	var river := w.river_cells()
	for name: String in CELL_FIELDS:
		site.cells[name] = _crop(river if name == "river_area" else w.get(name), w.W, data)
	site.hv = _crop(h.hv, w.W, data)
	site.hv_raw = _crop(h.hv_raw, w.W, data)
	site.water_level = _crop(h.water_level, w.W, data)
	var near := Rect2(Vector2(data.position - Vector2i(4, 4)), Vector2(data.size + Vector2i(8, 8)))
	for route in w.trails.size():
		var t: Dictionary = w.trails[route]
		if RoadBed.KINDS.has(t.kind):
			site.trails.append_array(_clip_route(t, route, near, data.position))
	var bridge_count := w.bridges.size()
	for k in kept:
		var s: Dictionary = h.structures[k].duplicate()
		for key in ["ax", "bx"]: s[key] -= o.x
		for key in ["az", "bz"]: s[key] -= o.y
		site.structures.append(s)
		var e: EntityRecord = w.bridges[k] if k < bridge_count else w.tunnels[k - bridge_count]
		var list := site.bridges if k < bridge_count else site.tunnels
		for c: int in [e.a, e.b]:
			list.append((c / w.W - data.position.y) * data.size.x + c % w.W - data.position.x)
		if k < bridge_count: site.bridges = list
		else: site.tunnels = list
	for v: SettlementData in w.settlements:
		if Rect2(near).grow(12).has_point(Vector2(v.x, v.y)):
			site.settlements.append(Vector2(v.x, v.y) - Vector2(data.position))
	var reach := Rect2(o, Vector2(data.size) * TILE).grow(TILE * 2.0)
	for pts: Array in h.ribbons:
		site.ribbons.append_array(_clip_ribbon(pts, reach, o))
	for key: int in h.road_refinement.patches:
		var cx := key % w.W - data.position.x
		var cz := key / w.W - data.position.y
		if cx >= 0 and cz >= 0 and cx <= data.size.x - 2 and cz <= data.size.y - 2:
			site.patches[cz * data.size.x + cx] = (h.road_refinement.patches[key] as Dictionary).duplicate()
	var terrain: Variant = view.get("terrain")
	if terrain is Dictionary and terrain.w % w.W == 0:
		var px: int = terrain.w / w.W
		var full := Image.create_from_data(terrain.w, terrain.h, false, terrain.f, terrain.data)
		var part := full.get_region(Rect2i(data.position * px, data.size * px))
		site.image = {w = part.get_width(), h = part.get_height(), f = part.get_format(), data = part.get_data()}
	site._prepare_template()
	return {site = site, errors = errors}


## Прямоугольник сооружения с защитной зоной (мировые метры): участок обязан захватить его целиком или не трогать.
static func structure_foot(s: Dictionary) -> Rect2:
	var r: float = s.half + RoadBed.PIN + RoadBed.PIN_FADE + Heightfield.TUNNEL_WALL + TILE
	var lo := Vector2(minf(s.ax, s.bx), minf(s.az, s.bz)) - Vector2.ONE * r
	return Rect2(lo, Vector2(maxf(s.ax, s.bx), maxf(s.az, s.bz)) + Vector2.ONE * r - lo)


static func _crop(values: Variant, width: int, data: Rect2i) -> Variant:
	var out: Variant = values.slice(0, 0)
	for z in range(data.position.y, data.end.y):
		out.append_array(values.slice(z * width + data.position.x, z * width + data.end.x))
	return out


## Куски пути с точками в near (клетки): с одной точкой до и после, чтобы разметка и соседство не обрывались.
static func _clip_route(t: Dictionary, route: int, near: Rect2, corner: Vector2i) -> Array:
	var out: Array = []
	var pts: Array = t.pts
	var k := 0
	while k < pts.size():
		if not near.has_point(Vector2(pts[k].x, pts[k].y)):
			k += 1
			continue
		var first := k
		while k < pts.size() and near.has_point(Vector2(pts[k].x, pts[k].y)):
			k += 1
		var from := maxi(0, first - 1)
		var to := mini(pts.size(), k + 1)
		var piece := {kind = t.kind, pts = [], surf = (t.surf as PackedByteArray).slice(from, to), source_route = route, source_from = from}
		for n in range(from, to):
			var p: Dictionary = (pts[n] as Dictionary).duplicate()
			p.x -= corner.x
			p.y -= corner.y
			piece.pts.append(p)
		if piece.pts.size() >= 2:
			out.append(piece)
	return out


## Куски ленты реки, отрезки которых задевают reach (метры), в локальных метрах; берега не пересчитываются.
static func _clip_ribbon(pts: Array, reach: Rect2, o: Vector2) -> Array:
	var out: Array = []
	var shift := Vector3(o.x, 0.0, o.y)
	var piece: Array = []
	for k in range(1, pts.size() + 1):
		var touch := false
		if k < pts.size():
			var lo := Vector2(INF, INF)
			var hi := Vector2(-INF, -INF)
			for p: Dictionary in [pts[k - 1], pts[k]]:
				for v: Vector3 in [p.left, p.right]:
					lo = lo.min(Vector2(v.x, v.z))
					hi = hi.max(Vector2(v.x, v.z))
			touch = Rect2(lo, hi - lo).grow(TILE).intersects(reach)
		if touch:
			if piece.is_empty():
				piece.append(_shift_point(pts[k - 1], o, shift))
			piece.append(_shift_point(pts[k], o, shift))
		elif not piece.is_empty():
			out.append(piece)
			piece = []
	return out


static func _shift_point(p: Dictionary, o: Vector2, shift: Vector3) -> Dictionary:
	var q := p.duplicate()
	q.x -= o.x
	q.z -= o.y
	q.left -= shift
	q.right -= shift
	return q


## Свежая копия данных мира участка: каждая сборка получает свои массивы и пути.
func world() -> WorldData:
	var w := WorldData.new()
	w.W = size.x
	w.H = size.y
	w.N = w.W * w.H
	w.seed_text = source.seed_text
	w.seed_num = source.seed_num
	w.world_origin = origin + source.get("world_origin", Vector2i.ZERO)
	for owner in [w.geology, w.climate, w.civil]:
		for property: Dictionary in owner.get_property_list():
			var value: Variant = owner.get(property.name)
			if value is GridBuffer2D.Float32 or value is GridBuffer2D.Byte or value is GridBuffer2D.Int32:
				value.resize()
	for name: String in cells:
		w.set(name, cells[name].duplicate()) # массивы передаются по ссылке: разметка трассы не должна попасть в участок
	w.lake_id.fill(-1) # озёра как места (имена, задания) в участок не входят
	w.trails = trails.duplicate(true)
	var list: Array = []
	for k in range(0, bridges.size(), 2):
		list.append(BridgeData.new(bridges[k], bridges[k + 1]))
	w.bridges = list
	list = []
	for k in range(0, tunnels.size(), 2):
		list.append(TunnelData.new(tunnels[k], tunnels[k + 1]))
	w.tunnels = list
	list = []
	for p in settlements:
		list.append(SettlementData.new(p.x, p.y))
	w.settlements = list
	return w


## Свежий Heightfield участка на мире w: своя высота клеток и список сооружений; ленты рек, уровни воды и
## индекс рек общие и только читаются. Метровая сетка задаётся при сборке (prepare).
func heights(w: WorldData) -> Heightfield:
	var h := _template.copy()
	h.world = w
	h.structures = structures.duplicate()
	h.index_structures()
	return h


func _prepare_template() -> void:
	_template = Heightfield.new()
	_template.world = world()
	_template.hv = hv
	_template.hv_raw = hv_raw
	_template.water_level = water_level
	_template.ribbons = ribbons
	_template.index_ribbons()
	_template.structures = structures
	_template.index_structures()
	_template.road_refinement = RoadRefinement.from_patches(patches, size.y)
	# Углы готовых патчей полотно новой трассы не двигает: иначе край патча разошёлся бы с соседней клеткой
	_frozen.resize(size.x * size.y)
	for key: int in patches:
		for corner in [0, 1, size.x, size.x + 1]:
			_frozen[key + corner] = 1


## Готовая поверхность участка до трасс (только чтение): для композитора и проверки.
func surface() -> Heightfield:
	return _template


## Естественная земля участка (готовая поверхность до новой трассы), локальные метры.
func ground_at(at: Vector2) -> float:
	return _template.ground_at(at.x, at.y)


func origin_m() -> Vector2:
	return Vector2(origin) * TILE


## Ошибки трасс вне рабочего прямоугольника (запас данных — не место для трассы).
func inside_errors(routes: Array[TrailDefinition]) -> PackedStringArray:
	var errors := PackedStringArray()
	var lo := Vector2(work.position) * TILE
	var hi := Vector2(work.end) * TILE
	for d in routes:
		if d == null:
			continue
		var m := d.width * 0.5 + RoadRefinement.REACH + TILE
		for p in d.points:
			if p.x < lo.x + m or p.y < lo.y + m or p.x > hi.x - m or p.y > hi.y - m:
				errors.append("Трасса выходит из рабочей зоны участка: " + d.id)
				break
	return errors


## Сборка трасс на свежей копии участка; тот же контракт, что у лабораторной Fixture.prepare:
## {heights, errors, timings: setup_ms, surface_ms (полотно и сетка новой трассы), earthworks_ms}.
func prepare(routes: Array[TrailDefinition], with_elements := true, limits := {}) -> Dictionary:
	var started := Time.get_ticks_usec()
	var timings := {setup_ms = 0.0, surface_ms = -1.0, earthworks_ms = -1.0}
	var errors := inside_errors(routes)
	if not errors.is_empty():
		return {heights = null, errors = errors, timings = timings}
	var w := world()
	var existing := w.trails.size()
	errors = TrailBuilder.append_routes(w, routes)
	timings.setup_ms = (Time.get_ticks_usec() - started) / 1000.0
	if not errors.is_empty():
		return {heights = null, errors = errors, timings = timings}
	started = Time.get_ticks_usec()
	var h := heights(w)
	var only := {}
	for k in range(existing, w.trails.size()):
		only[k] = true
	h.road_refinement = _form(h, only)
	timings.surface_ms = (Time.get_ticks_usec() - started) / 1000.0
	if with_elements and not routes.is_empty():
		errors = TrailBuilder.bake_elements(h, routes, limits)
		if not errors.is_empty():
			return {heights = null, errors = errors, timings = timings}
		timings.earthworks_ms = h.road_refinement.build_timings.trail_elements_ms
	started = Time.get_ticks_usec()
	h.obstacles = ForestObstacles.new(w, h)
	timings.setup_ms += (Time.get_ticks_usec() - started) / 1000.0
	return {heights = h, errors = PackedStringArray(), timings = timings}


## Метровая сетка: копия готовых патчей + патчи новых путей. В вершинах новых патчей, где ближе всего прежний путь
## или пути нет, остаётся готовая вершина участка: полотно существующих путей не формируется второй раз.
func _form(h: Heightfield, only: Dictionary) -> RoadRefinement:
	var ready := {}
	for key: int in patches:
		ready[key] = (patches[key] as Dictionary).duplicate() # массивы копируются при записи
	if only.is_empty():
		return RoadRefinement.from_patches(ready, size.y)
	var t := Time.get_ticks_usec()
	RoadBed.refine(h, only, _frozen)
	h.path_timings.road_bed_ms = (Time.get_ticks_usec() - t) / 1000.0
	var fresh := RoadRefinement.build(h, true, only)
	for key: int in fresh.patches:
		var p: Dictionary = fresh.patches[key]
		var owner: PackedByteArray = p.owner
		p.erase("owner")
		var hs: PackedFloat32Array = p.h
		var colors: PackedColorArray = p.color
		var uvs: PackedVector2Array = p.uv
		var surfaces: PackedByteArray = p.surface
		var roads: PackedByteArray = p.road
		for n in owner.size():
			if owner[n] != 0:
				continue
			var at := _saved_vertex(key, n)
			if at.x < 0:
				continue
			var q: Dictionary = patches[at.x]
			hs[n] = q.h[at.y]
			colors[n] = q.color[at.y]
			uvs[n] = q.uv[at.y]
			surfaces[n] = q.surface[at.y]
			roads[n] = q.road[at.y]
		ready[key] = {h = hs, color = colors, uv = uvs, surface = surfaces, road = roads}
	fresh.patches = ready
	h.path_timings.merge(fresh.build_timings)
	return fresh


## Готовая вершина участка в той же точке метровой сетки, что вершина n квадрата key: (квадрат, номер) или -1.
func _saved_vertex(key: int, n: int) -> Vector2i:
	var gx := (key % size.x) * DIV + n % STRIDE
	var gz := (key / size.x) * DIV + n / STRIDE
	for qz in [gz / DIV, gz / DIV - 1]:
		for qx in [gx / DIV, gx / DIV - 1]:
			var lx: int = gx - qx * DIV
			var lz: int = gz - qz * DIV
			if qx < 0 or qz < 0 or lx > DIV or lz > DIV:
				continue
			var k: int = qz * size.x + qx
			if patches.has(k):
				return Vector2i(k, lz * STRIDE + lx)
	return Vector2i(-1, -1)


## Демонстрационная трасса в локальных метрах: сплайн через опорные точки demo.points с шагом 1 м.
func demo_route(kind := "") -> TrailDefinition:
	var d := TrailDefinition.new()
	d.id = "site_demo"
	d.title = str(demo.get("title", "Трасса участка"))
	d.kind = kind if not kind.is_empty() else str(demo.get("kind", "mountain"))
	d.width = float(demo.get("width", 4.0))
	d.surface = int(demo.get("surface", RoadSurface.DIRT))
	d.earthwork = 1.0
	d.auto_bank = 1.0
	var control := PackedVector2Array()
	for p: Vector2 in demo.get("points", []):
		control.append(p - origin_m())
	var pts := PackedVector2Array()
	for k in range(0, control.size() - 1):
		var a := control[maxi(0, k - 1)]
		var b := control[k]
		var c := control[k + 1]
		var e := control[mini(control.size() - 1, k + 2)]
		var steps := maxi(1, ceili(b.distance_to(c)))
		for s in steps:
			pts.append(b.cubic_interpolate(c, a, e, float(s) / steps))
	if not control.is_empty():
		pts.append(control[-1])
	d.points = pts
	var list: Array[TrailElement] = []
	for e: Dictionary in demo.get("elements", []):
		list.append(TrailElementLibrary.make(int(e.profile) as TrailElement.Profile, e.station, e.length, e.height, e.get("bank", 1.0)))
	d.elements = list
	return d


func base_image() -> Image:
	if image.is_empty():
		return null
	return Image.create_from_data(image.w, image.h, false, image.f, image.data)


## Показания поверхности в точке (x, z) — метры данных h; o — их мировой сдвиг (м). Тот же контакт, что у колеса:
## опора, вода, RideSurface, покрытие клетки и кочка RoadBump в мировых координатах.
static func probe(h: Heightfield, x: float, z: float, o: Vector2) -> PackedFloat32Array:
	var contact := RideSurface.sample(h.world, h, x, z)
	var cell := PlayerState.surface(h.world.tile_info(x / TILE, z / TILE))
	return PackedFloat32Array([h.ground_at(x, z), h.surface_at(x, z, INF), h.depth_at(x, z), contact.surface,
		contact.weight, contact.across, cell, RoadBump.height(x + o.x, z + o.y, contact.surface, 0.0, contact.across) * contact.weight])


## Точки проверки в мировых метрах: сетка 2 м по рабочему прямоугольнику и плотные точки поперёк существующих
## путей (ось, середина полуширины, кромка, обочина и край влияния метровой сетки). {x, z, near_road}
func probe_points() -> Dictionary:
	var xs := PackedFloat32Array()
	var zs := PackedFloat32Array()
	var road := PackedByteArray()
	var lo := Vector2(work.position) * TILE
	var hi := Vector2(work.end) * TILE
	var at := lo + Vector2.ONE
	while at.y < hi.y:
		at.x = lo.x + 1.0
		while at.x < hi.x:
			xs.append(at.x + origin_m().x)
			zs.append(at.y + origin_m().y)
			road.append(0)
			at.x += 2.0
		at.y += 2.0
	var inner := Rect2(lo, hi - lo).grow(-2.0)
	for t: Dictionary in trails:
		for n in range(1, t.pts.size()):
			var a := Vector2(t.pts[n - 1].x, t.pts[n - 1].y) * TILE
			var b := Vector2(t.pts[n].x, t.pts[n].y) * TILE
			var half := float(t.pts[n - 1].w) * TILE * 0.5
			var along := b - a
			if along.length() < 0.01:
				continue
			var side := Vector2(-along.y, along.x).normalized()
			for s in ceili(along.length()):
				var p := a + along * (s / along.length())
				for f in [0.0, 0.5, -0.5, 1.0, -1.0]:
					for extra in ([0.0] if absf(f) < 1.0 else [0.0, 1.5, RoadRefinement.REACH]):
						var q: Vector2 = p + side * (half * f + signf(f) * extra)
						if inner.has_point(q):
							xs.append(q.x + origin_m().x)
							zs.append(q.y + origin_m().y)
							road.append(1)
	return {x = xs, z = zs, near_road = road}


## Сравнение готовой поверхности h (локальная) с выборками источника reference: наибольшие расхождения по PROBE
## и число несовпадений покрытия, отдельно у путей. Мировые точки переводятся в локальные через origin.
func compare(h: Heightfield, ref: Dictionary = reference) -> Dictionary:
	var o := origin_m()
	var out := {points = ref.x.size(), road_points = 0, surface_mismatch = 0, cell_mismatch = 0, road_mismatch = 0}
	for name: String in PROBE:
		out[name] = 0.0
	var count := PROBE.size()
	for n in ref.x.size():
		var got := probe(h, ref.x[n] - o.x, ref.z[n] - o.y, o)
		var near: bool = ref.near_road[n] != 0
		if near:
			out.road_points += 1
		for k in count:
			var want: float = ref.values[n * count + k]
			var d := absf(got[k] - want) if is_finite(want) or is_finite(got[k]) else 0.0
			if not is_finite(d):
				d = INF
			out[PROBE[k]] = maxf(out[PROBE[k]], d)
		if got[3] != ref.values[n * count + 3]:
			out.surface_mismatch += 1
			if near:
				out.road_mismatch += 1
		if got[6] != ref.values[n * count + 6]:
			out.cell_mismatch += 1
	return out


## Допуски сравнения с источником (единые для экспорта и tools/trail_site_test.gd): высоты и вода, м; вес полотна
## и поперечная координата — доли; кочка, м. Покрытия колеса и клетки должны совпасть точно.
const TOLERANCE := {ground = 1e-4, support = 1e-4, depth = 1e-3, weight = 1e-4, across = 1e-4, bump = 1e-5}


## Превышения допусков в результате compare(): пусто — площадка воспроизводит источник.
static func mismatch(c: Dictionary) -> PackedStringArray:
	var out := PackedStringArray()
	for key: String in TOLERANCE:
		if not (c[key] <= TOLERANCE[key]):
			out.append("%s расходится на %.6f (допуск %.6f)" % [key, c[key], TOLERANCE[key]])
	if c.surface_mismatch != 0 or c.cell_mismatch != 0:
		out.append("покрытие колеса не совпало в %d точках, покрытие клетки — в %d" % [c.surface_mismatch, c.cell_mismatch])
	if c.points == 0:
		out.append("нет точек сравнения")
	return out


## Выборки источника по probe_points: h — исходный мир (мировые метры, сдвиг ноль).
func record_reference(h: Heightfield) -> void:
	var pts := probe_points()
	var values := PackedFloat32Array()
	for n in pts.x.size():
		values.append_array(probe(h, pts.x[n], pts.z[n], Vector2.ZERO))
	reference = {x = pts.x, z = pts.z, near_road = pts.near_road, values = values}


func to_dict() -> Dictionary:
	return {format = FORMAT, title = title, source = source, origin = origin, size = size, work = work, cells = cells,
		trails = trails, bridges = bridges, tunnels = tunnels, settlements = settlements, hv = hv, hv_raw = hv_raw,
		water_level = water_level, ribbons = ribbons, structures = structures, patches = patches, image = image,
		demo = demo, reference = reference,
		constants = {tile = TILE, hs = GameConfig.HS, div = DIV, ocean_depth = GameConfig.OCEAN_DEPTH}}


## Записать во временный файл и переименовать: оборванная запись не оставляет полуфайла под настоящим именем.
func save(path: String) -> Error:
	var raw := var_to_bytes(to_dict())
	var packed := raw.compress(FileAccess.COMPRESSION_ZSTD)
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var tmp := path + ".tmp"
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		return FileAccess.get_open_error()
	f.store_buffer(MAGIC.to_ascii_buffer())
	f.store_32(FORMAT)
	f.store_64(raw.size())
	f.store_64(packed.size())
	f.store_buffer(Util.sha256(packed))
	f.store_buffer(packed)
	var err := f.get_error()
	f.close()
	if err != OK:
		DirAccess.remove_absolute(tmp)
		return err
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)
	return DirAccess.rename_absolute(tmp, path)


## Открыть площадку: {site} или {error} (нет файла, чужой или битый файл, другая версия формата или единиц).
static func open(path: String) -> Dictionary:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {error = "нет сохранённой площадки " + path}
	if f.get_length() < 60 or f.get_buffer(4).get_string_from_ascii() != MAGIC:
		return {error = "файл не похож на площадку Trail Lab: " + path}
	var format := f.get_32()
	if format != FORMAT:
		return {error = "формат площадки %d, код читает %d: экспортировать участок заново" % [format, FORMAT]}
	var raw_size := f.get_64()
	var packed_size := f.get_64()
	var expected := f.get_buffer(32)
	if packed_size <= 0 or packed_size != f.get_length() - f.get_position() or raw_size <= 0 or raw_size > (1 << 30):
		return {error = "площадка повреждена (размеры): " + path}
	var packed := f.get_buffer(packed_size)
	if Util.sha256(packed) != expected:
		return {error = "площадка повреждена (хеш не совпал): " + path}
	var raw := packed.decompress(raw_size, FileAccess.COMPRESSION_ZSTD)
	var data: Variant = bytes_to_var(raw) if raw.size() == raw_size else null
	if not data is Dictionary:
		return {error = "площадка повреждена (данные): " + path}
	return from_dict(data)


static func from_dict(data: Dictionary) -> Dictionary:
	var c: Variant = data.get("constants")
	if not c is Dictionary or c.get("tile") != TILE or c.get("hs") != GameConfig.HS or c.get("div") != DIV \
			or c.get("ocean_depth") != GameConfig.OCEAN_DEPTH:
		return {error = "единицы площадки (клетка, высота, метровая сетка) не совпадают с кодом: экспортировать заново"}
	var site := TrailSite.new()
	for key: String in ["title", "source", "origin", "size", "work", "cells", "trails", "bridges", "tunnels", "settlements",
			"hv", "hv_raw", "water_level", "ribbons", "structures", "patches", "image", "demo", "reference"]:
		if not data.has(key) or typeof(data[key]) != typeof(site.get(key)):
			return {error = "в площадке нет поля «%s» или оно другого типа" % key}
		site.set(key, data[key])
	var n := site.size.x * site.size.y
	if n <= 0 or site.hv.size() != n or site.hv_raw.size() != n or site.water_level.size() != n \
			or not Rect2i(Vector2i.ONE, site.size - Vector2i(2, 2)).encloses(site.work):
		return {error = "размеры площадки не сходятся"}
	for name: String in CELL_FIELDS:
		if not site.cells.has(name) or site.cells[name].size() != n:
			return {error = "в площадке нет поля клеток «%s»" % name}
	for key: int in site.patches:
		var p: Dictionary = site.patches[key]
		if key < 0 or key % site.size.x > site.size.x - 2 or key / site.size.x > site.size.y - 2 \
				or p.get("h", PackedFloat32Array()).size() != STRIDE * STRIDE:
			return {error = "метровая сетка площадки повреждена"}
	site._prepare_template()
	return {site = site}
