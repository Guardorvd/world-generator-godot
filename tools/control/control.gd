extends RefCounted
## Общее для инструментов контроля разработки (tools/control): список миров, папки, ключи командной строки,
## точки съёмки, сводка мира, память процесса. Сами инструменты: shots.gd, perf.gd, compare.gd.

const SEEDS := "res://tools/control/seeds.json"
const BASELINE := "res://tools/control/baseline"
const RUNS := "res://tools/control/runs"
const TILE := GameConfig.TILE
const SelfTest := preload("res://tools/selftest.gd")
const ShotUtil := preload("res://tools/shot_util.gd")
const LOAD_TIMEOUT_MS := ShotUtil.LOAD_TIMEOUT_MS
const WINDOW_SIZE := Vector2i(1280, 720)   # окно для снимков и замеров


## Список миров из seeds.json
static func seeds() -> Dictionary:
	return JSON.parse_string(FileAccess.get_file_as_string(SEEDS))


static func version() -> String:
	return str(ProjectSettings.get_setting("application/config/version"))


## Значение ключа «--имя значение» из аргументов после «--» (или default)
static func arg(name: String, default: String = "") -> String:
	var args := OS.get_cmdline_user_args()
	var k := args.find("--" + name)
	return args[k + 1] if k >= 0 and k + 1 < args.size() else default


## Путь к папке без res://: относительный считается от папки проекта (пустой остаётся пустым)
static func abs_dir(dir: String) -> String:
	if dir.begins_with("res://"):
		return ProjectSettings.globalize_path(dir)
	if dir != "" and dir.is_relative_path():
		return ProjectSettings.globalize_path("res://").path_join(dir)
	return dir


## Папка результатов: --out или tools/control/runs/<версия>; создаётся, если её нет
static func out_dir() -> String:
	var dir := abs_dir(arg("out", RUNS.path_join(version())))
	DirAccess.make_dir_recursive_absolute(dir)
	# Godot не должен импортировать снимки как ресурсы проекта
	var gdignore := dir.path_join(".gdignore")
	if not FileAccess.file_exists(gdignore):
		FileAccess.open(gdignore, FileAccess.WRITE)
	return dir


## Последняя по номеру версии база в tools/control/baseline
static func latest_baseline() -> String:
	var root := ProjectSettings.globalize_path(BASELINE)
	var best := ""
	for d in DirAccess.get_directories_at(root):
		if best == "" or _version_less(best, d):
			best = d
	return root.path_join(best) if best != "" else ""


static func _version_less(a: String, b: String) -> bool:
	var pa := a.split(".")
	var pb := b.split(".")
	for k in maxi(pa.size(), pb.size()):
		var x := int(pa[k]) if k < pa.size() else 0
		var y := int(pb[k]) if k < pb.size() else 0
		if x != y:
			return x < y
	return false


static func save_json(path: String, data: Variant) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(JSON.stringify(data, "\t", false) + "\n")


static func load_json(path: String) -> Variant:
	if not FileAccess.file_exists(path):
		return null
	return JSON.parse_string(FileAccess.get_file_as_string(path))


## Имя файла для мира: «Север-1234@512» -> «Север-1234_512»
static func world_id(seed_text: String, size: int) -> String:
	return "%s_%d" % [seed_text, size]


## Память процесса (рабочий набор и его пик), байты; -1, если узнать не удалось
static func process_memory() -> Dictionary:
	var out := []
	var pid := OS.get_process_id()
	if OS.get_name() == "Windows":
		# по строке на число: кавычки внутри команды Windows съедает при передаче аргументов
		OS.execute("powershell", ["-NoProfile", "-Command", "$p = Get-Process -Id %d; $p.WorkingSet64; $p.PeakWorkingSet64" % pid], out)
	else:
		OS.execute("ps", ["-o", "rss=", "-p", str(pid)], out)
	var parts := (out[0] as String).split("\n", false) if out.size() > 0 else PackedStringArray()
	if OS.get_name() != "Windows" and parts.size() > 0:
		return {rss = int(parts[0].strip_edges()) * 1024, peak = -1}
	if parts.size() < 2:
		return {rss = -1, peak = -1}
	return {rss = int(parts[0].strip_edges()), peak = int(parts[1].strip_edges())}


