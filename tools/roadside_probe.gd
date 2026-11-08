extends SceneTree
## Проба леса у путей на реальных мирах (15.0) без генерации: сохранённые миры tools/control/runs/road_relief/<сид>.fixture.bin,
## на них заново раскладывается растительность (StageVegetation.run — этот же код), затем меряется:
##  - время раскладки и число объектов и деревьев;
##  - у каждого вида пути на станциях через 2 м в лесу (не меньше 10 деревьев в 30 м): расстояние от кромки полотна
##    до ближайшего ствола в ±4 м вдоль пути, доля станций, где над осью есть крона, стволы ближе 2 м к кромке на 100 м пути;
##  - нарушения: ствол на полотне (ближе к оси, чем полуширина плюс его радиус).
## «Было» — этот же скрипт в копии прошлой версии кода (--fixtures на эту папку, --out своя папка).
##   godot --headless --path . --script res://tools/roadside_probe.gd -- [--tag after] [--out <папка>] [--fixtures <папка>]
##         [--base <папка было>] [--seeds Север-1234,Туман-4821,Ущелье] [--parity]
## --parity — ещё сверка поля просвета C# и GDScript (Grid.path_clearance) побайтно (только новый код).

const TILE := GameConfig.TILE
const CELL := 8.0
const STATION := 2.0
const KINDS := ["road", "trail", "mountain", "animal"]
const TRUNK := {
	Biomes.T_BIRCH: 0.14, Biomes.T_PINE: 0.23, Biomes.T_SNOWPINE: 0.23, Biomes.T_OAK: 0.32,
	Biomes.T_JUNGLE: 0.32, Biomes.T_ACACIA: 0.3, Biomes.T_PALM: 0.25, Biomes.T_DEAD: 0.34, Biomes.T_CACTUS: 0.3,
}

var out := ""
var fixtures := "res://tools/control/runs/road_relief"
var base_dir := ""
var seeds := PackedStringArray(["Север-1234", "Туман-4821", "Ущелье"])
var summary := {}
var failures := 0


func _arg(name: String, fallback: String) -> String:
	var a := OS.get_cmdline_user_args()
	var at := a.find("--" + name)
	return a[at + 1] if at >= 0 and at + 1 < a.size() else fallback


func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 420)
	out = _arg("out", "res://tools/control/runs/roadside/" + _arg("tag", "after"))
	fixtures = _arg("fixtures", fixtures)
	base_dir = _arg("base", "")
	var listed := _arg("seeds", "")
	if listed != "": seeds = listed.split(",")
	DirAccess.make_dir_recursive_absolute(out)
	run.call_deferred()


func run() -> void:
	if seeds.is_empty() or ("--parity" in OS.get_cmdline_user_args() and Grid.fast_grid() == null):
		printerr("ROADSIDE: нужны сиды и C# backend для --parity")
		quit(1)
		return
	for seed_text in seeds:
		if not FileAccess.file_exists(fixtures.path_join(seed_text + ".fixture.bin")):
			printerr("ROADSIDE: нет фикстуры ", seed_text)
			quit(1)
			return
	for seed_text in seeds:
		var path := fixtures.path_join(seed_text + ".fixture.bin")
		var saved: Dictionary = FileAccess.open(path, FileAccess.READ).get_var()
		var w: WorldData = WorldCache.new()._restore(saved.world, true)
		saved = {}
		var started := Time.get_ticks_usec()
		StageVegetation.run(w)
		var ms := (Time.get_ticks_usec() - started) / 1000.0
		var row := {seed = seed_text, metrics_version = 2, vegetation_ms = ms, objects = w.obj_count, trees = 0}
		for o in w.obj_count:
			if TRUNK.has(w.obj_k[o]) and w.obj_s[o] >= 0.6: row.trees += 1
		row.kinds = _measure(w)
		row.on_tread = _violations(w)
		if row.on_tread > 0: failures += 1
		if "--parity" in OS.get_cmdline_user_args():
			var stage: Script = load("res://scripts/world/stages/stage_vegetation.gd") # вызов по имени: в старом коде функции нет
			var fast: PackedFloat32Array = stage.call("path_clearance", w.W, w.H, w.trails)
			var allowed := Grid.allow_fast
			Grid.allow_fast = false
			var slow: PackedFloat32Array = stage.call("path_clearance", w.W, w.H, w.trails)
			Grid.allow_fast = allowed
			row.clearance_parity = fast == slow
			if not row.clearance_parity: failures += 1
		summary[seed_text] = row
		_print(row)
	FileAccess.open(out.path_join("roadside.json"), FileAccess.WRITE).store_string(JSON.stringify(summary, "\t"))
	if base_dir != "" and not _compare(): failures += 1
	print("ROADSIDE DONE ", out, "; failures=", failures)
	quit(1 if failures else 0)


