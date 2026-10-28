class_name WorldData
extends RefCounted
## Фасад мира: идентичность и совместимый API над геологией, климатом/природой и инфраструктурой.
## Поля принадлежат контекстам, адресация — GridBuffer2D; packed-алиасы оставлены для массовых циклов/C#.
## Этот же объект служит общим состоянием этапов генерации (ctx в JS-версии): этапы читают и дополняют его поля.
## Генерация не зависит от отрисовки, поэтому её можно запускать в отдельном потоке.

# Настройки генерации (js/world/config.js)
const RIVER_ACC := 200.0  # характерный сток небольшой реки; русла начинаются с STREAM_ACC
const STREAM_ACC := 55.0 # постоянные ручьи; ширина плавно растёт с водосбором, без классов рек
const CHUNK_SIZE := 16    # сторона чанка растительности в клетках
## Поля шума, которые этапы берут целиком: имя шума -> [масштаб в клетках, число октав]
const NOISE_FIELDS := {moist = [170.0, 4], temp = [200.0, 3], forest = [36.0, 3], cost = [14.0, 2]}

const GridBuffer = preload("res://scripts/core/grid_buffer_2d.gd")
const Geology = preload("res://scripts/world/geology_data.gd")
const Climate = preload("res://scripts/world/climate_biogeography_data.gd")
const Civil = preload("res://scripts/world/civil_infrastructure_data.gd")
const Generation = preload("res://scripts/world/world_generation_state.gd")
const Streaming = preload("res://scripts/world/world_streaming_state.gd")

var grid := GridBuffer.Layout.new()
var geology := Geology.new(grid)
var climate := Climate.new(grid, CHUNK_SIZE)
var civil := Civil.new(grid)
var generation := Generation.new()
var streaming := Streaming.new()

## Явный плоский контракт кэша; служебные объекты и индексы в него не входят.
const CACHE_FIELDS := ["W", "H", "N", "seed_text", "seed_num", "territory_center", "available_rect",
	"territory_revision", "scale", "generation_profile"] + Geology.CACHE_FIELDS + Climate.CACHE_FIELDS + Civil.CACHE_FIELDS

var W := 0:
	set(value):
		W = value
		grid.width = value
var H := 0:
	set(value):
		H = value
		grid.height = value
var N := 0
var seed_text := ""
var seed_num := 0
## Мировая клетка, на которой лежит клетка (0, 0) этих данных. У мира и областей — ноль; у сохранённого участка
## Trail Lab (TrailSite) — его угол в плане: по ней шумы полотна, участки покрытий и кочки берутся в мировых
## координатах и не меняются от переноса участка. В кэш не входит.
var world_origin := Vector2i.ZERO

## 8.5: W/H — неизменный общий план, доступная территория — вложенное окно в нём.
## Координаты всегда мировые: при расширении нет ни сдвига, ни пересчёта массивов.
## Пустое окно у вручную созданных WorldData означает отсутствие ограничения.
## С 8.8 соседнее окно открывается заранее при движении (open_around).
const REGION_SIZE := 256
var territory_center: Vector2i:
	get:
		return streaming.territory_center
	set(value):
		streaming.territory_center = value
var available_rect: Rect2i:
	get:
		return streaming.available_rect
	set(value):
		streaming.available_rect = value
var territory_revision: int:
	get:
		return streaming.territory_revision
	set(value):
		streaming.territory_revision = value
const TRAVEL_MARGIN := 32.0 # клетки: открыть соседей до того, как тело/велосипед достигнет границы


## Только открывает новые клетки того же мира. Меньший размер не закрывает уже открытое.
func expand_territory(size: int) -> void:
	var side := clampi(size, 1, mini(W, H))
	side = maxi(side, maxi(available_rect.size.x, available_rect.size.y))
	var corner := Vector2i(clampi(territory_center.x - side / 2, 0, W - side),
		clampi(territory_center.y - side / 2, 0, H - side))
	var next := Rect2i(corner, Vector2i(side, side))
	if next != available_rect:
		available_rect = next
		territory_revision += 1


