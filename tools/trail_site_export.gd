extends SceneTree
## Trail Lab: сохранённая площадка из готового мира. Мир читается из кэша (WorldCache.read_only), генерация не
## запускается: нет подходящего кэша — отказ с причиной. Рельеф готовится как при загрузке игры
## (Heightfield с finish_paths: русла, полотно путей, мосты, метровая сетка), затем вырезается участок.
##   godot --headless --path . --script res://tools/trail_site_export.gd -- --list
##   godot --headless --path . --script res://tools/trail_site_export.gd -- --rect 400,300,64 --demo "1650,1300;1700,1350"
## --seed — мир (по умолчанию первый RecommendedSeeds), --cache bundled|user — откуда кэш (по умолчанию проект),
## --rect x,z,сторона или x,z,ширина,высота — рабочий прямоугольник в мировых клетках, --margin — запас (16 клеток),
## --demo — опорные точки демонстрационной трассы в мировых метрах, --name — имя файла в TrailSite.DIR,
## --refusals — проверить отказы (граница за стартовой областью, разрезанный мост). Кэш не меняется: хеши файлов
## до и после печатаются. Ожидание: чтение кэша и рельеф 768 — десятки секунд на втором ПК.

const Watchdog = preload("res://tools/watchdog.gd")


func _init() -> void:
	Watchdog.arm(self, 300)
	var args := _args()
	var seed: String = args.get("seed", RecommendedSeeds.SEEDS[0].seed)
	var cache := WorldCache.new()
	cache.dir = WorldCache.BUNDLED if args.get("cache", "bundled") == "bundled" else "user://world_cache"
	var started := Time.get_ticks_msec()
	var got := cache.read_only(seed)
	if got.has("error"):
		printerr("ОТКАЗ: ", got.error, ". Генерация не запускается: нужен готовый мир в кэше.")
		quit(1)
		return
	var before := _hashes(got.files)
	var w: WorldData = got.world
	print("Мир «%s» из кэша %s: %d мс, план %d, стартовая область %s" % [seed, cache.dir, Time.get_ticks_msec() - started, w.W, w.available_rect])
	if args.has("list"):
		_list(w)
		quit()
		return
	started = Time.get_ticks_msec()
	var h := Heightfield.new(w) # как WorldLoader: ленты рек, русла, вода, finish_paths
	print("Готовая поверхность мира (как при загрузке игры): %d мс" % (Time.get_ticks_msec() - started))
	var margin := int(args.get("margin", "16"))
	if args.has("refusals"):
		_refusals(w, h, margin)
	if not args.has("rect"):
		printerr("Нужен --rect x,z,сторона")
		quit(1)
		return
	var r := PackedInt32Array(Array(str(args.rect).split(",")).map(func(s: String) -> int: return int(s)))
	var rect := Rect2i(r[0], r[1], r[2], r[3] if r.size() > 3 else r[2])
	started = Time.get_ticks_msec()
	var cut := TrailSite.cut(w, h, rect, margin, got.view)
	if not cut.errors.is_empty():
		printerr("ОТКАЗ: ", "; ".join(cut.errors))
		quit(1)
		return
	var site: TrailSite = cut.site
	site.title = str(args.get("title", "Участок мира «%s» (%d, %d)" % [seed, rect.position.x, rect.position.y]))
	site.source.cache = {format = WorldCache.FORMAT, dir = cache.dir, keys = got.keys,
		schema = [WorldCache.SCHEMA_WORLD_VERSION, WorldCache.SCHEMA_GEO_VERSION, WorldCache.SCHEMA_TRAILS_VERSION,
			WorldCache.SCHEMA_NATURE_VERSION, WorldCache.SCHEMA_VIEW_VERSION]}
	site.source.files = before
	var demo: Array = []
	for pair in str(args.get("demo", "")).split(";", false):
		var xz := pair.split(",")
		demo.append(Vector2(float(xz[0]), float(xz[1])))
	var T := TrailElement.Profile
	site.demo = {title = "Трасса участка", kind = "mountain", width = 4.0, surface = RoadSurface.DIRT, points = demo,
		elements = [{profile = T.ROLLER, station = 40.0, length = 8.0, height = 0.5}, {profile = T.TABLETOP, station = 85.0, length = 14.0, height = 0.7}]}
	print("Участок: рабочий %s, запас %d, origin %s, клеток %s; путей %d кусков, сооружений %d, лент рек %d, патчей %d, текстура %s; %d мс" % [
		rect, margin, site.origin, site.size, site.trails.size(), site.structures.size(), site.ribbons.size(), site.patches.size(),
		"есть" if not site.image.is_empty() else "нет", Time.get_ticks_msec() - started])
	started = Time.get_ticks_msec()
	site.record_reference(h)
	print("Выборки источника: %d точек (у путей %d), %d мс" % [site.reference.x.size(), Array(site.reference.near_road).count(1), Time.get_ticks_msec() - started])
	var direct := site.prepare([] as Array[TrailDefinition])
	_report("Участок в памяти против источника", site.compare(direct.heights))
	var demo_route := site.demo_route()
	var demo_errors := site.inside_errors([demo_route] as Array[TrailDefinition])
	var wet := 0.0
	var roads := 0
	for p in demo_route.points:
		wet = maxf(wet, direct.heights.depth_at(p.x, p.y))
		roads += int(direct.heights.road_refinement.sample(p.x, p.y, site.size.x).get("weight", 0.0) > 0.3)
	print("Демонстрационная трасса: %.0f м, %s; глубина воды на оси до %.2f м, точек на полотне путей %d" % [
		demo_route.route_length(), "в рабочей зоне" if demo_errors.is_empty() else "; ".join(demo_errors), wet, roads])
	var path := TrailSite.DIR.path_join(str(args.get("name", "site_%d_%d" % [rect.position.x, rect.position.y])) + TrailSite.EXT)
	started = Time.get_ticks_msec()
	var err := site.save(path)
	if err != OK:
		printerr("Не записан ", path, ": ", error_string(err))
		quit(1)
		return
	print("Записан %s: %.2f МБ, %d мс" % [path, FileAccess.get_size(path) / 1048576.0, Time.get_ticks_msec() - started])
	started = Time.get_ticks_msec()
	var opened := TrailSite.open(path)
	if opened.has("error"):
		printerr("Не открылся: ", opened.error)
		quit(1)
		return
	print("Открыт заново: %d мс" % (Time.get_ticks_msec() - started))
	_report("Открытый файл против источника", (opened.site as TrailSite).compare((opened.site as TrailSite).prepare([] as Array[TrailDefinition]).heights))
	var after := _hashes(got.files)
	print("Файлы кэша мира не изменились: %s" % ("да" if after == before else "НЕТ"))
	quit(0 if after == before else 1)


