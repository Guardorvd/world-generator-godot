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
const Roads := preload("res://scripts/world/region_roads.gd")
const Known := preload("res://scripts/world/region_known.gd")


## В отличие от WorldData.region_rect, адрес существует и за краем стартового плана.
static func rect_for(key: Vector2i) -> Rect2i:
	return Rect2i(key * WorldData.REGION_SIZE, Vector2i.ONE * WorldData.REGION_SIZE)


## ledger — закреплённые области (commit): их клетки так же окончательны, как стартовый план.
static func prepare(w: WorldData, key: Vector2i, ledger := {}) -> Dictionary:
	return prepare_rect(w, rect_for(key), ledger)


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
static func finish_neighbors(source: WorldData, regions: Array, networks: Array, ledger := {}) -> Dictionary:
	var batch := WaterBatch.finish(regions, networks)
	batch.settlements = []
	batch.settlement_profiles = [] # время и число мест/домов по областям; в сравнения результата не входит
	batch.geographies = [] # уклоны, расстояния до воды и биомы областей; живут, пока жив пакет
	if not batch.ready: return batch
	for i in regions.size():
		var places := Settlements.prepare(source, regions[i], batch.surfaces[i], ledger)
		batch.settlements.append(places.settlements)
		batch.settlement_profiles.append(places.get("profile", {}))
		batch.geographies.append(places.get("geography", {}))
	return batch


## 13.5: следующий явный этап после воды и поселений, не изменяет уже подготовленную группу.
## 13.8: подходы к дорогам стартового плана, продолжение выходов закреплённых дорог и новые выходы.
static func prepare_roads(source: WorldData, regions: Array, batch: Dictionary, ledger := {}) -> Dictionary:
	return Roads.prepare(source, regions, batch, ledger)


## 13.8: закрепить принятую группу. Возвращает новый журнал, входной не меняется.
## Клетки областей становятся окончательными: следующий сосед их не пересчитывает, а продолжает
## выходы рек (outlets) и дорог (exits). Подходы к старым дорогам внутри плана — в plan_paths.
static func commit(ledger: Dictionary, regions: Array, networks: Array, batch: Dictionary, roads: Dictionary) -> Dictionary:
	if not batch.get("ready", false) or not roads.has("sample_rect") or regions.size() != networks.size():
		return {ready = false, reason = "not_ready", ledger = ledger}
	# 13.9+: записи закреплённых областей не меняются — копируются ссылками, без их полей.
	# Глубоко копируется только то, что commit правит: выходы и метки сетей поселений.
	var out := {regions = ledger.get("regions", {}).duplicate(), plan_paths = ledger.get("plan_paths", {}).duplicate(),
		outlets = ledger.get("outlets", []).duplicate(true), exits = ledger.get("exits", []).duplicate(true),
		settlements = EntityCodec.copy(EntityCodec.settlements(ledger.get("settlements", []))), trails = ledger.get("trails", []).duplicate(),
		bridges = ledger.get("bridges", []).duplicate()}
	var keys: Array[Vector2i] = []
	for region: Dictionary in regions:
		var key := Vector2i(floori(float(region.rect.position.x) / WorldData.REGION_SIZE),
			floori(float(region.rect.position.y) / WorldData.REGION_SIZE))
		if out.regions.has(key) or region.rect != rect_for(key):
			return {ready = false, reason = "already_committed", ledger = ledger}
		keys.append(key)
	var bounds: Rect2i = roads.sample_rect
	for n in regions.size():
		var region: Dictionary = regions[n]
		var rect: Rect2i = region.rect
		var surface: Dictionary = batch.surfaces[n]
		var cells := {h = PackedFloat32Array(), water_level = PackedFloat32Array(), dist = PackedFloat32Array(),
			river = PackedByteArray(), ocean = PackedByteArray(), lake = PackedByteArray(), biome = PackedByteArray(), path = PackedByteArray(),
			slope = PackedFloat32Array(), dw = PackedFloat32Array(), dist_path = PackedFloat32Array(), village = PackedByteArray()}
		for name: String in cells: cells[name].resize(rect.get_area())
		for y in range(rect.position.y, rect.end.y):
			for x in range(rect.position.x, rect.end.x):
				var dst := (y - rect.position.y) * rect.size.x + x - rect.position.x
				var src: int = (y - region.sample_rect.position.y) * region.sample_rect.size.x + x - region.sample_rect.position.x
				var at := (y - bounds.position.y) * bounds.size.x + x - bounds.position.x
				cells.h[dst] = surface.h[src]
				cells.water_level[dst] = maxf(surface.water_level[src], region.fields.water_level[src])
				cells.dist[dst] = region.fields.dist[src]
				cells.river[dst] = maxi(surface.river[src], region.fields.river[src])
				cells.ocean[dst] = region.fields.ocean[src]
				cells.lake[dst] = region.fields.lake[src]
				cells.biome[dst] = roads.biome[at]
				cells.path[dst] = roads.path_mask[at]
				# 13.9: для растительности и уклонов игры, как поля плана.
				for name: String in ["slope", "dw", "dist_path", "village"]:
					cells[name][dst] = roads[name][at] if roads.has(name) else 0
		# decor — что строит игра (RegionStream): у группы оно записано в первую её область.
		var decor := {trails = roads.trails.duplicate(true), bridges = roads.bridges.duplicate(true),
			settlements = roads.settlements.duplicate(true)} if n == 0 else {trails = [], bridges = [], settlements = []}
		out.regions[keys[n]] = {rect = rect, fields = cells, decor = decor}
	# Выходы, попавшие в закреплённые области, продолжены; остальные ждут следующего соседа.
	var regions_now: Dictionary = out.regions
	var reached := func(o: Dictionary) -> bool:
		var cell := Vector2i(floori(o.x + o.dx * 0.5), floori(o.y + o.dy * 0.5))
		return regions_now.has(Vector2i(floori(float(cell.x) / WorldData.REGION_SIZE), floori(float(cell.y) / WorldData.REGION_SIZE)))
	var outlets: Array = out.outlets.filter(func(o: Dictionary) -> bool: return not reached.call(o))
	for network: Dictionary in networks:
		for outlet: Dictionary in network.outlets:
			if not reached.call(outlet): outlets.append(outlet.duplicate(true))
	out.outlets = outlets
	var merged: Dictionary = roads.get("merged_nets", {})
	var exits: Array = []
	for exit: Dictionary in out.exits + roads.exits.duplicate(true):
		if reached.call(exit): continue
		exit.net = merged.get(exit.net, exit.net)
		exits.append(exit)
	out.exits = exits
	for s: SettlementData in out.settlements: s.net = merged.get(s.net, s.net)
	out.settlements.append_array(EntityCodec.copy(EntityCodec.settlements(roads.settlements)))
	out.trails.append_array(roads.trails.duplicate(true))
	out.bridges.append_array(roads.bridges.duplicate(true))
	for cell: Vector2i in roads.plan_paths:
		out.plan_paths[cell] = maxi(int(out.plan_paths.get(cell, 0)), roads.plan_paths[cell])
	return {ready = true, reason = "", ledger = out}


