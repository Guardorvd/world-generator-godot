class_name ValleyAxis
extends RefCounted
## Единственный источник правды о геометрии долины (docs/WORLD_TEMPLATES.md):
## ось реки, продольный профиль дна, ширина и глубина русла, сторона дороги, поперечные отроги,
## торцы, экологическая высота, разметка русла и якоря дороги. Все числа читаются из WorldTypeConfig (.tres).
## Неизменяема после построения: безопасно читается из фоновых потоков OuterLand и генерации.

const TILE := GameConfig.TILE
const HS := GameConfig.HS

var cfg: WorldTypeConfig
var seed_num := 0
var W := 256
var H := 768
var road_side := 1          # +1 — дорога справа (+x от реки), -1 — слева (-x от реки)
var top_h := 0.20
var bot_h := 0.070
var base_cx := 92.0

## Табуляция по строкам плана 0..H-1 (доступ O(1) и строгая монотонность спуска).
var _axis_x := PackedFloat64Array()
var _axis_cos := PackedFloat64Array()
var _floor_h := PackedFloat64Array()
var _river_hw := PackedFloat64Array()
var _bed_depth := PackedFloat64Array()
var _spur_h := PackedFloat64Array()
var _spur_reach := PackedFloat64Array()
var _opp_spur_h := PackedFloat64Array()
var _opp_spur_reach := PackedFloat64Array()
var _wall_shift_r := PackedFloat64Array()
var _wall_shift_l := PackedFloat64Array()
## Список поперечных отрогов: [{y, half_len, height, reach}]
var spurs: Array[Dictionary] = []
var opp_spurs: Array[Dictionary] = []

var _meander_noise: Simplex
var _width_noise: Simplex
var _basin_noise: Simplex
var _swing_phase := 0.0

static var _cache := {}
static var _cache_lock := Mutex.new()


static func for_world(w: WorldData) -> ValleyAxis:
	return get_axis(w.seed_num, w.W, w.H, WorldTemplate.config(w.template_id))


static func get_axis(p_seed: int, p_w: int, p_h: int, p_cfg: WorldTypeConfig = null) -> ValleyAxis:
	var use_cfg := p_cfg if p_cfg != null else WorldTemplate.config(WorldTemplate.EXPEDITION_ID)
	# The axis retains the resource for anchor and site placement as well as geometry.
	var key := "%d|%d|%d|%d|%s" % [p_seed, p_w, p_h, use_cfg.get_instance_id(), use_cfg.geo_cache_digest()]
	_cache_lock.lock()
	var existing: ValleyAxis = _cache.get(key)
	_cache_lock.unlock()
	if existing != null:
		return existing
	var built := ValleyAxis.new(p_seed, p_w, p_h, use_cfg)
	_cache_lock.lock()
	if _cache.size() >= 16:
		_cache.clear()
	_cache[key] = built
	_cache_lock.unlock()
	return built


func _init(p_seed: int = 0, p_w: int = 256, p_h: int = 768, p_cfg: WorldTypeConfig = null) -> void:
	cfg = p_cfg if p_cfg != null else WorldTemplate.config(WorldTemplate.EXPEDITION_ID)
	seed_num = p_seed
	W = maxi(64, p_w)
	H = maxi(64, p_h)
	var side_rng := WGRandom.at(seed_num, "valley.side")
	road_side = 1 if side_rng.next_float() < 0.5 else -1
	base_cx = float(W) * (0.5 - cfg.corridor_shift * float(road_side))
	_meander_noise = Simplex.new(WorldGenerator.noise_rng(seed_num, "valley_meander"))
	_width_noise = Simplex.new(WorldGenerator.noise_rng(seed_num, "valley_width"))
	_basin_noise = Simplex.new(WorldGenerator.noise_rng(seed_num, "valley_basin"))
	_swing_phase = WGRandom.at(seed_num, "valley.swing").next_float() * TAU
	_build_tables()


