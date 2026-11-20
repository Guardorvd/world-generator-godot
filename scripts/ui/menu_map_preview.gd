extends RefCounted
## Производные мини-карты строятся в рабочем потоке только из проверенного кэша.
const Data := preload("res://scripts/ui/local_map_data.gd")
const Topology := preload("res://scripts/world/road_topology.gd")
const SIDE := 256

static func build(seed_text: String) -> Array:
	var cache := WorldCache.new()
	if cache.ready_layers(seed_text) < 2:
		if QuickTrails.active(): return []
		cache.dir = WorldCache.BUNDLED
	if cache.ready_layers(seed_text) < 2: return []
	var data := {}
	for layer in 2:
		var part: Variant = cache._read(cache.path_for(seed_text, WorldGenerator.START_SIZE, layer), cache._key(seed_text, WorldGenerator.START_SIZE, layer))
		if not part is Dictionary: return []
		data.merge(part, true)
	var w: WorldData = cache._restore(data, false)
	if w == null: return []
	return render(w)


## Полная география совпадает с миром по зерну; дороги и объекты ещё не строятся.
static func generate_geography(seed_text: String, should_cancel: Callable) -> Array:
	var w := WorldGenerator.geography(seed_text, Callable(), should_cancel)
	if w == null or (should_cancel.is_valid() and should_cancel.call()): return []
	var maps := render(w)
	if maps.size() != 2 or (should_cancel.is_valid() and should_cancel.call()): return []
	var relief := Image.create(SIDE, SIDE, false, Image.FORMAT_RGB8)
	for y in SIDE:
		if y % 16 == 0 and should_cancel.is_valid() and should_cancel.call(): return []
		for x in SIDE:
			var wx := mini(w.W - 1, x * w.W / SIDE)
			var wy := mini(w.H - 1, y * w.H / SIDE)
			var i := wy * w.W + wx
			var rgb: Array = Biomes.LIST[clampi(w.biome[i], 0, Biomes.LIST.size() - 1)].color
			var color := Color(rgb[0] / 255.0, rgb[1] / 255.0, rgb[2] / 255.0)
			if w.ocean[i] == 0 and w.lake[i] == 0:
				var west: float = w.h[wy * w.W + maxi(0, wx - 2)]
				var north: float = w.h[maxi(0, wy - 2) * w.W + wx]
				color *= 1.0 + clampf((west + north - 2.0 * w.h[i]) * 8.0, -0.32, 0.25)
			relief.set_pixel(x, y, color)
	return [relief, maps[0], maps[1]]

static func render(w: WorldData) -> Array:
	if w.W <= 0 or w.H <= 0 or w.h.size() != w.N or w.biome.size() != w.N or w.lake.size() != w.N or w.ocean.size() != w.N: return []
	var atlas := Image.create(SIDE, SIDE, false, Image.FORMAT_RGB8)
	var heights := Image.create(SIDE, SIDE, false, Image.FORMAT_RGB8)
	for y in SIDE:
		for x in SIDE:
			var wx := mini(w.W - 1, x * w.W / SIDE)
			var wy := mini(w.H - 1, y * w.H / SIDE)
			var i := wy * w.W + wx
			var water := w.ocean[i] != 0 or w.lake[i] != 0
			var biome := clampi(int(w.biome[i]), 0, Data.PALETTE.size() - 1)
			var paper: Color = Data.WATER if water else Data.PALETTE[biome].lerp(Color("#f2e7cd"), 0.3)
			var h := clampf(w.h[i] * 2.5, 0.0, 1.0)
			var color := Color("#396f8b") if water else Color("#355d48").lerp(Color("#d1be7c"), clampf(h * 1.6, 0.0, 1.0)).lerp(Color("#f4eee1"), clampf((h - 0.52) * 2.1, 0.0, 1.0))
			atlas.set_pixel(x, y, paper)
			heights.set_pixel(x, y, color)
	for river: Array in w.rivers:
		_draw_line(atlas, river, Color("#719da8"), float(SIDE) / w.W)
	for section: Dictionary in Topology.sections(w).values():
		_draw_line(atlas, section.pts, Color("#947d5d"), float(SIDE) / w.W)
	var plan: Dictionary = w.trail_plan
	if plan.get("state") == "found" and plan.has("definition"):
		for route: Dictionary in plan.get("routes", [plan.definition]):
			_draw_line(atlas, route.get("points", PackedVector2Array()), Color("#526c49"), float(SIDE) / (w.W * GameConfig.TILE))
	return [atlas, heights]

static func _draw_line(image: Image, points: Variant, color: Color, scale: float) -> void:
	for n in range(1, points.size()):
		var a := Vector2(points[n - 1].x, points[n - 1].y) * scale
		var b := Vector2(points[n].x, points[n].y) * scale
		var steps := ceili(a.distance_to(b))
		for j in range(steps + 1):
			var p := a.lerp(b, float(j) / maxf(steps, 1.0))
			var x := roundi(p.x)
			var y := roundi(p.y)
			if x >= 0 and x < SIDE and y >= 0 and y < SIDE:
				image.set_pixel(x, y, color)
