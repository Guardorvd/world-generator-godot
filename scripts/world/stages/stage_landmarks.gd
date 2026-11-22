class_name StageLandmarks
extends RefCounted
## Этап 6. Поселения с домами и вершины с названиями.
## Пишет: w.settlements [{x, y, i, name, town, homes, style, character, huts: []}], w.peaks [{x, y, i, elev, name}].
## Дома (huts) ставит lay_out после путей.

const Roles := preload("res://scripts/world/settlement_roles.gd")

const PROGRESS := 0.46
const LABEL := "Основание поселений"
const LAYOUT_R := 6.8 # клеток: дома и сараи не дальше от костра (вырубка леса у поселения — 7 клеток)

## 16.11.2026 (план «Поселения и география дорог»): вода — преимущество площадки, но не сильнее биома.
## Раньше водный член (+0,6 у берега, до −0,6 вдали) перевешивал всё остальное: у воды 2–3 % кандидатов,
## а выбиралось туда 85 % поселений. Теперь он вдвое слабее.
const WATER_WEIGHT := 0.5
## Поправка на удалённость в отборе плана: следующее место получает до SPREAD к оценке, если до ближайшего
## уже выбранного не меньше SPREAD_R клеток. Группы в пятнах плотности остаются, но вся карта заселяется равномернее.
const SPREAD := 0.5
const SPREAD_R := 250.0
const BORDER_MIN := 24.0
const COVER_BORDER_MIN := 42.0
const COVER_GRID := 3
const COVER_MAX := 3
const COVER_WALK_GRADE := 0.34 # запас для поиска площадки, фактический подъезд проверяет StageTrails
const COVER_GAP := 150.0 # клеток (600 м): минимальный радиус просвета для добавки покрытия
const COVER_EDGE_GAP := 125.0 # клеток: минимальный эффективный радиус с учётом зеркала границы (2.2 * border)
## Прежний отбор (стенд settlement_look.gd -- --legacy): водный член целиком, без поправки на удалённость.
static var legacy := false


## Оценка площадки поселения — одна для плана (здесь и FastGrid.SettlementCandidates) и соседних областей
## (RegionSettlements). Порядок действий не менять: при legacy результат совпадает с прежним до бита.
static func site_score(habit: float, noise: float, slope: float, access: float, density: float, dw: float) -> float:
	var score := habit + noise * 0.2 - slope * 0.6
	score += access * 0.45 + density * 0.35
	var k := water_weight()
	if dw >= 1.5 and dw <= 6.0:
		score += 0.6 * k
	elif dw > 16.0:
		score -= minf(0.6, (dw - 16.0) / 40.0) * k
	# Сухая площадка непосредственно у воды уступает береговой террасе.
	if dw < 1.5:
		score -= 0.4 * k
	return score


static func water_weight() -> float:
	return 1.0 if legacy else WATER_WEIGHT


static func run(w: WorldData) -> void:
	_place_settlements(w)
	_place_peaks(w)


## Сортировка кандидатов [score, i] по убыванию; при равенстве — по порядку добавления (как стабильная сортировка JS)
static func _by_score_desc(a: Array, b: Array) -> bool:
	if a[0] != b[0]:
		return a[0] > b[0]
	return a[1] < b[1]