## Движение открывает соседнюю часть уже готового плана, без генерации и загрузочного экрана.
## Вызывать перед физикой: проверка столкновений не должна встретить старую границу.
func open_around(x: float, y: float) -> bool:
	if not available_rect.has_area() or x < 0.0 or y < 0.0 or x >= W or y >= H:
		return false
	var revision := territory_revision
	var limit := mini(W, H)
	while available_rect.size.x < limit:
		# Внешняя граница плана не требует открытия ещё одной области.
		var left := available_rect.position.x > 0 and x < available_rect.position.x + TRAVEL_MARGIN
		var top := available_rect.position.y > 0 and y < available_rect.position.y + TRAVEL_MARGIN
		var right := available_rect.end.x < W and x >= available_rect.end.x - TRAVEL_MARGIN
		var bottom := available_rect.end.y < H and y >= available_rect.end.y - TRAVEL_MARGIN
		if not (left or top or right or bottom):
			break
		expand_territory(mini(limit, available_rect.size.x + REGION_SIZE))
	return territory_revision != revision


## Координаты в клетках; margin — запас для тела игрока, тоже в клетках.
## 13.9+: за краем плана открыты закреплённые соседние области (OuterLand.committed).
func accessible(x: float, y: float, margin: float = 0.0) -> bool:
	if not available_rect.has_area():
		return true
	if x >= available_rect.position.x + margin and y >= available_rect.position.y + margin \
			and x < available_rect.end.x - margin and y < available_rect.end.y - margin:
		return true
	if outer == null:
		return false
	for corner: Vector2 in [Vector2(x - margin, y - margin), Vector2(x + margin, y - margin),
			Vector2(x - margin, y + margin), Vector2(x + margin, y + margin)]:
		var cell := Vector2i(floori(corner.x), floori(corner.y))
		if not available_rect.has_point(cell) and not outer.committed(cell.x, cell.y):
			return false
	return true


## Соседние области — адреса в общем плане, а не отдельные генерации с новым RNG.
## Их можно читать в любом порядке; индекс клетки остаётся y * W + x.
func region_rect(key: Vector2i) -> Rect2i:
	return Rect2i(key * REGION_SIZE, Vector2i(REGION_SIZE, REGION_SIZE)).intersection(Rect2i(0, 0, W, H))


func region_at(cell: Vector2i) -> Vector2i:
	return Vector2i(floori(float(cell.x) / REGION_SIZE), floori(float(cell.y) / REGION_SIZE))


## 8.9 extra: адреса мест и направлений для игровых систем. id — тип и мировая клетка: не зависит
## от порядка списков, открытой территории, имени и загрузки рельефа/леса. Устойчив для сида в пределах
## версии генератора. Индекс строится один раз из готового плана и не копирует записи мест.
static func place_id(kind: String, x: float, y: float) -> String:
	return "%s:%d:%d" % [kind, floori(x), floori(y)]


## Виды мест с адресами; список каждого — поле с тем же именем и «s» на конце. «site» (с 9.3) — вышки,
## руины, хутора и другие места вне поселений (StageSites), вид внутри записи — src.type.
const PLACE_KINDS := ["settlement", "peak", "lake", "site"]


## Места: id -> {id, kind (из PLACE_KINDS), name, x, y — клетки, region, src — запись плана}.
## Направления: связи сети поселений {id, from, to — id мест, road, regions — пара областей}.
func place(id: String) -> Dictionary:
	var p: Dictionary = _places().places.get(id, {})
	return p if not p.is_empty() else region_places().places.get(id, {})


## 13.9+final: поселения закреплённых соседних областей (OuterLand), тот же вид записей, что у плана.
## Направления — их дороги между собой; подход к старой сети (связь «plan») ведёт к ближайшему
## поселению плана. Индекс пересобирается, когда журнал областей заменён.
var _region_index: Dictionary:
	get:
		return streaming.region_index
	set(value):
		streaming.region_index = value

func region_places() -> Dictionary:
	if outer == null:
		return {places = {}, routes = [], list = []}
	var current := outer.get_ledger()
	if not _region_index.is_empty() and is_same(_region_index.ledger, current):
		return _region_index
	_region_index = {ledger = current, places = {}, routes = [], list = []}
	var settlements_now: Array = current.get("settlements", [])
	for src: SettlementData in settlements_now:
		var region := region_at(Vector2i(floori(src.x), floori(src.y)))
		var record := {id = src.id, kind = "settlement", name = EntityCodec.value(src, "name", ""), x = src.x, y = src.y, region = region, src = src}
		_region_index.places[src.id] = record
		_region_index.list.append(record)
	for src: SettlementData in settlements_now:
		for other: String in EntityCodec.value(src, "connections", []):
			var to := other
			if other == "plan":
				to = _nearest_plan_settlement(Vector2(src.x, src.y))
			if not _region_index.places.has(to) and place(to).is_empty() or src.id >= to and _region_index.places.has(to):
				continue
			var b := place(to)
			_region_index.routes.append({id = src.id + ">" + to, from = src.id, to = to, road = true,
				regions = [_region_index.places[src.id].region, b.region]})
	return _region_index


