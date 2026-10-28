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
	if args.has("scan"):
		_scan(w, h, int(args.get("side", "64")), margin)
		quit()
		return
	if args.has("refusals") and not _refusals(w, h, margin):
		printerr("ОШИБКА: проверка отказов не прошла, площадка не записана")
		quit(1)
		return
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
	if args.has("note"): site.source.note = str(args.note) # почему выбран участок (набор площадок построителя)
	var demo: Array = []
	for pair in str(args.get("demo", "")).split(";", false):
		var xz := pair.split(",")
		demo.append(Vector2(float(xz[0]), float(xz[1])))
	var T := TrailElement.Profile
	# Без --demo площадка остаётся без демонстрационной трассы (только данные для построителя)
	site.demo = {} if demo.is_empty() else {title = "Трасса участка", kind = "mountain", width = 4.0, surface = RoadSurface.DIRT, points = demo,
		elements = [{profile = T.ROLLER, station = 40.0, length = 8.0, height = 0.5}, {profile = T.TABLETOP, station = 85.0, length = 14.0, height = 0.7}]}
	print("Участок: рабочий %s, запас %d, origin %s, клеток %s; путей %d кусков, сооружений %d, лент рек %d, патчей %d, текстура %s; %d мс" % [
		rect, margin, site.origin, site.size, site.trails.size(), site.structures.size(), site.ribbons.size(), site.patches.size(),
		"есть" if not site.image.is_empty() else "нет", Time.get_ticks_msec() - started])
	started = Time.get_ticks_msec()
	site.record_reference(h)
	print("Выборки источника: %d точек (у путей %d), %d мс" % [site.reference.x.size(), Array(site.reference.near_road).count(1), Time.get_ticks_msec() - started])
	var direct := site.prepare([] as Array[TrailDefinition])
	if not _verified("Участок в памяти против источника", site.compare(direct.heights)):
		quit(1)
		return
	var demo_route := site.demo_route()
	var demo_errors := site.inside_errors([demo_route] as Array[TrailDefinition])
	var wet := 0.0
	var roads := 0
	for p in demo_route.points:
		wet = maxf(wet, direct.heights.depth_at(p.x, p.y))
		roads += int(direct.heights.road_refinement.sample(p.x, p.y, site.size.x).get("weight", 0.0) > 0.3)
	print("Демонстрационная трасса: %.0f м, %s; глубина воды на оси до %.2f м, точек на полотне путей %d" % [
		demo_route.route_length(), "в рабочей зоне" if demo_errors.is_empty() else "; ".join(demo_errors), wet, roads])
	if not demo_errors.is_empty():
		printerr("ОШИБКА: демонстрационная трасса вне рабочей зоны, площадка не записана")
		quit(1)
		return
	# Новый файл пишется рядом и заменяет прежний только после проверки: пригодная площадка не теряется.
	var path := TrailSite.DIR.path_join(str(args.get("name", "site_%d_%d" % [rect.position.x, rect.position.y])) + TrailSite.EXT)
	var candidate := path + ".candidate"
	started = Time.get_ticks_msec()
	var err := site.save(candidate)
	if err != OK:
		printerr("ОШИБКА: не записан ", candidate, ": ", error_string(err))
		quit(1)
		return
	print("Записан на проверку %s: %.2f МБ, %d мс" % [candidate, FileAccess.get_size(candidate) / 1048576.0, Time.get_ticks_msec() - started])
	started = Time.get_ticks_msec()
	var opened := TrailSite.open(candidate)
	if opened.has("error"):
		printerr("ОШИБКА: записанная площадка не открылась: ", opened.error)
		DirAccess.remove_absolute(candidate)
		quit(1)
		return
	print("Открыт заново: %d мс" % (Time.get_ticks_msec() - started))
	var reopened: TrailSite = opened.site
	var after := _hashes(got.files)
	var ok := _verified("Открытый файл против источника", reopened.compare(reopened.prepare([] as Array[TrailDefinition]).heights))
	if after != before:
		printerr("ОШИБКА: файлы кэша мира изменились во время экспорта")
		ok = false
	if not ok:
		DirAccess.remove_absolute(candidate)
		printerr("Площадка не записана; прежний файл %s оставлен как был" % path)
		quit(1)
		return
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)
	err = DirAccess.rename_absolute(candidate, path)
	if err != OK:
		printerr("ОШИБКА: не удалось заменить ", path, ": ", error_string(err))
		quit(1)
		return
	print("Площадка проверена и записана: %s. Файлы кэша мира не изменились." % path)
	quit(0)


