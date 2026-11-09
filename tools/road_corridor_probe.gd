extends SceneTree
## Проба конечной поверхности дорог на реальных мирах (ноябрь 2026, docs/ROAD_RELIEF.md). Генерации нет: сохранённые
## миры tools/control/runs/road_relief/<сид>.fixture.bin (WorldData + базовый рельеф до полотна дорог).
## Для каждого мира: время finish_paths (RoadBed + сооружения + RoadRefinement), меры КОНЕЧНОЙ высоты полотна
## (ground_at: то, что видит меш и на чём стоят колёса) по станциям через 1 м — продольные формы, поперечный профиль,
## разница двух линий движения, обочины; заезд BikeRide по трём участкам; снимки участков (нужно окно).
## Участки выбираются правилом, а не по силе изменения: самый длинный путь каждого вида, точка на 0,35 его длины
## (сдвигается вперёд, пока в ±30 м нет воды и сооружений).
## «Было» — этот же скрипт в копии прошлой версии кода (--fixtures указывает сюда), --tag before;
## «стало» с --base <папка прогона «было»> кладёт снимки парами (слева было, справа стало) и печатает обе сводки.
##   godot --path . --script res://tools/road_corridor_probe.gd -- [--tag after] [--out <папка>] [--fixtures <папка>]
##         [--base <папка>] [--seeds Север-1234,Туман-4821,Ущелье] [--no-shots] [--runs 3]
##         [--clutter] [--ride-metres 550] [--ride-clutter] [--verify-roots] [--sections forest] [--shot-kinds road,forest]

const Snapshot := preload("res://scripts/game/surface_snapshot.gd")
const Floor := preload("res://scripts/render/forest_floor.gd")
const TILE := GameConfig.TILE
const KINDS := ["road", "trail", "mountain"]
const WINDOW := 20          # м, окно продольной меры
const MID_R := 10           # м, полуокно среднего: «средние формы» — отклонение от среднего по ±10 м
const NOTICE := 0.06        # м, размах полосы 5–17 м (среднее ±2 м минус среднее ±8 м) в окне: бугор или впадина, заметные с велосипеда
const REGULAR := Vector3(0.05, 0.03, 0.015) # окно «гладкая лента»: размах продольных форм, разброс выпуклости, разброс перекоса

var out := ""
var tag := "after"
var fixtures := "res://tools/control/runs/road_relief"
var base_dir := ""
var seeds := PackedStringArray(["Север-1234", "Туман-4821", "Ущелье"])
var shots := true
var clutter := false
var ride_clutter := false
var verify_roots := false
var ride_metres := 95
var runs := 3
var summary := {}
var stations := {} # сид -> путь -> высоты станций подряд: ось, линии ±0,5, края ±0,9 полуширины, закреплено (1/0)
var mesh_node: MeshInstance3D
var camera: Camera3D
var vegetation: VegetationLayer
var terrain_material: ShaderMaterial
var shot_kinds := PackedStringArray()
var section_kinds := PackedStringArray()
var clutter_mismatches := 0


func _arg(name: String, fallback: String) -> String:
	var a := OS.get_cmdline_user_args()
	var at := a.find("--" + name)
	return a[at + 1] if at >= 0 and at + 1 < a.size() else fallback


func _warm_median(times: Array) -> float:
	var warm := times.slice(1)
	warm.sort()
	return (warm[(warm.size() - 1) / 2] + warm[warm.size() / 2]) * 0.5


func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 540)
	tag = _arg("tag", "after")
	out = _arg("out", "res://tools/control/runs/road_corridor/" + tag)
	fixtures = _arg("fixtures", fixtures)
	base_dir = _arg("base", "")
	runs = int(_arg("runs", "3"))
	var listed := _arg("seeds", "")
	if listed != "": seeds = listed.split(",")
	shots = not "--no-shots" in OS.get_cmdline_user_args() and DisplayServer.get_name() != "headless"
	shot_kinds = _arg("shot-kinds", "").split(",", false)
	section_kinds = _arg("sections", "").split(",", false)
	clutter = "--clutter" in OS.get_cmdline_user_args()
	ride_clutter = "--ride-clutter" in OS.get_cmdline_user_args() and clutter
	verify_roots = "--verify-roots" in OS.get_cmdline_user_args() and clutter
	ride_metres = clampi(int(_arg("ride-metres", "95")), 95, 1000)
	DirAccess.make_dir_recursive_absolute(out)
	run.call_deferred()