func _nearest_plan_settlement(at: Vector2) -> String:
	var best := ""
	var distance := INF
	for s: SettlementData in settlements:
		var d := at.distance_squared_to(Vector2(s.x, s.y))
		if d < distance:
			distance = d
			best = place_id("settlement", s.x, s.y)
	return best


func places_in_region(key: Vector2i) -> Array:
	var out: Array = []
	for id: String in _places().regions.get(key, []):
		out.append(_index.places[id])
	return out


## Направления из места; пустой from — все направления мира.
func routes(from: String = "") -> Array:
	var all: Array = _places().routes + region_places().routes
	return all if from.is_empty() else all.filter(func(r: Dictionary) -> bool: return r.from == from or r.to == from)


## Далёкое место назначения по сети: поселение в другой области, больше всего переходов от начала.
## Это выбор цели, а не задание: игрок сам решает, ехать ли и какой дорогой. Пусто, если такого нет.
func far_destination(from: String) -> Dictionary:
	var start := place(from)
	if start.is_empty():
		return {}
	var hops := {from: 0}
	var queue: Array[String] = [from]
	var best := {}
	var best_key := Vector2(-1.0, -1.0)
	while not queue.is_empty():
		var id: String = queue.pop_front()
		for r: Dictionary in routes(id):
			var next: String = r.to if r.from == id else r.from
			if hops.has(next):
				continue
			hops[next] = hops[id] + 1
			queue.append(next)
			var p := place(next)
			var key := Vector2(hops[next], Vector2(p.x, p.y).distance_to(Vector2(start.x, start.y)))
			if p.region != start.region and (key.x > best_key.x or key.x == best_key.x and key.y > best_key.y):
				best = p
				best_key = key
	return best


var _index := {}


func _places() -> Dictionary:
	# Пересобрать, только если этап генерации или тест заменил сами списки.
	if not _index.is_empty() and is_same(_index.lists[0], settlements) and is_same(_index.lists[1], peaks) \
			and is_same(_index.lists[2], lakes) and is_same(_index.lists[3], sites):
		return _index
	_index = {lists = [settlements, peaks, lakes, sites], places = {}, regions = {}, routes = []}
	for kind: String in PLACE_KINDS:
		for src: Variant in get(kind + "s"):
			var id := place_id(kind, src.x, src.y)
			var region := region_at(Vector2i(floori(src.x), floori(src.y)))
			_index.places[id] = {id = id, kind = kind, name = EntityCodec.value(src, "name", ""), x = src.x, y = src.y, region = region, src = src}
			if not _index.regions.has(region):
				_index.regions[region] = []
			_index.regions[region].append(id)
	var by_cell := {}
	for s: SettlementData in settlements:
		by_cell[s.i] = s
	for s: SettlementData in settlements:
		for other: int in s.connections:
			var o: SettlementData = by_cell.get(other)
			if o == null or other < s.i:
				continue
			var a := place_id("settlement", s.x, s.y)
			var b := place_id("settlement", o.x, o.y)
			_index.routes.append({id = a + ">" + b, from = a, to = b, road = StageTrails.main_road(s, o),
				regions = [_index.places[a].region, _index.places[b].region]})
	return _index

# Общее состояние генерации
var rng: WGRandom:
	get:
		return generation.rng
	set(value):
		generation.rng = value
var noise: Dictionary:
	get:
		return generation.noise
	set(value):
		generation.noise = value
var scale: float:
	get:
		return generation.scale
	set(value):
		generation.scale = value
# Названия не служат идентификаторами: идентификатор места — его мировая клетка.
var generation_profile: Dictionary:
	get:
		return generation.profile
	set(value):
		generation.profile = value

# Рельеф и вода
var macro_x: float:
	get:
		return geology.macro_x
	set(value):
		geology.macro_x = value