## Данные клеток лежат построчно в sample_rect, координаты — всегда мировые.
## fixed=1: окончательная география стартового плана или закреплённой области, её нельзя пересчитывать.
## fixed=0: существующий внешний рельеф/климат; пресная вода ещё НЕ рассчитана.
## ocean/lake/river — разные маски: отсутствие готовой реки снаружи не означает сухую область.
## water_level — нормализованные уровни filled внутри плана; снаружи море=0, суша=-INF.
## path (13.8) — готовые пути плана и закреплённых областей, как path_mask.
static func prepare_rect(w: WorldData, rect: Rect2i, ledger := {}) -> Dictionary:
	assert(rect.has_area(), "Область должна иметь положительный размер")
	assert(w.N == w.W * w.H and w.N > 0, "Нужен готовый стартовый план")
	for name: String in ["h", "biome", "temp", "moist", "elev", "slope", "dist_ocean",
			"dist_water", "filled", "ocean", "lake", "river"]:
		assert(w.get(name).size() == w.N, "Не готово поле " + name)
	var sample := rect.grow(HALO)
	# Тот же источник, которым уже пользуются внешний меш и растительность.
	var fields := OuterLand.compute(w, sample.position.x, sample.position.y, sample.size.x, sample.size.y)
	var area := sample.get_area()
	fields.fixed = PackedByteArray()
	fields.fixed.resize(area)
	fields.ocean = fields.fixed.duplicate()
	fields.lake = fields.fixed.duplicate()
	fields.path = fields.fixed.duplicate()
	fields.water_level = PackedFloat32Array()
	fields.water_level.resize(area)
	fields.water_level.fill(-INF)
	for i in area:
		fields.ocean[i] = int(fields.h[i] < 0.0)
		if fields.ocean[i] != 0: fields.water_level[i] = 0.0
	Known.apply_known(fields, sample, w, ledger)
	return {rect = rect, sample_rect = sample, fields = fields, river_inputs = river_inputs(w, rect, ledger)}


## 13.8: та же окончательная география для заранее посчитанной заготовки (изолированные проверки).
## Возвращает копию: клетки плана и журнала закреплены, входы рек взяты из плана и журнала.
static func pin(region: Dictionary, w: WorldData, ledger: Dictionary) -> Dictionary:
	var out: Dictionary = region.duplicate(true)
	if not out.fields.has("path"):
		out.fields.path = PackedByteArray()
		out.fields.path.resize(out.sample_rect.get_area())
	Known.apply_known(out.fields, out.sample_rect, w, ledger)
	out.river_inputs = river_inputs(w, out.rect, ledger)
	return out


## StageRivers уже хранит выходы в мировых координатах на геометрической границе.
## Полшага по направлению определяет ровно одну принимающую область, включая отрицательные
## координаты и углы. Ореол НЕ участвует в выборе владельца, иначе сток задвоится.
## 13.8: к выходам плана добавлены выходы рек закреплённых областей (ledger.outlets).
static func river_inputs(w: WorldData, rect: Rect2i, ledger := {}) -> Array[Dictionary]:
	var inputs: Array[Dictionary] = []
	for outlet: Dictionary in w.river_exits + ledger.get("outlets", []):
		var receiving := Vector2i(floori(outlet.x + outlet.dx * 0.5), floori(outlet.y + outlet.dy * 0.5))
		if rect.has_point(receiving):
			inputs.append(outlet.duplicate(true))
	# Порядок записей плана не должен влиять на последующую трассировку соседней области.
	inputs.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return a.y < b.y or a.y == b.y and a.x < b.x)
	return inputs


## One kit at most, using the start area's production construction chain on private regional data.
static func prepare_trails(w: WorldData, key: Vector2i, ledger: Dictionary, stop := Callable(), budget_ms := 10000) -> Dictionary:
	return preload("res://scripts/world/region_trails.gd").prepare(w, key, ledger, stop, budget_ms)
