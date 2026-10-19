class_name RoadSurface
extends RefCounted
## Слой дорожного полотна (с 4.3), часть 1: покрытие. Идёт после всех этапов генерации, по готовым
## линиям w.trails; маршруты, клетки путей и общий RNG не трогает. Покрытие выбирается по виду пути,
## биому, крутизне, близости поселения и по длинным отрезкам пути (хеш сида, без rng), поэтому одна
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
## hard — звук шагов «гравий»; color — цвет полосы на текстуре и карте
const LIST := [
	{},
	{name = "гравий", speed = 1.4, rough = 0.18, grip = 0.95, hard = true, color = [172, 162, 142]},
	{name = "грунтовка", speed = 1.33, rough = 0.2, grip = 1.0, hard = false, color = [160, 128, 88]},
	{name = "укатанная земля", speed = 1.4, rough = 0.12, grip = 1.0, hard = false, color = [150, 126, 96]},
	{name = "камень", speed = 1.2, rough = 0.45, grip = 0.9, hard = true, color = [150, 145, 136]},
	{name = "песок", speed = 1.1, rough = 0.2, grip = 0.75, hard = false, color = [212, 194, 148]},
	{name = "лесная тропа", speed = 1.22, rough = 0.32, grip = 0.95, hard = false, color = [124, 98, 68]},
	{name = "травяная колея", speed = 1.15, rough = 0.28, grip = 0.95, hard = false, color = [150, 146, 96]},
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
		var along := 0.0
		for n: int in t.pts.size():
			var p: Dictionary = t.pts[n]
			if n > 0:
				var q: Dictionary = t.pts[n - 1]
				along += Grid.hypot(p.x - q.x, p.y - q.y)
			t.surf.append(pick(w, t.kind, p.x, p.y, WGRandom.hash2(k, floori(along / SPAN), w.seed_num)))
	for kind: String in ORDER:
		for t: Dictionary in w.trails:
			if t.kind == kind:
				_stamp(w, t)


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


## Клетки под лентой пути t получают его покрытие (как отмечает их StageTrails._mark_line)
static func _stamp(w: WorldData, t: Dictionary) -> void:
	var pts: Array = t.pts
	for n: int in range(1, pts.size()):
		var a: Dictionary = pts[n - 1]
		var b: Dictionary = pts[n]
		var dx: float = b.x - a.x
		var dy: float = b.y - a.y
		var len := Grid.hypot(dx, dy)
		if len == 0.0:
			continue
		var half: float = maxf(float(a.w) * 0.5 - StageTrails.LINE_IN, 0.0)
		var nx := -dy / len * half
		var ny := dx / len * half
		var m := ceili(len / StageTrails.LINE_STEP)
		for s: int in m + 1:
			var f := float(s) / m
			var surf: int = t.surf[n - 1] if f < 0.5 else t.surf[n]
			for side: float in [-1.0, 0.0, 1.0]:
				var cx := floori(a.x + dx * f + nx * side)
				var cy := floori(a.y + dy * f + ny * side)
				if cx >= 0 and cy >= 0 and cx < w.W and cy < w.H and w.path_mask[cy * w.W + cx] >= 2:
					w.road_surface[cy * w.W + cx] = surf