## Сверка с источником по единым допускам TrailSite.TOLERANCE; превышение — ошибка экспорта.
func _verified(title: String, c: Dictionary) -> bool:
	print("%s: %d точек (у путей %d); земля %.6f м, опора %.6f м, вода %.6f м, вес полотна %.6f, поперёк %.6f, кочка %.6f м; покрытие колеса не совпало %d (у путей %d), покрытие клетки %d" % [
		title, c.points, c.road_points, c.ground, c.support, c.depth, c.weight, c.across, c.bump, c.surface_mismatch, c.road_mismatch, c.cell_mismatch])
	var problems := TrailSite.mismatch(c)
	if not problems.is_empty():
		printerr("ОШИБКА: %s — превышены допуски: %s" % [title, "; ".join(problems)])
	return problems.is_empty()


func _hashes(files: Array) -> Dictionary:
	var out := {}
	for path: String in files:
		out[path] = FileAccess.get_sha256(path) if FileAccess.file_exists(path) else ""
	return out


## Отказы на том же мире: граница за стартовой областью и участок, граница которого режет мост. Принятый участок
## или отказ не по той причине — false (ошибка экспорта); нет моста для проверки — тоже false: отказ не проверен.
func _refusals(w: WorldData, h: Heightfield, margin: int) -> bool:
	var area := w.available_rect if w.available_rect.has_area() else Rect2i(0, 0, w.W, w.H)
	var outside := TrailSite.cut(w, h, Rect2i(area.end - Vector2i(20, 20), Vector2i(32, 32)), margin)
	var ok := _refused("Отказ 1 (граница)", outside, "неподдерживаемая граница")
	for b: BridgeData in w.bridges:
		var m := (Vector2i(b.a % w.W, b.a / w.W) + Vector2i(b.b % w.W, b.b / w.W)) / 2
		var rect := Rect2i(m.x + margin, m.y - 16, 32, 32)
		if area.encloses(rect.grow(margin)):
			return _refused("Отказ 2 (мост у клетки %s)" % m, TrailSite.cut(w, h, rect, margin), "неполное сооружение") and ok
	printerr("Отказ 2: нет моста в стартовой области — отказ не проверен")
	return false


func _refused(title: String, cut: Dictionary, reason: String) -> bool:
	var errors: PackedStringArray = cut.get("errors", PackedStringArray())
	var ok := cut.get("site") == null and not errors.is_empty() and Array(errors).any(func(e: String) -> bool: return e.begins_with(reason))
	if ok: print(title, ": ", "; ".join(errors))
	else: printerr("ОШИБКА: %s — ожидался отказ «%s», получено: %s" % [title, reason, "; ".join(errors) if not errors.is_empty() else "участок принят"])
	return ok


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