func _build_tables() -> void:
	_axis_x.resize(H)
	_axis_cos.resize(H)
	_floor_h.resize(H)
	_river_hw.resize(H)
	_bed_depth.resize(H)
	_spur_h.resize(H)
	_spur_reach.resize(H)
	_opp_spur_h.resize(H)
	_opp_spur_reach.resize(H)
	_wall_shift_r.resize(H)
	_wall_shift_l.resize(H)

	# 1. Продольный профиль дна: строго невозрастающий спуск с полками и живыми сливами.
	var length_m := float(maxi(1, H - 1)) * TILE
	var drop := clampf(length_m * cfg.river_target_grade / HS, cfg.river_drop_min, cfg.river_drop_max)
	bot_h = cfg.river_bot_h
	top_h = bot_h + drop

	var slope_noise := Simplex.new(WorldGenerator.noise_rng(seed_num, "valley_slope"))
	var weights := PackedFloat64Array()
	weights.resize(H)
	var w_sum := 0.0
	for y in H:
		var slow := slope_noise.fbm(float(y) / cfg.slope_slow_scale + 11.3, 3.7, 2)
		var med := slope_noise.noise(float(y) / cfg.slope_med_scale - 19.1, 17.2)
		var wave := clampf(0.5 + 0.42 * slow + 0.24 * med, 0.0, 1.0)
		var wv := cfg.slope_shelf_min + cfg.slope_drop_span * (wave * wave * (3.0 - 2.0 * wave))
		weights[y] = wv
		if y < H - 1:
			w_sum += wv
	var cur_h := top_h
	_floor_h[0] = cur_h
	for y in range(1, H):
		cur_h -= drop * (weights[y - 1] / maxf(1e-6, w_sum))
		_floor_h[y] = maxf(bot_h, cur_h)
	_floor_h[H - 1] = bot_h

	# 2. Ширина и глубина русла по строкам плана.
	for y in H:
		var s := float(y) / float(maxi(1, H - 1))
		var mod := _width_noise.fbm(float(y) / 140.0 + 5.1, -9.4, 2)
		var hw := lerpf(cfg.river_hw_start, cfg.river_hw_end, pow(s, cfg.river_hw_power)) * (1.0 + cfg.river_hw_mod * mod)
		_river_hw[y] = clampf(hw, cfg.river_hw_min, cfg.river_hw_max)
		_bed_depth[y] = (cfg.river_depth_base_m + cfg.river_depth_per_hw_m * _river_hw[y]) / HS

	# 3. Поперечные отроги на обоих берегах (перехлёст кулисами) и отталкивание оси в излучины.
	spurs.clear()
	var spur_rng := WGRandom.at(seed_num, "valley.spurs")
	var y_cursor := cfg.spur_first_y_min + spur_rng.next_float() * cfg.spur_first_y_span
	var y_limit := float(H) - cfg.spur_end_margin
	while y_cursor < y_limit:
		var half_len := cfg.spur_half_len_min + spur_rng.next_float() * cfg.spur_half_len_span
		var height_m := cfg.spur_height_min_m + spur_rng.next_float() * cfg.spur_height_span_m
		var reach := cfg.spur_reach_min + spur_rng.next_float() * cfg.spur_reach_span
		spurs.append({y = y_cursor, half_len = half_len, height = height_m / HS, reach = reach})
		y_cursor += cfg.spur_gap_min + spur_rng.next_float() * cfg.spur_gap_span

	opp_spurs.clear()
	var opp_rng := WGRandom.at(seed_num, "valley.opp_spurs")
	var opp_targets: Array[float] = []
	if not spurs.is_empty():
		var pre_y := 0.5 * (cfg.spur_first_y_min * 0.65 + float(spurs[0].y))
		if float(spurs[0].y) - pre_y >= 40.0 and pre_y >= 45.0:
			opp_targets.append(pre_y)
		for k in spurs.size() - 1:
			opp_targets.append(lerpf(float(spurs[k].y), float(spurs[k + 1].y), lerpf(0.38, 0.62, opp_rng.next_float())))
		var post_y := float(spurs[-1].y) + 0.5 * (cfg.spur_gap_min + cfg.spur_gap_span * 0.4)
		if post_y <= float(H) - cfg.spur_end_margin * 0.85:
			opp_targets.append(post_y)
	for oy: float in opp_targets:
		var half_len := (cfg.spur_half_len_min + opp_rng.next_float() * cfg.spur_half_len_span) * 1.15
		var height_m := cfg.opp_spur_height_min_m + opp_rng.next_float() * cfg.opp_spur_height_span_m
		var reach := cfg.opp_spur_reach_min + opp_rng.next_float() * cfg.opp_spur_reach_span
		opp_spurs.append({y = oy, half_len = half_len, height = height_m / HS, reach = reach})

	var bend_push := PackedFloat64Array()
	bend_push.resize(H)
	for y in H:
		var road_spur := _sample_spurs(spurs, float(y), 40.0)
		_spur_h[y] = road_spur.x
		_spur_reach[y] = road_spur.y
		var road_w := road_spur.z
		var opp_spur := _sample_spurs(opp_spurs, float(y), 32.0)
		_opp_spur_h[y] = opp_spur.x
		_opp_spur_reach[y] = opp_spur.y
		var opp_w := opp_spur.z
		var end_fade := smoothstep(0.0, 24.0, float(y)) * (1.0 - smoothstep(float(H - 28), float(H - 4), float(y)))
		bend_push[y] = (opp_w - road_w) * float(road_side) * cfg.bend_push_amp * end_fade

	# 4. Двухмасштабная ось реки (макроколена + излучины + отроги), нормаль-косинус и сдвиг стен котловин/прижимов.
	for y in H:
		_axis_x[y] = _compute_axis_x(float(y), bend_push[y])
	for y in H:
		var dx := (axis_x_at(float(y + 4)) - axis_x_at(float(y - 4))) * 0.125
		_axis_cos[y] = 1.0 / sqrt(1.0 + dx * dx)
	for y in H:
		var ws := _wall_shifts_at(y)
		_wall_shift_r[y] = ws.x
		_wall_shift_l[y] = ws.y


