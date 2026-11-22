class_name ValleyAxis
extends RefCounted
## Единственный источник правды об оси долины Типа 2 «Речная экспедиция» (docs/WORLD_TEMPLATES.md).
## Чистая, неизменяемая после построения модель от (seed_num, W, H): безопасно читается из фоновых
## потоков OuterLand и генерации без мьютексов на горячем пути.

const TILE := GameConfig.TILE
const HS := GameConfig.HS

## Базовая экологическая высота дна долины (> 0.12, чтобы плоские берега реки не уходили в Biomes.SWAMP,
## и на входе в хвойный пояс StageVegetation.HIGH_LO = 0.12).
const ECO_BASE := 0.135
## Доля остаточного высотного градиента от верховьев к низовьям (верховья чуть суровее и хвойнее).
const ECO_RESIDUAL := 0.12
## Нижняя отметка дна долины у низовья (единицы w.h, ~18 м над уровнем моря — океана в плане нет).
const BOT_H := 0.070
## Целевой средний продольный уклон долины (доля: ~0.92 % — комфортный накат велосипеда с полками).
const TARGET_GRADE := 0.0092

var seed_num := 0
var W := 256
var H := 768
var road_side := 1          # +1 — дорога справа (+x от реки), -1 — слева (-x от реки)
var top_h := 0.20
var bot_h := BOT_H
var base_cx := 92.0

## Табуляция по строкам плана 0..H-1 (быстрый доступ O(1) и строгая монотонность спуска).
var _axis_x := PackedFloat64Array()
var _floor_h := PackedFloat64Array()
var _river_hw := PackedFloat64Array()
var _bed_depth := PackedFloat64Array()
var _spur_h := PackedFloat64Array()
var _spur_reach := PackedFloat64Array()
## Список поперечных отрогов на дорожной стороне: [{y, half_len, height, reach}]
var spurs: Array[Dictionary] = []

var _meander_noise: Simplex
var _width_noise: Simplex

static var _cache := {}
static var _cache_lock := Mutex.new()


static func for_world(w: WorldData) -> ValleyAxis:
	return get_axis(w.seed_num, w.W, w.H)


static func get_axis(p_seed: int, p_w: int, p_h: int) -> ValleyAxis:
	var key := Vector3i(p_seed, p_w, p_h)
	_cache_lock.lock()
	var existing: ValleyAxis = _cache.get(key)
	_cache_lock.unlock()
	if existing != null:
		return existing
	var built := ValleyAxis.new(p_seed, p_w, p_h)
	_cache_lock.lock()
	if _cache.size() >= 16:
		_cache.clear()
	_cache[key] = built
	_cache_lock.unlock()
	return built


func _init(p_seed: int = 0, p_w: int = 256, p_h: int = 768) -> void:
	seed_num = p_seed
	W = maxi(64, p_w)
	H = maxi(64, p_h)
	var side_rng := WGRandom.at(seed_num, "valley.side")
	road_side = 1 if side_rng.next_float() < 0.5 else -1
	# Смещаем ось реки к недорожному берегу, чтобы на дорожной стороне было 550–650 м лесных предгорий.
	base_cx = float(W) * (0.5 - 0.14 * float(road_side))
	_meander_noise = Simplex.new(WorldGenerator.noise_rng(seed_num, "valley_meander"))
	_width_noise = Simplex.new(WorldGenerator.noise_rng(seed_num, "valley_width"))
	_build_tables()


