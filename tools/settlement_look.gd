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
##   -- --profile       с --roads: время частей этапа путей (generation_profile: *_ms, parts_ms, поиск)
##   -- --tag <имя>     суффикс файлов, например _old
##   -- --surface <папка> --roads   сохранить поверхность после подгонки дорог для mountain_detail_look
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
	var surface_dir := _arg("--surface", "")
	if roads and not surface_dir.is_empty():
		DirAccess.make_dir_recursive_absolute(surface_dir)
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
			if "--profile" in OS.get_cmdline_user_args():
				_print_profile(seed_text, w.generation_profile)
				print("  отпечаток путей %s: %s" % [seed_text, _roads_print(w)])
			row.after = _describe(w, land)
			if not surface_dir.is_empty():
				RoadSurface.run(w)
				var surface := Heightfield.base_of(w)
				surface.finish_paths()
				var heights := surface.hv.duplicate()
				for i in heights.size(): heights[i] /= GameConfig.HS
				FileAccess.open(surface_dir.path_join(seed_text + ".bin"), FileAccess.WRITE).store_var({h = heights})
				surface.weaken_world()
		rows[seed_text] = row
		maps.append(_map(w, roads))
		var p: Dictionary = row.places
		var line := "%s: %d мест (добавлено покрытием %d: %s), у воды %d, пустая суша %d %%, просвет %d м, сосед %d м, %s; старт — %s; отбор %.0f мс" % [seed_text, p.n,
			int(w.generation_profile.get("cover_added", 0)), w.generation_profile.get("cover_cells", []),
			p.by_water, roundi(p.land_far_800m * 100.0), p.widest_gap_m, p.mean_neighbor_m, JSON.stringify(p.kinds), p.home, row.landmarks_ms]
		print(line)
		print("    сетка 3×3: кандидаты %s, walk %s, основной отбор %s, с покрытием %s" % [
			w.generation_profile.get("sector_cand", []), w.generation_profile.get("sector_walk", []),
			w.generation_profile.get("sector_main", []), p.sectors])
		print("    роли [мест, связей]: %s; посёлков %d" % [JSON.stringify(p.roles), p.towns])
		if roads:
			print("    поездки: %s" % JSON.stringify(row.roads.journeys))
			print("    после дорог сетка 3×3: %s; роли [мест, связей]: %s; меньше всего жилых домов в одном месте: %d; край >= %d кл." % [JSON.stringify(row.after.sectors), JSON.stringify(row.after.roles), row.after.min_homes, row.after.min_border])
			var r: Dictionary = row.roads
			print("    дороги: осталось %d из %d, оторванных %d, отказы %s, связи %s, км %s, мостов %d, туннелей %d, вторые %s, этап %.1f с, домов %d" % [r.kept, r.placed, r.orphan_trails,
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
	var sectors := [0, 0, 0, 0, 0, 0, 0, 0, 0]
	var min_border := w.W
	for s: SettlementData in w.settlements:
		sectors[StageLandmarks.sector_of(s.i, w.W, w.H)] += 1
		min_border = mini(min_border, floori(minf(minf(s.x, s.y), minf(w.W - s.x, w.H - s.y))))
	return {n = w.settlements.size(), by_water = water, kinds = kinds, roles = roles, cells = cells, sectors = sectors,
		min_border = min_border,
		cover_added = int(w.generation_profile.get("cover_added", 0)),
		cover_cells = Array(w.generation_profile.get("cover_cells", PackedInt32Array())),
		sector_cand = w.generation_profile.get("sector_cand", []),
		sector_walk = w.generation_profile.get("sector_walk", []),
		sector_main = w.generation_profile.get("sector_main", []),
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
	return {journeys = journeys, placed = placed, kept = w.settlements.size(), orphan_trails = _count_orphan_trails(w),
		failures = gp.get("road_failures", {}), degrees = degrees, km = km,
		bridges = w.bridges.size(), tunnels = w.tunnels.size(), second_ways = ways, ms = ms,
		main_ms = gp.get("main_roads_ms", 0), secondary_ms = gp.get("secondary_roads_ms", 0),
		budget_stops = gp.get("budget_stops", 0), homes = gp.get("homes_kept", 0)}


static func _count_orphan_trails(w: WorldData) -> int:
	if w.settlements.is_empty():
		return 0
	var seen := PackedByteArray()
	seen.resize(w.N)
	var queue := PackedInt32Array()
	for s: SettlementData in w.settlements:
		if seen[s.i] == 0:
			seen[s.i] = 1
			queue.append(s.i)
	var head := 0
	while head < queue.size():
		var c := queue[head]
		head += 1
		var cx := c % w.W
		var cy := c / w.W
		for k in 8:
			var nx: int = cx + Grid.DX[k]
			var ny: int = cy + Grid.DY[k]
			if nx < 0 or ny < 0 or nx >= w.W or ny >= w.H:
				continue
			var n := ny * w.W + nx
			if seen[n] == 0 and w.path_mask[n] >= 2:
				seen[n] = 1
				queue.append(n)
	var orphans := 0
	for tr: Dictionary in w.trails:
		if tr.get("kind", "") == "animal":
			continue
		var connected := false
		for p: Dictionary in tr.get("pts", []):
			var pc := clampi(floori(float(p.y)), 0, w.H - 1) * w.W + clampi(floori(float(p.x)), 0, w.W - 1)
			if seen[pc] != 0:
				connected = true
				break
		if not connected:
			orphans += 1
	return orphans


func _map(w: WorldData, roads: bool) -> Image:
	var img := MacroLook.map_image(w)
	var s := 3
	if roads:
		for py in img.get_height():
			for px in img.get_width():
				if w.path_mask[(py * s + 1) * w.W + px * s + 1] >= 2:
					img.set_pixel(px, py, Color(0.25, 0.16, 0.08))
	for cut in [img.get_width() / 3, img.get_width() * 2 / 3]:
		for py in img.get_height():
			img.set_pixel(cut, py, img.get_pixel(cut, py).lerp(Color(1.0, 1.0, 1.0), 0.38))
		for px in img.get_width():
			img.set_pixel(px, cut, img.get_pixel(px, cut).lerp(Color(1.0, 1.0, 1.0), 0.38))
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


## Время частей этапа путей, по убыванию: где уходит время StageTrails
func _print_profile(seed_text: String, gp: Dictionary) -> void:
	var rows := []
	for key: String in gp:
		if key.ends_with("_ms") and (gp[key] is float or gp[key] is int):
			rows.append([float(gp[key]), key])
	for key: String in gp.get("parts_ms", {}):
		rows.append([float(gp.parts_ms[key]), "parts." + key])
	rows.sort_custom(func(a: Array, b: Array) -> bool: return a[0] > b[0])
	print("  время путей %s:" % seed_text)
	for r: Array in rows:
		if r[0] >= 20.0:
			print("    %8.0f мс  %s" % [r[0], r[1]])
	for key: String in gp:
		if key.ends_with("_search") or key.ends_with("_details") or key == "rides" or key == "road_links":
			print("    %s %s" % [key, JSON.stringify(gp[key])])


## Отпечаток результата путей: те же ли пути, сооружения, связи и маршруты (сверка рефакторинга было/стало)
func _roads_print(w: WorldData) -> String:
	var links := []
	for st: SettlementData in w.settlements:
		links.append([st.i, st.connections])
	var spans := []
	for st: Variant in w.bridges + w.tunnels:
		spans.append(inst_to_dict(st) if st is Object else st)
	var parts := PackedStringArray()
	for part: Variant in [w.trails, w.path_mask, spans, links, w.road_rides]:
		parts.append(var_to_bytes(part).hex_encode().md5_text().left(8))
	return " ".join(parts)
