extends RefCounted
## Роли поселений стартового плана (16.11.2026, этап 2 плана «Поселения и география дорог»).
## Настройки ценности: сколько мест каждой роли (сид выбирает из диапазона), чем роль дополняет оценку площадки,
## какой у неё размер и важность для сети. Отбор — в StageLandmarks._place_settlements: у каждого очередного места
## есть роль слота; кандидаты слота — только подходящие этой роли. Нет подходящих — слот становится обычным.
## Размер (town, homes), важность для сети (importance → дорога или тропа, StageTrails.main_road) и удалённость — разные
## величины: маленькая предгорная деревня получает тропу, дорогу — только если через неё идёт путь между центрами.

## count — [от, до] мест на план 768; importance — для сети (StageTrails.main_road: дорога между местами, где у обоих
## ≥ 0,6, иначе тропа); town — посёлок; homes — [от, до] жилых домов (иначе обычная формула StageLandmarks);
## character — [посёлок, деревня]: характер места (пусто — по воде и биому, StageLandmarks._character).
const ROLES := {
	# Центр: большая долина или вода — обычная оценка площадки. Первый слот всегда центр: там старт игрока.
	center = {count = [1, 2], importance = 0.9, town = true, character = []},
	# Спутник: деревня в RING клеток от своего центра — центр с двумя-тремя деревнями вокруг.
	satellite = {per_center = [0, 3], importance = 0.45, town = false, character = []},
	# Лесное: поляна в глубине леса, не ближе FOREST_DEPTH клеток к опушке.
	forest = {count = [0, 2], importance = 0.5, town = false, character = ["лесной посёлок", "лесная деревня"]},
	# Предгорное: ровная терраса не дальше FOOT_NEAR клеток от гор.
	foothill = {count = [0, 2], importance = 0.45, town = false, character = ["предгорный посёлок", "предгорная деревня"]},
	# Удалённое: редкая точка вдали от остальных, маленькое, с одним подъездом (вторые пути к нему не прокладываются).
	# Стоит только там, где есть причина жить вдали (REASONS); характер — по причине.
	remote = {count = [0, 1], importance = 0.2, town = false, homes = [3, 5], character = []},
}
## Причины удалённого места, по порядку проверки: [условие, характер посёлка, характер деревни].
## mountain — горы не дальше FOOT_NEAR, water — вода не дальше REMOTE_WATER, forest — глубина леса от FOREST_DEPTH.
const REASONS := [["mountain", "горный посёлок", "горная деревня"], ["water", "рыбацкий посёлок", "рыбацкая деревня"],
	["forest", "лесной посёлок", "лесная заимка"]]
const REMOTE_WATER := 6.0 # клеток (24 м) до воды
## Порядок слотов: центры, спутники, лес, предгорья, обычные, удалённые (последними — дальше всех от уже выбранных).
const ORDER := ["center", "satellite", "forest", "foothill", "ordinary", "remote"]

const RING := Vector2(80.0, 160.0)   # клеток (320–640 м) от спутника до его центра
const FOREST_DEPTH := 12.0           # клеток (48 м) до опушки — уже глубина леса
const FOREST_FULL := 30.0            # глубже — прибавка не растёт
const FOOT_NEAR := 40.0              # клеток (160 м) до гор
const FOOT_GAP := 4.0                # не на самом склоне гор
const FOOT_SLOPE := 0.25             # терраса — ровное место
const MOUNTAIN := 0.5                # w.elev гор (вершины — от 0,45)
const REMOTE_MIN := 200.0            # клеток (800 м) до ближайшего выбранного места
const REMOTE_FULL := 300.0
## Прибавки внутри роли (ранжируют подходящие места между собой; с поправкой на удалённость StageLandmarks.SPREAD)
const FOREST_BONUS := 0.5
const FOOT_BONUS := 0.5
const REMOTE_BONUS := 1.0
const FOREST_BIOMES := [Biomes.FOREST, Biomes.TAIGA, Biomes.JUNGLE]


## Роли слотов по порядку отбора, всего want; сид выбирает число мест каждой роли из её диапазона.
static func slots(seed_num: int, want: int) -> Array[String]:
	var rng := WGRandom.new(WGRandom.derive(seed_num, "settlement.roles"))
	var pick := func(range_: Array) -> int: return int(range_[0]) + floori(rng.next_float() * (int(range_[1]) - int(range_[0]) + 1))
	var centers: int = mini(want, pick.call(ROLES.center.count))
	var satellites := 0
	for c in centers:
		satellites += pick.call(ROLES.satellite.per_center)
	var counts := {center = centers, satellite = satellites, forest = pick.call(ROLES.forest.count),
		foothill = pick.call(ROLES.foothill.count), remote = pick.call(ROLES.remote.count)}
	# Удалённых не больше want − 1: первый слот — центр. Особые роли сверх want отбрасываются с конца.
	var remote: int = mini(counts.remote, maxi(0, want - 1))
	var out: Array[String] = []
	for role: String in ORDER:
		if role in ["ordinary", "remote"]: continue
		for k in counts[role]: out.append(role)
	out.resize(mini(out.size(), want - remote))
	while out.size() < want - remote: out.append("ordinary")
	for k in remote: out.append("remote")
	return out


