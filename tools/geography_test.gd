extends SceneTree
## География на разных сидах: сток, поселения, стыки кусков и совпадение C#/GDScript.
## Печатает высоты, крутизну и площади связных горных участков. Полный прогон — 12 миров по 512 клеток;
## -- --quick — четыре мира самопроверки; -- --out <файл.json> — сохранить сводку.

const SelfTest := preload("res://tools/selftest.gd")
const Dev := preload("res://tools/control/control.gd")
const SEEDS := ["Север-1234", "Туман-4821", "Ущелье", "Янтарь-5150", "a1", "b2", "c3", "d4", "e5", "f6", "g7", "h8"]

var _fails := 0


func _check(ok: bool, what: String) -> void:
	if not ok:
		printerr("✗ " + what)
		_fails += 1


## Прямоугольник пересекает край карты или границу внешних кусков, включая отрицательные координаты.
## Высота в клетке не должна зависеть от размера и порядка расчёта прямоугольников.
func _relief_check(w: WorldData) -> void:
	var fast := Grid.fast_grid()
	# В начале координат noise = 0. При подходе с обеих сторон высота гребня одна:
	# асимметрия после скругления раньше давала здесь скачок даже при бесконечно малом шаге
	for d: Vector2 in [Vector2(0.0001, 0.0001), Vector2(0.0001, -0.0001)]:
		for interior in [0.0, 1.0]:
			for k in 3:
				var a := StageRelief._crest(w.noise.ridge, d.x, d.y, StageRelief.DIR_C[k], StageRelief.DIR_S[k], StageRelief.ASYM, 0.0, interior)
				var b := StageRelief._crest(w.noise.ridge, -d.x, -d.y, StageRelief.DIR_C[k], StageRelief.DIR_S[k], StageRelief.ASYM, 0.0, interior)
				_check(absf(a - b) < 1e-5, "%s: непрерывность гребня и внутренних долин" % w.seed_text)
	var top := 0
	for i in w.N:
		if w.h[i] > w.h[top]:
			top = i
	for p: Vector2i in [Vector2i(-65, -2), Vector2i(-1025, 767), Vector2i(w.W - 2, w.H - 2), Vector2i(top % w.W - 2, top / w.W - 2)]:
		var whole := StageRelief.raw_rect(w, p.x, p.y, 6, 4, false)
		var left := StageRelief.raw_rect(w, p.x, p.y, 3, 4, false)
		var right := StageRelief.raw_rect(w, p.x + 3, p.y, 3, 4, false)
		var gd := StageRelief._rows(w, p.x, p.y, 6, 0, 4)
		for y in 4:
			for x in 6:
				var i := y * 6 + x
				var part := left[y * 3 + x] if x < 3 else right[y * 3 + x - 3]
				_check(whole[i] == part, "%s: стык рельефа %s" % [w.seed_text, p])
				_check(whole[i] == gd[i], "%s: C#/GDScript %s" % [w.seed_text, p])
	_check(fast != null, "для сравнения C#/GDScript нужна сборка Godot .NET")


func _world_check(w: WorldData) -> void:
	var bad_height := 0
	var uphill := 0
	var wet_huts := 0
	var bad_climate := 0
	var bad_biomes := 0
	for i in w.N:
		if not is_finite(w.h[i]):
			bad_height += 1
		if not is_finite(w.temp[i]) or not is_finite(w.moist[i]) or not is_finite(w.slope[i]) or w.temp[i] < 0.0 or w.temp[i] > 1.0 or w.moist[i] < 0.0 or w.moist[i] > 1.0 or w.slope[i] < 0.0:
			bad_climate += 1
		if w.biome[i] >= Biomes.LIST.size() or (w.lake[i] != 0 and w.biome[i] != Biomes.LAKE) or (w.ocean[i] == 0 and w.lake[i] == 0 and w.biome[i] <= Biomes.LAKE):
			bad_biomes += 1
		var d := w.down[i]
		if w.river[i] != 0 and d >= 0 and w.ocean[d] == 0 and w.lake[d] == 0 and w.h[d] > w.h[i] + 1e-6:
			uphill += 1
	for s: Dictionary in w.settlements:
		_check(w.ocean[s.i] == 0 and w.lake[s.i] == 0 and w.river[s.i] == 0, "%s: поселение на суше" % w.seed_text)
		for h: Dictionary in s.huts:
			var i := floori(h.y) * w.W + floori(h.x)
			if w.ocean[i] != 0 or w.lake[i] != 0 or w.river[i] != 0:
				wet_huts += 1
	_check(bad_height == 0, "%s: конечные высоты (%d)" % [w.seed_text, bad_height])
	_check(uphill == 0, "%s: сток рек вниз (%d)" % [w.seed_text, uphill])
	_check(wet_huts == 0, "%s: дома на суше (%d)" % [w.seed_text, wet_huts])
	_check(bad_climate == 0, "%s: конечные и допустимые значения климата/уклона (%d)" % [w.seed_text, bad_climate])
	_check(bad_biomes == 0, "%s: биомы согласованы с сушей и озёрами (%d)" % [w.seed_text, bad_biomes])
	_check(SelfTest.settlements_connected(w), "%s: поселения связаны" % w.seed_text)


