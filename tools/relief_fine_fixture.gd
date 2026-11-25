extends RefCounted
## Сохраняет окончательное полотно вместе с планом, чтобы стенд не перестраивал ни мир, ни дорогу.

const Surface := preload("res://scripts/game/surface_snapshot.gd")
const Files := preload("res://scripts/core/cache_file.gd")
const DIR := "res://tools/control/runs/relief_fine"
const SEEDS := ["Север-1234", "Туман-4821"]
const VIEW_NAMES := ["Лес у тропы", "Речная терраса", "Полка отрога", "Вогнутый склон", "Стена долины"]
const SIZE := Vector2i(384, 1024)
const TILE := GameConfig.TILE
const VERSION := 1


static func save(seed_text: String) -> Error:
	var w := WorldGenerator.generate(seed_text, SIZE.x, Callable(), Callable(), Callable(), WorldTemplate.EXPEDITION_ID, true)
	if w == null or Vector2i(w.W, w.H) != SIZE or w.trails.is_empty():
		return ERR_CANT_CREATE
	var h := Heightfield.new()
	h.world = w
	var report := StageTrailPlan.prepare(h)
	if not report.errors.is_empty() or h.hv.size() != w.N:
		return ERR_INVALID_DATA
	var route := route_points(w)
	var views := _pick_views(w, h, route)
	if views.size() != VIEW_NAMES.size():
		return ERR_DOES_NOT_EXIST
	var world := {}
	for field: String in WorldData.CACHE_FIELDS:
		world[field] = EntityCodec.encode(w.get(field))
	var file := DIR.path_join(seed_text + ".fixture.bin")
	return Files.replace(file, var_to_bytes({version = VERSION, world = world,
		surface = Surface.capture(h, "final"), route = route, views = views}))


static func restore(seed_text: String) -> Dictionary:
	var file := FileAccess.open(DIR.path_join(seed_text + ".fixture.bin"), FileAccess.READ)
	if file == null:
		return {}
	var saved: Variant = bytes_to_var(file.get_buffer(file.get_length()))
	file.close()
	if not saved is Dictionary or saved.get("version") != VERSION:
		return {}
	if not saved.get("world") is Dictionary or not saved.get("surface") is Dictionary:
		return {}
	if not saved.get("views") is Array or saved.views.size() != VIEW_NAMES.size() or not saved.get("route") is PackedVector2Array:
		return {}
	var cache := WorldCache.new()
	cache.set_template(WorldTemplate.EXPEDITION_ID)
	var w := cache._restore(saved.world, true)
	if w == null or Vector2i(w.W, w.H) != SIZE or w.seed_text != seed_text:
		return {}
	var h := Surface.restore(w, saved.surface, "final")
	if h == null or h.road_refinement.patches.is_empty():
		return {}
	w.clear_noise_fields()
	return {world = w, heights = h, route = saved.route, views = saved.views}


static func route_points(w: WorldData) -> PackedVector2Array:
	var longest := PackedVector2Array()
	for trail: Dictionary in w.trails:
		if trail.pts.size() <= longest.size():
			continue
		longest.resize(0)
		for p: Dictionary in trail.pts:
			longest.append(Vector2(p.x, p.y) * TILE)
	return longest


static func _pick_views(w: WorldData, h: Heightfield, route: PackedVector2Array) -> Array:
	var axis := ValleyAxis.for_world(w)
	var scores := PackedFloat64Array()
	scores.resize(VIEW_NAMES.size())
	scores.fill(-INF)
	var views := []
	views.resize(scores.size())
	var bounds := Rect2(Vector2.ZERO, Vector2(w.W, w.H) * TILE).grow(-80.0)
	for i in range(2, route.size() - 2, 3):
		var p := route[i]
		if not bounds.has_point(p):
			continue
		var row := floori(p.y / TILE)
		var river := Vector2(axis.axis_x_at(p.y / TILE) * TILE, p.y)
		var outward := Vector2(signf(p.x - river.x), 0.0)
		var bank := river + outward * (axis.river_hw_at(row) * TILE + 24.0)
		var near_slope := p + outward * 26.0
		var ledge := p + outward * 52.0
		var low := p - outward * 34.0
		var across := river - outward * 290.0
		if not (bounds.has_point(bank) and bounds.has_point(ledge) and bounds.has_point(low) and bounds.has_point(across)):
			continue
		var rise := _height(h, near_slope) - _height(h, p)
		var above_river := _height(h, p) - _height(h, river)
		var bank_grade := absf(_height(h, bank + outward * 14.0) - _height(h, bank)) / 14.0
		var forest := _wooded(w, near_slope)
		var forward := (route[i + 2] - route[i - 2]).normalized()
		var separation := p.distance_to(river)
		if forest and h.depth_at(p.x, p.y) == 0.0:
			_keep(views, scores, h, 0, -absf(rise - 5.0) - absf(separation - 95.0) * 0.015,
				p, near_slope + forward * 12.0, 1.85, 24.0)
		if h.depth_at(bank.x, bank.y) == 0.0:
			_keep(views, scores, h, 1, -bank_grade - absf(separation - 65.0) * 0.005,
				bank, river + Vector2(0.0, 40.0), 1.68, 24.0)
		if above_river > 8.0 and h.depth_at(ledge.x, ledge.y) == 0.0:
			var ledge_grade := absf(_height(h, ledge) - _height(h, near_slope)) / 26.0
			_keep(views, scores, h, 2, minf(above_river, 45.0) * 0.1 - ledge_grade * 12.0,
				ledge, p + forward * 18.0, 1.68, 24.0)
		if separation > axis.river_hw_at(row) * TILE + 45.0 and h.depth_at(low.x, low.y) == 0.0:
			var shelf := (p + low) * 0.5
			var hollow := (_height(h, p) + _height(h, low)) * 0.5 - _height(h, shelf)
			_keep(views, scores, h, 3, hollow + clampf(above_river, 0.0, 30.0) * 0.03,
				p, low + forward * 17.0, 1.68, 25.0)
		var wall_rise := _height(h, across) - _height(h, bank)
		if wall_rise > 35.0 and h.depth_at(bank.x, bank.y) == 0.0:
			_keep(views, scores, h, 4, wall_rise - bank_grade * 30.0,
				bank, across + Vector2(0.0, 38.0), 1.85, 0.0)
	return [] if views.has(null) else views


static func _height(h: Heightfield, p: Vector2) -> float:
	return h.base_ground_at(p.x, p.y)


static func _wooded(w: WorldData, p: Vector2) -> bool:
	var biome := w.biome[floori(p.y / TILE) * w.W + floori(p.x / TILE)]
	return biome in [Biomes.FOREST, Biomes.TAIGA, Biomes.JUNGLE]


static func _keep(views: Array, scores: PackedFloat64Array, h: Heightfield, key: int, score: float,
		p: Vector2, target: Vector2, eye: float, focus_m: float) -> void:
	if score <= scores[key]:
		return
	scores[key] = score
	var focus := p + (target - p).normalized() * focus_m
	views[key] = {eye = Vector3(p.x, h.ground_at(p.x, p.y) + eye, p.y),
		target = Vector3(target.x, _height(h, target) + 1.0, target.y), focus = focus, score = score}
