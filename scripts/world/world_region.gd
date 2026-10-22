class_name WorldRegion
extends RefCounted
## Область — чтение общего результата, не ещё один запуск flood у её края.
## Массивы возвращаются копиями; места, реки, пути, связи и номера клеток остаются мировыми.
const FIELDS := ["h", "filled", "elev", "slope", "ocean", "lake", "river", "river_area", "acc",
	"down", "watershed", "rain", "dist_ocean", "dist_water", "temp", "moist", "biome"]


static func ready(w: WorldData) -> bool:
	if w.N <= 0:
		return false
	for name: String in FIELDS:
		if name != "river_area" and w.get(name).size() != w.N:
			return false
	return true


## Только прямоугольник внутри плана. Отдельные строки копируются целиком, без вызова на клетку.
static func fields(w: WorldData, rect: Rect2i, names: Array = FIELDS) -> Dictionary:
	var out := {}
	for name: String in names:
		var src: Variant = w.get(name)
		if src.size() != w.N:
			continue
		var dst: Variant = src.slice(0, 0)
		for y in range(rect.position.y, rect.end.y):
			var start := y * w.W + rect.position.x
			dst.append_array(src.slice(start, start + rect.size.x))
		out[name] = dst
	return out


static func read(w: WorldData, key: Vector2i, halo: int = 2) -> Dictionary:
	var core := w.region_rect(key)
	if not ready(w) or not core.has_area():
		return {}
	var rect := core.grow(maxi(0, halo)).intersection(Rect2i(0, 0, w.W, w.H))
	var out := fields(w, rect, FIELDS + ["path_mask", "road_surface"])
	out.rect = rect
	out.core = core
	out.stride = rect.size.x
	out.world_width = w.W
	out.rivers = []
	# Не обрезать и не сглаживать ленту заново: у общей линии сохраняются профиль и берега.
	for line: Array in w.rivers:
		if line.is_empty():
			continue
		var box := Rect2(Vector2(line[0].x, line[0].y), Vector2.ZERO)
		for p: Dictionary in line:
			box = box.expand(Vector2(p.x, p.y))
		if box.grow(4.0).intersects(Rect2(rect), true):
			out.rivers.append(line.duplicate(true))
	out.links = river_links(w, core)
	_read_travel(w, rect, core, out)
	return out


## Области читают те же поселения и целые линии путешествий из общего плана.
## Речные links остаются отдельными; travel_links — переходы путей людей.
static func _read_travel(w: WorldData, rect: Rect2i, core: Rect2i, out: Dictionary) -> void:
	for name: String in ["settlements", "peaks"]:
		out[name] = []
		for place: Dictionary in w.get(name):
			if Rect2(rect).has_point(Vector2(place.x, place.y)):
				out[name].append(place.duplicate(true))
	out.trails = []
	out.travel_links = []
	for id in w.trails.size():
		var trail: Dictionary = w.trails[id]
		var pts: Array = trail.pts
		if pts.is_empty():
			continue
		var box := Rect2(Vector2(pts[0].x, pts[0].y), Vector2.ZERO)
		for p: Dictionary in pts:
			box = box.expand(Vector2(p.x, p.y))
		if not box.grow(2.0).intersects(Rect2(rect), true):
			continue
		out.trails.append({id = id, kind = trail.kind, pts = pts.duplicate(true)})
		if trail.kind == "animal":
			continue
		for k in range(1, pts.size()):
			var a := Vector2(pts[k - 1].x, pts[k - 1].y)
			var b := Vector2(pts[k].x, pts[k].y)
			if Rect2(core).has_point(a) != Rect2(core).has_point(b):
				out.travel_links.append({id = Vector2i(id, k), from = a, to = b, kind = trail.kind})
	for name: String in ["bridges", "tunnels"]:
		out[name] = []
		for span: Dictionary in w.get(name):
			var a := Vector2(span.a % w.W + 0.5, span.a / w.W + 0.5)
			var b := Vector2(span.b % w.W + 0.5, span.b / w.W + 0.5)
			if Rect2(a, Vector2.ZERO).expand(b).grow(3.0).intersects(Rect2(rect), true):
				out[name].append(span.duplicate(true))


## Одно и то же направленное ребро возвращается обеим областям без смены направления/знака.
## Расход получателя включает остальные притоки, поэтому он может быть больше расхода этого ребра.
static func river_links(w: WorldData, core: Rect2i) -> Array:
	var links: Array = []
	var scan := core.grow(1).intersection(Rect2i(0, 0, w.W, w.H))
	for y in range(scan.position.y, scan.end.y):
		for x in range(scan.position.x, scan.end.x):
			var i := y * w.W + x
			var d := w.down[i]
			if d < 0 or (w.river[i] == 0 and not (w.lake[i] != 0 and w.river[d] != 0)):
				continue
			var a := Vector2i(x, y)
			var b := Vector2i(d % w.W, d / w.W)
			if core.has_point(a) == core.has_point(b):
				continue
			# Как у StageRivers: выход из озера получает ширину следующей речной клетки,
			# а устье в озеро/море расширяется. Сухой приток до начала русла не рисуем как реку.
			var width := StageRivers._width_of(w, i if w.river[i] != 0 else d)
			var next_width := StageRivers._width_of(w, d) if w.river[d] != 0 else width * 1.3
			links.append({id = Vector4i(a.x, a.y, b.x, b.y), from = a, to = b,
				acc = w.acc[i], receiving_acc = w.acc[d], e = w.filled[i], next_e = w.filled[d],
				width = width, next_width = next_width, from_lake = w.lake[i] != 0, watershed = w.watershed[i]})
	return links


## Та же схема полей, что OuterLand.compute, но по готовым долинам и воде общего плана.
static func terrain(w: WorldData, rect: Rect2i) -> Dictionary:
	var f := fields(w, rect)
	var out := {h = f.h, biome = f.biome, temp = f.temp, moist = f.moist, elev = f.elev,
		slope = f.slope, dist = f.dist_ocean, dw = f.dist_water, river = f.get("river_area", f.river),
		light = PackedFloat32Array()}
	out.light.resize(rect.get_area())
	for y in range(rect.position.y, rect.end.y):
		for x in range(rect.position.x, rect.end.x):
			out.light[(y - rect.position.y) * rect.size.x + x - rect.position.x] = StageClimate.natural_conditions(w, x, y).x
	return out


## Смешанный прямоугольник у внешнего края: только известная часть заменяется общим результатом.
static func overlay(w: WorldData, rect: Rect2i, out: Dictionary) -> void:
	out.dw = out.dist.duplicate()
	out.river = PackedByteArray()
	out.river.resize(rect.get_area())
	if not ready(w):
		return
	var overlap := rect.intersection(Rect2i(0, 0, w.W, w.H))
	var river := w.river_cells()
	for y in range(overlap.position.y, overlap.end.y):
		for x in range(overlap.position.x, overlap.end.x):
			var dst := (y - rect.position.y) * rect.size.x + x - rect.position.x
			var src := y * w.W + x
			for name: String in ["h", "biome", "temp", "moist", "elev", "slope"]:
				out[name][dst] = w.get(name)[src]
			out.dist[dst] = w.dist_ocean[src]
			out.dw[dst] = w.dist_water[src]
			out.river[dst] = river[src]
			out.light[dst] = StageClimate.natural_conditions(w, x, y).x