func _build_tables() -> void:
	_axis_x.resize(H)
	_floor_h.resize(H)
	_river_hw.resize(H)
	_bed_depth.resize(H)
	_spur_h.resize(H)
	_spur_reach.resize(H)

	# 1. Продольный профиль дна: строго невозрастающий спуск с полками и живыми сливами.
	var length_m := float(maxi(1, H - 1)) * TILE
	var drop := clampf(length_m * TARGET_GRADE / HS, 0.095, 0.43)
	bot_h = BOT_H
	top_h = bot_h + drop

	var slope_noise := Simplex.new(WorldGenerator.noise_rng(seed_num, "valley_slope"))
	var weights := PackedFloat64Array()
	weights.resize(H)
	var w_sum := 0.0
	for y in H:
		var slow := slope_noise.fbm(float(y) / 210.0 + 11.3, 3.7, 2)
		var med := slope_noise.noise(float(y) / 85.0 - 19.1, 17.2)
		var wave := clampf(0.5 + 0.42 * slow + 0.24 * med, 0.0, 1.0)
		# Пологие полки (~0.25x) чередуются с бодрыми сливами (~1.8x), но уклон всегда > 0.
		var wv := 0.24 + 1.56 * (wave * wave * (3.0 - 2.0 * wave))
		weights[y] = wv
		if y < H - 1:
			w_sum += wv
	var cur_h := top_h
	_floor_h[0] = cur_h
	for y in range(1, H):
		cur_h -= drop * (weights[y - 1] / maxf(1e-6, w_sum))
		_floor_h[y] = maxf(bot_h, cur_h)
	_floor_h[H - 1] = bot_h

	# 2. Ось реки (плавные извилины + закрытый поворот за лесистый мыс на финише) и ширина реки.
	for y in H:
		_axis_x[y] = _compute_axis_x(float(y))
		var s := float(y) / float(maxi(1, H - 1))
		var mod := _width_noise.fbm(float(y) / 140.0 + 5.1, -9.4, 2)
		# Верховья ~13 м ширины (hw ~1.6 кл), низовья ~34 м (hw ~4.2 кл).
		var hw := lerpf(1.65, 4.15, pow(s, 0.85)) * (1.0 + 0.16 * mod)
		_river_hw[y] = clampf(hw, 1.35, 5.2)
		# Глубина русла 2.0–3.2 м в центре (уверенно глубже брода).
		_bed_depth[y] = (1.75 + 0.32 * _river_hw[y]) / HS

	# 3. Поперечные отроги на дорожной стороне (через неравные промежутки, чтобы дорога не шла прямой).
	spurs.clear()
	var spur_rng := WGRandom.at(seed_num, "valley.spurs")
	var y_cursor := 88.0 + spur_rng.next_float() * 48.0
	var y_limit := float(H) - 115.0
	while y_cursor < y_limit:
		var half_len := 30.0 + spur_rng.next_float() * 26.0
		var height_m := 20.0 + spur_rng.next_float() * 19.0
		# Как близко нос отрога подходит к реке (клеток от оси реки по дорожной стороне).
		var reach := 26.0 + spur_rng.next_float() * 28.0
		spurs.append({y = y_cursor, half_len = half_len, height = height_m / HS, reach = reach})
		y_cursor += 96.0 + spur_rng.next_float() * 78.0

	for y in H:
		var sh := 0.0
		var sr := 40.0
		var best_w := 0.0
		for sp: Dictionary in spurs:
			var dy := absf(float(y) - float(sp.y))
			var hl: float = sp.half_len
			if dy >= hl:
				continue
			var u := 1.0 - dy / hl
			var env := u * u * (3.0 - 2.0 * u)
			var h_here := float(sp.height) * env
			if h_here > sh:
				sh = h_here
			if env > best_w:
				best_w = env
				sr = float(sp.reach)
		_spur_h[y] = sh
		_spur_reach[y] = sr


func _compute_axis_x(fy: float) -> float:
	var slow := _meander_noise.fbm(fy / 360.0 + 7.3, -13.7, 2)
	var med := _meander_noise.noise(fy / 145.0 - 31.2, 23.4)
	var amp := minf(34.0, float(W) * 0.13)
	var x := base_cx + (slow * 0.72 + med * 0.28) * amp
	# Закрытый поворот реки на финише: за ~115 клеток до края река мягко уходит к недорожному берегу
	# за лесистый мыс, чтобы с финишной базы край воды не обрывался на прямой.
	var bend_start := float(H) - 118.0
	if fy > bend_start:
		var t := clampf((fy - bend_start) / 118.0, 0.0, 1.0)
		var ease := t * t * (3.0 - 2.0 * t)
		x -= float(road_side) * 44.0 * ease
	# За стартом (y < 0) река уходит в узкую теснину за мягкий изгиб.
	if fy < 24.0:
		var t0 := clampf((24.0 - fy) / 72.0, 0.0, 1.0)
		var ease0 := t0 * t0 * (3.0 - 2.0 * t0)
		x -= float(road_side) * 24.0 * ease0
	var lo := 28.0 if fy > bend_start else 42.0
	var hi := float(W) - (28.0 if fy > bend_start else 42.0)
	return clampf(x, lo, hi)