static func _sample_spurs(list: Array[Dictionary], fy: float, default_reach: float) -> Vector3:
	var sh := 0.0
	var best_w := 0.0
	var sr_sum := 0.0
	var w_sum := 0.0
	for sp: Dictionary in list:
		var dy := absf(fy - float(sp.y))
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
		sr_sum += float(sp.reach) * env
		w_sum += env
	var sr := (sr_sum / w_sum) if w_sum > 1e-6 else default_reach
	return Vector3(sh, sr, best_w)


static func _soft_clamp(x: float, lo: float, hi: float, soft: float) -> float:
	if hi <= lo:
		return 0.5 * (lo + hi)
	var s := minf(soft, 0.45 * (hi - lo))
	if s <= 1e-6:
		return clampf(x, lo, hi)
	if x < lo + s:
		var d := (lo + s) - x
		return lo + s / (1.0 + d / s)
	if x > hi - s:
		var d := x - (hi - s)
		return hi - s / (1.0 + d / s)
	return x


func _compute_axis_x(fy: float, push := 0.0) -> float:
	var phase_n := _meander_noise.fbm(fy / maxf(1.0, cfg.valley_swing_warp_scale) + 3.1, 19.7, 2)
	var amp_mod := 0.65 + 0.50 * clampf(_meander_noise.noise(fy / maxf(1.0, cfg.valley_swing_warp_scale * 1.3) - 11.4, -7.2) + 0.5, 0.0, 1.0)
	var swing := sin(TAU * fy / maxf(1.0, cfg.valley_swing_wave) + _swing_phase + phase_n * cfg.valley_swing_warp) * cfg.valley_swing_amp * amp_mod
	var slow := _meander_noise.fbm(fy / cfg.meander_slow_scale + 7.3, -13.7, 2)
	var med := _meander_noise.noise(fy / cfg.meander_med_scale - 31.2, 23.4)
	var amp := minf(cfg.meander_amp_max, float(W) * cfg.meander_amp_width_frac)
	var x := base_cx + swing + (slow * 0.72 + med * 0.28) * amp + push
	var bend_start := float(H) - cfg.finish_bend_len
	if fy > bend_start:
		var t := clampf((fy - bend_start) / maxf(1.0, cfg.finish_bend_len), 0.0, 1.0)
		var ease := t * t * (3.0 - 2.0 * t)
		x -= float(road_side) * cfg.finish_bend_shift * ease
	if fy < cfg.head_bend_y:
		var t0 := clampf((cfg.head_bend_y - fy) / maxf(1.0, cfg.head_bend_span), 0.0, 1.0)
		var ease0 := t0 * t0 * (3.0 - 2.0 * t0)
		x -= float(road_side) * cfg.head_bend_shift * ease0
	var opp_margin := cfg.axis_margin_bend if fy > bend_start else cfg.axis_margin_opp
	var lo := opp_margin if road_side > 0 else cfg.axis_margin_road
	var hi := (float(W) - cfg.axis_margin_road) if road_side > 0 else (float(W) - opp_margin)
	return _soft_clamp(x, lo, hi, cfg.axis_soft_margin)


func axis_cos_at(y: int) -> float:
	if y >= 0 and y < H:
		return _axis_cos[y]
	var dx := (axis_x_at(float(y + 4)) - axis_x_at(float(y - 4))) * 0.125
	return 1.0 / sqrt(1.0 + dx * dx)


static func _soft_floor(v: float, lo: float, s: float) -> float:
	var d := v - lo
	return lo + 0.5 * (d + sqrt(d * d + s * s))