func run() -> void:
	# Fixtures are local measurement data, not part of a clean checkout. An empty
	# successful report must not look like a completed real-world verification.
	if runs < 1 or seeds.is_empty():
		printerr("PROBE: нужны --runs >= 1 и хотя бы один сид")
		quit(1)
		return
	for seed_text in seeds:
		var path := fixtures.path_join(seed_text + ".fixture.bin")
		if not FileAccess.file_exists(path):
			printerr("PROBE нет фикстуры ", path)
			quit(1)
			return
	if shots: _scene()
	for seed_text in seeds:
		var path := fixtures.path_join(seed_text + ".fixture.bin")
		var saved: Dictionary = FileAccess.open(path, FileAccess.READ).get_var()
		var w: WorldData = WorldCache.new()._restore(saved.world, true)
		w.available_rect = Rect2i() # весь план открыт: участки и заезды не только в стартовом окне
		var base: Heightfield = Snapshot.restore(w, saved.base, "base")
		saved = {}
		var times := []
		var stages := {}
		var h: Heightfield
		for k in runs:
			h = base.copy()
			var started := Time.get_ticks_usec()
			h.finish_paths()
			times.append((Time.get_ticks_usec() - started) / 1000.0)
			stages = h.path_timings.duplicate()
		var row := {seed = seed_text, finish_ms = times, stages = stages}
		if times.size() > 1:
			row.finish_warm_median_ms = _warm_median(times)
		row.patches = h.road_refinement.patches.size()
		if shots:
			var terrain_image := MapBaker.finish(w, 1, [MapBaker.paint(w, 1, true, false)[0]], false)[0]
			terrain_material = GameContext.scope.terrain.material(terrain_image)
		var forest := Floor.surface_image(w) if clutter else null
		var sections := _sections(w, h, forest)
		stations = {}
		row.metrics = _metrics(w, h)
		FileAccess.open(out.path_join(seed_text + "_stations.bin"), FileAccess.WRITE).store_var(stations)
		if clutter:
			vegetation = VegetationLayer.new()
			root.add_child(vegetation)
			vegetation.setup(w, h, Models.tree_defs() if shots else {}, Models.grass_mesh(), forest)
			vegetation.settings.trail_clutter = true
			if "measure_road_clutter" in vegetation:
				vegetation.set("measure_road_clutter", true)
		row.sections = []
		for s: Dictionary in sections:
			if not section_kinds.is_empty() and not s.kind in section_kinds:
				continue
			var capture: bool = shots and (shot_kinds.is_empty() or s.kind in shot_kinds)
			var ride := _ride(w, h, s)
			s.ride = ride
			s.profile = _profile(h, s)
			if clutter:
				s.clutter = _clutter_at(Vector2(s.x, s.z), capture)
				print("CLUTTER ", seed_text, " ", s.kind, " ", JSON.stringify(s.clutter))
			var root_at := _nearest_root(Vector2(s.x, s.z)) if verify_roots and s.kind == "forest" else Vector2.INF
			if ride_clutter and s.kind == "forest":
				s.clutter_ride = _ride(w, h, s, true)
				print("CLUTTER RIDE ", seed_text, " ", JSON.stringify(s.clutter_ride))
				h.obstacles = null
				if capture: _clutter_at(Vector2(s.x, s.z), true)
			row.sections.append(s.duplicate())
			if capture: await _shoot(w, h, seed_text, s)
			if root_at != Vector2.INF:
				var near_root := _clutter_at(root_at, false)
				row.sections[-1].root_contact = near_root
				print("ROOT CONTACT ", seed_text, " ", root_at, " ", JSON.stringify(near_root))
		if vegetation != null:
			vegetation.free()
			vegetation = null
		summary[seed_text] = row
		_print(seed_text, row)
		FileAccess.open(out.path_join(seed_text + "_probe.json"), FileAccess.WRITE).store_string(JSON.stringify(row, "\t"))
	FileAccess.open(out.path_join("probe.json"), FileAccess.WRITE).store_string(JSON.stringify(summary, "\t"))
	if base_dir != "": _compare()
	print("PROBE DONE ", out)
	quit(1 if clutter_mismatches > 0 else 0)


## Станции через 1 м по линии пути: точка, полуширина
func _stations(t: Dictionary) -> Dictionary:
	var pts: Array = t.pts
	var ps := PackedVector2Array()
	var half := PackedFloat32Array()
	var along := 0.0
	var next := 0.0
	for n in range(1, pts.size()):
		var a := Vector2(pts[n - 1].x, pts[n - 1].y) * TILE
		var b := Vector2(pts[n].x, pts[n].y) * TILE
		var length := a.distance_to(b)
		if length < 0.01: continue
		while next <= along + length:
			var f := (next - along) / length
			ps.append(a.lerp(b, f))
			half.append(lerpf(float(pts[n - 1].w), float(pts[n].w), f) * TILE * 0.5)
			next += 1.0
		along += length
	return {p = ps, half = half}


func _normal(ps: PackedVector2Array, j: int) -> Vector2:
	var t := (ps[mini(ps.size() - 1, j + 2)] - ps[maxi(0, j - 2)]).normalized()
	return Vector2(-t.y, t.x)


## Клетки, где полотно по правилам закреплено: вода рядом, сооружения, поселения — их не считаем
func _pinned(w: WorldData, h: Heightfield) -> PackedByteArray:
	var pin := PackedByteArray()
	pin.resize(w.N)
	for i in w.N:
		if w.dist_water[i] < 3.0 or h.water_level[i] != -INF: pin[i] = 1
	for s: Dictionary in h.structures:
		var a := Vector2(s.ax, s.az)
		var b := Vector2(s.bx, s.bz)
		var steps := maxi(1, ceili(a.distance_to(b) / TILE))
		for k in steps + 1:
			var p := a.lerp(b, float(k) / steps) / TILE
			for dz in range(-4, 5):
				for dx in range(-4, 5):
					var x := floori(p.x) + dx
					var z := floori(p.y) + dz
					if x >= 0 and z >= 0 and x < w.W and z < w.H: pin[z * w.W + x] = 1
	for v: SettlementData in w.settlements:
		for dz in range(-3, 4):
			for dx in range(-3, 4):
				var x := floori(v.x) + dx
				var z := floori(v.y) + dz
				if x >= 0 and z >= 0 and x < w.W and z < w.H: pin[z * w.W + x] = 1
	return pin


func _cell(w: WorldData, p: Vector2) -> int:
	return clampi(floori(p.y / TILE), 0, w.H - 1) * w.W + clampi(floori(p.x / TILE), 0, w.W - 1)


