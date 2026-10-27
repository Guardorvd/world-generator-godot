class_name StageLandmarks
extends RefCounted
## Этап 6. Поселения с домами и вершины с названиями.
## Пишет: w.settlements [{x, y, i, name, town, homes, style, character, huts: []}], w.peaks [{x, y, i, elev, name}].
## Дома (huts) ставит lay_out после путей.

const PROGRESS := 0.46
const LABEL := "Основание поселений"
const LAYOUT_R := 6.8 # клеток: дома и сараи не дальше от костра (вырубка леса у поселения — 7 клеток)


static func run(w: WorldData) -> void:
	_place_settlements(w)
	_place_peaks(w)


## Сортировка кандидатов [score, i] по убыванию; при равенстве — по порядку добавления (как стабильная сортировка JS)
static func _by_score_desc(a: Array, b: Array) -> bool:
	if a[0] != b[0]:
		return a[0] > b[0]
	return a[1] < b[1]


static func _place_settlements(w: WorldData) -> void:
	var W := w.W
	var H := w.H
	var candidate_seed := WGRandom.derive(w.seed_num, "settlement.candidate")
	var density_seed := WGRandom.derive(w.seed_num, "settlement.density")
	var biome := w.biome
	var river := w.river_cells()
	var slope := w.slope
	var dist_water := w.dist_water
	var ocean := w.ocean
	var lake := w.lake
	var settlements: Array = []
	var cand: Array = []
	# Не размещаем поселение за проливом, который шире любого допустимого моста.
	# Иначе дороги перебирают все соседние поселения и десятки объездов без шанса на связь.
	var wet := PackedByteArray()
	wet.resize(w.N)
	for i in w.N:
		wet[i] = 1 if ocean[i] != 0 or lake[i] != 0 or river[i] != 0 else 0
	var reachable := Grid.bridge_region(W, H, wet, StageTrails.SPAN)
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
			var score: float = bd.habit + WGRandom.hash2(x, y, candidate_seed) * 0.2 - slope[i] * 0.6
			score += access * 0.45 + density_value * 0.35
			if dist_water[i] >= 1.5 and dist_water[i] <= 6.0:
				score += 0.6
			elif dist_water[i] > 16.0:
				score -= minf(0.6, (dist_water[i] - 16.0) / 40.0)
			# Сухая площадка непосредственно у воды уступает береговой террасе.
			if dist_water[i] < 1.5:
				score -= 0.4
			cand.append([score, i, access, density_value])
	cand.sort_custom(_by_score_desc)
	# Плотность мира зависит от сида. С 9.3 деревень почти вдвое меньше и они дальше друг от друга:
	# мелкое жильё между ними — хутора и одинокие дома (StageSites).
	var maximum := clampi(roundi(7.0 * w.scale), 3, 16)
	var minimum := maxi(2, ceili(maximum * 0.5))
	var density := WGRandom.new(w.seed_num ^ 0x5e771e)
	var want := minimum + floori(density.next_float() * (maximum - minimum + 1))
	var min_d := maxf(32.0, W / 8.0)
	for c: Array in cand:
		if settlements.size() >= want:
			break
		var i: int = c[1]
		var x := (i % W) + 0.5
		var y := (i / W) + 0.5
		# Благоприятные долины дают группы деревень, бедные окраины — редкие места.
		# Радиусы обоих соседей действуют и через границу любой области.
		var spacing: float = min_d * lerpf(1.35, 0.7, c[3])
		var close := false
		for s: SettlementData in settlements:
			var dx: float = s.x - x
			var dy: float = s.y - y
			var separation: float = (spacing + s.spacing) * 0.5
			if dx * dx + dy * dy < separation * separation:
				close = true
				break
		if close:
			continue
		# Берег большой воды и удобная долина делают место узлом округи.
		var shore := 0.12 if dist_water[i] < 6.0 else 0.0
		var importance := clampf(float(biome[i] == Biomes.GRASS) * 0.15 + c[2] * 0.5 + c[3] * 0.3 + shore, 0.0, 1.0)
		var settlement := SettlementData.new(x, y, i, w.make_name(Names.SETTLEMENT, "settlement", floori(x), floori(y)))
		settlement.spacing = spacing
		settlement.importance = importance
		settlements.append(settlement)
	# Посёлков — примерно треть, самые важные места; остальные — деревни.
	var ranks: Array = settlements.map(func(s: SettlementData) -> float: return s.importance)
	ranks.sort()
	var town_from: float = ranks[ranks.size() - ceili(ranks.size() / 3.0)] if not ranks.is_empty() else 1.0
	for s: SettlementData in settlements:
		var rng := WGRandom.at(w.seed_num, "settlement.huts", floori(s.x), floori(s.y))
		# Посёлок — узел округи: вдвое больше домов, чем у деревни. Сами дома ставит lay_out,
		# когда известны дороги (с 9.5): улицы — это дороги и тропы, пришедшие в поселение.
		s.town = s.importance >= town_from
		s.homes = (8 if s.town else 4) + roundi(s.importance * 3.0) + floori(rng.next_float() * 3)
		# Облик поселения: свои крыши, штукатурка и ставни, чтобы соседние деревни не были копиями
		s.style = floori(rng.next_float() * 4)
		s.character = _character(w, s.i, s.town)
	w.settlements = settlements