static func _place_settlements(w: WorldData) -> void:
	if WorldTemplate.has_single_road(w.template_id):
		_place_expedition_settlements(w)
		return
	var W := w.W
	var H := w.H
	var candidate_seed := WGRandom.derive(w.seed_num, "settlement.candidate")
	var density_seed := WGRandom.derive(w.seed_num, "settlement.density")
	var biome := w.biome
	var river := w.river_cells()
	var dist_water := w.dist_water
	var ocean := w.ocean
	var lake := w.lake
	var settlements: Array = []
	# Не размещаем поселение за проливом, который шире любого допустимого моста.
	# Иначе дороги перебирают все соседние поселения и десятки объездов без шанса на связь.
	var wet := PackedByteArray()
	wet.resize(w.N)
	for i in w.N:
		wet[i] = 1 if ocean[i] != 0 or lake[i] != 0 or river[i] != 0 else 0
	var corridor_wet := wet.duplicate()
	var surface := w.base_heights
	if surface != null and surface.water_level.size() == w.N and surface.hv.size() == w.N:
		for i in w.N:
			if surface.water_level[i] > 0.0 and surface.water_level[i] - 0.15 > surface.hv[i]:
				corridor_wet[i] = 1
	var reachable := Grid.bridge_region(W, H, wet, StageTrails.SPAN)
	var cand := _settlement_candidates(w, river, wet, reachable, candidate_seed, density_seed)
	# Плотность мира зависит от сида. С 9.3 деревень почти вдвое меньше и они дальше друг от друга:
	# мелкое жильё между ними — хутора и одинокие дома (StageSites).
	var maximum := clampi(roundi(7.0 * w.scale), 3, 16)
	var minimum := maxi(2, ceili(maximum * 0.5))
	var density := WGRandom.new(w.seed_num ^ 0x5e771e)
	var want := minimum + floori(density.next_float() * (maximum - minimum + 1))
	var min_d := maxf(32.0, W / 8.0)
	var pick := {cand = cand, dead = PackedByteArray(), min_d = min_d, spread = 0.0 if legacy else SPREAD,
		fields = {}, centers = [], corridor_wet = corridor_wet}
	pick.dead.resize(cand.size() / 4) # кандидат выбран или слишком близко к выбранному (выбранных только прибавляется)
	# Роли слотов (с 16.11, SettlementRoles): центры, спутники, лес, предгорья, обычные, удалённые. Legacy — все обычные.
	var slots: Array[String] = []
	var lists := {} # роль -> номера подходящих кандидатов по убыванию оценки (только для ролей с постоянным условием)
	if legacy:
		for k in want: slots.append("ordinary")
	else:
		slots = Roles.slots(w.seed_num, want)
		pick.fields = Roles.fields(w)
		lists[""] = Roles.thin(w, pick.fields, cand, "")
		for role: String in ["forest", "foothill"]:
			lists[role] = Roles.thin(w, pick.fields, cand, role)
	var thin_all: PackedInt32Array = lists.get("", PackedInt32Array())
	for slot: String in slots:
		var role := slot
		var best := _best(w, settlements, pick, role, lists.get(role, thin_all))
		if not legacy and settlements.is_empty() and best >= 0:
			# Первый центр не должен оказаться в изолированном кармане: проверяем, что его область walk
			# охватывает основную связную часть пригодной суши.
			var best_fallback := best
			var best_walk := Roles.walk(w, corridor_wet, int(cand[best * 4 + 1]))
			var best_reach := _count_walk_candidates(cand, thin_all, best_walk)
			var tries := 0
			while best >= 0 and best_reach * 2 < thin_all.size() and tries < 8:
				pick.dead[best] = 1
				tries += 1
				var next_best := _best(w, settlements, pick, role, lists.get(role, thin_all))
				if next_best < 0:
					break
				var next_walk := Roles.walk(w, corridor_wet, int(cand[next_best * 4 + 1]))
				var next_reach := _count_walk_candidates(cand, thin_all, next_walk)
				if next_reach > best_reach:
					best_fallback = next_best
					best_walk = next_walk
					best_reach = next_reach
				best = next_best
			best = best_fallback
			pick.walk = best_walk
		if best < 0 and role != "ordinary":
			# Карта не даёт места этой роли (нет гор, леса, свободного кольца у центра) — обычное место.
			role = "ordinary"
			best = _best(w, settlements, pick, role, thin_all)
		if best < 0:
			break
		pick.dead[best] = 1
		var at := best * 4
		var i := int(cand[at + 1])
		var x := (i % W) + 0.5
		var y := (i / W) + 0.5
		# Берег большой воды и удобная долина делают место узлом округи; у ролей важность для сети — своя.
		var shore := 0.12 if dist_water[i] < 6.0 else 0.0
		var importance := clampf(float(biome[i] == Biomes.GRASS) * 0.15 + cand[at + 2] * 0.5 + cand[at + 3] * 0.3 + shore, 0.0, 1.0)
		var settlement := SettlementData.new(x, y, i, w.make_name(Names.SETTLEMENT, "settlement", floori(x), floori(y)))
		settlement.spacing = min_d * lerpf(1.35, 0.90, cand[at + 3])
		settlement.importance = Roles.ROLES[role].importance if Roles.ROLES.has(role) else importance
		settlement.role = "" if legacy else role
		if role == "center": pick.centers.append(Vector2(x, y))
		if not legacy and settlements.is_empty() and not pick.has("walk"):
			pick.walk = Roles.walk(w, corridor_wet, i)
		settlements.append(settlement)
	var main_count := settlements.size()
	# Роль задаёт размер сама. Среди мест без роли (обычные; legacy — все) посёлков примерно треть, самые важные места:
	# их доля не зависит от того, сколько мест заняли роли и проход покрытия.
	var ranks: Array = settlements.filter(func(s: SettlementData) -> bool: return not Roles.ROLES.has(s.role)) \
		.map(func(s: SettlementData) -> float: return s.importance)
	ranks.sort()
	var town_from: float = ranks[ranks.size() - ceili(ranks.size() / 3.0)] if not ranks.is_empty() else 1.0
	var cover_cells := PackedInt32Array()
	if not legacy and not settlements.is_empty():
		cover_cells = _cover_sectors(w, settlements, pick, lists.get("", PackedInt32Array()))
	w.generation.coverage_cells = cover_cells
	w.generation_profile.cover_added = cover_cells.size()
	w.generation_profile.cover_cells = cover_cells
	for idx in settlements.size():
		var s: SettlementData = settlements[idx]
		var rng := WGRandom.at(w.seed_num, "settlement.huts", floori(s.x), floori(s.y))
		var role: Dictionary = Roles.ROLES.get(s.role, {})
		# Посёлок — узел округи: вдвое больше домов, чем у деревни. Сами дома ставит lay_out,
		# когда известны дороги (с 9.5): улицы — это дороги и тропы, пришедшие в поселение.
		# Проход покрытия добавляет только деревни/хутора (idx >= main_count).
		s.town = false if idx >= main_count else (role.town if role.has("town") else s.importance >= town_from)
		if role.has("homes"):
			s.homes = int(role.homes[0]) + floori(rng.next_float() * (int(role.homes[1]) - int(role.homes[0]) + 1))
		else:
			s.homes = (8 if s.town else 4) + roundi(s.importance * 3.0) + floori(rng.next_float() * 3)
		# Облик поселения: свои крыши, штукатурка и ставни, чтобы соседние деревни не были копиями
		s.style = floori(rng.next_float() * 4)
		s.character = _character(w, s.i, s.town, Roles.character(s.role, w, pick.fields, s.i))
	w.settlements = settlements


## Тип 2 («Речная экспедиция»): два опорных поселения по дорожному берегу —
## старт-лагерь в верховье (индекс 0) и финишная речная база перед закрытым поворотом (индекс 1).
static func _place_expedition_settlements(w: WorldData) -> void:
	var W := w.W
	var H := w.H
	var axis := ValleyAxis.for_world(w)
	var cfg := axis.cfg
	var start_y_pref := roundi(0.5 * float(cfg.start_y_min + mini(cfg.start_y_max, H / 4)))
	var finish_y_min := maxi(H - cfg.finish_from_end_max, H * 3 / 4)
	var finish_y_max := H - cfg.finish_from_end_min
	var finish_y_pref := roundi(0.5 * float(finish_y_min + finish_y_max))
	var start_rhw := axis.river_hw_at(54)
	var finish_rhw := axis.river_hw_at(H - 94)
	var settlements: Array = []
	var specs := [
		{
			y_min = cfg.start_y_min, y_max = mini(cfg.start_y_max, H / 4),
			sd_min = start_rhw + cfg.start_sd_min, sd_max = start_rhw + cfg.start_sd_max,
			prefer_y = float(start_y_pref if cfg.start_y_min != 42 or cfg.start_y_max != 72 else 54),
			prefer_sd = start_rhw + 0.5 * (cfg.start_sd_min + minf(cfg.start_sd_max, 12.5)),
			role = "forest", importance = 0.90, homes_min = cfg.start_homes_min, homes_max = cfg.start_homes_max,
			character = "лагерь в верховье",
		},
		{
			y_min = finish_y_min, y_max = finish_y_max,
			sd_min = finish_rhw + cfg.finish_sd_min, sd_max = finish_rhw + cfg.finish_sd_max,
			prefer_y = float(finish_y_pref if cfg.finish_from_end_max != 114 or cfg.finish_from_end_min != 72 else H - 94),
			prefer_sd = finish_rhw + 0.5 * (cfg.finish_sd_min + minf(cfg.finish_sd_max, 11.5)),
			role = "coastal", importance = 0.85, homes_min = cfg.finish_homes_min, homes_max = cfg.finish_homes_max,
			character = "речная база",
		},
	]
	for spec: Dictionary in specs:
		var cell := axis.find_terrace_cell(w, int(spec.y_min), int(spec.y_max),
			float(spec.sd_min), float(spec.sd_max), axis.road_side, 0.16, float(spec.prefer_y), float(spec.prefer_sd))
		if cell < 0:
			cell = axis.find_terrace_cell(w, int(spec.y_min) - 12, int(spec.y_max) + 12,
				float(spec.sd_min), float(spec.sd_max) + 14.0, axis.road_side, 0.30, float(spec.prefer_y), float(spec.prefer_sd))
		if cell < 0:
			var fy := clampi(roundi(float(spec.prefer_y)), 24, H - 24)
			var fx := clampi(roundi(axis.axis_x_at(float(fy)) + float(spec.prefer_sd) * float(axis.road_side)), 8, W - 9)
			cell = fy * W + fx
		var x := (cell % W) + 0.5
		var y := (cell / W) + 0.5
		var rng := WGRandom.at(w.seed_num, "settlement.huts", floori(x), floori(y))
		var s := SettlementData.new(x, y, cell, w.make_name(Names.SETTLEMENT, "settlement", floori(x), floori(y)))
		s.spacing = 64.0
		s.importance = float(spec.importance)
		s.role = str(spec.role)
		s.town = false
		s.homes = int(spec.homes_min) + floori(rng.next_float() * float(int(spec.homes_max) - int(spec.homes_min) + 1))
		s.style = floori(rng.next_float() * 4)
		s.character = str(spec.character)
		settlements.append(s)
	w.generation.coverage_cells = PackedInt32Array()
	w.generation_profile.cover_added = 0
	w.generation_profile.cover_cells = PackedInt32Array()
	w.settlements = settlements


