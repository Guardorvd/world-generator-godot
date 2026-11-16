extends SceneTree
## Отбор поселений без мира (16.11.2026, план «Поселения и география дорог»): география плана 768 и StageLandmarks,
## без сцены и окна. ~3 с на сид; с --roads ещё StageTrails (~8 с на сид).
## Печатает на сид: сколько мест, сколько у воды (до 6 клеток), характер мест (StageLandmarks._character),
## долю пригодной суши дальше 800 м от поселений, наибольший просвет, среднее расстояние до соседа, стартовое место.
## С --roads: оставлено и удалено мест, отказы связей по причинам, число связей у мест, км путей по видам,
## мосты, туннели, вторые пути, время этапа.
## Пишет tools/control/runs/settlement_look<tag>.json и лист карт settlement_look<tag>.png (1 пиксель = 3 клетки;
## посёлок — красный, деревня — оранжевый, с --roads пути — тёмные).
##   -- --seeds a,b,c   свои сиды (по умолчанию CONTROL)
##   -- --legacy        прежний отбор (StageLandmarks.legacy: полный водный член, без поправки на удалённость)
##   -- --roads         ещё дороги
##   -- --tag <имя>     суффикс файлов, например _old
## Лимит 240 с.

const MacroLook := preload("res://tools/macro_geo_look.gd")
const CONTROL := ["Север-1234", "Ущелье", "Туман-4821", "Янтарь-5150", "a1", "b2", "c3", "d4"]
const OUT := "res://tools/control/runs"
const ROLE_COLORS := {center = Color(0.9, 0.1, 0.1), satellite = Color(1.0, 0.55, 0.1), forest = Color(0.05, 0.3, 0.1),
	foothill = Color(0.6, 0.2, 0.8), remote = Color(1.0, 1.0, 1.0)}


func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 240)
	call_deferred("_run")


func _arg(name: String, fallback: String = "") -> String:
	var args := OS.get_cmdline_user_args()
	var at := args.find(name)
	if at < 0:
		return fallback
	return args[at + 1] if at + 1 < args.size() and not args[at + 1].begins_with("--") else ""


func _run() -> void:
	var args := OS.get_cmdline_user_args()
	StageLandmarks.legacy = args.has("--legacy")
	var roads := args.has("--roads")
	var tag := _arg("--tag", "")
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT))
	var seeds: PackedStringArray = _arg("--seeds", ",".join(CONTROL)).split(",", false)
	var rows := {}
	var maps: Array[Image] = []
	for seed_text in seeds:
		var w := WorldGenerator._geography(seed_text, WorldGenerator.PLAN_SIZE)
		if w.base_heights == null:
			w.base_heights = Heightfield.new(w, false)
		w.start_noise_fields(["cost", "forest"])
		var land := _land_samples(w)
		var t := Time.get_ticks_usec()
		StageLandmarks.run(w)
		var row := {landmarks_ms = (Time.get_ticks_usec() - t) / 1000.0}
		row.places = _describe(w, land)
		if roads:
			var placed := w.settlements.size()
			t = Time.get_ticks_usec()
			StageTrails.run(w, func(_p: float, _l: String) -> void: pass)
			row.roads = _roads(w, placed, (Time.get_ticks_usec() - t) / 1000.0)
			row.after = _describe(w, land)
		rows[seed_text] = row
		maps.append(_map(w, roads))
		var p: Dictionary = row.places
		var line := "%s: %d мест, у воды %d, пустая суша %d %%, просвет %d м, сосед %d м, %s; старт — %s; отбор %.0f мс" % [seed_text, p.n,
			p.by_water, roundi(p.land_far_800m * 100.0), p.widest_gap_m, p.mean_neighbor_m, JSON.stringify(p.kinds), p.home, row.landmarks_ms]
		print(line)
		print("    роли [мест, связей]: %s; посёлков %d" % [JSON.stringify(p.roles), p.towns])
		if roads:
			print("    поездки: %s" % JSON.stringify(row.roads.journeys))
			print("    после дорог роли [мест, связей]: %s; меньше всего жилых домов в одном месте: %d" % [JSON.stringify(row.after.roles), row.after.min_homes])
			var r: Dictionary = row.roads
			print("    дороги: осталось %d из %d, отказы %s, связи %s, км %s, мостов %d, туннелей %d, вторые %s, этап %.1f с, домов %d" % [r.kept, r.placed,
				JSON.stringify(r.failures), JSON.stringify(r.degrees), JSON.stringify(r.km), r.bridges, r.tunnels, JSON.stringify(r.second_ways), r.ms / 1000.0, r.homes])
	_summary(rows, roads)
	var sheet := MacroLook._sheet(maps)
	sheet.save_png(ProjectSettings.globalize_path(OUT.path_join("settlement_look%s.png" % tag)))
	var f := FileAccess.open(ProjectSettings.globalize_path(OUT.path_join("settlement_look%s.json" % tag)), FileAccess.WRITE)
	f.store_string(JSON.stringify({legacy = StageLandmarks.legacy, roads = roads, rows = rows}, "\t"))
	f.close()
	print("OK ", ProjectSettings.globalize_path(OUT.path_join("settlement_look%s.json" % tag)))
	quit(0)


