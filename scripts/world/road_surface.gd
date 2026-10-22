class_name RoadSurface
extends RefCounted
## Слой дорожного полотна (с 4.3), часть 1: покрытие. Идёт после всех этапов генерации, по готовым
## линиям w.trails; маршруты, клетки путей и общий RNG не трогает. Покрытие выбирается по виду пути,
## биому, крутизне, близости поселения и мировым участкам длиной SPAN (хеш сида, без rng), поэтому одна
## дорога может идти гравием, грунтовкой и камнем. Высоты полотна — вторая часть, RoadBed (scripts/game).
## Пишет: t.surf (покрытие у каждой точки t.pts) и w.road_surface (покрытие клетки пути людей, 0 — нет).
## Звериные тропы остаются как были: это не полотно, а примятая трава.

const NONE := 0
const GRAVEL := 1    # гравий: обычная дорога
const DIRT := 2      # грунтовка или утоптанная тропа
const PACKED := 3    # укатанная земля у поселений
const STONE := 4     # каменистое полотно на крутом и в скалах
const SAND := 5      # песок у пляжей и в пустыне
const FOREST := 6    # лесная тропа: хвоя, листья, корни
const MEADOW := 7    # травяная колея, тропа заросла

## name — для интерфейса; speed — множитель скорости поверх биома (раньше у дороги 1.4, у тропы 1.3);
## rough — тряска и покачивание велосипеда (0 — гладко, 1 — бездорожье; до 4.3 у всех путей 0.15); grip — сцепление в повороте;
## hard — звук шагов «гравий»; color — цвет полосы на текстуре и карте;
## grain — выраженность каменного зерна; organic — примесь лесной подстилки и травы (только внешний вид)
const LIST := [
	{},
	{name = "гравий", grain = 0.8, organic = 0.0, speed = 1.4, rough = 0.18, grip = 0.95, hard = true, color = [172, 162, 142]},
	{name = "грунтовка", grain = 0.3, organic = 0.0, speed = 1.33, rough = 0.2, grip = 1.0, hard = false, color = [160, 128, 88]},
	{name = "укатанная земля", grain = 0.08, organic = 0.0, speed = 1.4, rough = 0.12, grip = 1.0, hard = false, color = [150, 126, 96]},
	{name = "камень", grain = 1.0, organic = 0.0, speed = 1.2, rough = 0.45, grip = 0.9, hard = true, color = [150, 145, 136]},
	{name = "песок", grain = 0.12, organic = 0.0, speed = 1.1, rough = 0.2, grip = 0.75, hard = false, color = [212, 194, 148]},
	{name = "лесная тропа", grain = 0.18, organic = 0.65, speed = 1.22, rough = 0.32, grip = 0.95, hard = false, color = [124, 98, 68]},
	{name = "травяная колея", grain = 0.05, organic = 1.0, speed = 1.15, rough = 0.28, grip = 0.95, hard = false, color = [150, 146, 96]},
]

const SPAN := 18.0        # длина отрезка пути (клеток, ~70 м), на котором покрытие меняется по хешу
const VILLAGE_R := 7.0    # ближе этого к костру (клеток) дорога укатана
const STONE_SLOPE := 0.17 # крутизна клетки (w.slope, ~37 % уклона), с которой тропа каменистая; дорога — с 0.21
const ROAD_DIRT := 0.3    # доля отрезков дороги на равнине без гравия (грунтовка)
const TRAIL_MEADOW := 0.25 # доля отрезков тропы по открытой местности, которые заросли травой
const ORDER := ["mountain", "trail", "road"]   # кто кого перекрывает в w.road_surface (дорога сверху)


static func run(w: WorldData) -> void:
	w.road_surface = PackedByteArray()
	w.road_surface.resize(w.N)
	for k: int in w.trails.size():
		var t: Dictionary = w.trails[k]
		t.surf = PackedByteArray()
		if t.kind == "animal":
			t.surf.resize(t.pts.size())
			continue
		var surface_seed := WGRandom.derive(w.seed_num, "surface." + t.kind)
		for n: int in t.pts.size():
			var p: Dictionary = t.pts[n]
			t.surf.append(pick(w, t.kind, p.x, p.y,
				WGRandom.hash2(floori(p.x / SPAN), floori(p.y / SPAN), surface_seed)))
	# На пересечении путей одного типа приоритет также не зависит от порядка их загрузки.
	var routes := w.trails.duplicate()
	routes.sort_custom(_route_less)
	for kind: String in ORDER:
		for t: Dictionary in routes:
			if t.kind == kind:
				_stamp(w, t)


static func _route_less(a: Dictionary, b: Dictionary) -> bool:
	if a.kind != b.kind:
		return a.kind < b.kind
	if a.pts.size() != b.pts.size():
		return a.pts.size() < b.pts.size()
	for n in a.pts.size():
		for field: String in ["x", "y", "w"]:
			if a.pts[n][field] != b.pts[n][field]:
				return a.pts[n][field] < b.pts[n][field]
	return false


## Покрытие пути вида kind в точке (x, y), в клетках; v — хеш отрезка пути [0, 1)
static func pick(w: WorldData, kind: String, x: float, y: float, v: float) -> int:
	var i := clampi(floori(y), 0, w.H - 1) * w.W + clampi(floori(x), 0, w.W - 1)
	var b := w.biome[i]
	if b == Biomes.ROCK or b == Biomes.PEAK or b == Biomes.SNOW or b == Biomes.STONESHORE:
		return STONE
	if w.slope[i] > (STONE_SLOPE + 0.04 if kind == "road" else STONE_SLOPE):
		return STONE
	if b == Biomes.BEACH or b == Biomes.DESERT:
		return SAND
	if kind == "mountain":
		return STONE if v < 0.5 or w.slope[i] > STONE_SLOPE * 0.6 else DIRT
	var wooded := b == Biomes.FOREST or b == Biomes.TAIGA or b == Biomes.JUNGLE
	if kind == "road":
		for s: Dictionary in w.settlements:
			if absf(s.x - x) < VILLAGE_R and absf(s.y - y) < VILLAGE_R and Grid.hypot(s.x - x, s.y - y) < VILLAGE_R:
				return PACKED
		return DIRT if v < ROAD_DIRT and not wooded and b != Biomes.SWAMP else GRAVEL
	if wooded:
		return FOREST
	return MEADOW if v < TRAIL_MEADOW else DIRT


## Та же разметка ленты, что у path_mask, включая угловые клетки диагоналей.
static func _stamp(w: WorldData, t: Dictionary) -> void:
	if t.pts.size() < 2:
		return
	var half := maxf(float(t.pts[0].w) * 0.5 - Grid.PATH_IN, 0.0)
	Grid.stamp_path(w.road_surface, w.W, w.H, t.pts, 0, half, t.surf)
