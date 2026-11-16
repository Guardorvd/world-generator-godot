extends SceneTree
## Стенд дорог стартового плана (ревью дорожной сети 29.10): места и пути (StageLandmarks + StageTrails) на готовой
## географии одного мира, без сцены. Для отчёта дополнительно строятся готовая поверхность и растительность.
## География генерируется один раз и хранится в
## user://road_plan_test как слой кэша миров (тот же путь, что загрузка мира с одной географией из кэша), дальше
## каждый запуск начинается сразу с мест. Печатает причины отказов, работу поиска, время и отпечаток результата.
##   godot --headless --path . --script res://tools/road_plan_test.gd -- [--seed Север-1234] [--save <файл.json>] [--compare <файл.json>]
## --save пишет отпечаток (было), --compare сверяет с ним (стало): тот же мир — рефакторинг, разный — изменение маршрутов.
## --metrics-json <файл> сохраняет сравнимый отчёт о готовой сети; --metrics также пишет картинку.
## Первый запуск на этом ПК ~1,5 мин (география), следующие ~1 мин.

const SelfTest := preload("res://tools/selftest.gd")
const Metrics := preload("res://tools/road_network_metrics.gd")
const Floor := preload("res://scripts/render/forest_floor.gd")
const SIZE := 512
const DIR := "user://road_plan_test"
const KEYS := ["stage_ms", "main_roads_ms", "secondary_roads_ms", "mountain_trails_ms", "settlement_attempts",
	"settlement_rejected", "road_failures", "expanded", "prefetch_expanded", "budget_stops", "no_path", "skipped",
	"reach_calls", "reach_rejects", "reach_visited", "checkpoints", "checkpoint_mb", "restores", "road_windows", "no_bridge_cells", "cost_ms", "route_heightfield_ms", "finder_setup_ms",
	"animal_trails_ms", "corridor_road_ms", "corridor_trail_ms", "corridor_mountain_ms", "layout_ms", "native_ms", "call_ms", "calls",
	"parts_ms"]