var macro_y: float:
	get:
		return geology.macro_y
	set(value):
		geology.macro_y = value
## Характер гор мира (с 3.5), постоянный на сид и независимый от размера стартовой карты.
var mountain_scale: float:
	get:
		return geology.mountain_scale
	set(value):
		geology.mountain_scale = value
var mountain_bias: float:
	get:
		return geology.mountain_bias
	set(value):
		geology.mountain_bias = value
var mountain_height: float:
	get:
		return geology.mountain_height
	set(value):
		geology.mountain_height = value
var foothill_spread: float:
	get:
		return geology.foothill_spread
	set(value):
		geology.foothill_spread = value
var outer: OuterLand:
	get:
		return streaming.outer
	set(value):
		streaming.outer = value
## Общий базовый рельеф: владеет только слабой обратной ссылкой на мир, в том числе при прерывании генерации.
## После генерации освобождается; игровые копии Heightfield.base_of владеют миром независимо.
var base_heights: Heightfield:
	get:
		return generation.base_heights
	set(value):
		generation.base_heights = value
		if value != null:
			value.weaken_world()
var h: PackedFloat32Array:
	get:
		return geology.h.data
	set(value):
		geology.h.data = value
var filled: PackedFloat32Array:
	get:
		return geology.filled.data
	set(value):
		geology.filled.data = value
var elev: PackedFloat32Array:
	get:
		return geology.elev.data
	set(value):
		geology.elev.data = value
var ocean: PackedByteArray:
	get:
		return geology.ocean.data
	set(value):
		geology.ocean.data = value
var lake: PackedByteArray:
	get:
		return geology.lake.data
	set(value):
		geology.lake.data = value
var river: PackedByteArray:
	get:
		return geology.river.data
	set(value):
		geology.river.data = value
var river_area: PackedByteArray:
	get:
		return geology.river_area.data
	set(value):
		geology.river_area.data = value
var acc: PackedFloat32Array:
	get:
		return geology.acc.data
	set(value):
		geology.acc.data = value
var slope: PackedFloat32Array:
	get:
		return geology.slope.data
	set(value):
		geology.slope.data = value
var watershed: PackedInt32Array:
	get:
		return geology.watershed.data
	set(value):
		geology.watershed.data = value
var down: PackedInt32Array:
	get:
		return geology.down.data
	set(value):
		geology.down.data = value
var order: PackedInt32Array:
	get:
		return geology.order
	set(value):
		geology.order = value
var order_n: int:
	get:
		return geology.order_n
	set(value):
		geology.order_n = value
var rain: PackedFloat32Array:
	get:
		return geology.rain.data
	set(value):
		geology.rain.data = value
var dist_ocean: PackedFloat32Array:
	get:
		return geology.dist_ocean.data
	set(value):
		geology.dist_ocean.data = value
var dist_water: PackedFloat32Array:
	get:
		return geology.dist_water.data
	set(value):
		geology.dist_water.data = value

# Климат
var temp: PackedFloat32Array:
	get:
		return climate.temp.data
	set(value):
		climate.temp.data = value
var moist: PackedFloat32Array:
	get:
		return climate.moist.data
	set(value):
		climate.moist.data = value
var biome: PackedByteArray:
	get:
		return climate.biome.data
	set(value):
		climate.biome.data = value

# Реки, тропы, поселения, вершины
var rivers: Array:
	get:
		return geology.rivers
	set(value):
		geology.rivers = value
var river_exits: Array:
	get:
		return geology.river_exits
	set(value):
		geology.river_exits = value
var cost: PackedFloat32Array:
	get:
		return civil.cost.data
	set(value):
		civil.cost.data = value
var path_mask: PackedByteArray:
	get:
		return civil.path_mask.data
	set(value):
		civil.path_mask.data = value
var trails: Array:
	get:
		return civil.trails
	set(value):
		civil.trails = value
var trail_plan: Dictionary:
	get:
		return civil.trail_plan
	set(value):
		civil.trail_plan = value
var road_surface: PackedByteArray:
	get:
		return civil.road_surface.data
	set(value):
		civil.road_surface.data = value
var bridges: Array:
	get:
		return civil.bridges
	set(value):
		civil.bridges = EntityCodec.bridges(value)