## Сколько прореженных кандидатов попадает в область пешей досягаемости walk
static func _count_walk_candidates(cand: PackedFloat64Array, thin_all: PackedInt32Array, walk: PackedByteArray) -> int:
	if walk.is_empty():
		return thin_all.size()
	var reached := 0
	for k: int in thin_all:
		if walk[int(cand[k * 4 + 1])] != 0:
			reached += 1
	return reached


## Проверка выхода дорожного коридора (ширина 4 м, полуширина 0.5 клетки) из клетки поселения i:
## все 8 соседних клеток должны быть сухими с учётом прорезанного русла (corridor_wet == 0),
## уклон самой клетки <= 0.34, и хотя бы в 4 направлениях шаг не круче ROAD_LIMIT.
static func _site_exit_ok(w: WorldData, corridor_wet: PackedByteArray, i: int) -> bool:
	if w.slope[i] > 0.34:
		return false
	var W := w.W
	var H := w.H
	var x := i % W
	var y := i / W
	if x < 2 or y < 2 or x >= W - 2 or y >= H - 2:
		return false
	var h0 := w.h[i]
	var exits := 0
	for dy in range(-1, 2):
		for dx in range(-1, 2):
			var nb := (y + dy) * W + (x + dx)
			if not corridor_wet.is_empty() and corridor_wet[nb] != 0:
				return false
			if dx == 0 and dy == 0:
				continue
			var step := 1.41421356 if dx != 0 and dy != 0 else 1.0
			if w.slope[nb] <= 0.34 and absf(w.h[nb] - h0) * StageTrails.HEIGHT_SCALE / step <= StageTrails.ROAD_LIMIT:
				exits += 1
	return exits >= 4


## Номер области 0..8 в сетке COVER_GRID × COVER_GRID плана W × H
static func sector_of(i: int, W: int, H: int) -> int:
	return mini(COVER_GRID - 1, (i / W) * COVER_GRID / H) * COVER_GRID + mini(COVER_GRID - 1, (i % W) * COVER_GRID / W)


## Проход покрытия после основного отбора: ищет крупнейшие незаселённые просветы пригодной суши
## (gap_r = min(nearest_settlement, 2.2 * border) >= COVER_EDGE_GAP и nearest >= COVER_GAP),
## предварительно доступные от первого центра с запасом для горного подъезда и с сухим выездом (_site_exit_ok).
## Не привязан жёстко к границам секторов 3×3 (закрывает и центральные долины, и свободные углы вдали от края карты).
## Добавляет роль ordinary (деревня), ≤ COVER_MAX на мир.
static func _cover_sectors(w: WorldData, settlements: Array, pick: Dictionary, thin_all: PackedInt32Array) -> PackedInt32Array:
	var W := w.W
	var H := w.H
	var cand: PackedFloat64Array = pick.cand
	var corridor_wet: PackedByteArray = pick.get("corridor_wet", PackedByteArray())
	var walk := Roles.walk(w, corridor_wet, settlements[0].i, COVER_WALK_GRADE)
	var dist_water := w.dist_water
	var biome := w.biome
	var min_d: float = pick.min_d
	var sectors := COVER_GRID * COVER_GRID
	var covered := PackedByteArray()
	covered.resize(sectors)
	var sec_main := [0, 0, 0, 0, 0, 0, 0, 0, 0]
	var sec_cand := [0, 0, 0, 0, 0, 0, 0, 0, 0]
	var sec_walk := [0, 0, 0, 0, 0, 0, 0, 0, 0]
	for s: SettlementData in settlements:
		var sec := sector_of(s.i, W, H)
		covered[sec] = 1
		sec_main[sec] += 1
	for c in cand.size() / 4:
		var ci := int(cand[c * 4 + 1])
		var sec := sector_of(ci, W, H)
		sec_cand[sec] += 1
		if walk.is_empty() or walk[ci] != 0:
			sec_walk[sec] += 1
	w.generation_profile.sector_cand = sec_cand
	w.generation_profile.sector_walk = sec_walk
	w.generation_profile.sector_main = sec_main.duplicate()
	var valid_k := PackedInt32Array()
	for k: int in thin_all:
		var ci := int(cand[k * 4 + 1])
		if (walk.is_empty() or walk[ci] != 0) and _site_exit_ok(w, corridor_wet, ci):
			var cx := (ci % W) + 0.5
			var cy := (ci / W) + 0.5
			if minf(minf(cx, cy), minf(W - cx, H - cy)) >= COVER_BORDER_MIN:
				valid_k.append(k)
	var added := PackedInt32Array()
	while added.size() < COVER_MAX:
		# 1. Найти наибольший геометрический радиус пустого круга gap_r = min(nearest, 2.2 * border)
		var max_gap := 0.0
		var max_empty_sec_gap := 0.0
		for k: int in valid_k:
			if pick.dead[k] != 0:
				continue
			var at := k * 4
			var ci := int(cand[at + 1])
			var cx := (ci % W) + 0.5
			var cy := (ci / W) + 0.5
			var spacing: float = min_d * lerpf(1.35, 0.90, cand[at + 3])
			var close := false
			var nearest := INF
			for s: SettlementData in settlements:
				var d := Grid.hypot(s.x - cx, s.y - cy)
				if d < (spacing + s.spacing) * 0.5:
					close = true
					break
				nearest = minf(nearest, d)
			if close:
				pick.dead[k] = 1
				continue
			if nearest < COVER_GAP:
				continue
			var border := minf(minf(cx, cy), minf(W - cx, H - cy))
			var gap_r := minf(nearest, 2.2 * border)
			if gap_r < COVER_EDGE_GAP:
				continue
			max_gap = maxf(max_gap, gap_r)
			if covered[sector_of(ci, W, H)] == 0:
				max_empty_sec_gap = maxf(max_empty_sec_gap, gap_r)
		if max_gap < COVER_EDGE_GAP:
			break
		# Если есть пустой сектор 3×3 с достойным просветом вдали от края, сначала закрываем его или конкурирующий
		# центральный просвет; иначе закрываем крупнейший просвет карты (например, центральную долину).
		var prefer_empty_sec := max_empty_sec_gap >= COVER_EDGE_GAP and max_empty_sec_gap >= max_gap - 55.0
		var target_gap := maxf(COVER_EDGE_GAP, (max_empty_sec_gap if prefer_empty_sec else max_gap) - 38.0)
		var best_k := -1
		var best_val := -INF
		for k: int in valid_k:
			if pick.dead[k] != 0:
				continue
			var at := k * 4
			var ci := int(cand[at + 1])
			var sec := sector_of(ci, W, H)
			if prefer_empty_sec and covered[sec] != 0 and max_gap - max_empty_sec_gap < 28.0:
				continue
			var cx := (ci % W) + 0.5
			var cy := (ci / W) + 0.5
			var nearest := INF
			for s: SettlementData in settlements:
				nearest = minf(nearest, Grid.hypot(s.x - cx, s.y - cy))
			if nearest < COVER_GAP:
				continue
			var border := minf(minf(cx, cy), minf(W - cx, H - cy))
			var gap_r := minf(nearest, 2.2 * border)
			if gap_r < target_gap:
				continue
			var sec_bonus := 0.20 if covered[sec] == 0 else (0.08 if sec_main[sec] == 1 else 0.0)
			var val: float = cand[at] + 0.85 * minf(gap_r, SPREAD_R) / SPREAD_R + sec_bonus
			if val > best_val or (val == best_val and k < best_k):
				best_val = val
				best_k = k
		if best_k < 0:
			break
		var chosen_sec := sector_of(int(cand[best_k * 4 + 1]), W, H)
		covered[chosen_sec] = 1
		sec_main[chosen_sec] += 1
		_append_cover_settlement(w, settlements, pick, best_k, min_d, dist_water, biome, added)
	return added