func axis_x_at(y: float) -> float:
	var iy := floori(y)
	if iy >= 0 and iy < H - 1:
		var t := y - float(iy)
		return lerpf(_axis_x[iy], _axis_x[iy + 1], t)
	if iy == H - 1 and y <= float(H - 1):
		return _axis_x[H - 1]
	return _compute_axis_x(y)


func floor_h_at(y: int) -> float:
	if y >= 0 and y < H:
		return _floor_h[y]
	if y < 0:
		# За стартом дно плавно поднимается в горный цирк / перевал.
		var d := float(-y)
		return top_h + 0.0018 * d + 0.000012 * d * d
	# За финишем дно остаётся выше моря и плавно уходит в лесистую гряду за поворотом.
	var d2 := float(y - (H - 1))
	return bot_h + 0.0008 * d2


func river_hw_at(y: int) -> float:
	if y >= 0 and y < H:
		return _river_hw[y]
	return _river_hw[0] if y < 0 else _river_hw[H - 1]


func bed_depth_at(y: int) -> float:
	if y >= 0 and y < H:
		return _bed_depth[y]
	return _bed_depth[0] if y < 0 else _bed_depth[H - 1]


## Экологическая высота клетки (для w.elev в StageGeography и OuterLand):
## физическая высота h относительно дна долины + база ECO_BASE (> порога болот 0.12) + мягкий высотный сдвиг верховьев.
func eco_elev(y: int, raw_h: float) -> float:
	var fh := floor_h_at(y)
	var base := ECO_BASE + ECO_RESIDUAL * maxf(0.0, fh - bot_h)
	return maxf(0.0, maxf(0.0, raw_h) - fh + base)


## Табуляция 1D-параметров по строкам прямоугольника [y0, y0 + ch) для C# и GDScript рельефа.
## Все массивы длины ch; вычисляется за O(ch) вместо O(cw * ch).
func sample_rows(y0: int, ch: int) -> Dictionary:
	var ax := PackedFloat64Array()
	var fh := PackedFloat64Array()
	var hw := PackedFloat64Array()
	var bd := PackedFloat64Array()
	var sh := PackedFloat64Array()
	var sr := PackedFloat64Array()
	var cf := PackedFloat64Array()
	var ew := PackedFloat64Array()
	ax.resize(ch)
	fh.resize(ch)
	hw.resize(ch)
	bd.resize(ch)
	sh.resize(ch)
	sr.resize(ch)
	cf.resize(ch)
	ew.resize(ch)
	for j in ch:
		var y := y0 + j
		if y >= 0 and y < H:
			ax[j] = _axis_x[y]
			fh[j] = _floor_h[y]
			hw[j] = _river_hw[y]
			bd[j] = _bed_depth[y]
			sh[j] = _spur_h[y]
			sr[j] = _spur_reach[y]
			# Русло держится на полной глубине на всём протяжении ленты [1, H - 5] и плавно закрывается к торцам.
			var fade_top := smoothstep(-5.0, 1.0, float(y))
			var fade_bot := 1.0 - smoothstep(float(H - 5), float(H + 3), float(y))
			cf[j] = fade_top * fade_bot
			ew[j] = 0.0
		elif y < 0:
			var d := float(-y)
			ax[j] = _compute_axis_x(float(y))
			fh[j] = floor_h_at(y)
			hw[j] = _river_hw[0]
			bd[j] = _bed_depth[0]
			sh[j] = 0.0
			sr[j] = 40.0
			cf[j] = smoothstep(-5.0, 1.0, float(y))
			# Горный цирк плавно замыкает верховье за стартом (уже после закрытия русла cf = 0).
			ew[j] = smoothstep(6.0, 190.0, d) * 0.34
		else:
			var d2 := float(y - (H - 1))
			ax[j] = _compute_axis_x(float(y))
			fh[j] = floor_h_at(y)
			hw[j] = _river_hw[H - 1]
			bd[j] = _bed_depth[H - 1]
			sh[j] = 0.0
			sr[j] = 40.0
			cf[j] = 1.0 - smoothstep(float(H - 5), float(H + 3), float(y))
			# Лесистая гряда плавно замыкает долину за закрытым поворотом реки на финише.
			ew[j] = smoothstep(6.0, 210.0, d2) * 0.28
	return {
		axis_x = ax, floor_h = fh, river_hw = hw, bed_depth = bd,
		spur_h = sh, spur_reach = sr, channel_fade = cf, end_wall = ew,
	}