func _sections(w: WorldData, h: Heightfield, forest: Image) -> Array:
	var pin := _pinned(w, h)
	var picked := []
	# по виду пути самый длинный; ещё самая длинная лесная тропа (покрытие у начала), если она есть
	for kind: String in KINDS + ([] if forest != null else ["forest"]):
		var best := -1
		var best_len := 0
		for k in w.trails.size():
			var t: Dictionary = w.trails[k]
			if t.has("trail_id"): continue
			if kind == "forest":
				if t.kind != "trail" or t.surf.is_empty() or t.surf[t.surf.size() / 3] != RoadSurface.FOREST: continue
			elif t.kind != kind: continue
			var n: int = _stations(t).p.size()
			if n > best_len:
				best_len = n
				best = k
		if best < 0 or best_len < 90: continue
		var st := _stations(w.trails[best])
		var ps: PackedVector2Array = st.p
		var at := int(best_len * 0.35)
		while at < best_len - 45:
			var clean := true
			for j in range(at - 30, at + 31, 3):
				if pin[_cell(w, ps[j])] != 0: clean = false; break
			if clean: break
			at += 10
		if at >= best_len - 45: continue
		var surf: int = w.road_surface[_cell(w, ps[at])]
		picked.append({kind = kind, route = best, station = at, x = ps[at].x, z = ps[at].y, surface = surf,
			surface_name = RoadSurface.LIST[surf].get("name", "-") if surf > 0 else "-"})
	if forest != null:
		var best := {}
		var best_cover := 0.0
		for route in w.trails.size():
			var trail: Dictionary = w.trails[route]
			if trail.kind != "trail" or trail.has("trail_id"): continue
			var points: PackedVector2Array = _stations(trail).p
			for j in range(45, points.size() - 45, 16):
				if pin[_cell(w, points[j])] != 0: continue
				var cover := 0.0
				for k in range(j - 24, j + 25, 8):
					var side := _normal(points, k) * 4.0
					for p: Vector2 in [points[k] - side, points[k] + side]:
						var cell := _cell(w, p)
						cover += forest.get_pixel(cell % w.W, cell / w.W).r
				cover *= minf(1.0, (points.size() - j) / float(ride_metres))
				if cover <= best_cover: continue
				best_cover = cover
				var surf: int = w.road_surface[_cell(w, points[j])]
				best = {kind = "forest", route = route, station = j, x = points[j].x, z = points[j].y, surface = surf,
					surface_name = RoadSurface.LIST[surf].get("name", "-") if surf > 0 else "-"}
		if not best.is_empty(): picked.append(best)
	return picked


func _avg(a: PackedFloat64Array, j: int, r: int) -> float:
	var lo := maxi(0, j - r)
	var hi := mini(a.size() - 1, j + r)
	var s := 0.0
	for k in range(lo, hi + 1): s += a[k]
	return s / (hi - lo + 1)


## Полоса средних форм: среднее по ±2 м минус среднее по ±8 м (длины волн примерно 5–17 м; плавный перегиб склона почти не проходит)
func _band(a: PackedFloat64Array) -> PackedFloat64Array:
	var n := a.size()
	var sum := PackedFloat64Array()
	sum.resize(n + 1)
	for j in n: sum[j + 1] = sum[j] + a[j]
	var outv := PackedFloat64Array()
	outv.resize(n)
	for j in n:
		var lo := maxi(0, j - 2)
		var hi := mini(n - 1, j + 2)
		var wide_lo := maxi(0, j - 8)
		var wide_hi := mini(n - 1, j + 8)
		outv[j] = (sum[hi + 1] - sum[lo]) / (hi - lo + 1) - (sum[wide_hi + 1] - sum[wide_lo]) / (wide_hi - wide_lo + 1)
	return outv


## Отклонение от среднего по ±MID_R станций (префиксные суммы)
func _detrend(a: PackedFloat64Array) -> PackedFloat64Array:
	var n := a.size()
	var sum := PackedFloat64Array()
	sum.resize(n + 1)
	for j in n: sum[j + 1] = sum[j] + a[j]
	var outv := PackedFloat64Array()
	outv.resize(n)
	for j in n:
		var lo := maxi(0, j - MID_R)
		var hi := mini(n - 1, j + MID_R)
		outv[j] = a[j] - (sum[hi + 1] - sum[lo]) / (hi - lo + 1)
	return outv