func _stats(w: WorldData) -> Dictionary:
	var land := 0
	var mountains := 0
	var steep := 0
	var high := 0
	var hills := 0
	var steep_land := 0
	var gentle_mountains := 0
	var curvature := 0.0
	var max_height := 0.0
	for y in range(1, w.H - 1):
		for x in range(1, w.W - 1):
			var i := y * w.W + x
			if w.ocean[i] != 0 or w.lake[i] != 0:
				continue
			land += 1
			var h := w.h[i] * GameConfig.HS
			max_height = maxf(max_height, h)
			var l := w.h[i - 1] * GameConfig.HS
			var r := w.h[i + 1] * GameConfig.HS
			var u := w.h[i - w.W] * GameConfig.HS
			var d := w.h[i + w.W] * GameConfig.HS
			var slope := Vector2(r - l, d - u).length() / (2.0 * GameConfig.TILE)
			if h > 150.0:
				high += 1
			if h >= 20.0 and h < 80.0 and slope < tan(deg_to_rad(25.0)):
				hills += 1
			if slope > tan(deg_to_rad(35.0)):
				steep_land += 1
			if h < 80.0 or w.river[i] != 0:
				continue
			mountains += 1
			if slope < tan(deg_to_rad(25.0)):
				gentle_mountains += 1
			if slope > tan(deg_to_rad(45.0)):
				steep += 1
			curvature += (absf(l + r - 2.0 * h) + absf(u + d - 2.0 * h)) * 0.5
	var lake_cells := 0
	for i in w.N:
		if w.lake[i] != 0:
			lake_cells += 1
	var out := {seed = w.seed_text, size = w.W, land_share = 0.0,
		mountain_scale = w.mountain_scale, mountain_bias = w.mountain_bias, mountain_height = w.mountain_height,
		lake_cells = lake_cells, rivers = w.rivers.size(), settlements = w.settlements.size(),
		bridges = w.bridges.size(), tunnels = w.tunnels.size(), connected = SelfTest.settlements_connected(w)}
	var dry := 0
	for i in w.N:
		if w.ocean[i] == 0:
			dry += 1
	out.land_share = float(dry) / w.N
	out.mountain_share = 100.0 * mountains / maxi(1, land)
	out.mountain_gentle_share = 100.0 * gentle_mountains / maxi(1, mountains)
	out.mountain_steep_share = 100.0 * steep / maxi(1, mountains)
	out.mountain_curvature_m = curvature / maxi(1, mountains)
	out.max_height_m = max_height
	out.high_share = 100.0 * high / maxi(1, land)
	out.hill_share = 100.0 * hills / maxi(1, land)
	out.steep_land_share = 100.0 * steep_land / maxi(1, land)
	out.merge(_massif_stats(w))
	out.mountain_gentle_largest_km2 = _massif_stats(w, true).mountain_largest_km2
	out.merge(_foothill_stats(w))
	out.merge(_traversal_stats(w))
	return out


