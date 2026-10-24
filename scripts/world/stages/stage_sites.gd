class_name StageSites
extends RefCounted
## Этап 7.5 (с 9.3). Интересные места вне поселений: дозорные вышки, обелиски, руины, одинокие дома, хутора,
## горные приюты, каменные круги. Ставятся после путей: вышке нужен холм над дорогой, хутору — поле у дороги,
## приюту — горная тропа. Один общий отбор кандидатов с оценкой по типу, без отдельной системы на каждый тип.
## Пишет: w.sites [{x, y, i, type, rank (1..3 — значимость), name, clear — поляна, клеток,
## huts: [{x, y, v, t — вид постройки, a — поворот}]}]. Постройки названы huts, как у поселений:
## растительность и столкновения обходят их тем же кодом. Адрес места — WorldData.place_id("site", x, y).

const PROGRESS := 0.76
const LABEL := "Старые места и хутора"

const STEP := 4             # шаг сетки кандидатов, клеток
const NEAR_VILLAGE := 13.0  # ближе к костру поселения (клеток) — его окрестности, не отдельное место
const SPACE := 14.0         # между любыми двумя местами, клеток
const DENSITY_CELL := 128.0 # размер областей, где тип встречается чаще или реже, клеток
const RING := 10            # радиус, по которому холм сравнивается с окрестностью, клеток

## Сколько мест каждого типа на мир размером 512 (w.scale = 1); сид умножает на 0,5..1,5.
## Порядок — от значимых к мелким: значимые первыми выбирают лучшие места.
const TYPES := {
	ruin = {base = 3.0, space = 50.0, clear = 0.0, title = "руины"},
	tower = {base = 2.0, space = 70.0, clear = 2.0, title = "дозорная вышка"},
	stones = {base = 0.9, space = 120.0, clear = 4.0, title = "каменный круг"},
	shelter = {base = 1.2, space = 50.0, clear = 2.0, title = "горный приют"},
	obelisk = {base = 1.4, space = 80.0, clear = 1.5, title = "обелиск"},
	farm = {base = 4.0, space = 22.0, clear = 5.0, title = "хутор"},
	house = {base = 3.5, space = 30.0, clear = 3.0, title = "одинокий дом"},
}
## Наибольший перепад земли под постройкой, м: руинам и камням неровность не мешает
## (с 9.5 и для построек поселений: шале на склоне стоит на высоком каменном цоколе)
const FLAT := {house = 1.6, barn = 1.6, shelter = 1.8, tower = 1.4, obelisk = 1.2, ruin = 3.0, keep = 2.4, stone = 3.0, hay = 2.0,
	chalet = 2.0, tall = 1.5, shed = 1.4, fountain = 0.8}


static func run(w: WorldData) -> void:
	var W := w.W
	var H := w.H
	var human := PackedByteArray()
	human.resize(w.N)
	for i in w.N:
		human[i] = 1 if w.path_mask[i] >= 2 else 0
	var dist_path := Grid.distance_field(W, H, human)
	var river := w.river_cells()
	var pick_seed := WGRandom.derive(w.seed_num, "site.candidate")
	var cand := {}
	var density_seed := {}
	for type: String in TYPES:
		cand[type] = []
		density_seed[type] = WGRandom.derive(w.seed_num, "site.density." + type)
	for y in range(8, H - 8, STEP):
		for x in range(8, W - 8, STEP):
			var i := y * W + x
			if w.ocean[i] != 0 or w.lake[i] != 0 or river[i] != 0 or w.path_mask[i] != 0:
				continue
			var settle := _settlement_dist(w, x, y)
			if settle < NEAR_VILLAGE:
				continue
			var f := {e = w.elev[i], sl = w.slope[i], dp = dist_path[i], settle = settle, bi = w.biome[i],
				habit = float(Biomes.LIST[w.biome[i]].get("habit", 0.0)), prom = _prominence(w, x, y),
				r = WGRandom.hash2(x, y, pick_seed)}
			for type: String in TYPES:
				var s := _score(type, f)
				if s == -INF:
					continue
				# Области, где тип часто встречается, и области почти без него: места не размазаны ровно.
				var d := StageLandmarks.patches(x, y, DENSITY_CELL, density_seed[type])
				if d < 0.22:
					continue
				# Vector2 сортируется встроенным сравнением, без вызова функции на каждую пару (клетка < 2^24).
				cand[type].append(Vector2(s + (d - 0.5) * 1.2, -i))
	var sites: Array = []
	var names := {}
	for s: SettlementData in w.settlements:
		names[s.name] = true
	for type: String in TYPES:
		var list: Array = cand[type]
		list.sort()
		var rng := WGRandom.new(WGRandom.derive(w.seed_num, "site.count." + type))
		var want := roundi(TYPES[type].base * w.scale * (0.5 + rng.next_float()))
		var placed := 0
		for k in range(list.size() - 1, -1, -1):
			if placed >= want:
				break
			var i := -int(list[k].y)
			var x := (i % W) + 0.5
			var y := (i / W) + 0.5
			if _crowded(sites, type, x, y):
				continue
			var site := _build(w, river, type, x, y, i, names)
			if site.is_empty():
				continue
			sites.append(site)
			placed += 1
	w.sites = sites