func _report(title: String, c: Dictionary) -> void:
	print("%s: %d точек (у путей %d); земля %.6f м, опора %.6f м, вода %.6f м, вес полотна %.6f, поперёк %.6f, кочка %.6f м; покрытие колеса не совпало %d (у путей %d), покрытие клетки %d" % [
		title, c.points, c.road_points, c.ground, c.support, c.depth, c.weight, c.across, c.bump, c.surface_mismatch, c.road_mismatch, c.cell_mismatch])


func _hashes(files: Array) -> Dictionary:
	var out := {}
	for path: String in files:
		out[path] = FileAccess.get_sha256(path) if FileAccess.file_exists(path) else ""
	return out


## Отказы на том же мире: граница за стартовой областью и участок, граница которого режет мост.
func _refusals(w: WorldData, h: Heightfield, margin: int) -> void:
	var area := w.available_rect
	var outside := TrailSite.cut(w, h, Rect2i(area.end - Vector2i(20, 20), Vector2i(32, 32)), margin)
	print("Отказ 1 (граница): ", "; ".join(outside.get("errors", PackedStringArray(["НЕТ ОТКАЗА"]))))
	for b: BridgeData in w.bridges:
		var m := (Vector2i(b.a % w.W, b.a / w.W) + Vector2i(b.b % w.W, b.b / w.W)) / 2
		var rect := Rect2i(m.x + margin, m.y - 16, 32, 32)
		if area.encloses(rect.grow(margin)):
			var cut := TrailSite.cut(w, h, rect, margin)
			print("Отказ 2 (мост у клетки %s): " % m, "; ".join(cut.get("errors", PackedStringArray(["НЕТ ОТКАЗА"]))))
			return
	print("Отказ 2: нет моста в стартовой области для проверки")


## Сводка стартовой области для выбора участка вручную: мосты, туннели, поселения, плотность путей по блокам 32 клетки.
func _list(w: WorldData) -> void:
	var area := w.available_rect
	for b: BridgeData in w.bridges:
		var c := Vector2i(b.a % w.W, b.a / w.W)
		if area.has_point(c): print("мост ", c, " — ", Vector2i(b.b % w.W, b.b / w.W))
	for t: TunnelData in w.tunnels:
		var c := Vector2i(t.a % w.W, t.a / w.W)
		if area.has_point(c): print("туннель ", c, " — ", Vector2i(t.b % w.W, t.b / w.W))
	for s: SettlementData in w.settlements:
		if area.has_point(Vector2i(floori(s.x), floori(s.y))): print("поселение (%d, %d)" % [s.x, s.y])
	var blocks := {}
	for t: Dictionary in w.trails:
		if not RoadBed.KINDS.has(t.kind): continue
		for p: Dictionary in t.pts:
			var key := Vector2i(floori(p.x / 32.0), floori(p.y / 32.0))
			var entry: Dictionary = blocks.get(key, {road = 0, trail = 0, mountain = 0})
			entry[t.kind] += 1
			blocks[key] = entry
	var rows := []
	for key: Vector2i in blocks:
		var cell := key * 32 + Vector2i(16, 16)
		if area.has_point(cell):
			var i := cell.y * w.W + cell.x
			rows.append([key, blocks[key], w.elev[i], w.biome[i], w.dist_water[i]])
	rows.sort_custom(func(a: Array, b: Array) -> bool: return a[1].road + a[1].trail > b[1].road + b[1].trail)
	for row in rows.slice(0, 40):
		print("блок %s (клетки %s): дорога %d, тропа %d, горная %d; высота %.2f, биом %d, до воды %.0f" % [row[0], row[0] * 32, row[1].road, row[1].trail, row[1].mountain, row[2], row[3], row[4]])


func _args() -> Dictionary:
	var out := {}
	var list := OS.get_cmdline_user_args()
	var k := 0
	while k < list.size():
		var key := list[k].trim_prefix("--")
		if k + 1 < list.size() and not list[k + 1].begins_with("--"):
			out[key] = list[k + 1]
			k += 2
		else:
			out[key] = true
			k += 1
	return out