func _metrics(w: WorldData, h: Heightfield) -> Dictionary:
	var pin := _pinned(w, h)
	var groups := {}
	for route in w.trails.size():
		var t: Dictionary = w.trails[route]
		if not t.kind in KINDS: continue
		var st := _stations(t)
		var ps: PackedVector2Array = st.p
		var hw: PackedFloat32Array = st.half
		var n := ps.size()
		if n < WINDOW * 2: continue
		var c := PackedFloat64Array(); var raw := PackedFloat64Array(); var l := PackedFloat64Array(); var r := PackedFloat64Array()
		var tilt := PackedFloat64Array(); var dish := PackedFloat64Array(); var shoulder := PackedFloat64Array()
		var grade := PackedFloat64Array()
		for arr: PackedFloat64Array in [c, raw, l, r, tilt, dish, shoulder, grade]: arr.resize(n)
		for j in n:
			var p := ps[j]
			var nn := _normal(ps, j)
			var half := hw[j]
			c[j] = h.ground_at(p.x, p.y)
			raw[j] = h.ground_at(p.x, p.y, true)
			l[j] = h.ground_at(p.x - nn.x * half * 0.5, p.y - nn.y * half * 0.5)
			r[j] = h.ground_at(p.x + nn.x * half * 0.5, p.y + nn.y * half * 0.5)
			var el := h.ground_at(p.x - nn.x * half * 0.9, p.y - nn.y * half * 0.9)
			var er := h.ground_at(p.x + nn.x * half * 0.9, p.y + nn.y * half * 0.9)
			tilt[j] = (er - el) / (1.8 * half)
			dish[j] = c[j] - (el + er) * 0.5
			# обочина: отклонение от прямой между краем полотна и землёй за зоной метровой сетки (ров < 0, вал > 0)
			var dev := 0.0
			for sgn in [-1.0, 1.0]:
				var e := h.ground_at(p.x + nn.x * half * 0.9 * sgn, p.y + nn.y * half * 0.9 * sgn)
				var far := h.ground_at(p.x + nn.x * (half + 3.6) * sgn, p.y + nn.y * (half + 3.6) * sgn)
				var mid := h.ground_at(p.x + nn.x * (half + 1.4) * sgn, p.y + nn.y * (half + 1.4) * sgn)
				var f := (half + 1.4 - half * 0.9) / (half + 3.6 - half * 0.9)
				dev = maxf(dev, absf(mid - lerpf(e, far, f)))
			shoulder[j] = dev
		for j in n: grade[j] = absf(c[mini(n - 1, j + 1)] - c[j])
		var keep := PackedFloat32Array()
		keep.resize(n * 6)
		for j in n:
			var nn := _normal(ps, j)
			keep[j * 6] = c[j]
			keep[j * 6 + 1] = l[j]
			keep[j * 6 + 2] = r[j]
			keep[j * 6 + 3] = h.ground_at(ps[j].x - nn.x * hw[j] * 0.9, ps[j].y - nn.y * hw[j] * 0.9)
			keep[j * 6 + 4] = h.ground_at(ps[j].x + nn.x * hw[j] * 0.9, ps[j].y + nn.y * hw[j] * 0.9)
			keep[j * 6 + 5] = pin[_cell(w, ps[j])]
		stations[route] = keep
		var mids := _detrend(c); var raw_mids := _detrend(raw); var tvs := _detrend(tilt)
		var band := _band(c); var raw_band := _band(raw)
		var ls := _detrend(l); var rs := _detrend(r)
		var windows := floori(n / float(WINDOW))
		for k in windows:
			var lo := k * WINDOW
			var hi := lo + WINDOW
			var pinned := false
			for j in range(lo, hi, 2):
				if pin[_cell(w, ps[j])] != 0: pinned = true; break
			var slope := absf(raw[mini(n - 1, hi)] - raw[lo]) / WINDOW
			var acc := {mid2 = 0.0, raw_mid2 = 0.0, tilt_var2 = 0.0, dish_abs = 0.0, line2 = 0.0, shoulder = 0.0}
			var notice := false
			var raw_notice := false
			var regular := false
			if not pinned:
				var lo_mid := INF; var hi_mid := -INF
				var lo_raw := INF; var hi_raw := -INF
				var lo_dish := INF; var hi_dish := -INF
				var lo_tilt := INF; var hi_tilt := -INF
				for j in range(lo, hi):
					var mid := mids[j]
					var line := ls[j] - rs[j]
					lo_mid = minf(lo_mid, band[j]); hi_mid = maxf(hi_mid, band[j])
					lo_raw = minf(lo_raw, raw_band[j]); hi_raw = maxf(hi_raw, raw_band[j])
					lo_dish = minf(lo_dish, dish[j]); hi_dish = maxf(hi_dish, dish[j])
					lo_tilt = minf(lo_tilt, tilt[j] * hw[j]); hi_tilt = maxf(hi_tilt, tilt[j] * hw[j])
					acc.mid2 += mid * mid
					acc.raw_mid2 += raw_mids[j] * raw_mids[j]
					acc.tilt_var2 += tvs[j] * tvs[j]
					acc.dish_abs += absf(dish[j])
					acc.line2 += line * line
					acc.shoulder += shoulder[j]
				notice = hi_mid - lo_mid >= NOTICE
				raw_notice = hi_raw - lo_raw >= NOTICE
				regular = hi_mid - lo_mid < REGULAR.x and hi_dish - lo_dish < REGULAR.y and hi_tilt - lo_tilt < REGULAR.z
			var key: String = t.kind + ("/плоско" if slope < 0.03 else "/склон")
			for name: String in [key, t.kind]:
				if not groups.has(name): groups[name] = {windows = 0, pinned = 0, notice = 0, raw_notice = 0, regular = 0, mid2 = 0.0, raw_mid2 = 0.0,
					tilt_var2 = 0.0, dish_abs = 0.0, line2 = 0.0, shoulder = 0.0, grade = PackedFloat64Array(), samples = 0}
				var g: Dictionary = groups[name]
				g.windows += 1
				if pinned:
					g.pinned += 1
					continue
				for field: String in acc: g[field] += acc[field]
				g.notice += int(notice)
				g.raw_notice += int(raw_notice)
				g.regular += int(regular)
				g.samples += WINDOW
				g.grade = (g.grade as PackedFloat64Array) + grade.slice(lo, hi)
	var result := {}
	for name: String in groups:
		var g: Dictionary = groups[name]
		var free: int = g.windows - g.pinned
		var s: int = maxi(1, g.samples)
		var grades: PackedFloat64Array = g.grade
		grades.sort()
		result[name] = {km = g.windows * WINDOW / 1000.0, pinned = float(g.pinned) / maxi(1, g.windows),
			notice = float(g.notice) / maxi(1, free), raw_notice = float(g.raw_notice) / maxi(1, free), regular = float(g.regular) / maxi(1, free),
			mid_rms_cm = sqrt(g.mid2 / s) * 100.0, raw_mid_rms_cm = sqrt(g.raw_mid2 / s) * 100.0,
			tilt_var_pct = sqrt(g.tilt_var2 / s) * 100.0, dish_cm = g.dish_abs / s * 100.0,
			lines_cm = sqrt(g.line2 / s) * 100.0, shoulder_cm = g.shoulder / s * 100.0,
			grade1_p99 = grades[int(grades.size() * 0.99)] if not grades.is_empty() else 0.0,
			grade1_max = grades[-1] if not grades.is_empty() else 0.0}
	return result