func _wall_shifts_at(y: int) -> Vector2:
	var bn := _basin_noise.fbm(float(y) / maxf(1.0, cfg.basin_scale) - 14.3, 8.9, 2)
	var base_basin := lerpf(-cfg.basin_narrow, cfg.basin_wide, smoothstep(-0.55, 0.55, bn))
	var xm := axis_x_at(float(y - 48))
	var xc := axis_x_at(float(y))
	var xp := axis_x_at(float(y + 48))
	var bend_k := (xp - 2.0 * xc + xm) / 2304.0
	var u_k := -bend_k * float(road_side) * cfg.bend_asym_gain
	var cutbank_road := u_k / sqrt(1.0 + u_k * u_k)
	var wr: float
	var wl: float
	if cutbank_road >= 0.0:
		wr = base_basin - cutbank_road * cfg.bend_wall_pull
		wl = base_basin + cutbank_road * cfg.bend_terrace_push
	else:
		wr = base_basin + (-cutbank_road) * cfg.bend_terrace_push
		wl = base_basin - (-cutbank_road) * cfg.bend_wall_pull
	wr = _soft_floor(wr, cfg.min_road_corridor - cfg.wall_road_start, 8.0)
	wl = _soft_floor(wl, river_hw_at(y) + 6.0 - cfg.wall_opp_start, 6.0)
	return Vector2(wr, wl)


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
		var d := float(-y)
		return top_h + 0.0018 * d + 0.000012 * d * d
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
## физическая высота h относительно дна долины + база cfg.eco_base + остаточный сдвиг верховьев.
func eco_elev(y: int, raw_h: float) -> float:
	var fh := floor_h_at(y)
	var base := cfg.eco_base + cfg.eco_residual * maxf(0.0, fh - bot_h)
	return maxf(0.0, maxf(0.0, raw_h) - fh + base)


## Пересчёт w.elev относительно дна долины для всего плана (вызывается StageGeography).
func apply_eco_elev(w: WorldData) -> void:
	var elev := w.elev
	var h := w.h
	var ocean := w.ocean
	var lake := w.lake
	var filled := w.filled
	for y in H:
		var row := y * W
		for x in W:
			var i := row + x
			if ocean[i] != 0:
				elev[i] = 0.0
			else:
				var raw_h := filled[i] if lake[i] != 0 else h[i]
				elev[i] = eco_elev(y, raw_h)
	w.elev = elev


## Разметка клеток русла в w.river / w.filled / w.river_area (вызывается StageHydrology).
func mark_river(w: WorldData) -> void:
	var river := w.river
	var filled := w.filled
	var h := w.h
	for y in range(1, H - 4):
		var ax := _axis_x[y]
		var rhw := _river_hw[y]
		var cos_t := _axis_cos[y]
		var h_reach := (rhw + cfg.river_mask_pad) / maxf(cos_t, 0.25)
		var fh := _floor_h[y]
		var x0 := maxi(0, floori(ax - h_reach - 0.5))
		var x1 := mini(W - 1, ceili(ax + h_reach + 0.5))
		var row := y * W
		for x in range(x0, x1 + 1):
			if absf(float(x) - ax) * cos_t <= rhw + cfg.river_mask_pad:
				var i := row + x
				river[i] = 1
				filled[i] = maxf(h[i], fh)
	w.river = river
	w.filled = filled
	w.river_area = river.duplicate()


## Запрещает размещение редких озёр вблизи оси реки (вызывается StageHydrology).
func excludes_lake(x: int, y: int) -> bool:
	return absf(float(x) - axis_x_at(float(y))) * axis_cos_at(y) < river_hw_at(y) + cfg.lake_exclude_margin


## Табуляция 1D-параметров по строкам прямоугольника [y0, y0 + ch) для C# и GDScript рельефа.
func sample_rows(y0: int, ch: int) -> Dictionary:
	return sample_rows_stepped(y0, ch, 1)