## Поля для ролей: глубина леса (клеток до не-леса) и расстояние до гор. Ставятся один раз на отбор.
static func fields(w: WorldData) -> Dictionary:
	var forest_biome := PackedByteArray()
	forest_biome.resize(Biomes.LIST.size())
	for b: int in FOREST_BIOMES: forest_biome[b] = 1
	var open := PackedByteArray()
	var high := PackedByteArray()
	var fast := Grid.fast_grid()
	if fast != null:
		# Маски на C#: цикл по 590 тыс. клеток на GDScript стоил ~0,2 с
		open = fast.OutsideBiomes(w.biome, forest_biome)
		high = fast.AtLeast(w.elev, MOUNTAIN)
	else:
		open.resize(w.N)
		high.resize(w.N)
		for i in w.N:
			open[i] = 1 - forest_biome[w.biome[i]]
			high[i] = int(w.elev[i] >= MOUNTAIN)
	var out := {depth = Grid.distance_field(w.W, w.H, open)}
	if high.has(1):
		out.to_high = Grid.distance_field(w.W, w.H, high)
	return out


## Куда можно дойти пешком от клетки start (первый центр): уклон шага не круче предела тропы StageTrails.TRAIL_GRADE,
## вода — там, где её перекроет мост (StageTrails.BRIDGE_REACH). Приближение (без ширины тропы и берегов моста), но
## место вне маски почти наверняка осталось бы без пути и было бы удалено. Пусто без C# — тогда проверки нет.
## wet — вода (океан, озёра, реки), как в StageLandmarks._place_settlements.
## Предел уклона маски — запасной предел дороги: с ним ищется каркас сети. Маска грубее поиска (нет ширины полотна,
## берегов моста и прорезанного рельефа), поэтому редкое место всё же может остаться без связи и удалиться
## (16.11.2026: одно предгорное на Север-1234 — и с пределом тропы 0,4, и с 0,28).
const WALK_GRADE := StageTrails.ROAD_LIMIT
static func walk(w: WorldData, wet: PackedByteArray, start: int) -> PackedByteArray:
	var fast := Grid.fast_grid()
	if fast == null:
		return PackedByteArray()
	return fast.WalkRegion(w.W, w.H, w.h, StageTrails.HEIGHT_SCALE, wet, StageTrails.BRIDGE_REACH, start, WALK_GRADE)


## Отбор работает по прореженным спискам: в каждом квадрате BLOCK × BLOCK клеток — только лучший подходящий кандидат
## (кандидаты уже по убыванию оценки, порядок сохраняется). spacing мест — от 67 клеток, так что точность не теряется,
## а просмотр с поправками короче в десятки раз. role — для постоянного условия роли (forest, foothill), "" — все.
const BLOCK := 16


static func thin(w: WorldData, f: Dictionary, cand: PackedFloat64Array, role: String) -> PackedInt32Array:
	var side := ceili(float(w.W) / BLOCK)
	var seen := PackedByteArray()
	seen.resize(side * ceili(float(w.H) / BLOCK))
	var out := PackedInt32Array()
	for k in cand.size() / 4:
		var i := int(cand[k * 4 + 1])
		var block := (i / w.W / BLOCK) * side + (i % w.W) / BLOCK
		if seen[block] != 0:
			continue
		if not role.is_empty() and bonus(role, w, f, i, 0.0, 0.0, 0.0, []) == -INF:
			continue
		seen[block] = 1
		out.append(k)
	return out


## Прибавка роли к оценке кандидата i или -INF, если место роли не подходит. nearest — до ближайшего выбранного,
## centers — выбранные центры [Vector2]. Для обычного слота и центра — 0.
static func bonus(role: String, w: WorldData, f: Dictionary, i: int, x: float, y: float, nearest: float, centers: Array) -> float:
	match role:
		"center":
			# Первый центр — место старта игрока (PlayerState.home): не у края плана.
			if centers.is_empty() and minf(minf(x, y), minf(w.W - x, w.H - y)) < PlayerState.HOME_EDGE * w.W: return -INF
			return 0.0
		"satellite":
			for c: Vector2 in centers:
				var d := c.distance_to(Vector2(x, y))
				if d >= RING.x and d <= RING.y: return 0.0
			return -INF
		"forest":
			var depth: float = f.depth[i]
			return FOREST_BONUS * minf(depth, FOREST_FULL) / FOREST_FULL if depth >= FOREST_DEPTH else -INF
		"foothill":
			if not f.has("to_high"): return -INF
			var d: float = f.to_high[i]
			return FOOT_BONUS * (1.0 - d / FOOT_NEAR) if d > FOOT_GAP and d <= FOOT_NEAR and w.slope[i] <= FOOT_SLOPE else -INF
		"remote":
			if nearest < REMOTE_MIN or reason(w, f, i).is_empty(): return -INF
			return REMOTE_BONUS * minf(nearest, REMOTE_FULL) / REMOTE_FULL
	return 0.0


## Причина удалённого места в клетке i (строка из REASONS[k][1..2]) или [] — причины нет
static func reason(w: WorldData, f: Dictionary, i: int) -> Array:
	for r: Array in REASONS:
		var ok := false
		match r[0]:
			"mountain": ok = f.has("to_high") and f.to_high[i] <= FOOT_NEAR
			"water": ok = w.dist_water[i] <= REMOTE_WATER
			"forest": ok = f.depth[i] >= FOREST_DEPTH
		if ok: return [r[1], r[2]]
	return []


## Характер места роли: [посёлок, деревня] или [] (тогда — по воде и биому)
static func character(role: String, w: WorldData, f: Dictionary, i: int) -> Array:
	if role == "remote" and not f.is_empty():
		return reason(w, f, i)
	return ROLES[role].character if ROLES.has(role) else []


## Наибольшая прибавка роли — граница просмотра отсортированного списка
static func max_bonus(role: String) -> float:
	match role:
		"forest": return FOREST_BONUS
		"foothill": return FOOT_BONUS
		"remote": return REMOTE_BONUS
	return 0.0
