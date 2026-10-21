class_name WorldData
extends RefCounted
## Мир — чистые данные: сетка W × H клеток, клетка (x, y) лежит в массивах по индексу y * W + x.
## Этот же объект служит общим состоянием этапов генерации (ctx в JS-версии): этапы читают и дополняют его поля.
## Генерация не зависит от отрисовки, поэтому её можно запускать в отдельном потоке.

# Настройки генерации (js/world/config.js)
const RIVER_ACC := 200.0  # характерный сток небольшой реки; русла начинаются с STREAM_ACC
const STREAM_ACC := 55.0 # постоянные ручьи; ширина плавно растёт с водосбором, без классов рек
const CHUNK_SIZE := 16    # сторона чанка растительности в клетках
## Поля шума, которые этапы берут целиком: имя шума -> [масштаб в клетках, число октав]
const NOISE_FIELDS := {moist = [170.0, 4], temp = [200.0, 3], forest = [36.0, 3], cost = [14.0, 2]}

var W := 0
var H := 0
var N := 0
var seed_text := ""
var seed_num := 0

# Общее состояние генерации
var rng: WGRandom
var noise := {}           # имя -> Simplex
var scale := 1.0          # во сколько раз мир больше среднего: от этого зависит число поселений и троп
var used_names := {}
var generation_profile := {} # необязательные счётчики дорожного этапа из bench.gd
var _fields_thread: Thread
var _fields := {}         # имя -> поле fbm из NOISE_FIELDS

# Рельеф и вода
var macro_x := 0.0       # сдвиг шума материков в клетках: где в бесконечном мире лежит стартовая область (StageRelief)
var macro_y := 0.0
## Характер гор мира (с 3.5), постоянный на сид и независимый от размера стартовой карты.
var mountain_scale := 1.0  # масштаб массивов, гребней и внутренних долин
var mountain_bias := 0.3   # распространённость гор: ниже — реже
var mountain_height := 1.0 # высота горного подъёма
var foothill_spread := 0.0 # ширина и выраженность предгорий (с 3.6), 0 — без дополнительного пояса
var outer: OuterLand     # рельеф за краем карты (с 1.9.5), если игра его подключила; иначе null
var h := PackedFloat32Array()        # высота (0 — уровень моря, суша до 1, дно до -1)
var filled := PackedFloat32Array()   # высота с заполненными впадинами (уровень озёр)
var elev := PackedFloat32Array()     # StageGeography: высота суши / поверхности озера, океан = 0
var ocean := PackedByteArray()
var lake := PackedByteArray()
var river := PackedByteArray()
var river_area := PackedByteArray() # коридор сглаженной воды с учётом ширины; river остаётся сетью стока
var acc := PackedFloat32Array()      # накопленный сток
var slope := PackedFloat32Array()    # StageGeography: уклон по elev (историческая шкала ×60)
var down := PackedInt32Array()       # клетка, куда стекает вода (-1 — нет)
var order := PackedInt32Array()      # порядок заполнения впадин
var order_n := 0
var rain := PackedFloat32Array()
var dist_ocean := PackedFloat32Array()
var dist_water := PackedFloat32Array() # StageGeography: расстояние до океана, озёр и рек в клетках

# Климат
var temp := PackedFloat32Array()
var moist := PackedFloat32Array()
var biome := PackedByteArray()

# Реки, тропы, поселения, вершины
var rivers: Array = []        # ломаные из точек {x, y, w — ширина в клетках, e — высота воды}
var river_exits: Array = []   # выходы за карту: {x, y, dx, dy, acc, e, w}; задел для продолжения стока
var cost := PackedFloat32Array()
var path_mask := PackedByteArray()   # 1 — звериная тропа, 2 — тропа людей, 3 — дорога
var trails: Array = []        # [{kind: "animal" | "trail" | "mountain" | "road", pts, surf — покрытие точек (RoadSurface)}]
var road_surface := PackedByteArray() # покрытие клетки пути людей из RoadSurface (с 4.3), 0 — нет
var bridges: Array = []       # мосты [{a, b}]: клетки на берегах, мост — прямой отрезок между их центрами
var tunnels: Array = []       # туннели [{a, b}]: клетки у входов, туннель — прямой отрезок между ними
var settlements: Array = []   # [{x, y, i, name, character, huts: [{x, y, v}], connections: [i соседей по дорогам]}]
var peaks: Array = []         # [{x, y, i, elev, name}]
var lakes: Array = []         # озёра с названиями (с 2.9) [{x, y, i, level, name, cells, sx, sy}], см. StageLakes
var lake_id := PackedInt32Array()    # номер озера из lakes для клетки или -1