## Итог по всем сидам одной строкой (сравнивать прогоны: было — с --legacy, стало — без)
func _summary(rows: Dictionary, roads: bool) -> void:
	var total := {places = 0, by_water = 0, ms = 0.0}
	var far: Array = []
	var gaps: Array = []
	var roles := {}
	var trips := {links = 0, long_1km = 0, zones_2plus = 0, pass_20m = 0}
	var kept := 0
	var placed := 0
	var stage_ms := 0.0
	for seed_text: String in rows:
		var row: Dictionary = rows[seed_text]
		var p: Dictionary = row.places
		total.places += p.n
		total.by_water += p.by_water
		total.ms += row.landmarks_ms
		far.append(p.land_far_800m)
		gaps.append(p.widest_gap_m)
		for role: String in p.roles: roles[role] = int(roles.get(role, 0)) + int(p.roles[role][0])
		if roads:
			var r: Dictionary = row.roads
			kept += r.kept
			placed += r.placed
			stage_ms += r.ms
			for key: String in trips: trips[key] += int(r.journeys[key])
	far.sort()
	gaps.sort()
	print("ИТОГ: мест %d, у воды %d %%, пустая суша (медиана) %d %%, наименьший просвет %d м, роли %s, отбор %.0f мс на сид" % [total.places,
		roundi(100.0 * total.by_water / maxi(1, total.places)), roundi(far[far.size() / 2] * 100.0), gaps[0], JSON.stringify(roles), total.ms / maxi(1, rows.size())])
	if roads:
		print("ИТОГ дорог: осталось %d из %d мест, поездки %s, этап путей %.1f с на сид" % [kept, placed, JSON.stringify(trips), stage_ms / 1000.0 / maxi(1, rows.size())])


## Пригодная суша — те же условия, что у кандидатов (без доступа по пяти пробам), шаг 6 клеток
func _land_samples(w: WorldData) -> PackedInt32Array:
	var river := w.river_cells()
	var wet := PackedByteArray()
	wet.resize(w.N)
	for i in w.N:
		wet[i] = 1 if w.ocean[i] != 0 or w.lake[i] != 0 or river[i] != 0 else 0
	var reachable := Grid.bridge_region(w.W, w.H, wet, StageTrails.SPAN)
	var cells := PackedInt32Array()
	for y in range(6, w.H - 6, 6):
		for x in range(6, w.W - 6, 6):
			var i := y * w.W + x
			if wet[i] != 0 or reachable[i] == 0 or w.slope[i] > 0.6 or not Biomes.LIST[w.biome[i]].has("habit"):
				continue
			cells.append(i)
	return cells


func _describe(w: WorldData, land: PackedInt32Array) -> Dictionary:
	var kinds := {}
	var roles := {}
	var water := 0
	var cells := []
	for s: SettlementData in w.settlements:
		var role := s.role if not s.role.is_empty() else "—"
		var entry: Array = roles.get(role, [0, 0])
		roles[role] = [entry[0] + 1, entry[1] + s.connections.size()] # мест, связей у них всего
		var kind := _kind(s.character)
		kinds[kind] = int(kinds.get(kind, 0)) + 1
		if w.dist_water[s.i] <= 6.0: water += 1
		cells.append(s.i)
	var far := 0
	var gap := 0.0
	for c: int in land:
		var near := INF
		for s: SettlementData in w.settlements:
			near = minf(near, Vector2(s.x - (c % w.W + 0.5), s.y - (c / w.W + 0.5)).length())
		if near > 200.0: far += 1
		gap = maxf(gap, near)
	var nn := 0.0
	for a: SettlementData in w.settlements:
		var near := INF
		for b: SettlementData in w.settlements:
			if b != a: near = minf(near, Vector2(a.x - b.x, a.y - b.y).length())
		nn += near
	var home: Variant = PlayerState.home(w)
	return {n = w.settlements.size(), by_water = water, kinds = kinds, roles = roles, cells = cells,
		min_homes = w.settlements.map(func(s: SettlementData) -> int: return StageLandmarks.homes_of(s)).min() if not w.settlements.is_empty() else 0,
		towns = w.settlements.filter(func(s: SettlementData) -> bool: return s.town).size(),
		land_far_800m = snappedf(float(far) / maxi(1, land.size()), 0.01), widest_gap_m = roundi(gap * GameConfig.TILE),
		mean_neighbor_m = roundi(nn / maxi(1, w.settlements.size()) * GameConfig.TILE),
		home = home.character if home is SettlementData else "—"}