static func _append_cover_settlement(w: WorldData, settlements: Array, pick: Dictionary, best_k: int,
		min_d: float, dist_water: PackedFloat32Array, biome: PackedByteArray, added: PackedInt32Array) -> void:
	var W := w.W
	var cand: PackedFloat64Array = pick.cand
	pick.dead[best_k] = 1
	var at := best_k * 4
	var i := int(cand[at + 1])
	var x := (i % W) + 0.5
	var y := (i / W) + 0.5
	var shore := 0.12 if dist_water[i] < 6.0 else 0.0
	var importance := clampf(float(biome[i] == Biomes.GRASS) * 0.15 + cand[at + 2] * 0.5 + cand[at + 3] * 0.3 + shore, 0.0, 1.0)
	var settlement := SettlementData.new(x, y, i, w.make_name(Names.SETTLEMENT, "settlement", floori(x), floori(y)))
	settlement.spacing = min_d * lerpf(1.35, 0.90, cand[at + 3])
	settlement.importance = importance
	settlement.role = "ordinary"
	settlements.append(settlement)
	added.append(i)


## Номер лучшего кандидата для слота роли или -1. Оценка + поправка на удалённость + прибавка роли;
## кандидаты идут по убыванию оценки (order — только подходящие роли, пусто — все), просмотр кончается, когда
## оценка + наибольшие поправки уже не обгонит лучшего; при равенстве — раньше в списке. Без поправок (legacy) —
## первый живой кандидат, как прежний отбор.
static func _best(w: WorldData, settlements: Array, pick: Dictionary, role: String, order: PackedInt32Array) -> int:
	var cand: PackedFloat64Array = pick.cand
	var dead: PackedByteArray = pick.dead
	var spread: float = pick.spread
	var min_d: float = pick.min_d
	var walk: PackedByteArray = pick.get("walk", PackedByteArray())
	var corridor_wet: PackedByteArray = pick.get("corridor_wet", PackedByteArray())
	var top := spread + Roles.max_bonus(role)
	var listed := not legacy # с ролями — прореженные списки (Roles.thin), legacy — все кандидаты, как раньше
	var count := order.size() if listed else cand.size() / 4
	var best := -1
	var best_value := -INF
	for n in count:
		var k: int = order[n] if listed else n
		if dead[k] != 0:
			continue
		var at := k * 4
		if best >= 0 and cand[at] + top <= best_value:
			break
		var i := int(cand[at + 1])
		if not walk.is_empty() and walk[i] == 0:
			continue
		if listed and not _site_exit_ok(w, corridor_wet, i):
			continue
		var x := (i % w.W) + 0.5
		var y := (i / w.W) + 0.5
		var border := minf(minf(x, y), minf(w.W - x, w.H - y))
		if listed and border < BORDER_MIN:
			continue
		# Благоприятные долины дают группы деревень, бедные окраины — редкие места.
		# Радиусы обоих соседей действуют и через границу любой области.
		var spacing: float = min_d * lerpf(1.35, 0.90, cand[at + 3])
		var close := false
		# Зеркало границы 2.2 * border не штрафует внутреннюю часть карты (при border >= 114 клеток 2.2 * border >= SPREAD_R),
		# но плавно удерживает поселения от прилипания к самому краю плана.
		var edge := 2.2 * border
		var nearest := edge if top > 0.0 else 0.0
		for s: SettlementData in settlements:
			var dx: float = s.x - x
			var dy: float = s.y - y
			var separation: float = (spacing + s.spacing) * 0.5
			if dx * dx + dy * dy < separation * separation:
				close = true
				break
			if top > 0.0:
				nearest = minf(nearest, sqrt(dx * dx + dy * dy))
		if close:
			dead[k] = 1
			continue
		var extra := Roles.bonus(role, w, pick.fields, i, x, y, nearest, pick.centers) if not pick.fields.is_empty() else 0.0
		if extra == -INF:
			continue
		var value: float = cand[at] + spread * minf(nearest, SPREAD_R) / SPREAD_R + extra
		if value > best_value:
			best = k
			best_value = value
		if top == 0.0:
			break
	return best