func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 300)
	var args := OS.get_cmdline_user_args()
	var seed_text := _arg(args, "--seed", "Север-1234")
	var metrics_file := _arg(args, "--metrics-json", "")
	if "--metrics-json" in args and (metrics_file.is_empty() or metrics_file.begins_with("--")):
		printerr("--metrics-json требует путь к файлу")
		quit(1)
		return
	var report_metrics := "--metrics" in args or not metrics_file.is_empty()
	# --profile: время поиска A* в каждой попытке и всего (FastGrid считает вызовы; на мир не влияет).
	Pathfinder.profile_searches = "--profile" in args
	# --macro-legacy: прежние старт, осадки и лужи (docs/MACRO_GEOGRAPHY.md) — сравнить время путей на той же версии
	if "--macro-legacy" in args:
		StageRelief.legacy_start = true
		StageHydrology.regional = false
		StageOcean.dry_pockets = false
	# --stages: вся генерация мира без сцены и загрузчика — время каждого этапа (generation_profile.stages_ms).
	if "--stages" in args:
		var t0 := Time.get_ticks_msec()
		var full := WorldGenerator.generate(seed_text, SIZE)
		print("генерация %d мс" % (Time.get_ticks_msec() - t0))
		print("STAGES ", JSON.stringify(full.generation_profile.get("stages_ms", {})))
		var parts := {}
		for key: String in full.generation_profile:
			var value: Variant = full.generation_profile[key]
			if key.ends_with("_ms") and (value is float or value is int) and float(value) >= 200.0: parts[key] = value
		print("PARTS ", JSON.stringify(parts))
		print("TRAIL PLAN ", JSON.stringify(full.trail_plan.get("stats", {})))
		quit(0)
		return
	# --turn r,t,m: штраф поворота в поиске пути дорог, троп и горных троп (StageTrails.routing_overrides.turn_costs) — подбор чисел
	var turn := _arg(args, "--turn", "")
	if not turn.is_empty():
		StageTrails.routing_overrides.turn_costs = {road = float(turn.get_slice(",", 0)), trail = float(turn.get_slice(",", 1)), mountain = float(turn.get_slice(",", 2))}
		print("штраф поворота: ", StageTrails.routing_overrides.turn_costs)
	# --straighten r,t,m: допуск срезания лесенки сетки (клеток) для дорог, троп и горных (StageTrails.routing_overrides.straighten)
	var pull := _arg(args, "--straighten", "")
	if not pull.is_empty():
		StageTrails.routing_overrides.straighten = {road = float(pull.get_slice(",", 0)), trail = float(pull.get_slice(",", 1)), mountain = float(pull.get_slice(",", 2))}
		print("срезание лесенки: ", StageTrails.routing_overrides.straighten)
	# --bend r,t,m: штраф длинных галсов дорог, троп и горных (StageTrails.routing_overrides.bend_costs)
	var bend := _arg(args, "--bend", "")
	if not bend.is_empty():
		StageTrails.routing_overrides.bend_costs = {road = float(bend.get_slice(",", 0)), trail = float(bend.get_slice(",", 1)), mountain = float(bend.get_slice(",", 2))}
		print("длинные галсы: ", StageTrails.routing_overrides.bend_costs)
	# --line-relax r,t,m: срезаемый бугор при построении линии (StageTrails.routing_overrides.line_relax, доля предела; 0 — без поблажки)
	var line_arg := _arg(args, "--line-relax", "")
	if not line_arg.is_empty():
		StageTrails.routing_overrides.line_relax = {road = float(line_arg.get_slice(",", 0)), trail = float(line_arg.get_slice(",", 1)), mountain = float(line_arg.get_slice(",", 2))}
		print("линия: срезаемый бугор ", StageTrails.routing_overrides.line_relax)
	var cache := WorldCache.new()
	cache.dir = DIR
	cache.enabled = true
	var started := Time.get_ticks_msec()
	var got: Dictionary = cache._load(seed_text, SIZE)
	if int(got.layers) < 1:
		print("география %s: генерация (один раз)" % seed_text)
		var geo := WorldGenerator._geography(seed_text, WorldGenerator.PLAN_SIZE)
		cache._save_layer(geo, SIZE, 0, {})
		cache.wait_writes()
		got = cache._load(seed_text, SIZE)
	if int(got.layers) < 1:
		print("ОШИБКА: слой географии не прочитан")
		quit(1)
		return
	# --geo-check: география заново нынешним кодом и сверка с сохранённой (прошлой версии) по полям слоя.
	if "--geo-check" in args:
		var t0 := Time.get_ticks_msec()
		var fresh := WorldGenerator._geography(seed_text, WorldGenerator.PLAN_SIZE)
		print("география %d мс, этапы %s" % [Time.get_ticks_msec() - t0, JSON.stringify(fresh.generation_profile.get("stages_ms", {}))])
		var old: WorldData = got.world
		var differ := []
		for name: String in WorldCache.PER_CELL + ["down", "order", "watershed"]:
			var a: Variant = fresh.get(name)
			var b: Variant = old.get(name)
			if a != null and b != null and typeof(a) == typeof(b) and a != b: differ.append(name)
		print("география %s %s" % ["та же" if differ.is_empty() else "другая:", str(differ)])
		quit(0 if differ.is_empty() else 1)
		return
	var w: WorldData = got.world
	# Как WorldGenerator._generate_plan с start = 1: базовый рельеф и поля шума из сида.
	w.base_heights = Heightfield.new(w, false)
	w.start_noise_fields()
	var load_ms := Time.get_ticks_msec() - started
	started = Time.get_ticks_msec()
	StageLandmarks.run(w)
	var landmarks_ms := Time.get_ticks_msec() - started
	started = Time.get_ticks_msec()
	StageTrails.run(w, func(_p: float, _label: String) -> void: pass)
	var trails_ms := Time.get_ticks_msec() - started
	var profile := {}
	for key: String in w.generation_profile:
		if key in KEYS or key.begins_with("mountain_"): profile[key] = w.generation_profile[key]
	print("загрузка %d мс, места %d мс, пути %d мс" % [load_ms, landmarks_ms, trails_ms])
	print("линий без поблажки на бугры (профиль круче предела): ", StageTrails.line_fallbacks)
	print("PROFILE ", JSON.stringify(profile))
	print("SECOND WAYS ", JSON.stringify(w.generation_profile.get("second_ways", [])), " повышено до дорог, м: ", w.generation_profile.get("upgraded_m", 0))
	for link: Array in w.generation_profile.get("road_links", []):
		print("  связь %d→%d, %d клеток: запас %d, %s, %.0f мс (поиск %.0f)" % link)
	for why: Dictionary in w.generation_profile.get("site_failures", []):
		var at: Array = why.at
		print("  переправа (%d,%d)→(%d,%d), воды по пути %d: %s" % [at[0] % w.W, at[0] / w.W, at[1] % w.W, at[1] / w.W, at[2],
			JSON.stringify(why).replace("\"at\":[%d,%d,%d]" % at, "")])
	# Готовая поверхность, как в игре (полотно, сооружения с площадками въездов, метровая сетка дорог):
	# въезд каждого моста по ширине настила на уровне его конца и не над водой (как road_safety_test).
	started = Time.get_ticks_msec()
	if report_metrics:
		StageSites.run(w)
		StageLakes.run(w)
		w.generation.surface_rock = RockRelief.field_of(w)
	RoadSurface.run(w)
	var final := Heightfield.new(w)
	var max_gap := 0.0
	var wet := 0
	var worst := []
	for s: Dictionary in final.structures:
		if s.tunnel:
			continue
		for end in 2:
			var t: float = 0.0 if end == 0 else s.len
			var deck: float = s.ay if end == 0 else s.by
			for side in [-1.0, 0.0, 1.0]:
				var x: float = s.ax + s.ux * t - s.uz * side * s.half
				var z: float = s.az + s.uz * t + s.ux * side * s.half
				var gap := absf(final.ground_at(x, z) - deck)
				if gap > StageTrails.BRIDGE_LANDING_GAP + 0.01:
					worst.append("(%d,%d) %.2f м" % [floori(x / GameConfig.TILE), floori(z / GameConfig.TILE), gap])
				max_gap = maxf(max_gap, gap)
				wet += 1 if final.depth_at(x, z) > 0.3 else 0
	print("въезды мостов в игре: наибольший перепад %.2f м, над водой %d, выше %.2f м: %d %s (%d мс)" % [max_gap, wet,
		StageTrails.BRIDGE_LANDING_GAP, worst.size(), str(worst.slice(0, 8)), Time.get_ticks_msec() - started])
	# --rides: природные велосипедные маршруты (RideRoutes): сводка, проходимость на готовой поверхности, картинка.
	var fails := 0
	if "--rides" in args:
		fails += _rides(w, final, seed_text)
	# --metrics: измеритель сети (tools/road_network_metrics.gd) и картинка tools/control/runs/network/<сид>[-<метка>].png
	if report_metrics:
		started = Time.get_ticks_msec()
		StageVegetation.run(w, final)
		var trodden := w.cost
		StageTrails._build_cost(w)
		var base := w.cost
		w.cost = trodden
		var m: Dictionary = Metrics.measure(w, base, final, Floor.surface_image(w))
		var report := Metrics.summary(m)
		print("NETWORK ", JSON.stringify(report))
		if report.route_usage.status != "recorded" or report.route_usage.routes.size() != w.generation_profile.rides.accepted:
			printerr("Отчёт не содержит полного набора принятых веломаршрутов")
			fails += 1
		if not metrics_file.is_empty():
			var output := FileAccess.open(metrics_file, FileAccess.WRITE)
			if output == null or not output.store_string(JSON.stringify(report, "\t") + "\n"):
				printerr("Не записан отчёт ", metrics_file)
				fails += 1
			else:
				output.close()
				print("отчёт сети: ", metrics_file)
		if "--metrics" in args:
			var tag := _arg(args, "--tag", "")
			var file := ProjectSettings.globalize_path("res://tools/control/runs/network").path_join(seed_text + ("" if tag.is_empty() else "-" + tag) + ".png")
			Metrics.draw(w, m, file)
			print("картинка сети: %s (%d мс)" % [file, Time.get_ticks_msec() - started])
	# --bed: полотно RoadBed на этой сети (только C#): время, число клеток и хеш рельефа; --refine — и метровая сетка.
	# Хеши сравнивать между версиями кода (было — запуск на прежнем коммите): изменение значит, что результат другой
	if "--bed" in args:
		var base := Heightfield.new(w, false)
		var bed := base.copy()
		var t0 := Time.get_ticks_usec()
		var changed := RoadBed.refine(bed)
		var bed_ms := (Time.get_ticks_usec() - t0) / 1000.0
		print("RoadBed (C#): %.0f мс, клеток %d, хеш hv %s" % [bed_ms, changed.size(), _digest(bed.hv)])
		if changed.is_empty(): fails += 1
		if "--refine" in args:
			bed.structures = base.structures
			bed.build_structures()
			t0 = Time.get_ticks_usec()
			var built := RoadRefinement.build(bed)
			print("RoadRefinement (C#): %.0f мс, патчей %d, хеш патчей %s, хеш подгонки %s" % [(Time.get_ticks_usec() - t0) / 1000.0,
				built.patches.size(), _digest(built.patches), _digest(built.fit_routes)])
			if built.patches.is_empty(): fails += 1
	# --probe x,y: пути людей ближе 12 клеток к точке (номер, вид, длина, концы, ближайшее расстояние)
	var probe := _arg(args, "--probe", "")
	if not probe.is_empty():
		var at := Vector2(float(probe.get_slice(",", 0)), float(probe.get_slice(",", 1)))
		for k in w.trails.size():
			var t: Dictionary = w.trails[k]
			if t.kind == "animal": continue
			var best := INF
			for j in range(1, t.pts.size()):
				best = minf(best, Grid.segment_dist(at.x, at.y, t.pts[j - 1].x, t.pts[j - 1].y, t.pts[j].x, t.pts[j].y))
			if best <= 12.0:
				print("  путь %d %s%s: %d точек, %.0f м, (%.1f,%.1f)→(%.1f,%.1f), до точки %.1f кл" % [k, t.kind, " " + str(t.ride) if t.has("ride") else "",
					t.pts.size(), StageTrails._kind_length_of(t) * GameConfig.TILE, t.pts[0].x, t.pts[0].y, t.pts[-1].x, t.pts[-1].y, best])
	# Через JSON, как в файле: числа сравниваются одного вида.
	var print_out: Dictionary = JSON.parse_string(JSON.stringify(_fingerprint(w)))
	print("FINGERPRINT ", JSON.stringify(print_out))
	var save := _arg(args, "--save", "")
	if not save.is_empty():
		var f := FileAccess.open(save, FileAccess.WRITE)
		f.store_string(JSON.stringify(print_out, "\t"))
		f.close()
		print("отпечаток записан: ", save)
	var compare := _arg(args, "--compare", "")
	if not compare.is_empty():
		var before: Variant = JSON.parse_string(FileAccess.get_file_as_string(compare))
		if not before is Dictionary:
			print("ОШИБКА: не прочитан ", compare)
			fails += 1
		else:
			var same := true
			for key: String in print_out:
				if str(before.get(key)) != str(print_out[key]):
					same = false
					print("  отличается %s: было %s, стало %s" % [key, str(before.get(key)).left(120), str(print_out[key]).left(120)])
			print("мир путей %s" % ("тот же" if same else "другой"))
	quit(1 if fails > 0 else 0)