## Оценка только земли, без путей и физики. Уклон до 25° проверяется по каждому ребру,
## а не центральной разностью, которая может пропустить узкую ступеньку или гребень.
## Оставляем центр лишь там, где все 3 × 3 клетки пригодны: исключаем узкие полки у воды/обрыва.
## Связность по четырём сторонам не позволяет перескочить угол препятствия по диагонали.
func _traversal_stats(w: WorldData) -> Dictionary:
	var gentle := PackedByteArray()
	gentle.resize(w.N)
	var wide := gentle.duplicate()
	var mountain_cells := 0
	var step_limit := tan(deg_to_rad(25.0)) * GameConfig.TILE / GameConfig.HS
	for y in range(1, w.H - 1):
		for x in range(1, w.W - 1):
			var i := y * w.W + x
			if w.ocean[i] != 0 or w.lake[i] != 0 or w.river[i] != 0:
				continue
			if w.h[i] * GameConfig.HS >= 80.0:
				mountain_cells += 1
			var ok := true
			for offset in [1, -1, w.W, -w.W]:
				if absf(w.h[i + offset] - w.h[i]) > step_limit:
					ok = false
			gentle[i] = int(ok)
	var wide_mountains := 0
	for y in range(2, w.H - 2):
		for x in range(2, w.W - 2):
			var i := y * w.W + x
			var ok := gentle[i] != 0
			for k in 8:
				if gentle[i + Grid.DY[k] * w.W + Grid.DX[k]] == 0:
					ok = false
			wide[i] = int(ok)
			if ok and w.h[i] * GameConfig.HS >= 80.0:
				wide_mountains += 1
	var linked_mountains := 0
	var best_rise := 0.0
	var rise_area := 0
	var largest := 0
	for i in w.N:
		if wide[i] == 0:
			continue
		var queue := PackedInt32Array([i])
		wide[i] = 0
		var head := 0
		var low := INF
		var high := 0.0
		var mountains := 0
		var foot := false
		while head < queue.size():
			var c := queue[head]
			head += 1
			var h := w.h[c] * GameConfig.HS
			low = minf(low, h)
			high = maxf(high, h)
			mountains += int(h >= 80.0)
			foot = foot or (h >= 20.0 and h < 60.0)
			for offset in [1, -1, w.W, -w.W]:
				var n: int = c + offset
				if wide[n] != 0:
					wide[n] = 0
					queue.append(n)
		if mountains > 0:
			if high - low > best_rise:
				best_rise = high - low
				rise_area = queue.size()
			largest = maxi(largest, queue.size())
			if foot:
				linked_mountains += mountains
	return {mountain_wide_share = 100.0 * wide_mountains / maxi(1, mountain_cells),
		mountain_foot_linked_share = 100.0 * linked_mountains / maxi(1, mountain_cells),
		traversal_rise_m = best_rise, traversal_rise_area_km2 = rise_area * GameConfig.TILE * GameConfig.TILE / 1e6,
		traversal_largest_km2 = largest * GameConfig.TILE * GameConfig.TILE / 1e6}


## На редкой сетке сравниваем исходный рельеф с отключённым дополнительным поясом.
## Это площадь влияния предгорий, а не новый биом; вода и дороги считаются позже по общему рельефу.
func _foothill_stats(w: WorldData) -> Dictionary:
	var without := WorldData.new()
	for key in ["W", "H", "N", "noise", "macro_x", "macro_y", "mountain_scale", "mountain_bias", "mountain_height"]:
		without.set(key, w.get(key))
	var before := StageRelief.raw_rect(without, 0, 0, w.W, w.H, false)
	var after := StageRelief.raw_rect(w, 0, 0, w.W, w.H, false)
	var land := 0
	var affected := 0
	var shift := 0.0
	var max_shift := 0.0
	for y in range(4, w.H - 4, 8):
		for x in range(4, w.W - 4, 8):
			var i := y * w.W + x
			if before[i] <= StageRelief.SEA_RAW:
				continue
			land += 1
			var delta := (StageRelief.normalize(after[i]) - StageRelief.normalize(before[i])) * GameConfig.HS
			max_shift = maxf(max_shift, absf(delta))
			if absf(delta) > 1.0:
				affected += 1
				shift += delta
	return {foothill_spread = w.foothill_spread, foothill_affected_share = 100.0 * affected / maxi(1, land),
		foothill_mean_change_m = shift / maxi(1, affected), foothill_max_change_m = max_shift}


## Связные участки выше 80 м (8 соседей). Крупный — от 0,04 км²: сравниваем цельность,
## а не только число высоких клеток. Вода и край карты не входят, как в _stats.
func _massif_stats(w: WorldData, gentle: bool = false) -> Dictionary:
	var seen := PackedByteArray()
	seen.resize(w.N)
	for y in range(1, w.H - 1):
		for x in range(1, w.W - 1):
			var i := y * w.W + x
			if w.ocean[i] == 0 and w.lake[i] == 0 and w.river[i] == 0 and w.h[i] * GameConfig.HS >= 80.0:
				if gentle:
					var dx := (w.h[i + 1] - w.h[i - 1]) * GameConfig.HS
					var dy := (w.h[i + w.W] - w.h[i - w.W]) * GameConfig.HS
					if Grid.hypot(dx, dy) / (2.0 * GameConfig.TILE) >= tan(deg_to_rad(25.0)):
						continue
				seen[i] = 1
	var total := 0
	var large := 0
	var large_count := 0
	var largest := 0
	var cell_area := GameConfig.TILE * GameConfig.TILE / 1e6
	for i in w.N:
		if seen[i] != 1:
			continue
		var queue := PackedInt32Array([i])
		seen[i] = 0
		var head := 0
		while head < queue.size():
			var c := queue[head]
			head += 1
			for k in 8:
				var nx: int = c % w.W + Grid.DX[k]
				var ny: int = c / w.W + Grid.DY[k]
				if nx < 0 or ny < 0 or nx >= w.W or ny >= w.H:
					continue
				var n := ny * w.W + nx
				if seen[n] == 1:
					seen[n] = 0
					queue.append(n)
		total += queue.size()
		largest = maxi(largest, queue.size())
		if queue.size() * cell_area >= 0.04:
			large += queue.size()
			large_count += 1
	return {mountain_largest_km2 = largest * cell_area, mountain_large_share = 100.0 * large / maxi(1, total), mountain_large_count = large_count}