## Характеристики местности окон side × side клеток (шаг side/2) в стартовой области с запасом margin — для выбора
## площадок набора ДО запуска построителя: перепад, уклон клеток (средний, 90-й процентиль, доли круче 15 и 30 %),
## наклон плоскости окна и неровность вокруг неё (косогор — большой наклон при малой неровности), доли воды и путей,
## сооружения. Только печать; построитель трасс не вызывается.
func _scan(w: WorldData, h: Heightfield, side: int, margin: int) -> void:
	var area := w.available_rect if w.available_rect.has_area() else Rect2i(0, 0, w.W, w.H)
	var tile := GameConfig.TILE
	var mask := w.path_mask
	print("окно x,z | перепад м | уклон ср / p90 % | >15 % / >30 % доля | плоскость % / неровность м | вода / пути доля | сооружений")
	var z0 := area.position.y + margin
	while z0 + side + margin <= area.end.y:
		var x0 := area.position.x + margin
		while x0 + side + margin <= area.end.x:
			var lo := INF
			var hi := -INF
			var slopes := PackedFloat32Array()
			var wet := 0
			var paths := 0
			# плоскость z = a + bx·x + bz·z методом наименьших квадратов (центрированные координаты)
			var sx := 0.0
			var sz := 0.0
			var sxx := 0.0
			var szz := 0.0
			var sxz := 0.0
			var sy := 0.0
			var sxy := 0.0
			var szy := 0.0
			var n := 0
			for z in range(z0, z0 + side):
				for x in range(x0, x0 + side):
					var i := z * w.W + x
					var y := h.hv[i]
					lo = minf(lo, y)
					hi = maxf(hi, y)
					var gx := (h.hv[i + 1] - h.hv[i - 1]) / (2.0 * tile)
					var gz := (h.hv[i + w.W] - h.hv[i - w.W]) / (2.0 * tile)
					slopes.append(sqrt(gx * gx + gz * gz))
					wet += int(h.water_level[i] != -INF)
					paths += int(mask.size() == w.N and mask[i] != 0)
					var u := float(x - x0) * tile
					var v := float(z - z0) * tile
					sx += u; sz += v; sxx += u * u; szz += v * v; sxz += u * v; sy += y; sxy += u * y; szy += v * y
					n += 1
			var mu := sx / n
			var mv := sz / n
			var my := sy / n
			var cuu := sxx / n - mu * mu
			var cvv := szz / n - mv * mv
			var cuv := sxz / n - mu * mv
			var cuy := sxy / n - mu * my
			var cvy := szy / n - mv * my
			var det := cuu * cvv - cuv * cuv
			var bx := (cuy * cvv - cvy * cuv) / det
			var bz := (cvy * cuu - cuy * cuv) / det
			var resid := 0.0
			for z in range(z0, z0 + side):
				for x in range(x0, x0 + side):
					var e := h.hv[z * w.W + x] - (my + bx * (float(x - x0) * tile - mu) + bz * (float(z - z0) * tile - mv))
					resid += e * e
			var sorted := slopes.duplicate()
			sorted.sort()
			var mean := 0.0
			var steep := 0
			var cliff := 0
			for s in slopes:
				mean += s
				steep += int(s > 0.15)
				cliff += int(s > 0.30)
			# сооружения, задевающие участок с запасом (как TrailSite.cut); разрезанное границей — участок не вырезать (-1)
			var box := Rect2(Vector2(x0 - margin, z0 - margin) * tile, Vector2(side + 2 * margin, side + 2 * margin) * tile)
			var structures := 0
			for s: Dictionary in h.structures:
				var r: float = s.half + RoadBed.PIN + RoadBed.PIN_FADE + Heightfield.TUNNEL_WALL + tile
				var corner := Vector2(minf(s.ax, s.bx), minf(s.az, s.bz)) - Vector2.ONE * r
				var foot := Rect2(corner, Vector2(maxf(s.ax, s.bx), maxf(s.az, s.bz)) + Vector2.ONE * r - corner)
				if not foot.intersects(box): continue
				if not box.encloses(foot):
					structures = -1
					break
				structures += 1
			print("%d,%d | %.1f | %.1f / %.1f | %.2f / %.2f | %.1f / %.2f | %.3f / %.3f | %d" % [x0, z0, hi - lo,
				mean / n * 100.0, sorted[int(n * 0.9)] * 100.0, float(steep) / n, float(cliff) / n,
				Vector2(bx, bz).length() * 100.0, sqrt(resid / n), float(wet) / n, float(paths) / n, structures])
			x0 += side / 2
		z0 += side / 2


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