## Картовая линия реки в клетках [{x, y, w, e}] для WorldData.rivers (MapBaker, MenuMapPreview).
func build_map_river() -> Array:
	var pts: Array = []
	var step := 2
	var y := 0
	while y < H:
		pts.append({
			x = _axis_x[y] + 0.5,
			y = float(y) + 0.5,
			w = _river_hw[y] * 1.45,
			e = _floor_h[y],
		})
		y += step
	if (H - 1) % step != 0:
		pts.append({
			x = _axis_x[H - 1] + 0.5,
			y = float(H - 1) + 0.5,
			w = _river_hw[H - 1] * 1.45,
			e = _floor_h[H - 1],
		})
	return pts


## Готовая 3D-лента реки в формате Heightfield.ribbons (метры): края заходят в берег (+3.2 м),
## уровень воды строго невозрастает; подходит для WaterBuilder, RideGround, depth_at, current_at и SurfaceSnapshot.
func build_river_ribbon() -> Array:
	var pts: Array = []
	# Шаг 1.5 клетки (~6 м): плавная лента на поворотах без лишних треугольников.
	var step := 1.5
	var fy := 1.5
	var y_end := float(H - 5)
	while fy <= y_end:
		var y0 := clampi(floori(fy), 0, H - 1)
		var y1 := mini(H - 1, y0 + 1)
		var t := fy - float(y0)
		var cx := lerpf(_axis_x[y0], _axis_x[y1], t)
		var fh := lerpf(_floor_h[y0], _floor_h[y1], t)
		var hw_cells := lerpf(_river_hw[y0], _river_hw[y1], t)
		var depth_m := lerpf(_bed_depth[y0], _bed_depth[y1], t) * HS
		# Запас +3.2 м с каждого берега: кромки треугольников гарантированно уходят под берег (0 щелей).
		var ribbon_hw_m := hw_cells * TILE + 3.2
		var wy := fh * HS
		pts.append({
			x = (cx + 0.5) * TILE,
			z = (fy + 0.5) * TILE,
			w = ribbon_hw_m,
			y = wy,
			depth = depth_m,
		})
		fy += step
	for k in range(1, pts.size()):
		pts[k].y = minf(pts[k].y, pts[k - 1].y)
	for k in pts.size():
		var p: Dictionary = pts[k]
		var a: Dictionary = pts[maxi(0, k - 1)]
		var b: Dictionary = pts[mini(pts.size() - 1, k + 1)]
		var dir := Vector2(b.x - a.x, b.z - a.z).normalized()
		if dir.length_squared() < 0.01:
			dir = Vector2(0.0, 1.0)
		p.left = Vector3(p.x - dir.y * p.w, p.y, p.z + dir.x * p.w)
		p.right = Vector3(p.x + dir.y * p.w, p.y, p.z - dir.x * p.w)
		var incoming := Vector2(p.x - a.x, p.z - a.z).normalized()
		var outgoing := Vector2(b.x - p.x, b.z - p.z).normalized()
		p.bend = clampf(incoming.cross(outgoing) * 3.0, -1.0, 1.0)
		p.motion = Heightfield.river_motion(pts, k)
	return pts


