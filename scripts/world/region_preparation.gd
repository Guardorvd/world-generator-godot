extends RefCounted
## Первый этап подготовки соседей: исходная география и условия от готового плана.
## Не запускает flood в отдельном квадрате и не объявляет внешний рельеф готовым игровым миром.
## Вызывать только с завершённым WorldData, который больше не меняется. Результат принадлежит
## вызывающему потоку; ссылок на изменяемые массивы/словари мира в нём нет.

const HALO := 2 # соседи для уклонов и освещения; НЕ граница расчёта водосбора
const Rivers := preload("res://scripts/world/region_rivers.gd")
const WaterSurface := preload("res://scripts/world/region_water_surface.gd")
const WaterBatch := preload("res://scripts/world/region_water_batch.gd")
const Settlements := preload("res://scripts/world/region_settlements.gd")


## В отличие от WorldData.region_rect, адрес существует и за краем стартового плана.
static func rect_for(key: Vector2i) -> Rect2i:
	return Rect2i(key * WorldData.REGION_SIZE, Vector2i.ONE * WorldData.REGION_SIZE)


static func prepare(w: WorldData, key: Vector2i) -> Dictionary:
	return prepare_rect(w, rect_for(key))


## 13.1: отдельный, явный шаг. Не меняет поля заготовки и не открывает игровую границу.
## unresolved требует дальнейшей обработки впадин/слияний, а не публикации оборванной реки.
static func prepare_rivers(region: Dictionary) -> Dictionary:
	return Rivers.trace(region)


## 13.2: сеть + отдельный проект поверхности; исходные поля не меняются.
static func prepare_water(region: Dictionary) -> Dictionary:
	var network := prepare_rivers(region)
	network.surface = WaterSurface.prepare(region, network)
	return network


## 13.3: поверхности соседей утверждаются вместе; поселения получают только этот результат.
static func finish_neighbors(source: WorldData, regions: Array, networks: Array) -> Dictionary:
	var batch := WaterBatch.finish(regions, networks)
	batch.settlements = []
	if not batch.ready: return batch
	for i in regions.size():
		var places := Settlements.prepare(source, regions[i], batch.surfaces[i])
		batch.settlements.append(places.settlements)
	return batch


## Данные клеток лежат построчно в sample_rect, координаты — всегда мировые.
## fixed=1: окончательная география стартового плана, её нельзя пересчитывать при продолжении.
## fixed=0: существующий внешний рельеф/климат; пресная вода ещё НЕ рассчитана.
## ocean/lake/river — разные маски: отсутствие готовой реки снаружи не означает сухую область.
## water_level — нормализованные уровни filled внутри плана; снаружи море=0, суша=-INF.
static func prepare_rect(w: WorldData, rect: Rect2i) -> Dictionary:
	assert(rect.has_area(), "Область должна иметь положительный размер")
	assert(w.N == w.W * w.H and w.N > 0, "Нужен готовый стартовый план")
	for name: String in ["h", "biome", "temp", "moist", "elev", "slope", "dist_ocean",
			"dist_water", "filled", "ocean", "lake", "river"]:
		assert(w.get(name).size() == w.N, "Не готово поле " + name)
	var sample := rect.grow(HALO)
	# Тот же источник, которым уже пользуются внешний меш и растительность.
	var fields := OuterLand.compute(w, sample.position.x, sample.position.y, sample.size.x, sample.size.y)
	var fixed := PackedByteArray()
	fixed.resize(sample.get_area())
	var ocean := fixed.duplicate()
	var lake := fixed.duplicate()
	var water_level := PackedFloat32Array()
	water_level.resize(sample.get_area())
	water_level.fill(-INF)
	var plan := Rect2i(0, 0, w.W, w.H)
	for y in sample.size.y:
		for x in sample.size.x:
			var cell := sample.position + Vector2i(x, y)
			var dst := y * sample.size.x + x
			if plan.has_point(cell):
				var src := cell.y * w.W + cell.x
				fixed[dst] = 1
				ocean[dst] = w.ocean[src]
				lake[dst] = w.lake[src]
				water_level[dst] = w.filled[src]
			else:
				ocean[dst] = int(fields.h[dst] < 0.0)
				if ocean[dst] != 0:
					water_level[dst] = 0.0
	fields.fixed = fixed
	fields.ocean = ocean
	fields.lake = lake
	fields.water_level = water_level
	return {rect = rect, sample_rect = sample, fields = fields, river_inputs = river_inputs(w, rect)}


## StageRivers уже хранит выходы в мировых координатах на геометрической границе.
## Полшага по направлению определяет ровно одну принимающую область, включая отрицательные
## координаты и углы. Ореол НЕ участвует в выборе владельца, иначе сток задвоится.
static func river_inputs(w: WorldData, rect: Rect2i) -> Array[Dictionary]:
	var inputs: Array[Dictionary] = []
	for outlet: Dictionary in w.river_exits:
		var receiving := Vector2i(floori(outlet.x + outlet.dx * 0.5), floori(outlet.y + outlet.dy * 0.5))
		if rect.has_point(receiving):
			inputs.append(outlet.duplicate(true))
	# Порядок записей плана не должен влиять на последующую трассировку соседней области.
	inputs.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return a.y < b.y or a.y == b.y and a.x < b.x)
	return inputs