static func _settlement_candidates(w: WorldData, river: PackedByteArray, wet: PackedByteArray, reachable: PackedByteArray,
		candidate_seed: int, density_seed: int) -> PackedFloat64Array:
	var W := w.W
	var H := w.H
	var biome := w.biome
	var slope := w.slope
	var dist_water := w.dist_water
	var fast := Grid.fast_grid()
	if fast != null:
		var habit := PackedFloat64Array()
		for definition: Dictionary in Biomes.LIST:
			habit.append(definition.get("habit", -INF))
		return fast.SettlementCandidates(W, H, biome, wet, reachable, slope, dist_water, habit, candidate_seed, density_seed, water_weight())
	var cand: Array = []
	for y in range(6, H - 6, 2):
		for x in range(6, W - 6, 2):
			var i := y * W + x
			var bd: Dictionary = Biomes.LIST[biome[i]]
			if not bd.has("habit") or river[i] != 0 or slope[i] > 0.6:
				continue
			if wet[i] != 0 or reachable[i] == 0:
				continue
			# Центр на ровной клетке ещё не означает пригодную долину: нужны сухие
			# окрестности для домов и подходов. Пять проб вместо нового поля/поиска пути.
			var access := _site_access(w, i, wet)
			if access < 0.35:
				continue
			var density_value := patches(x, y, 96.0, density_seed)
			var score := site_score(bd.habit, WGRandom.hash2(x, y, candidate_seed), slope[i], access, density_value, dist_water[i])
			cand.append([score, i, access, density_value])
	cand.sort_custom(_by_score_desc)
	var columns := PackedFloat64Array()
	columns.resize(cand.size() * 4)
	for i in cand.size():
		for column in 4:
			columns[i * 4 + column] = cand[i][column]
	return columns


## Дома, площадь и хозяйственные постройки (с 9.5, после путей). Улица — путь людей у поселения: дома
## стоят по обе её стороны дверью к ней, за ними второй ряд и сараи, в середине свободная площадь
## с костром (у посёлка — шире и с колодцем). Где путей мало, остальные дома встают кольцом у площади.
## Пишет s.huts [{x, y, v, t — вид (SettlementsBuilder.HOMES или хозяйственная постройка), a — поворот как у Basis(UP, a)}].
static func lay_out(w: WorldData) -> void:
	var river := w.river_cells()
	var ground := Heightfield.base_of(w)
	for s: SettlementData in w.settlements:
		s.huts = _lay_out_one(w, ground, river, s, false)


## Сколько жилых домов встанет у площадки s при нынешних путях, без хозяйственного пояса и без записи
## в s (аудит 29.10: площадка оценивается до дорог, окончательные дома ставятся один раз).
static func capacity(w: WorldData, ground: Heightfield, river: PackedByteArray, s: SettlementData) -> int:
	return _lay_out_one(w, ground, river, s, true).size()


static func _plaza_radius(set_kind: String, town: bool) -> float:
	match set_kind:
		"center":
			return 2.55 if town else 2.10
		"ordinary", "coastal":
			return 2.10 if town else 1.65
		"forest":
			return 2.05
		"foothill":
			return 1.80
		"remote":
			return 1.35
	return 2.4 if town else 1.9


static func _lay_out_one(w: WorldData, ground: Heightfield, river: PackedByteArray, s: SettlementData, homes_only: bool) -> Array[HutData]:
	var W := w.W
	var rng := WGRandom.at(w.seed_num, "settlement.layout", floori(s.x), floori(s.y))
	var town: bool = s.town
	var set_kind := SettlementSets.kind_of(w, s)
	var plaza := _plaza_radius(set_kind, town)
	var slots: Array = [] # Vector4(порядок, x, y, поворот)

	# Улицы: клетки путей вокруг площади; направление улицы — главная ось соседних клеток пути
	for y in range(floori(s.y - LAYOUT_R), ceili(s.y + LAYOUT_R)):
		for x in range(floori(s.x - LAYOUT_R), ceili(s.x + LAYOUT_R)):
			if x < 1 or y < 1 or x >= W - 1 or y >= w.H - 1 or w.path_mask[y * W + x] < 2:
				continue
			var c := Vector2(x + 0.5, y + 0.5)
			var r := c.distance_to(Vector2(s.x, s.y))
			if r < plaza - 0.6 or r > LAYOUT_R - 1.5:
				continue
			var sxx := 0.0
			var syy := 0.0
			var sxy := 0.0
			for dy in range(-2, 3):
				for dx in range(-2, 3):
					var j := clampi(y + dy, 0, w.H - 1) * W + clampi(x + dx, 0, W - 1)
					if w.path_mask[j] >= 2:
						sxx += dx * dx
						syy += dy * dy
						sxy += dx * dy
			var along := 0.5 * atan2(2.0 * sxy, sxx - syy)
			var t := Vector2(cos(along), sin(along))
			var n := Vector2(-t.y, t.x)
			for side: float in [-1.0, 1.0]:
				for row in 2:
					var p := c + n * side * (1.75 + row * 2.5) + t * (rng.next_float() - 0.5) * 0.6
					var face := -n * side
					var dist_s := p.distance_to(Vector2(s.x, s.y))
					var order := dist_s + row * 2.2 + rng.next_float() * 0.8
					if set_kind in ["ordinary", "coastal"]:
						order = row * 4.2 + dist_s * 0.45 + rng.next_float() * 0.6
						if set_kind == "coastal" and p.x >= 0.0 and p.y >= 0.0 and floori(p.x) < W and floori(p.y) < w.H:
							var dw: float = w.dist_water[floori(p.y) * W + floori(p.x)]
							if dw >= 1.2 and dw <= 5.5:
								order -= 1.8
					elif set_kind == "forest":
						order = dist_s + row * 2.8 + 1.4 + rng.next_float() * 0.9
					elif set_kind == "foothill":
						order = dist_s * 0.85 + row * 2.4 + 0.8 + rng.next_float() * 0.8
					elif set_kind == "remote":
						order = dist_s + row * 3.0 + 1.8 + rng.next_float() * 0.8
					slots.append(Vector4(order, p.x, p.y, atan2(face.x, face.y)))

	_add_composition_slots(slots, w, ground, s, set_kind, plaza, rng)
	# Vector4 сортируется встроенным сравнением: сначала ближние к приоритетным зонам места
	slots.sort()

	var huts: Array[HutData] = []
	var homes: int = s.homes
	var placed := 0
	var need_hall := (set_kind == "center" and town)
	for sl: Vector4 in slots:
		if placed >= homes:
			break
		var p := Vector2(sl.y, sl.z)
		var r := p.distance_to(Vector2(s.x, s.y))
		if r < plaza or r > LAYOUT_R - 1.0:
			continue
		var kind := "tall_hall" if need_hall else _house_kind(s, r - plaza, rng.next_float(), set_kind)
		if need_hall and (_crowded(huts, p, 2.25) or not _fits(w, ground, river, p, sl.w, kind)):
			kind = _house_kind(s, r - plaza, rng.next_float(), set_kind)
		if _crowded(huts, p, 1.95) or not _fits(w, ground, river, p, sl.w, kind):
			continue
		if kind == "tall_hall":
			need_hall = false
		var variant := floori(rng.next_float() * 4)
		var yaw_spread := 0.30 if set_kind in ["forest", "remote"] else 0.12
		var angle := sl.w + (rng.next_float() - 0.5) * yaw_spread
		if not _fits(w, ground, river, p, angle, kind):
			angle = sl.w
		huts.append(HutData.new(p.x, p.y, variant, kind, angle))
		placed += 1
	if homes_only:
		return huts

	# Хозяйственный пояс: за частью домов, дальше от улицы — по набору вида поселения (SettlementSets)
	var chance := SettlementSets.outbuilding_chance(set_kind, s)
	var out_dist := 1.68 if set_kind == "remote" else 1.90
	for h in placed:
		var u: HutData = huts[h]
		if rng.next_float() > chance:
			continue
		var back := Vector2(-sin(u.a), -cos(u.a))
		var side := Vector2(back.y, -back.x) * (rng.next_float() - 0.5) * (1.8 if set_kind in ["forest", "remote"] else 1.4)
		var p := Vector2(u.x, u.y) + back * (out_dist + rng.next_float() * 0.5) + side
		var kind := SettlementSets.pick_outbuilding(set_kind, s, rng.next_float())
		var a: float = u.a + (PI / 2.0 if kind in ["barn", "barn_loft"] and rng.next_float() < 0.5 else 0.0)
		if p.distance_to(Vector2(s.x, s.y)) > LAYOUT_R - 0.3 or _crowded(huts, p, 1.45) or not _fits(w, ground, river, p, a, kind):
			continue
		huts.append(HutData.new(p.x, p.y, floori(rng.next_float() * 4), kind, a))

	# Характерные объекты на площади, у берега или на краю дворов
	var landmarks: Array = SettlementSets.SETS.get(set_kind, SettlementSets.SETS.ordinary).get("landmarks", [])
	for lm: Dictionary in landmarks:
		if town or rng.next_float() < float(lm.get("chance", 0.4)):
			_place_landmark(w, ground, river, s, huts, str(lm.id))
	return huts


