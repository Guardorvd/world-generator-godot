extends SceneTree
## Стенд дорог стартового плана (ревью дорожной сети 29.10): места и пути (StageLandmarks + StageTrails) на готовой
## географии одного мира, без растительности, полотна и сцены. География генерируется один раз и хранится в
## user://road_plan_test как слой кэша миров (тот же путь, что загрузка мира с одной географией из кэша), дальше
## каждый запуск начинается сразу с мест. Печатает причины отказов, работу поиска, время и отпечаток результата.
##   godot --headless --path . --script res://tools/road_plan_test.gd -- [--seed Север-1234] [--save <файл.json>] [--compare <файл.json>]
## --save пишет отпечаток (было), --compare сверяет с ним (стало): тот же мир — рефакторинг, разный — изменение маршрутов.
## Первый запуск на этом ПК ~1,5 мин (география), следующие ~1 мин.

const SelfTest := preload("res://tools/selftest.gd")
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
	# --profile: время поиска A* в каждой попытке и всего (FastGrid считает вызовы; на мир не влияет).
	Pathfinder.profile_searches = "--profile" in args
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
	print("PROFILE ", JSON.stringify(profile))
	for link: Array in w.generation_profile.get("road_links", []):
		print("  связь %d→%d, %d клеток: запас %d, %s, %.0f мс (поиск %.0f)" % link)
	for why: Dictionary in w.generation_profile.get("site_failures", []):
		var at: Array = why.at
		print("  переправа (%d,%d)→(%d,%d), воды по пути %d: %s" % [at[0] % w.W, at[0] / w.W, at[1] % w.W, at[1] / w.W, at[2],
			JSON.stringify(why).replace("\"at\":[%d,%d,%d]" % at, "")])
	# Готовая поверхность, как в игре (полотно, сооружения с площадками въездов, метровая сетка дорог):
	# въезд каждого моста по ширине настила на уровне его конца и не над водой (как road_safety_test).
	started = Time.get_ticks_msec()
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
	# Через JSON, как в файле: числа сравниваются одного вида.
	var print_out: Dictionary = JSON.parse_string(JSON.stringify(_fingerprint(w)))
	print("FINGERPRINT ", JSON.stringify(print_out))
	var fails := 0
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