## Оценка клетки для типа места или -INF, если тип здесь не стоит
static func _score(type: String, f: Dictionary) -> float:
	var open: bool = f.bi in [Biomes.GRASS, Biomes.STEPPE, Biomes.SAVANNA, Biomes.TUNDRA]
	match type:
		"tower":
			# Холм с видом на дорогу или тропу.
			if f.prom < 0.02 or f.dp > 24.0 or f.sl > 0.5 or f.e > 0.62:
				return -INF
			return f.prom * 25.0 + (1.0 - f.dp / 24.0) * 0.6 + f.r * 0.3
		"obelisk":
			# У пути, чаще на открытом месте или на перевале.
			if f.dp < 1.5 or f.dp > 4.0 or f.sl > 0.35 or f.settle < 30.0:
				return -INF
			return f.e * 0.8 + (0.3 if open else 0.0) + f.r * 0.8
		"ruin":
			# Брошенное место: в стороне от нынешних дорог, часто на возвышенности.
			if f.habit <= 0.0 and f.bi not in [Biomes.FOREST, Biomes.TAIGA]:
				return -INF
			if f.sl > 0.6 or f.settle < 30.0:
				return -INF
			return f.prom * 15.0 + f.r * 0.8 + (0.4 if f.settle > 45.0 else 0.0) + (0.3 if f.dp > 8.0 else 0.0)
		"house":
			if f.habit < 0.2 or f.dp < 2.0 or f.dp > 8.0 or f.sl > 0.35 or f.settle < 20.0:
				return -INF
			return f.habit + f.r * 0.6 + (0.3 if f.settle > 40.0 else 0.0)
		"farm":
			# Поле у дороги в дне пути от поселения.
			if f.bi not in [Biomes.GRASS, Biomes.STEPPE, Biomes.SAVANNA] or f.sl > 0.25:
				return -INF
			if f.dp < 2.0 or f.dp > 10.0 or f.settle > 70.0:
				return -INF
			return f.habit + (1.0 - absf(f.settle - 30.0) / 40.0) * 0.5 + f.r * 0.4
		"shelter":
			# Высоко в горах у тропы, далеко от жилья.
			if f.e < 0.45 or f.sl > 0.55 or f.dp > 10.0 or f.settle < 40.0:
				return -INF
			return f.e + (1.0 - f.dp / 10.0) * 0.3 + f.r * 0.3
		"stones":
			if not open or f.prom < 0.008 or f.dp < 6.0 or f.settle < 35.0 or f.sl > 0.4:
				return -INF
			return f.prom * 20.0 + f.r * 0.5
	return -INF


static func _crowded(sites: Array, type: String, x: float, y: float) -> bool:
	var space: float = TYPES[type].space
	for s: SiteData in sites:
		var d := Grid.hypot(s.x - x, s.y - y)
		if d < SPACE or s.type == type and d < space:
			return true
	return false