## Заезд по участку с 8 м/с, руль держит ось (точка в 5 м впереди).
func _ride(w: WorldData, h: Heightfield, s: Dictionary, with_clutter := false) -> Dictionary:
	var st := _stations(w.trails[s.route])
	var ps: PackedVector2Array = st.p
	var from: int = maxi(0, s.station - 25)
	var b := BikeRide.new()
	var p := PlayerState.new()
	var control := BikeController.new()
	b.x = ps[from].x
	b.z = ps[from].y
	var ahead := ps[mini(ps.size() - 1, from + 5)] - ps[from]
	b.heading = atan2(-ahead.x, -ahead.y)
	b.y = h.ground_at(b.x, b.z)
	b.mount(p)
	b.speed = 8.0
	var hz := 60
	var dt := 1.0 / hz
	var near := from
	var travel := PackedFloat64Array()
	var accel := 0.0
	var vy_prev := 0.0
	var off := 0.0
	var ticks := 0
	var air := 0
	var fill_at := Vector2.INF
	if with_clutter:
		h.obstacles = ForestObstacles.new(w, h)
	for tick in ceili(hz * ride_metres / 7.0):
		var pos := Vector2(b.x, b.z)
		if with_clutter and pos.distance_squared_to(fill_at) >= 35.0 * 35.0:
			_clutter_at(pos, false)
			h.obstacles.update(pos.x, pos.y, vegetation.obstacles, vegetation.obstacles_version, true)
			h.obstacles.set_bumps(vegetation.bumps, vegetation.obstacles_version)
			fill_at = pos
		var best := INF
		for j in range(near, mini(ps.size(), near + 12)):
			var d := pos.distance_squared_to(ps[j])
			if d < best: best = d; near = j
		if near >= mini(ps.size() - 6, from + ride_metres): break
		var goal := ps[mini(ps.size() - 1, near + 5)] - pos
		var want := atan2(-goal.x, -goal.y)
		var steer := clampf(-wrapf(want - b.heading, -PI, PI) * 2.5, -1.0, 1.0)
		var throttle := clampf((8.0 - b.speed) * 0.6, -1.0, 1.0)
		var y0 := b.y
		control.ride(dt, p, b, w, h, throttle, steer, false, false, false)
		var vy := (b.y - y0) / dt
		if tick > 0: accel += pow((vy - vy_prev) / dt, 2)
		vy_prev = vy
		travel.append(b.squash_f)
		travel.append(b.squash_r)
		off += sqrt(best)
		air += int(b.airborne)
		ticks += 1
		if b.crashed: break
	var mean := 0.0
	for v in travel: mean += v
	mean /= maxi(1, travel.size())
	var var2 := 0.0
	var lo := INF
	var hi := -INF
	for v in travel:
		var2 += (v - mean) * (v - mean)
		lo = minf(lo, v)
		hi = maxf(hi, v)
	return {metres = (near - from), ticks = ticks, crashed = b.crashed, crash_cause = BikeRide.CrashCause.keys()[b.crash_cause],
		airborne_ticks = air, axis_offset_m = off / maxi(1, ticks),
		travel_rms_cm = sqrt(var2 / maxi(1, travel.size())) * 100.0, travel_range_cm = (hi - lo) * 100.0,
		vertical_accel_rms = sqrt(accel / maxi(1, ticks - 1))}


func _clutter_at(at: Vector2, trees: bool) -> Dictionary:
	var started := Time.get_ticks_usec()
	if trees:
		vegetation.update(at.x, at.y, true)
	else:
		vegetation._fill_details(at.x, at.y, Vector2.ZERO, 0, 0.0, true)
		vegetation._apply_grass(true)
	var counts := {}
	for kind: int in [Floor.BRANCH, Floor.STONES, Floor.LOG, Floor.MOSS_LOG, Floor.BOULDER, Floor.ROOT_SPAN]:
		var group_id := Floor.FIRST + kind
		var group: MultiMesh = vegetation.understory[group_id].mm
		counts[kind] = group.visible_instance_count
		if vegetation._far_of.has(group_id):
			var distant: MultiMesh = vegetation.understory[vegetation._far_of[group_id]].mm
			counts[kind] += distant.visible_instance_count
	var parts: Dictionary = vegetation.get("road_clutter_stats").duplicate(true) if "road_clutter_stats" in vegetation else {}
	if "road_clutter_stats" in vegetation:
		var bumps := 0
		for kind: int in [RoadObstacles.BRANCH, RoadObstacles.STONES, RoadObstacles.ROOT]:
			var part: Dictionary = parts.get(kind, {})
			bumps += int(part.get("CONTACT", 0))
			if kind == RoadObstacles.STONES: continue # shared with the forest floor
			var mesh_kind := Floor.BRANCH if kind == RoadObstacles.BRANCH else Floor.ROOT_SPAN
			if counts[mesh_kind] != int(part.get("VISUAL", 0)) + int(part.get("CONTACT", 0)):
				clutter_mismatches += 1
				printerr("ROAD CLUTTER: missing MultiMesh instances of kind ", kind, " at ", at)
		if vegetation.bumps.size() / 6 < bumps:
			clutter_mismatches += 1
			printerr("ROAD CLUTTER: missing wheel contacts at ", at)
	return {
		road_parts = parts,
		multimesh_counts = counts, capsules = vegetation.obstacles.size() / 7, bumps = vegetation.bumps.size() / 6,
		fill_and_upload_ms = (Time.get_ticks_usec() - started) / 1000.0,
	}


