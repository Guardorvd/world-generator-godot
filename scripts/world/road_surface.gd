class_name RoadSurface
extends RefCounted
## Слой дорожного полотна (с 4.3), часть 1: покрытие. Идёт после всех этапов генерации, по готовым
## линиям w.trails; маршруты, клетки путей и общий RNG не трогает. Покрытие выбирается по виду пути,
## связному окружению, крутизне и близости поселения. Случайный хеш не меняет основной материал;
## его неоднородности рисует шейдер. Высоты полотна — вторая часть, RoadBed (scripts/game).
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
	{name = "гравий", grain = 0.8, organic = 0.0, speed = 1.4, rough = 0.18, grip = 0.95, hard = true, color = [164, 151, 127]},
	{name = "грунтовка", grain = 0.3, organic = 0.0, speed = 1.33, rough = 0.2, grip = 1.0, hard = false, color = [160, 128, 88]},
	{name = "укатанная земля", grain = 0.08, organic = 0.0, speed = 1.4, rough = 0.12, grip = 1.0, hard = false, color = [150, 126, 96]},
	{name = "камень", grain = 1.0, organic = 0.0, speed = 1.2, rough = 0.45, grip = 0.9, hard = true, color = [157, 144, 121]},
	{name = "песок", grain = 0.12, organic = 0.0, speed = 1.1, rough = 0.2, grip = 0.75, hard = false, color = [212, 194, 148]},
	{name = "лесная тропа", grain = 0.18, organic = 0.65, speed = 1.22, rough = 0.32, grip = 0.95, hard = false, color = [124, 98, 68]},
	{name = "травяная колея", grain = 0.05, organic = 1.0, speed = 1.15, rough = 0.28, grip = 0.95, hard = false, color = [150, 146, 96]},
]

const VILLAGE_R := 7.0    # ближе этого к костру (клеток) дорога укатана
const STONE_SLOPE := 0.19 # средняя крутизна окружения, а не отдельный камень в клетке
const ORDER := ["mountain", "trail", "road"]   # кто кого перекрывает в w.road_surface (дорога сверху)
static var allow_fast := true # the scalar pick() remains the reference and small authored-route API


static func run(w: WorldData) -> void:
	w.road_surface = PackedByteArray()
	w.road_surface.resize(w.N)
	var fast := Grid.fast_grid() if allow_fast else null
	if fast != null:
		_assign_native(w, fast)
	else:
		for t: Dictionary in w.trails: assign_route(w, t)
	rebuild_map(w)
	# The dominant route continues through the junction. Use the existing stamped map;
	# neither route order nor direction chooses a new material at a crossing.
	for t: Dictionary in w.trails:
		if t.kind == "animal" or t.get("surface_override", NONE) != NONE:
			continue
		for n in t.pts.size():
			var p: Dictionary = t.pts[n]
			var i := clampi(floori(p.y), 0, w.H - 1) * w.W + clampi(floori(p.x), 0, w.W - 1)
			if w.road_surface[i] != NONE:
				t.surf[n] = w.road_surface[i]
	rebuild_map(w)


## One call for the sparse route points; no extra whole-world environmental maps.
static func _assign_native(w: WorldData, fast: Object) -> void:
	var xs := PackedFloat64Array()
	var ys := PackedFloat64Array()
	var kinds := PackedInt32Array()
	var included: Array[Dictionary] = []
	for t: Dictionary in w.trails:
		if t.kind == "animal" or t.get("surface_override", NONE) != NONE:
			assign_route(w, t)
			continue
		included.append(t)
		for p: Dictionary in t.pts:
			xs.append(p.x); ys.append(p.y)
			kinds.append(0 if t.kind == "road" else (2 if t.kind == "mountain" else 1))
	var villages := PackedFloat64Array()
	for s: SettlementData in w.settlements: villages.append_array(PackedFloat64Array([s.x, s.y]))
	var biomes := PackedInt32Array([Biomes.FOREST, Biomes.TAIGA, Biomes.JUNGLE, Biomes.ROCK, Biomes.PEAK,
		Biomes.SNOW, Biomes.STONESHORE, Biomes.BEACH, Biomes.DESERT, Biomes.GRASS])
	var values: PackedByteArray = fast.PickRoadSurfaces(xs, ys, kinds, w.W, w.H, w.biome, w.slope, w.moist, villages, biomes, VILLAGE_R, STONE_SLOPE)
	var at := 0
	for t: Dictionary in included:
		t.surf = values.slice(at, at + t.pts.size())
		at += t.pts.size()