## Сводка мира: числа, по которым видно, что изменилось, и хеши массивов (как в selftest)
static func world_stats(w: WorldData, include_fingerprint := false) -> Dictionary:
	var land := 0
	var lake := 0
	var road_cells := 0
	var trail_cells := 0
	for i in w.N:
		if w.ocean[i] == 0:
			land += 1
		if w.lake[i] != 0:
			lake += 1
		if w.path_mask[i] == 3:
			road_cells += 1
		elif w.path_mask[i] == 2:
			trail_cells += 1
	var kinds := {}
	var lengths := {}
	for t in w.trails:
		kinds[t.kind] = int(kinds.get(t.kind, 0)) + 1
		lengths[t.kind] = float(lengths.get(t.kind, 0.0)) + path_length(t.pts) * TILE
	var huts := 0
	for s in w.settlements:
		huts += s.huts.size()
	var fp := SelfTest.fingerprint(w)
	var sites := {}
	for s in w.sites:
		sites[s.type] = int(sites.get(s.type, 0)) + 1
	var stats := {
		seed = w.seed_text, size = w.W,
		land_share = snappedf(float(land) / w.N, 0.001),
		lake_cells = lake,
		rivers = w.rivers.size(),
		peaks = w.peaks.size(),
		settlements = w.settlements.size(),
		huts = huts,
		sites = sites,
		ways = kinds,
		ways_m = _rounded(lengths),
		road_cells = road_cells,
		trail_cells = trail_cells,
		bridges = w.bridges.size(),
		tunnels = w.tunnels.size(),
		objects = w.obj_count,
		connected = SelfTest.settlements_connected(w),
		hash_relief = fp.h,
		hash_paths = fp.path_mask,
		hash_biome = fp.biome,
	}
	if include_fingerprint:
		stats.fingerprint = fp
	return stats


static func _rounded(d: Dictionary) -> Dictionary:
	var r := {}
	for k in d:
		r[k] = roundi(d[k])
	return r


## Длина ломаной в клетках
static func path_length(pts: Array) -> float:
	var s := 0.0
	for k in range(1, pts.size()):
		s += Vector2(pts[k].x - pts[k - 1].x, pts[k].y - pts[k - 1].y).length()
	return s


## Точка мира (метры) для точки ломаной или клетки (единицы — клетки)
static func _at(h: Heightfield, cx: float, cy: float, up: float) -> Vector3:
	var x := (cx + 0.5) * TILE
	var z := (cy + 0.5) * TILE
	return Vector3(x, h.ground_at(x, z) + up, z)


## Сколько метров камера в pos видит над рельефом по пути к target (наименьший зазор луча). Второй луч
## идёт к низу кадра (на треть расстояния ниже цели) и проверяется на первых 70 % пути: так склон
## перед камерой не закрывает пол-кадра
static func _clearance(h: Heightfield, pos: Vector3, target: Vector3) -> float:
	var best := INF
	var low := target - Vector3(0.0, pos.distance_to(target) * 0.33, 0.0)
	for k in range(1, 40):
		var p := pos.lerp(target, k / 40.0)
		best = minf(best, p.y - h.ground_at(p.x, p.z))
		if k < 28:
			var q := pos.lerp(low, k / 40.0)
			best = minf(best, q.y - h.ground_at(q.x, q.z))
	return best


## Камера на расстоянии dist от target с той стороны (из 16), откуда цель видна лучше всего;
## высота — не ниже up над землёй и не ниже target.y + rise
static func _look_from(h: Heightfield, target: Vector3, dist: float, up: float, rise: float) -> Vector3:
	var best := Vector3.ZERO
	var score := -INF
	var size := h.world.W * TILE
	for k in 16:
		var a := k * TAU / 16.0
		var x := clampf(target.x + sin(a) * dist, 8.0, size - 8.0)
		var z := clampf(target.z + cos(a) * dist, 8.0, size - 8.0)
		var pos := Vector3(x, maxf(h.ground_at(x, z) + up, target.y + rise), z)
		var c := _clearance(h, pos, target)
		if c > score + 0.01:
			score = c
			best = pos
	return best


## Точка ломаной в dist клетках вдоль неё от номера from (или последняя)
static func _along(pts: Array, from: int, dist: float) -> int:
	var s := 0.0
	for k in range(from + 1, pts.size()):
		s += Vector2(pts[k].x - pts[k - 1].x, pts[k].y - pts[k - 1].y).length()
		if s >= dist:
			return k
	return pts.size() - 1


static func _longest(lines: Array) -> Array:
	var best: Array = []
	var best_len := 0.0
	for pts in lines:
		var l := path_length(pts)
		if l > best_len:
			best_len = l
			best = pts
	return best