## Табуляция 1D-параметров для разреженной сетки [y0, y0 + rows * step) с шагом step (ближний и дальний рельеф).
func sample_rows_stepped(y0: int, rows: int, step: int) -> Dictionary:
	var ax := PackedFloat64Array()
	var ac := PackedFloat64Array()
	var fh := PackedFloat64Array()
	var hw := PackedFloat64Array()
	var bd := PackedFloat64Array()
	var sh := PackedFloat64Array()
	var sr := PackedFloat64Array()
	var osh := PackedFloat64Array()
	var osr := PackedFloat64Array()
	var wsr := PackedFloat64Array()
	var wsl := PackedFloat64Array()
	var cf := PackedFloat64Array()
	var ew := PackedFloat64Array()
	ax.resize(rows)
	ac.resize(rows)
	fh.resize(rows)
	hw.resize(rows)
	bd.resize(rows)
	sh.resize(rows)
	sr.resize(rows)
	osh.resize(rows)
	osr.resize(rows)
	wsr.resize(rows)
	wsl.resize(rows)
	cf.resize(rows)
	ew.resize(rows)
	for j in rows:
		var y := y0 + j * step
		if y >= 0 and y < H:
			ax[j] = _axis_x[y]
			ac[j] = _axis_cos[y]
			fh[j] = _floor_h[y]
			hw[j] = _river_hw[y]
			bd[j] = _bed_depth[y]
			sh[j] = _spur_h[y]
			sr[j] = _spur_reach[y]
			osh[j] = _opp_spur_h[y]
			osr[j] = _opp_spur_reach[y]
			wsr[j] = _wall_shift_r[y]
			wsl[j] = _wall_shift_l[y]
			var fade_top := smoothstep(-5.0, 1.0, float(y))
			var fade_bot := 1.0 - smoothstep(float(H - 5), float(H + 3), float(y))
			cf[j] = fade_top * fade_bot
			ew[j] = 0.0
		else:
			ax[j] = _compute_axis_x(float(y))
			ac[j] = axis_cos_at(y)
			fh[j] = floor_h_at(y)
			var near_end := y > -120 and y < H + 120
			var rs := _sample_spurs(spurs, float(y), 40.0) if near_end else Vector3(0.0, 40.0, 0.0)
			var os := _sample_spurs(opp_spurs, float(y), 32.0) if near_end else Vector3(0.0, 32.0, 0.0)
			sh[j] = rs.x
			sr[j] = rs.y
			osh[j] = os.x
			osr[j] = os.y
			var ws := _wall_shifts_at(y)
			wsr[j] = ws.x
			wsl[j] = ws.y
			if y < 0:
				var d := float(-y)
				hw[j] = _river_hw[0]
				bd[j] = _bed_depth[0]
				cf[j] = smoothstep(-5.0, 1.0, float(y))
				ew[j] = smoothstep(cfg.cirque_start, cfg.cirque_end, d) * cfg.cirque_height
			else:
				var d2 := float(y - (H - 1))
				hw[j] = _river_hw[H - 1]
				bd[j] = _bed_depth[H - 1]
				cf[j] = 1.0 - smoothstep(float(H - 5), float(H + 3), float(y))
				ew[j] = smoothstep(cfg.finish_ridge_start, cfg.finish_ridge_end, d2) * cfg.finish_ridge_height
	return {
		axis_x = ax, axis_cos = ac, floor_h = fh, river_hw = hw, bed_depth = bd,
		spur_h = sh, spur_reach = sr, opp_spur_h = osh, opp_spur_reach = osr,
		wall_shift_r = wsr, wall_shift_l = wsl, channel_fade = cf, end_wall = ew,
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


## Готовая 3D-лента реки в формате Heightfield.ribbons (метры): края заходят в берег (cfg.river_ribbon_margin_m),
## уровень воды строго невозрастает; подходит для WaterBuilder, RideGround, depth_at, current_at и SurfaceSnapshot.
func build_river_ribbon(ground_at: Callable) -> Array:
	var pts: Array = []
	var step := maxf(0.5, cfg.river_ribbon_step)
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
		var ribbon_hw_m := hw_cells * TILE + cfg.river_ribbon_margin_m
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
		var center := Vector2(p.x, p.z)
		var normal := Vector2(-dir.y, dir.x)
		p.left = _ribbon_bank(center, normal, p.w, p.y, ground_at)
		p.right = _ribbon_bank(center, -normal, p.w, p.y, ground_at)
		var incoming := Vector2(p.x - a.x, p.z - a.z).normalized()
		var outgoing := Vector2(b.x - p.x, b.z - p.z).normalized()
		p.bend = clampf(incoming.cross(outgoing) * 3.0, -1.0, 1.0)
		p.motion = Heightfield.river_motion(pts, k)
	return pts


## Fit a nominal ribbon edge to the nearest dry point when the sampled bank is lower.
static func _ribbon_bank(center: Vector2, normal: Vector2, width_m: float, level_m: float, ground_at: Callable) -> Vector3:
	var bank := center + normal * width_m
	if float(ground_at.call(bank.x, bank.y)) < level_m:
		# Search at half-metre resolution within two terrain cells of the nominal edge.
		for half_meter in range(1, int(TILE * 4.0) + 1):
			var delta := float(half_meter) * 0.5
			for offset in [-delta, delta]:
				var reach: float = width_m + offset
				if reach <= 0.0:
					continue
				var q := center + normal * reach
				if float(ground_at.call(q.x, q.y)) >= level_m:
					return Vector3(q.x, level_m, q.y)
	return Vector3(bank.x, level_m, bank.y)


## Проверка сухой проезжаемой клетки (для площадок поселений и якорей дороги).
static func _road_cell_ok(w: WorldData, river: PackedByteArray, x: int, y: int, max_slope: float, exit_grade := StageTrails.ROAD_LIMIT) -> bool:
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
			if w.slope[nb] <= maxf(0.34, max_slope) and absf(w.h[nb] - h0) * StageTrails.HEIGHT_SCALE / step <= exit_grade:
				exits += 1
	return exits >= 4


## Подбирает лучшую ровную сухую террасу в полосе [y_min, y_max] и отступе [sd_min, sd_max] по стороне side_sign.
func find_terrace_cell(w: WorldData, y_min: int, y_max: int, sd_min: float, sd_max: float, side_sign: int,
		max_slope := 0.22, prefer_y := -1.0, prefer_sd := -1.0, terrain_anchor := false) -> int:
	var river := w.river_cells()
	var y0 := clampi(y_min, 16, H - 16)
	var y1 := clampi(y_max, y0, H - 16)
	var py := prefer_y if prefer_y >= 0.0 else 0.5 * float(y0 + y1)
	var psd := prefer_sd if prefer_sd >= 0.0 else 0.5 * (sd_min + sd_max)
	var best := -1
	var best_score := -INF
	var slope_caps := [max_slope, maxf(max_slope, 0.32)]
	var exit_grade := StageTrails.ROAD_LIMIT
	var tech := terrain_anchor and cfg.anchor_terrain_slope > 0.0
	if tech:
		slope_caps = [cfg.anchor_terrain_slope]
		exit_grade = RoadTuning.for_world(w).routing.line_limits(exit_grade, 0.0).grade
	for cap: float in slope_caps:
		for y in range(y0, y1 + 1, 2):
			var ax := _axis_x[y]
			var rhw := _river_hw[y]
			var cos_t := maxf(_axis_cos[y], 0.25)
			var lo := maxf(rhw + 3.2, sd_min)
			var hi := maxf(lo + 1.0, sd_max)
			var x_a := clampi(roundi(ax + (lo / cos_t) * float(side_sign)), 6, W - 7)
			var x_b := clampi(roundi(ax + (hi / cos_t) * float(side_sign)), 6, W - 7)
			var xmin := mini(x_a, x_b)
			var xmax := maxi(x_a, x_b)
			for x in range(xmin, xmax + 1, 2):
				if not _road_cell_ok(w, river, x, y, cap, exit_grade):
					continue
				var i := y * W + x
				var sd := (float(x) - ax) * cos_t * float(side_sign)
				var dy_pen := absf(float(y) - py) / maxf(12.0, float(y1 - y0))
				var dsd_pen := absf(sd - psd) / maxf(8.0, hi - lo)
				var score := -w.slope[i] * 6.0 - dy_pen * 0.45 - dsd_pen * 0.40
				if tech:
					var d := 4
					var tpi := _anchor_tpi(w, i, d)
					var shoulder := absf(w.h[i - d] + w.h[i + d] - w.h[i - d * W] - w.h[i + d * W]) * GameConfig.HS
					score = smoothstep(0.15, 0.6, w.slope[i]) * 0.57 + smoothstep(0.25, 2.8, absf(tpi)) * 0.65
					score += smoothstep(0.4, 5.0, shoulder) * 0.33 - dy_pen * 0.85 - dsd_pen * 0.95
				if score > best_score:
					best_score = score
					best = i
		if best >= 0:
			break
	return best


## Якоря одной дороги вдоль долины: опираются на реальные поперечные отроги и береговые террасы.
## Чередуют выходы к самой воде и уходы вглубь лесных предгорий/седловин с неравным ритмом по сиду.
func road_anchors(w: WorldData, start_cell: int, finish_cell: int) -> PackedInt32Array:
	var out := PackedInt32Array()
	var start_y := start_cell / W
	var finish_y := finish_cell / W
	var span_y := finish_y - start_y
	if span_y < 110:
		return out
	var rng := WGRandom.at(seed_num, "valley.anchors")
	var events: Array[Dictionary] = []
	var prev_y := float(start_y)
	for sp: Dictionary in spurs:
		var sy: float = float(sp.y)
		if sy < float(start_y) + cfg.anchor_end_margin or sy > float(finish_y) - cfg.anchor_end_margin:
			continue
		if sy - prev_y >= cfg.anchor_basin_gap:
			var mid_y := 0.5 * (prev_y + sy)
			if mid_y >= float(start_y) + cfg.anchor_end_margin - 4.0 and mid_y <= float(finish_y) - (cfg.anchor_end_margin - 4.0):
				events.append({y = mid_y, kind = "basin", reach = 0.0})
		events.append({y = sy, kind = "spur", reach = float(sp.reach)})
		prev_y = sy
	if float(finish_y) - prev_y >= cfg.anchor_basin_gap:
		var tail_y := 0.5 * (prev_y + float(finish_y))
		if tail_y <= float(finish_y) - (cfg.anchor_end_margin - 4.0):
			events.append({y = tail_y, kind = "basin", reach = 0.0})
	if events.size() < 4:
		events.clear()
		var n := maxi(4, roundi(float(span_y) / 115.0))
		for k in range(1, n):
			var y := float(start_y) + float(span_y) * float(k) / float(n)
			events.append({y = y, kind = "spur" if k % 2 == 1 else "basin", reach = 38.0})

	var mode := "inland" if rng.next_float() < cfg.anchor_inland_start_chance else "river"
	var run_len := 0
	var target_run := 1 + (1 if rng.next_float() < 0.45 else 0)
	var last_y := start_y
	var last_sd := (float(start_cell % W) - _axis_x[start_y]) * _axis_cos[start_y] * float(road_side)
	var inland_n := 0
	var river_n := 0

	for idx in events.size():
		var ev: Dictionary = events[idx]
		var ey := roundi(float(ev.y))
		if finish_y - ey < 64:
			continue
		var want_mode := mode
		if run_len >= target_run:
			want_mode = "river" if mode == "inland" else "inland"
		elif ev.kind == "spur" and mode == "river" and run_len >= 1 and rng.next_float() < 0.65:
			want_mode = "inland"
		elif ev.kind == "basin" and mode == "inland" and run_len >= 2 and rng.next_float() < 0.70:
			want_mode = "river"
		if idx == events.size() - 2:
			if inland_n == 0: want_mode = "inland"
			elif river_n == 0: want_mode = "river"

		var rhw := river_hw_at(ey)
		var wall_lim := cfg.wall_road_start + _wall_shift_r[clampi(ey, 0, H - 1)] - 18.0
		var inland_hi := maxf(cfg.anchor_inland_min + 4.0, minf(cfg.anchor_inland_max, wall_lim))
		var est_sd := (rhw + 7.5) if want_mode == "river" else clampf((float(ev.reach) if float(ev.reach) > 10.0 else 34.0) + 12.0, cfg.anchor_inland_min, inland_hi - 2.0)
		var need_dy := maxi(cfg.anchor_min_dy, roundi(absf(est_sd - last_sd) * cfg.anchor_diag_ratio))
		if ey - last_y < need_dy:
			continue
		if want_mode != mode:
			mode = want_mode
			run_len = 0
			target_run = (1 + (1 if rng.next_float() < cfg.anchor_inland_streak_chance else 0)) if mode == "inland" else (1 + (1 if rng.next_float() < cfg.anchor_river_streak_chance else 0))

		var cell := -1
		if mode == "river":
			var sd_lo := rhw + cfg.anchor_river_pad_min
			var sd_hi := rhw + cfg.anchor_river_pad_max
			var sd_pref := lerpf(sd_lo + 1.0, sd_hi - 1.5, rng.next_float())
			cell = find_terrace_cell(w, ey - 14, ey + 14, sd_lo, sd_hi, road_side, 0.16, float(ey), sd_pref, true)
		else:
			var base_reach := float(ev.reach) if float(ev.reach) > 10.0 else 34.0
			var sd_pref := clampf(base_reach + lerpf(6.0, 18.0, rng.next_float()), cfg.anchor_inland_min, inland_hi)
			var sd_lo := maxf(cfg.anchor_inland_min - 6.0, sd_pref - 10.0)
			var sd_hi := minf(inland_hi + 4.0, sd_pref + 10.0)
			cell = find_terrace_cell(w, ey - 16, ey + 16, sd_lo, sd_hi, road_side, 0.20, float(ey), sd_pref, true)

		if cell >= 0:
			var cy := cell / W
			var csd := (float(cell % W) - _axis_x[cy]) * _axis_cos[cy] * float(road_side)
			if cy - last_y >= maxi(54, roundi(absf(csd - last_sd) * 1.7)) and finish_y - cy >= 58:
				out.append(cell)
				last_y = cy
				last_sd = csd
				run_len += 1
				if mode == "inland": inland_n += 1
				else: river_n += 1
	return out


## Corridor choices for each real spur. Groups advance down the valley, but a turn
## can lead back across its slope before the route descends to the exit.
func road_anchor_groups(w: WorldData, start: int, finish: int) -> Array[Dictionary]:
	var groups: Array[Dictionary] = []
	if cfg.anchor_traverse_reach <= 0.0:
		return groups
	for spur: Dictionary in spurs:
		var y: float = spur.y
		var span: float = spur.half_len
		if y - span < start / W + cfg.anchor_end_margin or y + span > finish / W - cfg.anchor_end_margin:
			continue
		var reach: float = spur.reach
		var inside := minf(reach + cfg.anchor_traverse_reach, cfg.wall_road_start + _wall_shift_r[roundi(y)] - 12.0)
		var entry := _spur_passage(w, y - span * 0.76, reach * 0.67, -1, false)
		var exit := _spur_passage(w, y + span * 0.80, reach * 0.74, -1, false)
		var shoulder := _spur_passage(w, y, inside, entry, false)
		if mini(mini(entry, exit), shoulder) < 0:
			continue
		var alternatives: Array[Dictionary] = []
		var approach := _spur_passage(w, y - span * 0.32, inside - 4.0, entry, false)
		var turn := _spur_passage(w, y + span * 0.39, inside + 3.0, approach, true)
		var return_leg := _spur_passage(w, y + span * 0.12, inside - 8.0, turn, false)
		if mini(mini(approach, turn), return_leg) >= 0:
			var gap := _spur_point(approach).distance_to(_spur_point(return_leg)) * GameConfig.TILE
			var drop := (w.h[approach] - w.h[return_leg]) * HS
			var lead := _spur_point(turn) - _spur_point(approach)
			var back := _spur_point(return_leg) - _spur_point(turn)
			if gap >= cfg.anchor_turn_gap_m.x and gap <= cfg.anchor_turn_gap_m.y and drop >= cfg.anchor_turn_drop_m.x \
					and drop <= cfg.anchor_turn_drop_m.y and lead.y > 0.0 and back.y < -3.0 \
					and absf(lead.angle_to(back)) >= deg_to_rad(125.0):
				alternatives.append({shape = "switchback", cells = PackedInt32Array([entry, approach, turn, return_leg, exit])})
		alternatives.append({shape = "traverse", cells = PackedInt32Array([entry, shoulder, exit])})
		var lower := _spur_passage(w, y + span * 0.14, inside - cfg.anchor_traverse_reach * 0.55, entry, false)
		var lower_exit := _spur_passage(w, y + span * 0.66, reach * 0.58, lower, false)
		if lower >= 0 and lower != shoulder and lower_exit >= 0:
			alternatives.append({shape = "lower_traverse", cells = PackedInt32Array([entry, lower, lower_exit])})
		# The connected approaches can themselves form the shoulders of an arc.
		# Retain the contour crossing when only its original lead-in or exit is blocked.
		alternatives.append({shape = "shoulder_arc", cells = PackedInt32Array([shoulder])})
		if lower >= 0 and lower != shoulder:
			alternatives.append({shape = "lower_arc", cells = PackedInt32Array([lower])})
		groups.append({y = roundi(y), options = alternatives})
	return groups


func _spur_point(i: int) -> Vector2:
	return Vector2(i % W, i / W)


static func _anchor_tpi(w: WorldData, i: int, reach: int) -> float:
	var row := reach * w.W
	return (w.h[i] - (w.h[i - reach] + w.h[i + reach] + w.h[i - row] + w.h[i + row]) * 0.25) * HS


## Search the shoulder or saddle itself. Prefer gentle continuation on contours
## and a broader, flatter patch where the route changes direction.
func _spur_passage(w: WorldData, row: float, offset: float, previous: int, turning: bool) -> int:
	var river := w.river_cells()
	var y0 := roundi(row)
	var best := -1
	var best_score := -INF
	var routing := RoadTuning.for_world(w).routing
	var climb: float = routing.line_limits(StageTrails.ROAD_LIMIT, 0.0).grade
	var descent := routing.expedition_grades.y if routing.expedition_grades.x > 0.0 and routing.expedition_grades.y > 0.0 else climb
	for y in range(maxi(16, y0 - 8), mini(H - 16, y0 + 9), 2):
		var cos_t := maxf(_axis_cos[y], 0.25)
		var x0 := roundi(_axis_x[y] + maxf(_river_hw[y] + 5.0, offset) * road_side / cos_t)
		for x in range(maxi(6, x0 - 9), mini(W - 6, x0 + 10), 2):
			if not _road_cell_ok(w, river, x, y, cfg.anchor_terrain_slope, maxf(climb, descent)):
				continue
			var i := y * W + x
			var contour_cost := 0.0
			if previous >= 0:
				var m := _spur_point(previous).distance_to(Vector2(x, y)) * GameConfig.TILE
				if m < 8.0:
					continue
				var pitch := (w.h[i] - w.h[previous]) * HS / m
				var limit := climb if pitch > 0.0 else descent
				if absf(pitch) > limit:
					continue
				contour_cost = absf(pitch) * 3.2
			var tpi := _anchor_tpi(w, i, 4)
			var patch_slope := maxf(maxf(w.slope[i - 2], w.slope[i + 2]), maxf(w.slope[i - 2 * W], w.slope[i + 2 * W]))
			var score := -w.slope[i] * 3.2 - contour_cost - absf(tpi) * (0.26 if turning else 0.08)
			score -= absf(float(y - y0)) * 0.045 + absf(float(x - x0)) * 0.06
			if turning:
				score -= patch_slope * 4.0
			if score > best_score:
				best_score = score
				best = i
	return best