static func _add_composition_slots(slots: Array, w: WorldData, ground: Heightfield, s: SettlementData,
		set_kind: String, plaza: float, rng: WGRandom) -> void:
	var W := w.W
	match set_kind:
		"center":
			# Парадное кольцо вокруг центральной площади + внешнее кольцо кварталов
			for k in 16:
				var a := TAU * k / 16.0 + rng.next_float() * 0.16
				var r := plaza + 0.25 + rng.next_float() * 0.75
				var p := Vector2(s.x + cos(a) * r, s.y + sin(a) * r)
				slots.append(Vector4(r * 0.82 + rng.next_float() * 0.5, p.x, p.y, atan2(s.x - p.x, s.y - p.y)))
			for k in 16:
				var a := TAU * k / 16.0 + 0.2 + rng.next_float() * 0.2
				var r := plaza + 1.4 + rng.next_float() * 2.3
				var p := Vector2(s.x + cos(a) * r, s.y + sin(a) * r)
				slots.append(Vector4(r + 3.2 + rng.next_float(), p.x, p.y, atan2(s.x - p.x, s.y - p.y)))
		"forest":
			# Живописная несимметричная расстановка на лесных полянах
			var ang := rng.next_float() * TAU
			for k in 22:
				ang += (TAU / 22.0) * (0.45 + rng.next_float() * 1.10)
				var r := plaza + 0.15 + rng.next_float() * 3.45
				var p := Vector2(s.x + cos(ang) * r, s.y + sin(ang) * r)
				var face := atan2(s.x - p.x, s.y - p.y) + (rng.next_float() - 0.5) * 0.55
				slots.append(Vector4(r * 0.95 + rng.next_float() * 1.6, p.x, p.y, face))
		"foothill":
			# Ступенчатые террасы вдоль горизонталей склона на 3 уступах
			var gx := ground.ground_at((s.x + 2.0) * GameConfig.TILE, s.y * GameConfig.TILE) - ground.ground_at((s.x - 2.0) * GameConfig.TILE, s.y * GameConfig.TILE)
			var gz := ground.ground_at(s.x * GameConfig.TILE, (s.y + 2.0) * GameConfig.TILE) - ground.ground_at(s.x * GameConfig.TILE, (s.y - 2.0) * GameConfig.TILE)
			var grad := Vector2(-gx, -gz)
			if grad.length() < 0.05:
				var fallback_a := rng.next_float() * TAU
				grad = Vector2(cos(fallback_a), sin(fallback_a))
			else:
				grad = grad.normalized()
			var contour := Vector2(-grad.y, grad.x)
			for tier: int in [-1, 0, 1]:
				for step: int in [-2, -1, 0, 1, 2]:
					if tier == 0 and step == 0:
						continue
					var p := Vector2(s.x, s.y) + grad * (float(tier) * 2.45 + (rng.next_float() - 0.5) * 0.45) \
						+ contour * (float(step) * 2.10 + (rng.next_float() - 0.5) * 0.45)
					var to_center := Vector2(s.x - p.x, s.y - p.y)
					var aim := (grad * 0.65 + (to_center.normalized() if to_center.length() > 0.1 else Vector2.ZERO) * 0.35).normalized()
					var order := absf(float(step)) * 0.90 + float(tier + 1) * 0.60 + rng.next_float() * 0.65
					slots.append(Vector4(order, p.x, p.y, atan2(aim.x, aim.y)))
			for k in 16:
				var a := TAU * k / 16.0 + rng.next_float() * 0.2
				var r := plaza + 0.5 + rng.next_float() * 3.0
				var p := Vector2(s.x + cos(a) * r, s.y + sin(a) * r)
				slots.append(Vector4(r + 3.8 + rng.next_float(), p.x, p.y, atan2(s.x - p.x, s.y - p.y)))
		"remote":
			# Тесный хутор / заимка: доминирующий дом у костра и компактная дуга построек
			var anchor := rng.next_float() * TAU
			var main_r := plaza + 0.22
			var main_p := Vector2(s.x + cos(anchor) * main_r, s.y + sin(anchor) * main_r)
			slots.append(Vector4(0.4 + rng.next_float() * 0.2, main_p.x, main_p.y, atan2(s.x - main_p.x, s.y - main_p.y)))
			for k in 10:
				var a := anchor + (rng.next_float() - 0.5) * 2.1
				var r := plaza + 0.8 + rng.next_float() * 2.3
				var p := Vector2(s.x + cos(a) * r, s.y + sin(a) * r)
				slots.append(Vector4(1.5 + r * 0.65 + rng.next_float() * 0.5, p.x, p.y, atan2(s.x - p.x, s.y - p.y)))
			for k in 16:
				var a := TAU * k / 16.0 + rng.next_float() * 0.2
				var r := plaza + 0.4 + rng.next_float() * 3.2
				var p := Vector2(s.x + cos(a) * r, s.y + sin(a) * r)
				slots.append(Vector4(r + 4.8 + rng.next_float(), p.x, p.y, atan2(s.x - p.x, s.y - p.y)))
		_:
			# ordinary / coastal: запасное кольцо после придорожных слотов
			for k in 24:
				var a := TAU * k / 24.0 + rng.next_float() * 0.2
				var r := plaza + 0.3 + rng.next_float() * 3.2
				var p := Vector2(s.x + cos(a) * r, s.y + sin(a) * r)
				var order := r + 5.2 + rng.next_float()
				if set_kind == "coastal" and p.x >= 0.0 and p.y >= 0.0 and floori(p.x) < W and floori(p.y) < w.H:
					var dw: float = w.dist_water[floori(p.y) * W + floori(p.x)]
					if dw >= 1.2 and dw <= 5.5:
						order -= 1.5
				slots.append(Vector4(order, p.x, p.y, atan2(s.x - p.x, s.y - p.y)))


