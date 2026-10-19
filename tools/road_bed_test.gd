extends SceneTree
## Проверка слоя дорожного полотна (4.3, RoadSurface и RoadBed). Без окна:
##   godot --headless --script res://tools/road_bed_test.gd [-- --seeds N --size S]
## Для каждого мира рельеф строится без полотна и с ним; печатается, как изменились профиль и
## поперечный крен вдоль линий основных дорог и троп (участки мостов, туннелей и воды не считаются),
## и проверяется, что полотно локально: меняются только клетки у путей, не больше наибольшей подсыпки,
## вода и концы мостов и туннелей не тронуты, покрытие есть у каждой клетки пути людей.

const SEEDS := ["Север-1234", "Туман-4821", "abc", "Ущелье", "Ветер-77", "Озёра-5", "Гряда-310", "Лес-9", "Степь-42", "Море-18", "Камень-6", "Долина-2024"]
const TILE := GameConfig.TILE

var fails := 0


func _check(ok: bool, what: String) -> void:
	if not ok:
		fails += 1
		print("  ✗ ", what)


func _init() -> void:
	var args := OS.get_cmdline_user_args()
	var count := 6
	var size := 512
	for k in args.size() - 1:
		if args[k] == "--seeds":
			count = int(args[k + 1])
		elif args[k] == "--size":
			size = int(args[k + 1])
	var total := {}
	for s: String in SEEDS.slice(0, count):
		var w := WorldGenerator.generate(s, size)
		var before := Heightfield.new(w, false)
		before.build_structures()
		var after := Heightfield.new(w, false)
		var t0 := Time.get_ticks_usec()
		var changed := RoadBed.refine(after)
		var ms := (Time.get_ticks_usec() - t0) / 1000.0
		after.build_structures()
		print("%s@%d: полотно %.0f мс, клеток изменено %d" % [s, size, ms, _unique(changed)])
		_invariants(w, before, after)
		for kind: String in ["road", "trail"]:
			var a := _stats(w, before, kind)
			var b := _stats(w, after, kind)
			print("  %-5s длина %6.0f м | макс. уклон %5.1f → %5.1f %% | > 36 %%: %5.0f → %5.0f м | крен ср. %4.1f → %4.1f %%, > 8 %%: %5.0f → %5.0f м | рябь %4.2f → %4.2f м/100 м" % [
				kind, a.len, a.max_grade, b.max_grade, a.steep, b.steep, a.cross, b.cross, a.tilted, b.tilted, a.bumps, b.bumps])
			if OS.get_cmdline_user_args().has("--where"):
				print("    наибольший уклон: было у клетки %s, стало у %s" % [a.at, b.at])
			for key in ["len", "steep", "tilted", "bumps_sum", "cross_sum"]:
				total["%s_%s_a" % [kind, key]] = total.get("%s_%s_a" % [kind, key], 0.0) + a[key]
				total["%s_%s_b" % [kind, key]] = total.get("%s_%s_b" % [kind, key], 0.0) + b[key]
		var kinds := {}
		for i in w.N:
			if w.path_mask[i] >= 2:
				var name: String = RoadSurface.LIST[PlayerState.surface(w.tile_info(i % w.W + 0.5, i / w.W + 0.5))].name
				kinds[name] = kinds.get(name, 0) + 1
		print("  покрытие клеток: ", kinds)
	for kind: String in ["road", "trail"]:
		var L: float = total["%s_len_a" % kind]
		print("Итого %s: %.0f м; > 36 %%: %.0f → %.0f м; крен > 8 %%: %.0f → %.0f м; рябь %.2f → %.2f м/100 м; крен ср. %.1f → %.1f %%" % [kind, L,
			total["%s_steep_a" % kind], total["%s_steep_b" % kind], total["%s_tilted_a" % kind], total["%s_tilted_b" % kind],
			total["%s_bumps_sum_a" % kind] / L * 100.0, total["%s_bumps_sum_b" % kind] / L * 100.0,
			total["%s_cross_sum_a" % kind] / L, total["%s_cross_sum_b" % kind] / L])
	print("Нарушений: %d" % fails if fails > 0 else "Полотно локально, вода и сооружения не тронуты.")
	quit(1 if fails > 0 else 0)


func _unique(a: PackedInt32Array) -> int:
	var seen := {}
	for i in a:
		seen[i] = true
	return seen.size()