## Assign one route without touching its neighbours. Explicit authoring survives run().
static func assign_route(w: WorldData, t: Dictionary) -> void:
	t.surf = PackedByteArray()
	if t.kind == "animal":
		t.surf.resize(t.pts.size())
		return
	var authored: int = t.get("surface_override", NONE)
	if authored > NONE and authored < LIST.size():
		t.surf.resize(t.pts.size())
		t.surf.fill(authored)
		return
	for n: int in t.pts.size():
		var p: Dictionary = t.pts[n]
		t.surf.append(pick(w, t.kind, p.x, p.y, 0.0))


## Rebuild the cell map from assigned point surfaces (also used by authored trails).
static func rebuild_map(w: WorldData) -> void:
	w.road_surface.resize(w.N)
	w.road_surface.fill(NONE)
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


## Local 16 m environment, shared by plan/regions and invariant to route reversal.
## Bilinear samples avoid a material decision tied to crossing a world-grid cell.
## v is retained for callers of the former hash-based API; it has no physical meaning.
static func pick(w: WorldData, kind: String, x: float, y: float, _v := 0.0) -> int:
	var wooded := 0.0
	var rocky := 0.0
	var sandy := 0.0
	var grass := 0.0
	var slope := 0.0
	var moist := 0.0
	for dz in range(-1, 2):
		for dx in range(-1, 2):
			var px := clampf(x + dx * 2.0 - 0.5, 0.0, w.W - 1.0)
			var py := clampf(y + dz * 2.0 - 0.5, 0.0, w.H - 1.0)
			var ix := floori(px)
			var iy := floori(py)
			var kernel := (2.0 if dx == 0 else 1.0) * (2.0 if dz == 0 else 1.0) / 16.0
			for oz in 2:
				for ox in 2:
					var weight := kernel * (px - ix if ox else 1.0 - px + ix) * (py - iy if oz else 1.0 - py + iy)
					var i := mini(iy + oz, w.H - 1) * w.W + mini(ix + ox, w.W - 1)
					var b := w.biome[i]
					wooded += weight if b == Biomes.FOREST or b == Biomes.TAIGA or b == Biomes.JUNGLE else 0.0
					rocky += weight if b == Biomes.ROCK or b == Biomes.PEAK or b == Biomes.SNOW or b == Biomes.STONESHORE else 0.0
					sandy += weight if b == Biomes.BEACH or b == Biomes.DESERT else 0.0
					grass += weight if b == Biomes.GRASS else 0.0
					# One cliff/root cell is an inclusion, not a different road material.
					slope += minf(w.slope[i], 0.4) * weight
					moist += w.moist[i] * weight
	if sandy > 0.55:
		return SAND
	if kind == "road":
		for s: SettlementData in w.settlements:
			if absf(s.x - x) < VILLAGE_R and absf(s.y - y) < VILLAGE_R and Grid.hypot(s.x - x, s.y - y) < VILLAGE_R:
				return PACKED
		# A maintained road keeps its aggregate through forest/meadow and moderate slopes.
		return STONE if rocky > 0.6 and slope > STONE_SLOPE + 0.04 else GRAVEL
	if rocky > 0.55 or slope > STONE_SLOPE:
		return STONE
	if wooded > 0.45:
		return FOREST
	if kind == "mountain":
		return DIRT
	return MEADOW if grass > 0.6 and moist > 0.32 and slope < 0.10 else DIRT


## Та же разметка ленты, что у path_mask, включая угловые клетки диагоналей.
static func _stamp(w: WorldData, t: Dictionary) -> void:
	if t.pts.size() < 2:
		return
	Grid.stamp_path(w.road_surface, w.W, w.H, t.pts, 0, -1.0, t.surf)