## Природные маршруты: сводка RideRoutes и проверка добавленных ими полотен (уклон на 8 м, вода на оси),
## картинка tools/control/runs/rides/<сид>.png (дороги светлые, тропы серые, горные тропы коричневые; метки полотен: плавные
## оранжевые, лесные зелёные, технические красные, старт — белая точка). Возвращает число отказов.
func _rides(w: WorldData, final: Heightfield, seed_text: String) -> int:
	var stats: Dictionary = w.generation_profile.get("rides", {})
	print("RIDES ", JSON.stringify(stats))
	var fails := 0
	var S := 2
	var img := Image.create(w.W * S, w.H * S, false, Image.FORMAT_RGB8)
	var river := w.river_cells()
	for y in w.H:
		for x in w.W:
			var i := y * w.W + x
			var v := clampf(0.25 + w.h[i] * 0.9, 0.0, 1.0) * (1.0 - clampf(w.slope[i] * 1.5, 0.0, 0.5))
			var c := Color(v, v, v * 0.95)
			if w.ocean[i] != 0 or w.lake[i] != 0 or river[i] != 0: c = Color(0.25, 0.45, 0.8)
			elif w.path_mask[i] >= 3: c = Color(0.95, 0.95, 0.85)
			elif w.path_mask[i] >= 2: c = c.lerp(Color(0.55, 0.55, 0.5), 0.6)
			img.fill_rect(Rect2i(x * S, y * S, S, S), c)
	var colors := {flow = Color(1.0, 0.55, 0.1), forest = Color(0.1, 0.75, 0.2), tech = Color(0.9, 0.1, 0.1), climb = Color(0.75, 0.45, 0.95)}
	for t: Dictionary in w.trails:
		if t.kind == "mountain" and not t.has("ride"): _draw(img, t.pts, S, Color(0.55, 0.35, 0.2), 1)
	for t: Dictionary in w.trails:
		if not t.has("ride"): continue
		_draw(img, t.pts, S, colors.get(t.ride_style, Color.MAGENTA), 2)
		img.fill_rect(Rect2i(int(t.pts[0].x * S) - 2, int(t.pts[0].y * S) - 2, 5, 5), Color.WHITE)
		# Проходимость: высоты готовой поверхности через 1 м, уклон на 8 м, вода глубже 0,3 м на оси
		var heights := PackedFloat32Array()
		var wet := 0
		var length := 0.0
		for k in range(1, t.pts.size()):
			var a: Dictionary = t.pts[k - 1]
			var b: Dictionary = t.pts[k]
			var seg := Grid.hypot(b.x - a.x, b.y - a.y) * GameConfig.TILE
			var n := maxi(1, ceili(seg))
			for j in n:
				var x: float = lerpf(a.x, b.x, float(j) / n) * GameConfig.TILE
				var z: float = lerpf(a.y, b.y, float(j) / n) * GameConfig.TILE
				heights.append(final.ground_at(x, z))
				if final.depth_at(x, z) > 0.3: wet += 1
			length += seg
		var worst := 0.0
		var steep := 0
		for k in range(8, heights.size(), 2):
			var g := absf(heights[k] - heights[k - 8]) / 8.0
			worst = maxf(worst, g)
			if g > 0.4: steep += 2
		var drop := heights[0] - heights[-1]
		print("  %s %-6s %4.0f м, перепад %3.0f м, ср. уклон %4.1f %%, круче 40 %%: %3.0f м, наибольший на 8 м %3.0f %%, вода %d м, вид %s" % [
			t.ride, t.ride_style, length, drop, drop / maxf(length, 1.0) * 100.0, float(steep), worst * 100.0, wet, t.kind])
		if wet > 12: # брод через узкую речку (две клетки) допустим, путь по руслу — нет
			print("    ОШИБКА: %s идёт по воде %d м" % [t.ride, wet])
			fails += 1
	var dir := ProjectSettings.globalize_path("res://tools/control/runs/rides")
	DirAccess.make_dir_recursive_absolute(dir)
	var file := dir.path_join("%s.png" % seed_text)
	img.save_png(file)
	print("картинка: ", file)
	return fails