## Проверка сухой проезжаемой клетки (для площадок поселений и якорей дороги Типа 2).
static func _road_cell_ok(w: WorldData, river: PackedByteArray, x: int, y: int, max_slope: float) -> bool:
	if x < 4 or y < 14 or x >= w.W - 4 or y >= w.H - 14:
		return false
	var i := y * w.W + x
	if w.ocean[i] != 0 or w.lake[i] != 0 or river[i] != 0 or w.slope[i] > max_slope:
		return false
	var h0 := w.h[i]
	var exits := 0
	for dy in range(-1, 2):
		for dx in range(-1, 2):
			var nb := (y + dy) * w.W + (x + dx)
			if w.ocean[nb] != 0 or w.lake[nb] != 0 or river[nb] != 0:
				return false
			if dx == 0 and dy == 0:
				continue
			var step := 1.41421356 if dx != 0 and dy != 0 else 1.0
			if w.slope[nb] <= 0.34 and absf(w.h[nb] - h0) * StageTrails.HEIGHT_SCALE / step <= StageTrails.ROAD_LIMIT:
				exits += 1
	return exits >= 4


## Подбирает лучшую ровную сухую террасу в полосе [y_min, y_max] и отступе [sd_min, sd_max] по стороне side_sign.
func find_terrace_cell(w: WorldData, y_min: int, y_max: int, sd_min: float, sd_max: float, side_sign: int,
		max_slope := 0.22, prefer_y := -1.0, prefer_sd := -1.0) -> int:
	var river := w.river_cells()
	var y0 := clampi(y_min, 16, H - 16)
	var y1 := clampi(y_max, y0, H - 16)
	var py := prefer_y if prefer_y >= 0.0 else 0.5 * float(y0 + y1)
	var psd := prefer_sd if prefer_sd >= 0.0 else 0.5 * (sd_min + sd_max)
	var best := -1
	var best_score := -INF
	var slope_caps := [max_slope, maxf(max_slope, 0.32)]
	for cap: float in slope_caps:
		for y in range(y0, y1 + 1, 2):
			var ax := _axis_x[y]
			var rhw := _river_hw[y]
			var lo := maxf(rhw + 3.2, sd_min)
			var hi := maxf(lo + 1.0, sd_max)
			var x_a := clampi(roundi(ax + lo * float(side_sign)), 6, W - 7)
			var x_b := clampi(roundi(ax + hi * float(side_sign)), 6, W - 7)
			var xmin := mini(x_a, x_b)
			var xmax := maxi(x_a, x_b)
			for x in range(xmin, xmax + 1, 2):
				if not _road_cell_ok(w, river, x, y, cap):
					continue
				var i := y * W + x
				var sd := (float(x) - ax) * float(side_sign)
				var dy_pen := absf(float(y) - py) / maxf(12.0, float(y1 - y0))
				var dsd_pen := absf(sd - psd) / maxf(8.0, hi - lo)
				var score := -w.slope[i] * 6.0 - dy_pen * 0.45 - dsd_pen * 0.40
				if score > best_score:
					best_score = score
					best = i
		if best >= 0:
			break
	return best