# Растительность: объекты хранятся столбцами, чанки — списки номеров объектов
var obj_x := PackedFloat64Array()
var obj_y := PackedFloat64Array()
var obj_k := PackedInt32Array()      # вид из Biomes.T_*
var obj_v := PackedInt32Array()      # вариант
var obj_s := PackedFloat64Array()    # масштаб
var chunks: Array[PackedInt32Array] = []
var CS := CHUNK_SIZE
var CW := 0
var CH := 0
var obj_count := 0


## Для размещения и маршрутов нужен весь коридор, а не только клетки стока.
func river_cells() -> PackedByteArray:
	return river_area if river_area.size() == N else river


## Начать считать поля NOISE_FIELDS в отдельном потоке. Они зависят только от сида, поэтому
## их расчёт идёт одновременно с последовательными этапами (заполнение впадин), а не после них
func start_noise_fields() -> void:
	_fields_thread = Thread.new()
	_fields_thread.start(func() -> Dictionary:
		var out := {}
		for name: String in NOISE_FIELDS:
			var p: Array = NOISE_FIELDS[name]
			out[name] = Parallel.fbm_field(W, H, noise[name], p[0], p[1])
		return out)


## Поле шума из NOISE_FIELDS (ждёт поток, если поле ещё не готово)
func noise_field(name: String) -> PackedFloat64Array:
	if _fields_thread != null:
		_fields = _fields_thread.wait_to_finish()
		_fields_thread = null
	if not _fields.has(name):
		var p: Array = NOISE_FIELDS[name]
		_fields[name] = Parallel.fbm_field(W, H, noise[name], p[0], p[1])
	return _fields[name]


## Поля нужны только этапам генерации; готовый мир не держит четыре временных карты шума.
func clear_noise_fields() -> void:
	if _fields_thread != null:
		_fields_thread.wait_to_finish()
		_fields_thread = null
	_fields.clear()


## Уникальное название из двух частей (см. scripts/data/names.gd)
func make_name(parts: Dictionary) -> String:
	var a: Array = parts.first
	var b: Array = parts.second
	var sep: String = parts.sep
	for _attempt in 40:
		var n: String = a[floori(rng.next_float() * a.size())] + sep + b[floori(rng.next_float() * b.size())]
		if not used_names.has(n):
			used_names[n] = true
			return n
	return a[0] + sep + b[0] + " " + str(used_names.size())


## Номер озера из lakes, у которого стоит точка (клетки): озеро в квадрате ±r клеток или -1
func lake_near(x: float, y: float, r: int) -> int:
	if lake_id.is_empty():
		return -1
	var tx := floori(x)
	var ty := floori(y)
	for dy in range(maxi(0, ty - r), mini(H, ty + r + 1)):
		for dx in range(maxi(0, tx - r), mini(W, tx + r + 1)):
			var id := lake_id[dy * W + dx]
			if id >= 0:
				return id
	return -1


## Сведения о местности в точке (координаты в клетках). За краем карты — из OuterLand, если он
## подключён и этот кусок уже посчитан, иначе пустой словарь
func tile_info(x: float, y: float) -> Dictionary:
	var tx := floori(x)
	var ty := floori(y)
	if tx < 0 or ty < 0 or tx >= W or ty >= H:
		return outer.info(tx, ty) if outer != null else {}
	var i := ty * W + tx
	return {
		i = i, biome = biome[i], river = river_cells()[i] == 1, path = path_mask[i],
		surface = road_surface[i] if road_surface.size() == N else 0,
		elev = elev[i], temp = temp[i], moist = moist[i], slope = slope[i],
	}