func _nearest_root(at: Vector2) -> Vector2:
	var entry: Dictionary = vegetation.understory[Floor.FIRST + Floor.ROOT_SPAN]
	var buffer: PackedFloat32Array = entry.buf
	var best := Vector2.INF
	for i in entry.count:
		var offset: int = i * VegetationLayer.STRIDE
		var point := Vector2(buffer[offset + 3], buffer[offset + 11])
		if at.distance_squared_to(point) < at.distance_squared_to(best):
			best = point
	return best


## Высоты участка для чертежа: ось и две линии движения ±0,5 полуширины на ±30 м, три поперечника
func _profile(h: Heightfield, s: Dictionary) -> Dictionary:
	var w := h.world
	var st := _stations(w.trails[s.route])
	var ps: PackedVector2Array = st.p
	var hw: PackedFloat32Array = st.half
	var axis := []
	for j in range(s.station - 30, s.station + 31):
		var nn := _normal(ps, j)
		var half := hw[j]
		axis.append([h.ground_at(ps[j].x, ps[j].y), h.ground_at(ps[j].x - nn.x * half * 0.5, ps[j].y - nn.y * half * 0.5),
			h.ground_at(ps[j].x + nn.x * half * 0.5, ps[j].y + nn.y * half * 0.5), h.ground_at(ps[j].x, ps[j].y, true)])
	var cuts := []
	for off in [-12, 0, 12]:
		var j: int = s.station + off
		var nn := _normal(ps, j)
		var row := []
		for k in range(-24, 25):
			var d := k * 0.25
			row.append(h.ground_at(ps[j].x + nn.x * d, ps[j].y + nn.y * d))
		cuts.append(row)
	return {axis = axis, cuts = cuts, half = hw[s.station]}


func _scene() -> void:
	DisplayServer.window_set_size(Vector2i(1000, 562))
	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	var sky := Sky.new()
	sky.sky_material = ProceduralSkyMaterial.new()
	env.environment.background_mode = Environment.BG_SKY
	env.environment.sky = sky
	env.environment.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.environment.ambient_light_energy = 0.4
	env.environment.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	root.add_child(env)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-24.0, 35.0, 0.0)
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 120.0
	root.add_child(sun)
	mesh_node = MeshInstance3D.new()
	root.add_child(mesh_node)
	camera = Camera3D.new()
	camera.fov = 70.0
	camera.far = 140.0
	root.add_child(camera)
	camera.make_current()


func _shoot(w: WorldData, h: Heightfield, seed_text: String, s: Dictionary) -> void:
	var st := _stations(w.trails[s.route])
	var ps: PackedVector2Array = st.p
	var hw: PackedFloat32Array = st.half
	var j: int = s.station
	var box := Rect2(ps[j], Vector2.ZERO)
	for k in range(maxi(0, j - 60), mini(ps.size(), j + 60)): box = box.expand(ps[k])
	box = box.grow(155.0)
	var cells := Rect2i(Vector2i((box.position / TILE).floor()), Vector2i((box.size / TILE).ceil()) + Vector2i.ONE)
	var arrays := TerrainBuilder.build_arrays(w, h, cells)
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh.surface_set_material(0, terrain_material)
	mesh_node.mesh = mesh
	var back := ps[maxi(0, j - 9)]
	var nn := _normal(ps, j)
	var views := {
		ride = [Vector3(back.x + nn.x * 0.4, h.ground_at(back.x, back.y) + 1.35, back.y + nn.y * 0.4), ps[mini(ps.size() - 1, j + 14)], 0.2],
		side = [_side_camera(h, ps[j], nn, hw[j]), ps[j], 0.0],
	}
	for view: String in views:
		var v: Array = views[view]
		var target: Vector2 = v[1]
		camera.look_at_from_position(v[0], Vector3(target.x, h.ground_at(target.x, target.y) + float(v[2]), target.y), Vector3.UP)
		for f in 3: await process_frame
		await RenderingServer.frame_post_draw
		var name := "%s_%s_%s.png" % [seed_text, s.kind, view]
		root.get_texture().get_image().save_png(out.path_join(name))
		if base_dir != "" and FileAccess.file_exists(base_dir.path_join(name)):
			var before := Image.load_from_file(base_dir.path_join(name))
			var after := Image.load_from_file(out.path_join(name))
			var pair := Image.create(before.get_width() + after.get_width() + 8, before.get_height(), false, Image.FORMAT_RGB8)
			pair.fill(Color.BLACK)
			before.convert(Image.FORMAT_RGB8)
			after.convert(Image.FORMAT_RGB8)
			pair.blit_rect(before, Rect2i(Vector2i.ZERO, before.get_size()), Vector2i.ZERO)
			pair.blit_rect(after, Rect2i(Vector2i.ZERO, after.get_size()), Vector2i(before.get_width() + 8, 0))
			pair.resize(pair.get_width() / 2, pair.get_height() / 2, Image.INTERPOLATE_BILINEAR)
			pair.save_jpg(out.path_join("pair_" + name.get_basename() + ".jpg"), 0.9)