static func _place_landmark(w: WorldData, ground: Heightfield, river: PackedByteArray, s: SettlementData,
		huts: Array[HutData], lm_id: String) -> void:
	var W := w.W
	if lm_id == "boat_shed":
		var best_score := INF
		var best_spot := Vector2.ZERO
		var best_yaw := 0.0
		for r: float in [2.6, 3.8, 5.2]:
			for k in 16:
				var a := TAU * k / 16.0
				var p := Vector2(s.x + cos(a) * r, s.y + sin(a) * r)
				var cx := clampi(floori(p.x), 0, W - 1)
				var cy := clampi(floori(p.y), 0, w.H - 1)
				var j := cy * W + cx
				if w.path_mask[j] >= 2 or _crowded(huts, p, 1.85):
					continue
				var yaw := atan2(s.x - p.x, s.y - p.y)
				if not _fits(w, ground, river, p, yaw, lm_id):
					continue
				var dw: float = w.dist_water[j] if not w.dist_water.is_empty() else 10.0
				if dw < best_score:
					best_score = dw
					best_spot = p
					best_yaw = yaw
		if best_score < INF:
			huts.append(HutData.new(best_spot.x, best_spot.y, 0, lm_id, best_yaw))
		return

	var radii := [1.4, 2.2] if lm_id == "woodpile_rack" else [1.4]
	for r: float in radii:
		var best := -1.0
		var spot := Vector2.ZERO
		for k in 12:
			var a := TAU * k / 12.0
			var p := Vector2(s.x + cos(a) * r, s.y + sin(a) * r)
			var j := clampi(floori(p.y), 0, w.H - 1) * W + clampi(floori(p.x), 0, W - 1)
			var free := 0.0 if w.path_mask[j] >= 2 else 1.0 + float(not _crowded(huts, p, 1.35))
			if free > best:
				best = free
				spot = p
		var yaw := atan2(s.x - spot.x, s.y - spot.y)
		if best >= 2.0 and _fits(w, ground, river, spot, yaw, lm_id):
			huts.append(HutData.new(spot.x, spot.y, 0, lm_id, yaw))
			return


## Жилые дома (без сараев и колодца): непустой huts ещё не значит, что в поселении можно жить.
const HOMES := ["house", "house_timber", "chalet", "tall"]


static func homes_of(s: SettlementData) -> int:
	var count := 0
	for hut: HutData in s.huts:
		if SettlementSets.is_home(hut.t): count += 1
	return count


static func count_homes(settlements: Array) -> int:
	var count := 0
	for s: SettlementData in settlements: count += homes_of(s)
	return count


## Вид жилого дома берётся из набора вида поселения (SettlementSets)
static func _house_kind(s: SettlementData, from_plaza: float, r: float, set_kind := "") -> String:
	var kind := set_kind if not set_kind.is_empty() else SettlementSets.kind_of(null, s)
	return SettlementSets.pick_home(kind, s.town, from_plaza, r)


static func _crowded(huts: Array, p: Vector2, gap: float) -> bool:
	for u: HutData in huts:
		if Vector2(u.x, u.y).distance_squared_to(p) < gap * gap:
			return true
	return false


## Постройка вида kind (SettlementSets) встаёт на сухую землю с перепадом не больше flat_of,
## не на путь и не на голую скалу. Пробы — по углам и серединам стен, повёрнутых на a
static func _fits(w: WorldData, ground: Heightfield, river: PackedByteArray, p: Vector2, a: float, kind: String) -> bool:
	if not structure_clear(w, p, a, kind):
		return false
	var half := SettlementSets.half_of(kind) + Vector2(0.4, 0.4)
	var low := INF
	var high := -INF
	var basis := Basis(Vector3.UP, a)
	for dz: float in [-1.0, 0.0, 1.0]:
		for dx: float in [-1.0, 0.0, 1.0]:
			var o := basis * Vector3(dx * half.x, 0, dz * half.y)
			var px := p.x * GameConfig.TILE + o.x
			var pz := p.y * GameConfig.TILE + o.z
			var cx := floori(px / GameConfig.TILE)
			var cy := floori(pz / GameConfig.TILE)
			if cx < 0 or cy < 0 or cx >= w.W or cy >= w.H:
				return false
			var j := cy * w.W + cx
			if w.path_mask[j] >= 2 or w.ocean[j] != 0 or w.lake[j] != 0 or river[j] != 0 or w.biome[j] == Biomes.ROCK or w.slope[j] > 0.45:
				return false
			if ground.depth_at(px, pz) > 0.0:
				return false
			var h := ground.ground_at(px, pz)
			low = minf(low, h)
			high = maxf(high, h)
	return high - low <= SettlementSets.flat_of(kind)