func _measure(w: WorldData) -> Dictionary:
	# индекс деревьев по клеткам 8 м
	var grid := {}
	for o in w.obj_count:
		var k := w.obj_k[o]
		if not TRUNK.has(k) or w.obj_s[o] < 0.6: continue
		var key := Vector2i(floori(w.obj_x[o] * TILE / CELL), floori(w.obj_y[o] * TILE / CELL))
		if not grid.has(key): grid[key] = []
		(grid[key] as Array).append(o)
	var result := {}
	for t: Dictionary in w.trails:
		if not t.kind in KINDS or t.pts.size() < 2: continue
		if not result.has(t.kind): result[t.kind] = {stations = 0, forest = 0, gaps = [], canopy = 0, close = {}, metres = 0.0}
		var g: Dictionary = result[t.kind]
		var pts: Array = t.pts
		var next := 0.0
		var along := 0.0
		for n in range(1, pts.size()):
			var a := Vector2(pts[n - 1].x, pts[n - 1].y) * TILE
			var b := Vector2(pts[n].x, pts[n].y) * TILE
			var length := a.distance_to(b)
			if length < 0.01: continue
			while next <= along + length:
				var f := (next - along) / length
				var p := a.lerp(b, f)
				var half := lerpf(float(pts[n - 1].w), float(pts[n].w), f) * TILE * 0.5
				_station(w, grid, p, (b - a) / length, half, g)
				next += STATION
			along += length
		g.metres += along
	var outv := {}
	for kind: String in result:
		var g: Dictionary = result[kind]
		var gaps: Array = g.gaps
		gaps.sort()
		outv[kind] = {km = g.metres / 1000.0, forest_share = float(g.forest) / maxi(1, g.stations),
			median_gap_m = gaps[gaps.size() / 2] if not gaps.is_empty() else -1.0,
			p25_gap_m = gaps[gaps.size() / 4] if not gaps.is_empty() else -1.0,
			canopy_share = float(g.canopy) / maxi(1, g.forest), close_per_100m = g.close.size() * 100.0 / maxf(1.0, g.forest * STATION)}
	return outv


## Стволы на полотне — точно, по отрезкам линий: ствол ближе к оси, чем полуширина плюс его радиус (по одному разу)
func _violations(w: WorldData) -> int:
	var bad := {}
	var grid := {}
	var radius := 0.0
	for o in w.obj_count:
		if not TRUNK.has(w.obj_k[o]) or w.obj_s[o] < 0.6: continue
		radius = maxf(radius, TRUNK[w.obj_k[o]] * w.obj_s[o])
		var key := Vector2i(floori(w.obj_x[o] * TILE / CELL), floori(w.obj_y[o] * TILE / CELL))
		if not grid.has(key): grid[key] = []
		(grid[key] as Array).append(o)
	for t: Dictionary in w.trails:
		if not t.kind in KINDS: continue
		for n in range(1, t.pts.size()):
			var a := Vector2(t.pts[n - 1].x, t.pts[n - 1].y) * TILE
			var b := Vector2(t.pts[n].x, t.pts[n].y) * TILE
			var ha := float(t.pts[n - 1].w) * TILE * 0.5
			var hb := float(t.pts[n].w) * TILE * 0.5
			# В том числе длинный прямой отрезок: индекс у середины не покрывает его концы.
			var reach := maxf(ha, hb) + radius
			for dy in range(floori((minf(a.y, b.y) - reach) / CELL), floori((maxf(a.y, b.y) + reach) / CELL) + 1):
				for dx in range(floori((minf(a.x, b.x) - reach) / CELL), floori((maxf(a.x, b.x) + reach) / CELL) + 1):
					for o: int in grid.get(Vector2i(dx, dy), []):
						var q := Vector2(w.obj_x[o], w.obj_y[o]) * TILE
						var d := b - a
						var f := clampf((q - a).dot(d) / maxf(d.length_squared(), 1e-9), 0.0, 1.0)
						# Метровый меш использует среднюю полуширину отрезка.
						if q.distance_to(a + d * f) < (ha + hb) * 0.5 + TRUNK[w.obj_k[o]] * w.obj_s[o]:
							bad[o] = true
	return bad.size()