## Дома, площадь и хозяйственные постройки (с 9.5, после путей). Улица — путь людей у поселения: дома
## стоят по обе её стороны дверью к ней, за ними второй ряд и сараи, в середине свободная площадь
## с костром (у посёлка — шире и с колодцем). Где путей мало, остальные дома встают кольцом у площади.
## Пишет s.huts [{x, y, v, t — вид (SettlementsBuilder.HOMES или хозяйственная постройка), a — поворот как у Basis(UP, a)}].
static func lay_out(w: WorldData) -> void:
	var W := w.W
	var river := w.river_cells()
	var ground := Heightfield.base_of(w)
	for s: SettlementData in w.settlements:
		var rng := WGRandom.at(w.seed_num, "settlement.layout", floori(s.x), floori(s.y))
		var town: bool = s.town
		var plaza := 2.4 if town else 1.9
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
						var order := p.distance_to(Vector2(s.x, s.y)) + row * 2.2 + rng.next_float() * 0.8
						slots.append(Vector4(order, p.x, p.y, atan2(face.x, face.y)))
		# Кольцо у площади: запас на случай, если улиц мало; дома дверью к костру
		for k in 24:
			var a := TAU * k / 24.0 + rng.next_float() * 0.2
			var r := plaza + 0.3 + rng.next_float() * 3.2
			var p := Vector2(s.x + cos(a) * r, s.y + sin(a) * r)
			slots.append(Vector4(r + 3.0 + rng.next_float(), p.x, p.y, atan2(s.x - p.x, s.y - p.y)))
		# Vector4 сортируется встроенным сравнением: сначала ближние к площади места первого ряда
		slots.sort()
		var huts: Array[HutData] = []
		var homes: int = s.homes
		var placed := 0
		for sl: Vector4 in slots:
			if placed >= homes:
				break
			var p := Vector2(sl.y, sl.z)
			var r := p.distance_to(Vector2(s.x, s.y))
			if r < plaza or r > LAYOUT_R - 1.0:
				continue
			var kind := _house_kind(s, r - plaza, rng.next_float())
			if _crowded(huts, p, 1.95) or not _fits(w, ground, river, p, sl.w, kind):
				continue
			huts.append(HutData.new(p.x, p.y, floori(rng.next_float() * 4), kind, sl.w + (rng.next_float() - 0.5) * 0.12))
			placed += 1
		# Хозяйственный пояс: за частью домов, дальше от улицы — сарай, сеновал или поленница
		var character: String = s.character
		var farming := character.begins_with("земледель") or character.begins_with("торгов")
		var chance := 0.7 if farming else (0.55 if character.begins_with("горн") or character.begins_with("лесн") else 0.35)
		for h in placed:
			var u: HutData = huts[h]
			if rng.next_float() > chance:
				continue
			var back := Vector2(-sin(u.a), -cos(u.a))
			var side := Vector2(back.y, -back.x) * (rng.next_float() - 0.5) * 1.4
			var p := Vector2(u.x, u.y) + back * (1.9 + rng.next_float() * 0.5) + side
			var kinds: Array = ["barn", "hay", "shed"] if farming else ["shed", "barn", "hay", "shed"]
			var kind: String = kinds[floori(rng.next_float() * kinds.size())]
			var a: float = u.a + (PI / 2.0 if kind == "barn" and rng.next_float() < 0.5 else 0.0)
			if p.distance_to(Vector2(s.x, s.y)) > LAYOUT_R - 0.3 or _crowded(huts, p, 1.45) or not _fits(w, ground, river, p, a, kind):
				continue
			huts.append(HutData.new(p.x, p.y, floori(rng.next_float() * 4), kind, a))
		# Колодец на краю площади, со стороны, дальней от путей
		if town or rng.next_float() < 0.4:
			var best := -1.0
			var spot := Vector2.ZERO
			for k in 8:
				var a := TAU * k / 8.0
				var p := Vector2(s.x + cos(a) * 1.4, s.y + sin(a) * 1.4)
				var j := floori(p.y) * W + floori(p.x)
				var free := 0.0 if w.path_mask[j] >= 2 else 1.0 + float(not _crowded(huts, p, 1.3))
				if free > best:
					best = free
					spot = p
			if best >= 2.0 and _fits(w, ground, river, spot, atan2(s.x - spot.x, s.y - spot.y), "fountain"):
				huts.append(HutData.new(spot.x, spot.y, 0, "fountain", atan2(s.x - spot.x, s.y - spot.y)))
		s.huts = huts


## Вид жилого дома: в горах и лесу — больше шале, у посёлка у площади — высокие дома
static func _house_kind(s: SettlementData, from_plaza: float, r: float) -> String:
	var character: String = s.character
	if s.town and from_plaza < 1.6 and r < 0.6:
		return "tall"
	var chalets := 0.65 if character.begins_with("горн") or character.begins_with("лесн") else 0.35
	return "chalet" if r < chalets else "house"


static func _crowded(huts: Array, p: Vector2, gap: float) -> bool:
	for u: HutData in huts:
		if Vector2(u.x, u.y).distance_squared_to(p) < gap * gap:
			return true
	return false


## Постройка вида kind (PlayerState.SITE_HALF) встаёт на сухую землю с перепадом не больше FLAT,
## не на путь и не на голую скалу. Пробы — по углам и серединам стен, повёрнутых на a
static func _fits(w: WorldData, ground: Heightfield, river: PackedByteArray, p: Vector2, a: float, kind: String) -> bool:
	var half: Vector2 = PlayerState.SITE_HALF[kind] + Vector2(0.4, 0.4)
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
	return high - low <= StageSites.FLAT[kind]


## Характер поселения по месту: «приморский посёлок», «горная деревня»…
static func _character(w: WorldData, i: int, town: bool) -> String:
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