## The base heightfield has no tunnel excavation. Reserve the entire rotated
## foundation before selecting a slot, rather than deleting the chosen house later.
static func structure_clear(w: WorldData, p: Vector2, a: float, kind: String) -> bool:
	var half := (SettlementSets.half_of(kind) + Vector2(0.4, 0.4)) / GameConfig.TILE
	var basis := Basis(Vector3.UP, a)
	for tunnel: bool in [false, true]:
		for sp in (w.tunnels if tunnel else w.bridges):
			var ax: float = sp.a % w.W + 0.5
			var ay: float = sp.a / w.W + 0.5
			var bx: float = sp.b % w.W + 0.5
			var by: float = sp.b / w.W + 0.5
			if Grid.segment_dist(p.x, p.y, ax, ay, bx, by) < StageTrails.HUT_CLEAR:
				return false
			var radius := StageTrails.TUNNEL_R if tunnel else Heightfield.BRIDGE_HALF / GameConfig.TILE
			for z: float in [-1.0, 0.0, 1.0]:
				for x: float in [-1.0, 0.0, 1.0]:
					var offset := basis * Vector3(x * half.x, 0, z * half.y)
					if Grid.segment_dist(p.x + offset.x, p.y + offset.z, ax, ay, bx, by) < radius:
						return false
	return true


## Характер поселения по месту: «приморский посёлок», «горная деревня»…
## by_role — [посёлок, деревня] роли (SettlementRoles.character): роль важнее воды и биома.
static func _character(w: WorldData, i: int, town: bool, by_role: Array = []) -> String:
	if not by_role.is_empty():
		return by_role[0] if town else by_role[1]
	var adj := ["окраинный", "окраинная"]
	# Заготовки тестов задают не все поля
	var sea := not w.dist_ocean.is_empty() and w.dist_ocean[i] < 8.0
	var high := not w.h.is_empty() and w.h[i] > 0.38
	if w.dist_water[i] < 5.0:
		adj = ["приморский", "приморская"] if sea else ["речной", "речная"]
	elif high:
		adj = ["горный", "горная"]
	elif w.biome[i] in [Biomes.FOREST, Biomes.TAIGA, Biomes.JUNGLE]:
		adj = ["лесной", "лесная"]
	elif w.biome[i] in [Biomes.GRASS, Biomes.STEPPE, Biomes.SAVANNA]:
		adj = ["торговый", "земледельческая"] if town else ["земледельческий", "земледельческая"]
	return adj[0] + " посёлок" if town else adj[1] + " деревня"


## Плавная неоднородность заселения в мировых координатах, без квот по областям.
static func _settlement_density(w: WorldData, x: int, y: int) -> float:
	return patches(x, y, 96.0, WGRandom.derive(w.seed_num, "settlement.density"))


## Плавные пятна 0..1 размером cell клеток в мировых координатах (заселённость, частота типов мест).
## 13.4: дробная часть через floor, а не fmod — верна и в отрицательных координатах соседних областей;
## для неотрицательных значение то же до бита.
static func patches(x: int, y: int, cell: float, seed: int) -> float:
	var gx := floori(x / cell)
	var gy := floori(y / cell)
	var tx := smoothstep(0.0, 1.0, x / cell - gx)
	var ty := smoothstep(0.0, 1.0, y / cell - gy)
	return lerpf(lerpf(WGRandom.hash2(gx, gy, seed), WGRandom.hash2(gx + 1, gy, seed), tx),
		lerpf(WGRandom.hash2(gx, gy + 1, seed), WGRandom.hash2(gx + 1, gy + 1, seed), tx), ty)


static func _site_access(w: WorldData, i: int, wet: PackedByteArray) -> float:
	var usable := 0.0
	for offset: Vector2i in [Vector2i.ZERO, Vector2i(-4, 0), Vector2i(4, 0), Vector2i(0, -4), Vector2i(0, 4)]:
		var x := i % w.W + offset.x
		var y := i / w.W + offset.y
		if x < 0 or y < 0 or x >= w.W or y >= w.H:
			continue
		var j := y * w.W + x
		if wet[j] != 0 or not Biomes.LIST[w.biome[j]].has("habit"):
			continue
		usable += maxf(0.0, 1.0 - w.slope[j] / 0.45)
	return usable / 5.0


## Вершины — локальные максимумы высоты, самые высокие и не слишком близко друг к другу
static func _place_peaks(w: WorldData) -> void:
	var W := w.W
	var H := w.H
	var elev := w.elev
	var ocean := w.ocean
	var lake := w.lake
	var peaks: Array = []
	var cand: Array = []
	var fast := Grid.fast_grid()
	var cells: PackedInt32Array = fast.PeakCandidates(W, H, elev, ocean, lake) if fast != null else peak_candidates_reference(W, H, elev, ocean, lake)
	for i: int in cells:
		cand.append([elev[i], i])
	cand.sort_custom(_by_score_desc)
	var want := clampi(roundi(6.0 * w.scale), 2, 14)
	for c: Array in cand:
		if peaks.size() >= want:
			break
		var i: int = c[1]
		var x := (i % W) + 0.5
		var y := (i / W) + 0.5
		var close := false
		for p: Dictionary in peaks:
			var dx: float = p.x - x
			var dy: float = p.y - y
			if dx * dx + dy * dy < 1600.0:
				close = true
				break
		if close:
			continue
		peaks.append({x = x, y = y, i = i, elev = c[0], name = w.make_name(Names.PEAK, "peak", floori(x), floori(y))})
	w.peaks = peaks


## Только кандидаты, в исходном порядке; сортировка, разрежение и имена остаются общими.
static func peak_candidates_reference(W: int, H: int, elev: PackedFloat32Array, ocean: PackedByteArray, lake: PackedByteArray) -> PackedInt32Array:
	var cells := PackedInt32Array()
	for y in range(4, H - 4):
		for x in range(4, W - 4):
			var i := y * W + x
			if elev[i] < 0.45 or ocean[i] != 0 or lake[i] != 0:
				continue
			var is_max := true
			for dy in range(-3, 4):
				for dx in range(-3, 4):
					if elev[(y + dy) * W + x + dx] > elev[i]:
						is_max = false
						break
				if not is_max:
					break
			if is_max:
				cells.append(i)
	return cells