## Проверка разнообразия на всей фиксированной подборке, а не требование гор к каждому сиду.
func _variety_check(results: Array) -> void:
	var sparse := false
	var rich := false
	var long_gentle := false
	var low := INF
	var high := 0.0
	var low_foothills := INF
	var high_foothills := 0.0
	for s: Dictionary in results:
		sparse = sparse or (s.mountain_large_count == 1 and s.mountain_share < 8.0)
		rich = rich or (s.mountain_share > 20.0 and s.mountain_largest_km2 > 0.2)
		long_gentle = long_gentle or (s.traversal_rise_m > 50.0 and s.traversal_rise_area_km2 > 0.01)
		low = minf(low, s.max_height_m)
		high = maxf(high, s.max_height_m)
		low_foothills = minf(low_foothills, s.foothill_affected_share)
		high_foothills = maxf(high_foothills, s.foothill_affected_share)
	_check(sparse, "есть мир с одним крупным горным участком среди низкой местности")
	_check(rich, "есть мир с протяжённой горной областью")
	_check(high - low > 80.0, "высота миров заметно различается")
	_check(high_foothills - low_foothills > 10.0, "распространённость предгорий различается между сидами")
	_check(long_gentle, "есть протяжённые пологие горные участки с перепадом более 50 м")


## Контроль самой оценки: широкий склон проходит, крутой склон и одноклеточная полка — нет.
func _traversal_check() -> void:
	var w := WorldData.new()
	w.W = 32
	w.H = 32
	w.N = w.W * w.H
	w.h.resize(w.N)
	w.ocean.resize(w.N)
	w.lake.resize(w.N)
	w.river.resize(w.N)
	for i in w.N:
		w.h[i] = (40.0 + 1.5 * (i % w.W)) / GameConfig.HS
	var gentle := _traversal_stats(w)
	_check(gentle.mountain_foot_linked_share > 50.0 and gentle.traversal_rise_m > 40.0, "оценка видит широкий подъём от подножия")
	for i in w.N:
		w.ocean[i] = int(i / w.W != 16)
	_check(_traversal_stats(w).mountain_wide_share == 0.0, "оценка исключает узкую полку у воды")
	w.ocean.fill(0)
	for i in w.N:
		w.h[i] = (40.0 + 6.0 * (i % w.W)) / GameConfig.HS
	_check(_traversal_stats(w).mountain_wide_share == 0.0, "оценка исключает крутой склон")


func _init() -> void:
	_traversal_check()
	var cases: Array = SelfTest.CASES if OS.get_cmdline_user_args().has("--quick") else []
	if cases.is_empty():
		for s in SEEDS:
			cases.append([s, 512])
	var results: Array = []
	for c: Array in cases:
		var t0 := Time.get_ticks_msec()
		var w := WorldGenerator.generate(c[0], c[1])
		var ms := Time.get_ticks_msec() - t0
		_world_check(w)
		_relief_check(w)
		var s := _stats(w)
		s.generation_ms = ms
		results.append(s)
		print("%s@%d: %d мс; горы %.1f%%; на них >45° %.1f%%; излом %.2f м; рек %d; поселений %d; связь %s" % [w.seed_text, w.W, ms, s.mountain_share, s.mountain_steep_share, s.mountain_curvature_m, w.rivers.size(), w.settlements.size(), s.connected])
		print("  широкие пологие участки гор %.1f%%; связаны с подножием %.1f%%; перепад связного участка %.1f м" % [s.mountain_wide_share, s.mountain_foot_linked_share, s.traversal_rise_m])
	if not OS.get_cmdline_user_args().has("--quick"):
		_variety_check(results)
	var path := Dev.arg("out")
	if path != "":
		Dev.save_json(Dev.abs_dir(path), results)
	print("Ошибок географии: %d" % _fails)
	quit(1 if _fails > 0 else 0)
