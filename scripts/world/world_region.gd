class_name WorldRegion
extends RefCounted
## Поля общего плана для прямоугольника OuterLand: чтение готового результата, не ещё один запуск flood.
## С 8.9 extra отдельного «чтения области» с копиями мест и путей нет: области — адреса в общем плане
## (WorldData.region_rect/region_at), места и направления ищутся через индекс WorldData.place/routes.
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