func _draw(img: Image, pts: Array, S: int, color: Color, width: int) -> void:
	for k in range(1, pts.size()):
		var a := Vector2(pts[k - 1].x, pts[k - 1].y) * S
		var b := Vector2(pts[k].x, pts[k].y) * S
		var n := maxi(1, ceili(a.distance_to(b) * 2.0))
		for j in n + 1:
			var p := a.lerp(b, float(j) / n)
			img.fill_rect(Rect2i(int(p.x) - width / 2, int(p.y) - width / 2, width, width), color)


## Отпечаток результата: поселения, их связи, мосты, туннели и разметка путей.
func _fingerprint(w: WorldData) -> Dictionary:
	var kinds := {}
	for trail: Dictionary in w.trails: kinds[trail.kind] = int(kinds.get(trail.kind, 0)) + 1
	var places := []
	var links := 0
	for s: SettlementData in w.settlements:
		places.append(s.i)
		links += s.connections.size()
	var spans := []
	for span: EntityRecord in w.bridges + w.tunnels: spans.append("%s:%d-%d" % ["t" if span is TunnelData else "b", span.a, span.b])
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(w.path_mask)
	return {settlements = places, connections = links / 2, connected = SelfTest.settlements_connected(w), trails = kinds,
		bridges = w.bridges.size(), tunnels = w.tunnels.size(), spans = spans, path_mask = ctx.finish().hex_encode().left(16)}


func _arg(args: PackedStringArray, name: String, fallback: String) -> String:
	var k := args.find(name)
	return args[k + 1] if k >= 0 and k + 1 < args.size() else fallback


func _digest(value: Variant) -> String:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(var_to_bytes(value))
	return ctx.finish().hex_encode().substr(0, 16)