## Одинаковые от версии к версии виды: точка появления, высочайшая вершина, долина самой длинной реки,
## середина самой длинной дороги и самое большое поселение. Каждый вид — {name, title, pos, target}.
## Виды считаются только из данных мира, поэтому для того же мира камера встаёт туда же.
static func views(game: GameWorld) -> Array:
	var w := game.world
	var h := game.heights
	var out: Array = []
	var cam := game.camera.global_transform
	out.append({name = "spawn", title = "Точка появления", pos = cam.origin, target = cam.origin - cam.basis.z * 20.0})
	if w.peaks.size() > 0:
		var top: Dictionary = w.peaks[0]
		for p in w.peaks:
			if p.elev > top.elev:
				top = p
		var t := _at(h, top.x, top.y, 0.0)
		out.append({name = "peak", title = "Вершина «%s»" % top.name, pos = _look_from(h, t, 400.0, 30.0, -60.0), target = t})
	var river := _longest(w.rivers)
	if river.size() > 2:
		var m := river.size() / 2
		var pos := _at(h, river[m].x, river[m].y, 22.0)
		var end: Dictionary = river[_along(river, m, 40.0)]
		var t := _at(h, end.x, end.y, 0.0)
		out.append({name = "valley", title = "Долина реки", pos = pos, target = t})
	var roads: Array = []
	for t in w.trails:
		if t.kind == "road":
			roads.append(t.pts)
	var road := _longest(roads)
	if road.size() > 2:
		var m := road.size() / 2
		var pos := _at(h, road[m].x, road[m].y, 5.0)
		var k := _along(road, m, 18.0)
		out.append({name = "road", title = "Дорога", pos = pos, target = _at(h, road[k].x, road[k].y, 1.0)})
	if w.settlements.size() > 0:
		var big: SettlementData = w.settlements[0]
		for s in w.settlements:
			if s.huts.size() > big.huts.size():
				big = s
		var t := Vector3(big.x * TILE, h.ground_at(big.x * TILE, big.y * TILE) + 2.0, big.y * TILE)
		out.append({name = "settlement", title = "Поселение «%s»" % big.name, pos = _look_from(h, t, 95.0, 40.0, 40.0), target = t})
		# с 9.5: то же поселение вблизи — с края площади на сторону, где больше построек, с высоты второго этажа
		var lean := Vector2.ZERO
		for u in big.huts:
			lean += Vector2(u.x - big.x, u.y - big.y)
		lean = lean.normalized() if lean.length() > 0.01 else Vector2(1, 0)
		var from := Vector2(big.x, big.y) - lean * 4.0
		var pos := _at(h, from.x - 0.5, from.y - 0.5, 0.0)
		pos.y = maxf(pos.y, t.y) + 6.0
		var look := _at(h, big.x + lean.x * 3.0 - 0.5, big.y + lean.y * 3.0 - 0.5, 2.0)
		out.append({name = "village", title = "Улица «%s»" % big.name, pos = pos, target = look})
	# с 9.3: самое значимое место вне поселений, из равных — ближайшее к дому
	var site := {}
	var home := Vector2(w.territory_center)
	for s in w.sites:
		if site.is_empty() or s.rank > site.rank or s.rank == site.rank and home.distance_to(Vector2(s.x, s.y)) < home.distance_to(Vector2(site.x, site.y)):
			site = s
	if not site.is_empty():
		var t := Vector3(site.x * TILE, h.ground_at(site.x * TILE, site.y * TILE) + 3.0, site.y * TILE)
		var kind: String = StageSites.TYPES[site.type].title
		out.append({name = "site", title = "%s «%s»" % [kind.left(1).to_upper() + kind.substr(1), site.name], pos = _look_from(h, t, 32.0, 10.0, 8.0), target = t})
	# с 9.4: лес изнутри на высоте глаз — у ближайшего к дому взрослого дерева в густом
	# (не меньше 60 % самого лесистого чанка) лиственном лесу или тайге
	var stand := PackedInt32Array()
	stand.resize(w.chunks.size())
	for c in w.chunks.size():
		for o in w.chunks[c]:
			if Biomes.is_tree(w.obj_k[o]):
				stand[c] += 1
	var densest := 0
	for c in stand:
		densest = maxi(densest, c)
	var tree := -1
	var tree_d := INF
	for o in w.obj_count:
		if not Biomes.is_tree(w.obj_k[o]) or w.obj_s[o] < 1.0:
			continue
		if stand[floori(w.obj_y[o] / w.CS) * w.CW + floori(w.obj_x[o] / w.CS)] < densest * 0.6:
			continue
		var cell := floori(w.obj_y[o]) * w.W + floori(w.obj_x[o])
		if w.biome[cell] != Biomes.FOREST and w.biome[cell] != Biomes.TAIGA or w.path_mask[cell] > 0:
			continue
		var d := home.distance_to(Vector2(w.obj_x[o], w.obj_y[o]))
		if d < tree_d:
			tree_d = d
			tree = o
	if tree >= 0:
		# Камера в 6 м от дерева, с той из восьми сторон, где ближайший ствол дальше всего (не в кроне)
		var tx := w.obj_x[tree] * TILE
		var tz := w.obj_y[tree] * TILE
		var best := Vector2(tx + 6.0, tz)
		var room := -1.0
		for k in 8:
			var p := Vector2(tx, tz) + Vector2.from_angle(k * TAU / 8.0) * 6.0
			var near := INF
			var cx := floori(p.x / TILE / w.CS)
			var cy := floori(p.y / TILE / w.CS)
			for j in range(maxi(0, cy - 1), mini(w.CH, cy + 2)):
				for i in range(maxi(0, cx - 1), mini(w.CW, cx + 2)):
					for o in w.chunks[j * w.CW + i]:
						if Biomes.is_tree(w.obj_k[o]):
							near = minf(near, p.distance_to(Vector2(w.obj_x[o], w.obj_y[o]) * TILE))
			if near > room:
				room = near
				best = p
		var eye := Vector3(best.x, h.ground_at(best.x, best.y) + GameConfig.EYE, best.y)
		var ahead := Vector2(tx, tz) + (Vector2(tx, tz) - best).normalized() * 14.0
		out.append({name = "forest", title = "Лес", pos = eye, target = Vector3(ahead.x, h.ground_at(ahead.x, ahead.y) + 2.0, ahead.y)})
	return out
