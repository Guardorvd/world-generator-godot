extends RefCounted
## Общая публикация подготовленных соседей: одна геометрия для земли и ореолов.
## Трассировка выполняется заранее, со всеми известными входами. Здесь нет новой гидрологии.
const Surface := preload("res://scripts/world/region_water_surface.gd")


static func finish(regions: Array, networks: Array) -> Dictionary:
	if regions.size() != networks.size() or regions.is_empty():
		return {ready = false, reason = "invalid_batch", surfaces = []}
	var all := {rivers = [], unresolved = []}
	for network: Dictionary in networks:
		all.rivers.append_array(network.rivers)
		all.unresolved.append_array(network.unresolved)
	if not all.unresolved.is_empty():
		return {ready = false, reason = "unresolved_water", surfaces = []}
	for network: Dictionary in networks:
		for outlet: Dictionary in network.outlets:
			var cell := Vector2i(floori(outlet.x + outlet.dx * 0.5), floori(outlet.y + outlet.dy * 0.5))
			for n in regions.size():
				if not regions[n].rect.has_point(cell): continue
				var matched := false
				for river: Dictionary in networks[n].rivers:
					var point: Dictionary = river.points[0]
					if point.x == outlet.x and point.y == outlet.y and point.e == outlet.e \
							and point.w == outlet.w and river.acc == outlet.acc:
						matched = true
				if not matched: return {ready = false, reason = "missing_continuation", surfaces = []}
	# Порядок расчёта соседей не влияет на обработку сегментов.
	all.rivers.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var ap: Dictionary = a.points[0]
		var bp: Dictionary = b.points[0]
		return ap.y < bp.y or ap.y == bp.y and ap.x < bp.x)
	var surfaces: Array = []
	for region: Dictionary in regions:
		var surface := Surface.prepare(region, all)
		if not surface.ready: return {ready = false, reason = surface.reason, surfaces = []}
		surfaces.append(surface)
	# Проверить и исходные поля: нельзя склеивать заготовки разных версий/сидов.
	for a in regions.size():
		for b in range(a + 1, regions.size()):
			if regions[a].rect.intersects(regions[b].rect):
				return {ready = false, reason = "overlapping_regions", surfaces = []}
			var overlap: Rect2i = regions[a].sample_rect.intersection(regions[b].sample_rect)
			for y in range(overlap.position.y, overlap.end.y):
				for x in range(overlap.position.x, overlap.end.x):
					var ai := index(regions[a], x, y)
					var bi := index(regions[b], x, y)
					for key in ["h", "fixed", "ocean"]:
						if regions[a].fields[key][ai] != regions[b].fields[key][bi]:
							return {ready = false, reason = "source_mismatch", surfaces = []}
					for key in ["h", "water_level", "river"]:
						if surfaces[a][key][ai] != surfaces[b][key][bi]:
							return {ready = false, reason = "surface_mismatch", surfaces = []}
	return {ready = true, reason = "", surfaces = surfaces}


static func index(r: Dictionary, x: int, y: int) -> int:
	return (y - r.sample_rect.position.y) * r.sample_rect.size.x + x - r.sample_rect.position.x
