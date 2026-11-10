extends RefCounted
## 13.8: окончательная география стартового плана и закреплённых областей (журнал commit).
## Общая для заготовки соседа и дорожной сетки: оба видят одни и те же готовые клетки.


## Окончательные клетки плана и закреплённых областей в полях прямоугольника rect:
## fixed и h, ocean, lake, water_level, river, biome, dist, path. Остальные поля не меняются.
static func apply_known(fields: Dictionary, rect: Rect2i, w: WorldData, ledger: Dictionary) -> void:
	var plan := Rect2i(0, 0, w.W, w.H).intersection(rect) if w.N > 0 else Rect2i()
	if plan.has_area():
		var river := w.river_cells()
		var paths: Dictionary = ledger.get("plan_paths", {})
		var has_paths := w.path_mask.size() == w.N
		var has_geography := w.elev.size() == w.N and w.slope.size() == w.N and w.dist_water.size() == w.N
		var has_climate := w.temp.size() == w.N and w.moist.size() == w.N
		for y in range(plan.position.y, plan.end.y):
			for x in range(plan.position.x, plan.end.x):
				var dst := (y - rect.position.y) * rect.size.x + x - rect.position.x
				var src := y * w.W + x
				fields.fixed[dst] = 1
				fields.h[dst] = w.h[src]
				fields.ocean[dst] = w.ocean[src]
				fields.lake[dst] = w.lake[src]
				fields.water_level[dst] = w.filled[src]
				if w.ocean[src] != 0:
					fields.water_level[dst] = 0.0
				elif w.lake[src] != 0 or river[src] != 0:
					fields.water_level[dst] = maxf(0.0, w.filled[src] - GameConfig.LAKE_DROP / GameConfig.HS)
				fields.river[dst] = river[src]
				fields.biome[dst] = w.biome[src]
				fields.dist[dst] = w.dist_ocean[src]
				if fields.has("dw"): fields.dw[dst] = w.dist_water[src] if has_geography else w.dist_ocean[src]
				if fields.has("elev"): fields.elev[dst] = w.elev[src] if has_geography else maxf(0.0, w.h[src])
				if fields.has("slope") and has_geography: fields.slope[dst] = w.slope[src]
				if fields.has("temp") and has_climate: fields.temp[dst] = w.temp[src]
				if fields.has("moist") and has_climate: fields.moist[dst] = w.moist[src]
				if fields.has("light") and has_geography: fields.light[dst] = StageClimate.natural_conditions(w, x, y).x
				fields.path[dst] = maxi(w.path_mask[src] if has_paths else 0, int(paths.get(Vector2i(x, y), 0)))
	var regions: Dictionary = ledger.get("regions", {})
	for key: Vector2i in regions:
		var known: Dictionary = regions[key]
		var r: Rect2i = known.rect
		var part := r.intersection(rect)
		if not part.has_area() or not known.has("fields"): continue # 13.9+: поля далёкой области на диске
		for y in range(part.position.y, part.end.y):
			for x in range(part.position.x, part.end.x):
				var dst := (y - rect.position.y) * rect.size.x + x - rect.position.x
				var src := (y - r.position.y) * r.size.x + x - r.position.x
				fields.fixed[dst] = 1
				for name: String in ["h", "ocean", "lake", "water_level", "river", "biome", "dist", "path"]:
					fields[name][dst] = known.fields[name][src]
				for name: String in ["elev", "slope", "dw", "temp", "moist", "light"]:
					if fields.has(name) and known.fields.has(name):
						fields[name][dst] = known.fields[name][src]
