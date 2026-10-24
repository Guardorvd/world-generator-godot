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
		for y in range(plan.position.y, plan.end.y):
			for x in range(plan.position.x, plan.end.x):
				var dst := (y - rect.position.y) * rect.size.x + x - rect.position.x
				var src := y * w.W + x
				fields.fixed[dst] = 1
				fields.h[dst] = w.h[src]
				fields.ocean[dst] = w.ocean[src]
				fields.lake[dst] = w.lake[src]
				fields.water_level[dst] = w.filled[src]
				fields.river[dst] = river[src]
				fields.biome[dst] = w.biome[src]
				fields.dist[dst] = w.dist_ocean[src]
				fields.path[dst] = maxi(w.path_mask[src] if has_paths else 0, int(paths.get(Vector2i(x, y), 0)))
	var regions: Dictionary = ledger.get("regions", {})
	for key: Vector2i in regions:
		var known: Dictionary = regions[key]
		var r: Rect2i = known.rect
		var part := r.intersection(rect)
		if not part.has_area(): continue
		for y in range(part.position.y, part.end.y):
			for x in range(part.position.x, part.end.x):
				var dst := (y - rect.position.y) * rect.size.x + x - rect.position.x
				var src := (y - r.position.y) * r.size.x + x - r.position.x
				fields.fixed[dst] = 1
				for name: String in ["h", "ocean", "lake", "water_level", "river", "biome", "dist", "path"]:
					fields[name][dst] = known.fields[name][src]