var tunnels: Array:
	get:
		return civil.tunnels
	set(value):
		civil.tunnels = EntityCodec.tunnels(value)
var settlements: Array:
	get:
		return civil.settlements
	set(value):
		civil.settlements = EntityCodec.settlements(value)
var peaks: Array:
	get:
		return geology.peaks
	set(value):
		geology.peaks = value
var sites: Array:
	get:
		return civil.sites
	set(value):
		civil.sites = EntityCodec.sites(value)
var lakes: Array:
	get:
		return geology.lakes
	set(value):
		geology.lakes = EntityCodec.lakes(value)
var lake_id: PackedInt32Array:
	get:
		return geology.lake_id.data
	set(value):
		geology.lake_id.data = value

# Растительность: объекты хранятся столбцами, чанки — списки номеров объектов
var obj_x: PackedFloat64Array:
	get:
		return climate.obj_x
	set(value):
		climate.obj_x = value
var obj_y: PackedFloat64Array:
	get:
		return climate.obj_y
	set(value):
		climate.obj_y = value
var obj_k: PackedInt32Array:
	get:
		return climate.obj_k
	set(value):
		climate.obj_k = value
var obj_v: PackedInt32Array:
	get:
		return climate.obj_v
	set(value):
		climate.obj_v = value
var obj_s: PackedFloat64Array:
	get:
		return climate.obj_s
	set(value):
		climate.obj_s = value
var chunks: Array[PackedInt32Array]:
	get:
		return climate.chunks
	set(value):
		climate.chunks = value
var CS: int:
	get:
		return climate.CS
	set(value):
		climate.CS = value
var CW: int:
	get:
		return climate.CW
	set(value):
		climate.CW = value
var CH: int:
	get:
		return climate.CH
	set(value):
		climate.CH = value
var obj_count: int:
	get:
		return climate.obj_count
	set(value):
		climate.obj_count = value


## Для размещения и маршрутов нужен весь коридор, а не только клетки стока.
func river_cells() -> PackedByteArray:
	return geology.river_mask(N).data


## Начать считать поля NOISE_FIELDS в отдельном потоке. Они зависят только от сида, поэтому
## их расчёт идёт одновременно с последовательными этапами (заполнение впадин), а не после них
func start_noise_fields() -> void:
	generation.start_fields(W, H, NOISE_FIELDS)


func noise_field(name: String) -> PackedFloat64Array:
	return generation.field(name, W, H, NOISE_FIELDS)


func clear_noise_fields() -> void:
	generation.clear_fields()


## Чистое имя места: дома, другие имена и порядок чтения областей не расходуют его RNG.
## Как в реальной географии, названия могут повторяться; UI использует клетку/тип, не текст имени.
func make_name(parts: Dictionary, kind: String, x: int, y: int) -> String:
	var local := WGRandom.at(seed_num, "name." + kind, x, y)
	var a: Array = parts.first
	var b: Array = parts.second
	return a[floori(local.next_float() * a.size())] + parts.sep + b[floori(local.next_float() * b.size())]


## Номер озера из lakes, у которого стоит точка (клетки): озеро в квадрате ±r клеток или -1
func lake_near(x: float, y: float, r: int) -> int:
	return geology.lake_near(x, y, r)


func lake_within(x: float, y: float, r: int, id: int) -> bool:
	return geology.lake_within(x, y, r, id)


## Сведения о местности в точке (координаты в клетках). За краем карты — из OuterLand, если он
## подключён и этот кусок уже посчитан, иначе пустой словарь
func tile_info(x: float, y: float) -> Dictionary:
	var tx := floori(x)
	var ty := floori(y)
	if tx < 0 or ty < 0 or tx >= W or ty >= H:
		return outer.info(tx, ty) if outer != null else {}
	var i := grid.index(tx, ty)
	return {
		i = i, biome = climate.biome.get_cell(tx, ty), river = geology.river_mask(N).get_cell(tx, ty) == 1, path = civil.path_mask.get_cell(tx, ty) if civil.path_mask.data.size() == N else 0,
		surface = civil.road_surface.get_cell(tx, ty) if civil.road_surface.data.size() == N else 0,
		elev = geology.elev.get_cell(tx, ty), temp = climate.temp.get_cell(tx, ty), moist = climate.moist.get_cell(tx, ty), slope = geology.slope.get_cell(tx, ty),
	}
