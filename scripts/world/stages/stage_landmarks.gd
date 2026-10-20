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
	var rng := w.rng
	var biome := w.biome
	var river := w.river
	var slope := w.slope
	var dist_water := w.dist_water
	var acc := w.acc
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
			var score: float = bd.habit + (rng.next_float() * 0.35) - slope[i] * 0.6
			if dist_water[i] >= 1.5 and dist_water[i] <= 6.0:
				score += 0.6
			if acc[i] > 0.0 and dist_water[i] < 6.0:
				score += 0.1
			cand.append([score, i])
	cand.sort_custom(_by_score_desc)
	# Плотность мира зависит от сида; прежнее количество — верхняя граница.
	var maximum := clampi(roundi(12.0 * w.scale), 4, 26)
	var minimum := maxi(2, ceili(maximum * 0.55))
	var density := WGRandom.new(w.seed_num ^ 0x5e771e)
	var want := minimum + floori(density.next_float() * (maximum - minimum + 1))
	var min_d := maxf(28.0, W / 6.5)
	var min_d2 := min_d * min_d
	for c: Array in cand:
		if settlements.size() >= want:
			break
		var i: int = c[1]
		if reachable[i] == 0:
			continue
		var x := (i % W) + 0.5
		var y := (i / W) + 0.5
		var close := false
		for s: Dictionary in settlements:
			var dx: float = s.x - x
			var dy: float = s.y - y
			if dx * dx + dy * dy < min_d2:
				close = true
				break
		if close:
			continue
		settlements.append({x = x, y = y, i = i, name = w.make_name(Names.SETTLEMENT), huts = []})
	# Дома вокруг центра поселения, не на воде и не на крутых склонах
	var ground := Heightfield.new(w, false)
	for s: Dictionary in settlements:
		var n := 3 + floori(rng.next_float() * 7)
		s.character = "прибрежный посёлок" if dist_water[s.i] < 5.0 else ("лесная деревня" if biome[s.i] in [Biomes.FOREST, Biomes.TAIGA, Biomes.JUNGLE] else "деревня у дороги")
		var k := 0
		var tries := 0
		while k < n and tries < 80:
			tries += 1
			var a := rng.next_float() * PI * 2.0
			var r := 1.6 + rng.next_float() * 3.4
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
		peaks.append({x = x, y = y, i = i, elev = c[0], name = w.make_name(Names.PEAK)})
	w.peaks = peaks