## Сбоку и чуть сверху: над землёй у камеры и над полотном, чтобы склон между ними не закрывал вид
func _side_camera(h: Heightfield, at: Vector2, nn: Vector2, half: float) -> Vector3:
	var from := at + nn * (half + 12.0)
	var top := maxf(h.ground_at(from.x, from.y), h.ground_at(at.x, at.y))
	for k in range(1, 12):
		var q := at + nn * (half + k)
		top = maxf(top, h.ground_at(q.x, q.y) - k * 0.15)
	return Vector3(from.x, top + 3.0, from.y)


func _print(seed_text: String, row: Dictionary) -> void:
	var timing := "warm median %.0f ms" % row.finish_warm_median_ms if row.has("finish_warm_median_ms") else "single run"
	print("PROBE ", seed_text, " finish_paths ", timing, ", runs ", row.finish_ms)
	var names: Array = row.metrics.keys()
	names.sort()
	for name: String in names:
		var m: Dictionary = row.metrics[name]
		print("  %-16s %6.1f км закреп %3.0f%% | заметно %3.0f%% (природа %3.0f%%) гладко %3.0f%% | средние %4.1f (природа %4.1f) см | перекос %4.2f%% выпукл %4.1f см линии %4.1f см обочина %4.1f см | шаг1м p99 %.3f max %.3f" % [
			name, m.km, m.pinned * 100, m.notice * 100, m.raw_notice * 100, m.regular * 100, m.mid_rms_cm, m.raw_mid_rms_cm, m.tilt_var_pct, m.dish_cm,
			m.lines_cm, m.shoulder_cm, m.grade1_p99, m.grade1_max])
	for s: Dictionary in row.sections:
		var r: Dictionary = s.ride
		print("  участок %s путь %d ст.%d (%s): заезд %d м, падение %s, полёт %d, ось %.2f м, подвеска rms %.2f см размах %.1f см, верт.ускор rms %.2f" % [
			s.kind, s.route, s.station, s.surface_name, r.metres, r.crashed, r.airborne_ticks, r.axis_offset_m, r.travel_rms_cm, r.travel_range_cm, r.vertical_accel_rms])


## Сводка «было → стало» по probe.json двух прогонов и чертежи профилей (серым было, цветом стало)
func _compare() -> void:
	var path := base_dir.path_join("probe.json")
	if not FileAccess.file_exists(path): return
	var before: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(path))
	var lines := PackedStringArray()
	for seed_text: String in summary:
		if not before.has(seed_text): continue
		var a: Dictionary = before[seed_text]
		var b: Dictionary = summary[seed_text]
		if a.finish_ms.size() > 1 and b.finish_ms.size() > 1:
			var before_ms := _warm_median(a.finish_ms)
			var after_ms := _warm_median(b.finish_ms)
			lines.append("%s: finish_paths %.0f → %.0f мс (%+.0f%%)" % [seed_text, before_ms, after_ms,
				(after_ms / before_ms - 1.0) * 100.0])
		else:
			lines.append("%s: геометрия сопоставима, замер времени с одним прогоном исключён" % seed_text)
		for name: String in b.metrics:
			if not a.metrics.has(name): continue
			var x: Dictionary = a.metrics[name]
			var y: Dictionary = b.metrics[name]
			lines.append("  %-16s заметно %3.0f→%3.0f%% гладко %3.0f→%3.0f%% средние %4.1f→%4.1f см перекос %4.2f→%4.2f%% выпукл %4.1f→%4.1f линии %4.1f→%4.1f обочина %4.1f→%4.1f шаг p99 %.3f→%.3f max %.3f→%.3f" % [
				name, x.notice * 100, y.notice * 100, x.regular * 100, y.regular * 100, x.mid_rms_cm, y.mid_rms_cm, x.tilt_var_pct, y.tilt_var_pct,
				x.dish_cm, y.dish_cm, x.lines_cm, y.lines_cm, x.shoulder_cm, y.shoulder_cm, x.grade1_p99, y.grade1_p99, x.grade1_max, y.grade1_max])
		var path_a := base_dir.path_join(seed_text + "_stations.bin")
		var path_b := out.path_join(seed_text + "_stations.bin")
		if FileAccess.file_exists(path_a) and FileAccess.file_exists(path_b):
			lines.append_array(_diff(FileAccess.open(path_a, FileAccess.READ).get_var(), FileAccess.open(path_b, FileAccess.READ).get_var(), seed_text))
		for k in b.sections.size():
			var sb: Dictionary = b.sections[k]
			var sa: Dictionary = {}
			for s: Dictionary in a.sections:
				if s.kind == sb.kind and s.route == sb.route and s.station == sb.station: sa = s
			if sa.is_empty(): continue
			lines.append("  участок %s (%s): подвеска rms %.2f→%.2f см, размах %.1f→%.1f, верт.ускор %.2f→%.2f, падение %s→%s, полёт %d→%d" % [
				sb.kind, sb.surface_name, sa.ride.travel_rms_cm, sb.ride.travel_rms_cm, sa.ride.travel_range_cm, sb.ride.travel_range_cm,
				sa.ride.vertical_accel_rms, sb.ride.vertical_accel_rms, sa.ride.crashed, sb.ride.crashed, sa.ride.airborne_ticks, sb.ride.airborne_ticks])
			_draw_profile(seed_text, sb, sa)
	var text := "\n".join(lines)
	print("PROBE COMPARE\n", text)
	FileAccess.open(out.path_join("compare.txt"), FileAccess.WRITE).store_string(text)


