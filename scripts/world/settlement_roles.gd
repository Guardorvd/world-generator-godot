extends RefCounted
## Роли поселений стартового плана (16.11.2026, этап 2 плана «Поселения и география дорог»).
## Настройки ценности: сколько мест каждой роли (сид выбирает из диапазона), чем роль дополняет оценку площадки,
## какой у неё размер и важность для сети. Отбор — в StageLandmarks._place_settlements: у каждого очередного места
## есть роль слота; кандидаты слота — только подходящие этой роли. Нет подходящих — слот становится обычным.
## Размер (town, homes), важность для сети (importance → дорога или тропа, StageTrails.main_road) и удалённость — разные
## величины: маленькая предгорная деревня получает тропу, дорогу — только если через неё идёт путь между центрами.

## count — [от, до] мест на план 768; importance — для сети (дорога между местами, где у обоих ≥ 0,6);
## town — посёлок; homes — [от, до] жилых домов (иначе обычная формула StageLandmarks).
const ROLES := {
	# Центр: большая долина или вода — обычная оценка площадки. Первый слот всегда центр: там старт игрока.
	center = {count = [1, 2], importance = 0.9, town = true, adjective = ""},
	# Спутник: деревня в RING клеток от своего центра — центр с двумя-тремя деревнями вокруг.
	satellite = {per_center = [0, 3], importance = 0.45, town = false, adjective = ""},
	# Лесное: поляна в глубине леса, не ближе FOREST_DEPTH клеток к опушке.
	forest = {count = [0, 2], importance = 0.5, town = false, adjective = "лесн"},
	# Предгорное: ровная терраса не дальше FOOT_NEAR клеток от гор.
	foothill = {count = [0, 2], importance = 0.45, town = false, adjective = "предгорн"},
	# Удалённое: редкая точка вдали от остальных, маленькое, с одним подъездом.
	remote = {count = [0, 1], importance = 0.2, town = false, homes = [3, 5], adjective = "дальн"},
}
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
	var biome := w.biome
	var elev := w.elev
	var open := PackedByteArray()
	open.resize(w.N)
	var high := PackedByteArray()
	high.resize(w.N)
	var mountains := false
	for i in w.N:
		open[i] = 1 - forest_biome[biome[i]]
		if elev[i] >= MOUNTAIN:
			high[i] = 1
			mountains = true
	var out := {depth = Grid.distance_field(w.W, w.H, open)}
	if mountains:
		out.to_high = Grid.distance_field(w.W, w.H, high)
	return out


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
			return REMOTE_BONUS * minf(nearest, REMOTE_FULL) / REMOTE_FULL if nearest >= REMOTE_MIN else -INF
	return 0.0


## Наибольшая прибавка роли — граница просмотра отсортированного списка
static func max_bonus(role: String) -> float:
	match role:
		"forest": return FOREST_BONUS
		"foothill": return FOOT_BONUS
		"remote": return REMOTE_BONUS
	return 0.0
