class_name StageLandmarks
extends RefCounted
## Этап 6. Поселения с домами и вершины с названиями.
## Пишет: w.settlements [{x, y, i, name, huts: [{x, y, v}]}], w.peaks [{x, y, i, elev, name}].

const PROGRESS := 0.46
const LABEL := "Основание поселений"


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
			var density_value := _settlement_density(w, x, y)
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
		for s: Dictionary in settlements:
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
		settlements.append({x = x, y = y, i = i, spacing = spacing, importance = importance,
			name = w.make_name(Names.SETTLEMENT, "settlement", floori(x), floori(y)), huts = []})
	# Дома вокруг центра поселения, не на воде и не на крутых склонах
	var ground := Heightfield.new(w, false)
	# Посёлков — примерно треть, самые важные места; остальные — деревни.
	var ranks: Array = settlements.map(func(s: Dictionary) -> float: return s.importance)
	ranks.sort()
	var town_from: float = ranks[ranks.size() - ceili(ranks.size() / 3.0)] if not ranks.is_empty() else 1.0
	for s: Dictionary in settlements:
		var rng := WGRandom.at(w.seed_num, "settlement.huts", floori(s.x), floori(s.y))
		# Посёлок — узел округи: вдвое больше домов и шире кольцо, чем у деревни.
		var town: bool = s.importance >= town_from
		var n := (8 if town else 4) + roundi(s.importance * 3.0) + floori(rng.next_float() * 3)
		s.character = _character(w, s.i, town)
		var k := 0
		var tries := 0
		while k < n and tries < 160:
			tries += 1
			var a := rng.next_float() * PI * 2.0
			var r := 1.6 + rng.next_float() * (4.4 if town else 3.4)
			var hx: float = s.x + cos(a) * r
			var hy: float = s.y + sin(a) * r
			var ti := floori(hy) * W + floori(hx)
			if hx < 1 or hy < 1 or hx >= W - 1 or hy >= H - 1:
				continue
			if ocean[ti] != 0 or lake[ti] != 0 or river[ti] != 0 or biome[ti] == Biomes.ROCK or slope[ti] > 0.45:
				continue
			# Проверяем весь фундамент: сухой центр не спасает дом над рекой или обрывом.
			var low := INF
			var high := -INF
			var dry := true
			for dz: float in [-2.3, 0.0, 2.3]:
				for dx: float in [-2.3, 0.0, 2.3]:
					var px: float = hx * GameConfig.TILE + dx
					var pz: float = hy * GameConfig.TILE + dz
					var h := ground.ground_at(px, pz)
					low = minf(low, h)
					high = maxf(high, h)
					dry = dry and ground.depth_at(px, pz) <= 0.0
			if not dry or high - low > 1.6:
				continue
			var near := false
			for u: Dictionary in s.huts:
				var dx: float = u.x - hx
				var dy: float = u.y - hy
				if dx * dx + dy * dy < 1.96:
					near = true
					break
			if near:
				continue
			s.huts.append({x = hx, y = hy, v = floori(rng.next_float() * 4)})
			k += 1
	w.settlements = settlements


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


## Плавные пятна 0..1 размером cell клеток в мировых координатах (заселённость, частота типов мест)
static func patches(x: int, y: int, cell: float, seed: int) -> float:
	var gx := floori(x / cell)
	var gy := floori(y / cell)
	var tx := smoothstep(0.0, 1.0, fmod(x / cell, 1.0))
	var ty := smoothstep(0.0, 1.0, fmod(y / cell, 1.0))
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