## Насколько изменилась конечная поверхность на тех же станциях: доля длины с изменением оси больше 5 и 10 см,
## доля с изменённым поперечным сечением (перекос или выпуклость сдвинулись больше 3 см), СКО изменений
func _diff(was: Dictionary, now: Dictionary, seed_text: String) -> PackedStringArray:
	var w: WorldData = null
	var kinds := {}
	var fixture := fixtures.path_join(seed_text + ".fixture.bin")
	var trails: Array = []
	if FileAccess.file_exists(fixture):
		var saved: Dictionary = FileAccess.open(fixture, FileAccess.READ).get_var()
		w = WorldCache.new()._restore(saved.world, true)
		trails = w.trails
	for route: int in now:
		if not was.has(route): continue
		var a: PackedFloat32Array = was[route]
		var b: PackedFloat32Array = now[route]
		var kind: String = trails[route].kind if route < trails.size() else "?"
		if not kinds.has(kind): kinds[kind] = {n = 0, c5 = 0, c10 = 0, cross = 0, dc2 = 0.0, dt2 = 0.0, dd2 = 0.0}
		var g: Dictionary = kinds[kind]
		for j in mini(a.size(), b.size()) / 6:
			if b[j * 6 + 5] != 0.0: continue
			var dc := b[j * 6] - a[j * 6]
			var dt := (b[j * 6 + 4] - b[j * 6 + 3]) - (a[j * 6 + 4] - a[j * 6 + 3])
			var dd := (b[j * 6] - (b[j * 6 + 3] + b[j * 6 + 4]) * 0.5) - (a[j * 6] - (a[j * 6 + 3] + a[j * 6 + 4]) * 0.5)
			g.n += 1
			g.c5 += int(absf(dc) >= 0.05)
			g.c10 += int(absf(dc) >= 0.10)
			g.cross += int(absf(dt) >= 0.03 or absf(dd) >= 0.03)
			g.dc2 += dc * dc
			g.dt2 += dt * dt
			g.dd2 += dd * dd
	var lines := PackedStringArray()
	for kind: String in kinds:
		var g: Dictionary = kinds[kind]
		var n := maxi(1, g.n)
		lines.append("  изменение %-9s %6.1f км: ось ≥5 см %3.0f%%, ≥10 см %3.0f%%, поперечник ≥3 см %3.0f%% | СКО ось %.1f см, перекос края %.1f см, выпукл %.1f см" % [
			kind, g.n / 1000.0, 100.0 * g.c5 / n, 100.0 * g.c10 / n, 100.0 * g.cross / n, sqrt(g.dc2 / n) * 100.0, sqrt(g.dt2 / n) * 100.0, sqrt(g.dd2 / n) * 100.0])
	return lines


func _draw_profile(seed_text: String, now: Dictionary, was: Dictionary) -> void:
	var img := Image.create(1200, 560, false, Image.FORMAT_RGB8)
	img.fill(Color(0.97, 0.97, 0.95))
	# продольный: 60 м на 1160 пикселей, высота относительно оси «было» в середине, 1 м = 200 пикселей (×10 к горизонтали)
	var a_axis: Array = was.profile.axis
	var b_axis: Array = now.profile.axis
	# высоты относительно скользящего среднего ±10 м оси «было»: видны средние формы, а не холм, на котором лежит участок
	var ref := PackedFloat64Array()
	for k in a_axis.size():
		var sum := 0.0
		var num := 0
		for q in range(maxi(0, k - 10), mini(a_axis.size(), k + 11)):
			sum += float(a_axis[q][0])
			num += 1
		ref.append(sum / num)
	var rows := [[a_axis, 0, Color(0.6, 0.6, 0.6)], [a_axis, 3, Color(0.75, 0.85, 0.75)], [b_axis, 1, Color(0.2, 0.45, 0.9)],
		[b_axis, 2, Color(0.9, 0.45, 0.2)], [b_axis, 0, Color(0.05, 0.05, 0.05)]]
	for row: Array in rows:
		var data: Array = row[0]
		var prev := Vector2i(-1, -1)
		for k in data.size():
			var y := float(data[k][row[1]]) - ref[k]
			var p := Vector2i(20 + k * 1160 / 60, 160 - int(y * 200.0))
			if prev.x >= 0: _line(img, prev, p, row[2])
			prev = p
	# поперечники: 12 м на 380 пикселей каждый, 1 м = 120 пикселей (×4)
	for c in 3:
		for pair: Array in [[was.profile.cuts[c], Color(0.6, 0.6, 0.6)], [now.profile.cuts[c], Color(0.05, 0.05, 0.05)]]:
			var data: Array = pair[0]
			var mid: float = was.profile.cuts[c][24]
			var prev := Vector2i(-1, -1)
			for k in data.size():
				var p := Vector2i(20 + c * 395 + k * 380 / 48, 430 - int((float(data[k]) - mid) * 120.0))
				if prev.x >= 0: _line(img, prev, p, pair[1])
				prev = p
		var half: float = now.profile.half
		for sgn in [-1, 1]:
			var x := 20 + c * 395 + int((24 + sgn * half * 4.0) * 380 / 48)
			_line(img, Vector2i(x, 330), Vector2i(x, 340), Color(0.8, 0.2, 0.2))
	img.save_png(out.path_join("profile_%s_%s.png" % [seed_text, now.kind]))


func _line(img: Image, a: Vector2i, b: Vector2i, color: Color) -> void:
	var n := maxi(absi(b.x - a.x), absi(b.y - a.y))
	for k in n + 1:
		var p := Vector2(a).lerp(Vector2(b), float(k) / maxi(1, n))
		var x := roundi(p.x)
		var y := roundi(p.y)
		if x >= 0 and y >= 0 and x < img.get_width() and y < img.get_height():
			img.set_pixel(x, y, color)
			if y + 1 < img.get_height(): img.set_pixel(x, y + 1, color)