## Вид места по характеру (StageLandmarks._character) без рода и размера
static func _kind(character: String) -> String:
	for pair: Array in [["прим", "приморские"], ["речн", "речные"], ["горн", "горные"], ["предгорн", "предгорные"], ["лесн", "лесные"],
			["рыбацк", "рыбацкие"], ["земл", "равнинные"], ["торг", "равнинные"]]:
		if character.begins_with(pair[0]): return pair[1]
	return "окраинные"


func _roads(w: WorldData, placed: int, ms: float) -> Dictionary:
	var gp := w.generation_profile
	var degrees := {}
	for s: SettlementData in w.settlements:
		var d := str(s.connections.size())
		degrees[d] = int(degrees.get(d, 0)) + 1
	var km := {}
	for tr: Dictionary in w.trails:
		km[tr.kind] = snappedf(float(km.get(tr.kind, 0.0)) + StageTrails._kind_length_of(tr) * GameConfig.TILE / 1000.0, 0.01)
	var ways := {}
	for note: Array in gp.get("second_ways", []):
		ways[note[0]] = int(ways.get(note[0], 0)) + 1
	# Поездки по основным связям (StageTrails._journeys): [длина м, длина/прямая, зон, подъём м]
	var trips: Array = gp.get("journeys", [])
	var lengths: Array = trips.map(func(t: Array) -> int: return t[0])
	lengths.sort()
	var journeys := {links = trips.size(),
		median_m = lengths[lengths.size() / 2] if not lengths.is_empty() else 0,
		long_1km = trips.filter(func(t: Array) -> bool: return t[0] >= 1000).size(),
		zones_2plus = trips.filter(func(t: Array) -> bool: return t[2] >= 2).size(),
		pass_20m = trips.filter(func(t: Array) -> bool: return t[3] >= 20).size(),
		mean_ratio = snappedf(trips.reduce(func(s: float, t: Array) -> float: return s + t[1], 0.0) / maxi(1, trips.size()), 0.01)}
	return {journeys = journeys, placed = placed, kept = w.settlements.size(), failures = gp.get("road_failures", {}), degrees = degrees, km = km,
		bridges = w.bridges.size(), tunnels = w.tunnels.size(), second_ways = ways, ms = ms,
		main_ms = gp.get("main_roads_ms", 0), secondary_ms = gp.get("secondary_roads_ms", 0),
		budget_stops = gp.get("budget_stops", 0), homes = gp.get("homes_kept", 0)}


func _map(w: WorldData, roads: bool) -> Image:
	var img := MacroLook.map_image(w)
	var s := 3
	if roads:
		for py in img.get_height():
			for px in img.get_width():
				if w.path_mask[(py * s + 1) * w.W + px * s + 1] >= 2:
					img.set_pixel(px, py, Color(0.25, 0.16, 0.08))
	for st: SettlementData in w.settlements:
		# Роль: центр — красный, спутник — оранжевый, лесное — тёмно-зелёный, предгорное — фиолетовый,
		# удалённое — белый, обычное и без ролей — жёлтый (посёлок — красный).
		var col: Color = ROLE_COLORS.get(st.role, Color(0.9, 0.1, 0.1) if st.town else Color(1.0, 0.85, 0.1))
		var cx := floori(st.x / s)
		var cy := floori(st.y / s)
		for dy in range(-2, 3):
			for dx in range(-2, 3):
				var x := cx + dx
				var y := cy + dy
				if x >= 0 and y >= 0 and x < img.get_width() and y < img.get_height():
					img.set_pixel(x, y, Color.BLACK if absi(dx) == 2 or absi(dy) == 2 else col)
	return img