func _station(w: WorldData, grid: Dictionary, p: Vector2, dir: Vector2, half: float, g: Dictionary) -> void:
	g.stations += 1
	var near := INF
	var trees := 0
	var canopy := false
	var close := {}
	var key := Vector2i(floori(p.x / CELL), floori(p.y / CELL))
	for dy in range(-4, 5):
		for dx in range(-4, 5):
			var list: Variant = grid.get(key + Vector2i(dx, dy))
			if list == null: continue
			for o: int in list:
				var q := Vector2(w.obj_x[o], w.obj_y[o]) * TILE
				var d := q.distance_to(p)
				if d > 30.0: continue
				trees += 1
				if d > 12.0: continue
				var lateral := absf((q - p).cross(dir))
				var along := absf((q - p).dot(dir))
				if along < 4.0:
					var gap := lateral - half
					near = minf(near, gap)
					if gap < 2.0: close[o] = true
				if d < Biomes.CROWN_RADIUS[w.obj_k[o]] * w.obj_s[o] * TILE: canopy = true
	if trees < 10: return
	# Считать ствол один раз, только у лесных станций, которыми нормируется длина.
	(g.close as Dictionary).merge(close)
	g.forest += 1
	if canopy: g.canopy += 1
	(g.gaps as Array).append(near if near < INF else 12.0)


func _print(row: Dictionary) -> void:
	print("ROADSIDE %s: растительность %.0f мс, объектов %d, деревьев %d, стволов на полотне (точно) %d%s" % [row.seed, row.vegetation_ms, row.objects, row.trees, row.on_tread,
		(", поле просвета C#/GDScript совпадает: %s" % row.clearance_parity) if row.has("clearance_parity") else ""])
	for kind: String in row.kinds:
		var m: Dictionary = row.kinds[kind]
		print("  %-9s %6.1f км, в лесу %3.0f%% | до ствола от кромки медиана %.1f м, четверть %.1f м | крона над осью %3.0f%% | стволов у кромки (<2 м) %.1f на 100 м" % [
			kind, m.km, m.forest_share * 100.0, m.median_gap_m, m.p25_gap_m, m.canopy_share * 100.0, m.close_per_100m])


func _compare() -> bool:
	var path := base_dir.path_join("roadside.json")
	if not FileAccess.file_exists(path):
		printerr("ROADSIDE: нет базы сравнения ", path)
		return false
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not parsed is Dictionary:
		printerr("ROADSIDE: некорректная база сравнения ", path)
		return false
	var before: Dictionary = parsed
	for seed_text: String in summary:
		if not before.has(seed_text):
			printerr("ROADSIDE: в базе нет сида ", seed_text)
			return false
	var lines := PackedStringArray()
	for seed_text: String in summary:
		if not before.has(seed_text): continue
		var a: Dictionary = before[seed_text]
		var b: Dictionary = summary[seed_text]
		lines.append("%s: растительность %.0f → %.0f мс, объектов %d → %d (%+.1f%%), деревьев %d → %d (%+.1f%%)" % [seed_text,
			a.vegetation_ms, b.vegetation_ms, a.objects, b.objects, (float(b.objects) / a.objects - 1.0) * 100.0,
			a.trees, b.trees, (float(b.trees) / a.trees - 1.0) * 100.0])
		for kind: String in b.kinds:
			if not a.kinds.has(kind): continue
			var x: Dictionary = a.kinds[kind]
			var y: Dictionary = b.kinds[kind]
			var close := "у кромки: разные версии подсчёта"
			if a.get("metrics_version", 1) == b.get("metrics_version", 1):
				close = "у кромки %.1f → %.1f на 100 м" % [x.close_per_100m, y.close_per_100m]
			lines.append("  %-9s до ствола медиана %.1f → %.1f м, четверть %.1f → %.1f м | крона над осью %3.0f → %3.0f%% | %s" % [
				kind, x.median_gap_m, y.median_gap_m, x.p25_gap_m, y.p25_gap_m, x.canopy_share * 100.0, y.canopy_share * 100.0,
				close])
	var text := "\n".join(lines)
	print("ROADSIDE COMPARE\n", text)
	FileAccess.open(out.path_join("compare.txt"), FileAccess.WRITE).store_string(text)
	return true