## Якоря одной дороги вдоль долины (Фаза 3): опираются на реальные поперечные отроги и береговые террасы.
## Чередуют выходы к самой воде и уходы вглубь лесных предгорий/седловин с неравным ритмом по сиду.
func road_anchors(w: WorldData, start_cell: int, finish_cell: int) -> PackedInt32Array:
	var out := PackedInt32Array()
	var start_y := start_cell / W
	var finish_y := finish_cell / W
	var span_y := finish_y - start_y
	if span_y < 110:
		return out
	var rng := WGRandom.at(seed_num, "valley.anchors")
	# Собираем естественные узлы вдоль долины: поперечные отроги (седловины в лесу) и межотроговые ложбины (берег).
	var events: Array[Dictionary] = []
	var prev_y := float(start_y)
	for sp: Dictionary in spurs:
		var sy: float = float(sp.y)
		if sy < float(start_y) + 46.0 or sy > float(finish_y) - 46.0:
			continue
		if sy - prev_y >= 88.0:
			var mid_y := 0.5 * (prev_y + sy)
			if mid_y >= float(start_y) + 42.0 and mid_y <= float(finish_y) - 42.0:
				events.append({y = mid_y, kind = "basin", reach = 0.0})
		events.append({y = sy, kind = "spur", reach = float(sp.reach)})
		prev_y = sy
	if float(finish_y) - prev_y >= 88.0:
		var tail_y := 0.5 * (prev_y + float(finish_y))
		if tail_y <= float(finish_y) - 42.0:
			events.append({y = tail_y, kind = "basin", reach = 0.0})
	# Если на короткой карте отрогов мало, дополняем равномерно-живой сеткой узлов.
	if events.size() < 4:
		events.clear()
		var n := maxi(4, roundi(float(span_y) / 115.0))
		for k in range(1, n):
			var y := float(start_y) + float(span_y) * float(k) / float(n)
			events.append({y = y, kind = "spur" if k % 2 == 1 else "basin", reach = 38.0})

	var mode := "inland" if rng.next_float() < 0.7 else "river"
	var run_len := 0
	var target_run := 1 + (1 if rng.next_float() < 0.45 else 0)
	var last_y := start_y
	var last_sd := (float(start_cell % W) - _axis_x[start_y]) * float(road_side)
	var inland_n := 0
	var river_n := 0

	for idx in events.size():
		var ev: Dictionary = events[idx]
		var ey := roundi(float(ev.y))
		if finish_y - ey < 64:
			continue
		# Привязываем выбор режима к естественному рельефу: отроги тяготеют к лесным седловинам, ложбины — к воде,
		# но длинные лесные серии из 2–3 отрогов подряд допускаются, чтобы дорога надолго уходила от реки.
		var want_mode := mode
		if run_len >= target_run:
			want_mode = "river" if mode == "inland" else "inland"
		elif ev.kind == "spur" and mode == "river" and run_len >= 1 and rng.next_float() < 0.65:
			want_mode = "inland"
		elif ev.kind == "basin" and mode == "inland" and run_len >= 2 and rng.next_float() < 0.70:
			want_mode = "river"
		# На финальной трети короткого/любого маршрута гарантируем, что были и берег, и лес.
		if idx == events.size() - 2:
			if inland_n == 0: want_mode = "inland"
			elif river_n == 0: want_mode = "river"

		var rhw := river_hw_at(ey)
		var est_sd := (rhw + 7.5) if want_mode == "river" else clampf((float(ev.reach) if float(ev.reach) > 10.0 else 34.0) + 12.0, 32.0, 56.0)
		# Плавный диагональный переход «берег ↔ лес»: на сдвиг Δsd нужен достаточный продольный разгон Δy (~2×Δsd),
		# чтобы не возникало резких 90° «ушей» и крутых траверсов поперёк отрога.
		var need_dy := maxi(68, roundi(absf(est_sd - last_sd) * 2.1))
		if ey - last_y < need_dy:
			continue
		if want_mode != mode:
			mode = want_mode
			run_len = 0
			target_run = (1 + (1 if rng.next_float() < 0.55 else 0)) if mode == "inland" else (1 + (1 if rng.next_float() < 0.30 else 0))

		var cell := -1
		if mode == "river":
			var sd_lo := rhw + 4.2
			var sd_hi := rhw + 11.5
			var sd_pref := lerpf(sd_lo + 1.0, sd_hi - 1.5, rng.next_float())
			cell = find_terrace_cell(w, ey - 14, ey + 14, sd_lo, sd_hi, road_side, 0.16, float(ey), sd_pref)
		else:
			var base_reach := float(ev.reach) if float(ev.reach) > 10.0 else 34.0
			var sd_pref := clampf(base_reach + lerpf(6.0, 18.0, rng.next_float()), 32.0, 58.0)
			var sd_lo := maxf(26.0, sd_pref - 10.0)
			var sd_hi := minf(64.0, sd_pref + 10.0)
			cell = find_terrace_cell(w, ey - 16, ey + 16, sd_lo, sd_hi, road_side, 0.20, float(ey), sd_pref)

		if cell >= 0:
			var cy := cell / W
			var csd := (float(cell % W) - _axis_x[cy]) * float(road_side)
			if cy - last_y >= maxi(54, roundi(absf(csd - last_sd) * 1.7)) and finish_y - cy >= 58:
				out.append(cell)
				last_y = cy
				last_sd = csd
				run_len += 1
				if mode == "inland": inland_n += 1
				else: river_n += 1
	return out