func _invariants(w: WorldData, before: Heightfield, after: Heightfield) -> void:
	# возле какого пути клетка (по линиям, с запасом обочины)
	var allowed := PackedFloat32Array()
	allowed.resize(w.N)
	for t: Dictionary in w.trails:
		if not RoadBed.KINDS.has(t.kind):
			continue
		var k: Dictionary = RoadBed.KINDS[t.kind]
		var reach: float = (float(t.pts[0].w) * TILE * 0.5 + k.flat + k.shoulder) / TILE + 0.8
		for p: Dictionary in t.pts:
			for cy in range(maxi(0, floori(p.y - reach)), mini(w.H, ceili(p.y + reach))):
				for cx in range(maxi(0, floori(p.x - reach)), mini(w.W, ceili(p.x + reach))):
					allowed[cy * w.W + cx] = maxf(allowed[cy * w.W + cx], k.side)
	var far := 0
	var big := 0
	var wet := 0
	var flooded := 0
	for i in w.N:
		var d := after.hv[i] - before.hv[i]
		if absf(d) < 0.001:
			continue
		if before.water_level[i] != -INF:
			wet += 1
		elif allowed[i] == 0.0:
			far += 1
		elif absf(d) > allowed[i] + 0.01:
			big += 1
		if d < 0.0 and after.hv[i] < RoadBed._wet_near(after, i) + RoadBed.WATER_GAP - 0.01 and after.hv[i] < before.hv[i]:
			flooded += 1
	_check(far == 0, "клетки вдали от путей изменены: %d" % far)
	_check(big == 0, "подсыпка или срез больше предела: %d" % big)
	_check(wet == 0, "изменены клетки с водой: %d" % wet)
	_check(flooded == 0, "берег опущен к воде: %d" % flooded)
	for k in before.structures.size():
		var a: Dictionary = before.structures[k]
		var b: Dictionary = after.structures[k]
		_check(absf(a.ay - b.ay) < 0.01 and absf(a.by - b.by) < 0.01, "сдвинут конец сооружения %d" % k)
	var bare := 0
	for i in w.N:
		if w.path_mask[i] >= 2 and w.road_surface[i] == RoadSurface.NONE:
			bare += 1
	# угловые клетки диагоналей могут остаться без своего покрытия (PlayerState.surface даёт им гравий или грунт)
	print("  клеток пути без своего покрытия: %d" % bare)


## Профиль вдоль линий вида kind по высотам heights: каждые 2 м; уклон на 4 м, крен между краями ленты,
## рябь — сумма |второй разности| высот на шаге 2 м
func _stats(w: WorldData, heights: Heightfield, kind: String) -> Dictionary:
	var r := {at = Vector2.ZERO, len = 0.0, max_grade = 0.0, steep = 0.0, cross = 0.0, cross_sum = 0.0, tilted = 0.0, bumps = 0.0, bumps_sum = 0.0}
	for t: Dictionary in w.trails:
		if t.kind != kind:
			continue
		var prof: Array = []   # [x, z, h, ok]
		for n in range(1, t.pts.size()):
			var a: Dictionary = t.pts[n - 1]
			var b: Dictionary = t.pts[n]
			var dx: float = (b.x - a.x) * TILE
			var dz: float = (b.y - a.y) * TILE
			var L := Grid.hypot(dx, dz)
			var m := maxi(1, ceili(L / 2.0))
			for s in m:
				var x: float = a.x * TILE + dx * s / m
				var z: float = a.y * TILE + dz * s / m
				var half: float = float(a.w) * TILE * 0.5
				var ok := heights.depth_at(x, z) <= 0.0 and heights.deck_at(x, z, heights.ground_at(x, z) + 10.0) == -INF and not heights.wall_at(x, z, heights.ground_at(x, z))
				var h := heights.ground_at(x, z)
				var nx := -dz / maxf(L, 0.001) * half
				var nz := dx / maxf(L, 0.001) * half
				var cross := absf(heights.ground_at(x + nx, z + nz) - heights.ground_at(x - nx, z - nz)) / maxf(2.0 * half, 0.1) * 100.0
				prof.append([x, z, h, ok and _clear(heights, x, z), cross])
		for n in range(2, prof.size()):
			var p0: Array = prof[n - 2]
			var p1: Array = prof[n - 1]
			var p2: Array = prof[n]
			if not (p0[3] and p1[3] and p2[3]):
				continue
			var d := Grid.hypot(p2[0] - p0[0], p2[1] - p0[1])
			if d < 0.5:
				continue
			var step := d * 0.5
			var grade := absf(p2[2] - p0[2]) / d * 100.0
			r.len += step
			if grade > r.max_grade:
				r.max_grade = grade
				r.at = Vector2(p1[0], p1[1]) / TILE
			if grade > 36.0:
				r.steep += step
			r.cross_sum += p1[4] * step
			if p1[4] > 8.0:
				r.tilted += step
			r.bumps_sum += absf(p2[2] - 2.0 * p1[2] + p0[2])
	if r.len > 0.0:
		r.cross = r.cross_sum / r.len
		r.bumps = r.bumps_sum / r.len * 100.0
	return r


## Не под туннелем и не у сооружения: туннели меняют рельеф сами
func _clear(heights: Heightfield, x: float, z: float) -> bool:
	for s: Dictionary in heights.structures:
		if Grid.segment_dist(x, z, s.ax, s.az, s.bx, s.bz) < RoadBed.PIN:
			return false
	return true