## Место со значимостью, названием и постройками; пусто, если главная постройка не встала
static func _build(w: WorldData, river: PackedByteArray, type: String, x: float, y: float, i: int, names: Dictionary) -> SiteData:
	var rng := WGRandom.at(w.seed_num, "site." + type, floori(x), floori(y))
	var prom := _prominence(w, floori(x), floori(y))
	var rank := 2
	var parts: Array = [] # [вид, смещение в клетках] до поворота; первая — главная
	match type:
		"tower":
			rank = 3 if prom > 0.04 else 2
			parts = [["tower", Vector2.ZERO]]
		"obelisk":
			rank = 3 if w.elev[i] > 0.45 else 2
			parts = [["obelisk", Vector2.ZERO]]
		"stones":
			rank = 3 if prom > 0.02 else 2
			var n := 7 + floori(rng.next_float() * 3)
			for k in n:
				var a := TAU * k / n
				parts.append(["stone", Vector2(cos(a), sin(a)) * 1.25])
		"shelter":
			parts = [["shelter", Vector2.ZERO]]
		"house":
			rank = 1
			parts = [["house", Vector2.ZERO]]
		"farm":
			rank = 2 if Biomes.LIST[w.biome[i]].get("habit", 0.0) > 0.8 and rng.next_float() < 0.4 else 1
			parts = [["house", Vector2.ZERO], ["barn", Vector2(1.9, 0.2)], ["hay", Vector2(0.4, 1.8)]]
			if rank == 2:
				parts += [["barn", Vector2(-0.3, -1.9)], ["hay", Vector2(1.6, 1.7)]]
		"ruin":
			# Крепость — редкая: только на заметном холме
			rank = 3 if prom > 0.045 and rng.next_float() < 0.5 else (2 if rng.next_float() < 0.5 else 1)
			var rooms := [Vector2.ZERO, Vector2(1.1, 0.3), Vector2(-0.5, 1.2), Vector2(0.7, -1.2), Vector2(1.9, 1.2)]
			for k in [1, 3, 5][rank - 1]:
				parts.append(["ruin", rooms[k]])
			if rank == 3:
				parts.append(["keep", Vector2(-1.4, -0.6)])
	var turn := rng.next_float() * TAU
	var huts: Array[HutData] = []
	for k in parts.size():
		var off: Vector2 = parts[k][1].rotated(turn)
		var hx := x + off.x
		var hy := y + off.y
		if _fits(w, river, parts[k][0], hx, hy):
			huts.append(HutData.new(hx, hy, floori(rng.next_float() * 4), parts[k][0], turn + (rng.next_float() - 0.5) * 0.3))
		elif k == 0:
			return SiteData.new()
	# Круг, от которого осталась пара камней, не читается как круг
	if type == "stones" and huts.size() < 5:
		return SiteData.new()
	# Названия в мире не повторяются: при совпадении берётся следующий вариант того же места.
	var name := ""
	for k in 6:
		name = _name(w, type, rank, floori(x) + k * 7919, floori(y))
		if not names.has(name):
			break
	names[name] = true
	return SiteData.new(x, y, i, type, rank, name, TYPES[type].clear, huts)


## Постройка на сухой ровной земле и не на пути (как дома поселений после StageTrails._clear_huts).
## Перепад — по высоте клеток: игровой рельеф для этого строить дорого, а на клетке 4 м разница мала.
static func _fits(w: WorldData, river: PackedByteArray, kind: String, hx: float, hy: float) -> bool:
	if hx < 2 or hy < 2 or hx >= w.W - 2 or hy >= w.H - 2:
		return false
	var low := INF
	var high := -INF
	for dz: float in [-0.55, 0.0, 0.55]:
		for dx: float in [-0.55, 0.0, 0.55]:
			var j := floori(hy + dz) * w.W + floori(hx + dx)
			if w.path_mask[j] != 0 or w.ocean[j] != 0 or w.lake[j] != 0 or river[j] != 0:
				return false
			low = minf(low, w.h[j])
			high = maxf(high, w.h[j])
	return (high - low) * GameConfig.HS <= FLAT[kind]


static func _name(w: WorldData, type: String, rank: int, x: int, y: int) -> String:
	match type:
		"ruin":
			var old := w.make_name(Names.SETTLEMENT, "site.ruin", x, y)
			return ("Крепость " if rank == 3 else "Руины ") + old
		"farm":
			return "Хутор " + w.make_name(Names.SETTLEMENT, "site.farm", x, y)
	return w.make_name(Names.SITES[type], "site." + type, x, y)


## Расстояние до ближайшего поселения, клеток
static func _settlement_dist(w: WorldData, x: int, y: int) -> float:
	var best := INF
	for s: SettlementData in w.settlements:
		best = minf(best, Grid.hypot(s.x - x, s.y - y))
	return best


## Насколько клетка выше окрестности в кольце RING (единицы elev, 0,01 ≈ 2,6 м)
static func _prominence(w: WorldData, x: int, y: int) -> float:
	var sum := 0.0
	for k in 8:
		var a := k * TAU / 8.0
		var sx := clampi(x + roundi(cos(a) * RING), 0, w.W - 1)
		var sy := clampi(y + roundi(sin(a) * RING), 0, w.H - 1)
		sum += w.elev[sy * w.W + sx]
	return w.elev[y * w.W + x] - sum / 8.0


