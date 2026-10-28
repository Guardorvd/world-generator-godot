class_name StageTrailPlan
extends RefCounted
## Одна автоматическая велотрасса в стартовой области нового мира (шаги 1–2): комплект из подхода от дорожной сети,
## самой трассы и выхода обратно в сеть. Общий механизм тот же, что в лаборатории:
## TrailScout → TrailPicker → TrailRouter (+ TrailAccess) → TrailFlow; второго построителя и второго графа нет.
##
## Порядок подготовки мира (единый результат до публикации):
## 1. Генерация до мест и путей (StageTrails, StageSites) — слой кэша «places».
## 2. ЭТОТ ЭТАП: на закрытой копии общего рельефа делается finish_paths (поверхность без новой трассы), по ней TrailScout
##    выбирает участок и строит трассу в локальных метрах участка. Определение переносится в мировые метры
##    (точки + начало участка), добавляется как обычный путь (TrailBuilder.append_routes: w.trails, path_mask, покрытия) и
##    сохраняется в w.trail_plan вместе со статусом «есть» / «нет». Копия рельефа выбрасывается.
## 3. Растительность и озёра (дальше по generate_layers) видят путь трассы в path_mask, как любую тропу.
## 4. Загрузка (WorldLoader): общий finish_paths уже прокладывает полотно всех путей, включая трассу; сразу после него
##    apply() запекает формирование и элементы (TrailBuilder.bake_elements) — до меша, столкновений и карты.
## Повторная загрузка из кэша: w.trail_plan и путь уже в мире — поиска нет, apply() запекает то же определение на свежем
## рельефе (земляные работы не копятся: рельеф каждый раз новый, запекается один раз).
## Отсутствие места — нормальный результат: статус «none» тоже сохраняется. Версия плана входит в ключ кэша
## (WorldCache.SCHEMA_TRAILS_VERSION): менять вместе с результатами TrailScout / TrailPicker / TrailRouter / TrailFlow.

const VERSION := 2
const ID := "start_trail"
const TITLE := "Трасса у дома"
## Сиды, для которых применение трассы не удалось: мир перегенерируется без неё (WorldLoader, откат).
static var skip := {}


## Выбрать и добавить трассу. size — сторона стартовой территории в клетках (0 — фон меню, этап пропускается).
static func run(w: WorldData, size: int) -> void:
	w.trail_plan = {version = VERSION, state = "none", reason = "этап не запускался"}
	if size <= 0 or w.base_heights == null:
		return
	if skip.has(w.seed_text):
		w.trail_plan.reason = "применение трассы в этом мире не удалось: мир собран без неё"
		return
	var started := Time.get_ticks_usec()
	# Покрытия путей нужны полотну finish_paths; в генераторе их ставит RoadSurface.run в конце (повторно, тем же
	# результатом: покрытие от биома, уклона и сида, не от растительности)
	RoadSurface.run(w)
	var h := w.base_heights.copy() # закрытая копия: общий рельеф генератора не трогаем
	h.finish_paths()
	var surface_ms := (Time.get_ticks_usec() - started) / 1000.0
	var area := WorldGenerator.start_rect(w, size)
	var scout := TrailScout.find(w, h, {area = area})
	var plan := {version = VERSION, state = "none", verdict = scout.verdict, reason = scout.reason, area = area,
		stats = {surface_ms = surface_ms, total_ms = (Time.get_ticks_usec() - started) / 1000.0, scout_ms = scout.stats.total_ms,
			eval_ms = scout.stats.eval_ms, cut_ms = scout.stats.cut_ms, picker_ms = scout.stats.picker_ms, flow_ms = scout.stats.flow_ms,
			expansions = scout.stats.expansions, builds = scout.stats.builds, searched = scout.stats.searched,
			access_expansions = scout.stats.access_expansions, access_ms = scout.stats.access_ms, nav_ms = scout.stats.nav_ms},
		windows = scout.windows.map(func(c: Dictionary) -> Dictionary: return {rect = c.rect, score = c.score, outcome = c.outcome})}
	if scout.accepted:
		var kit: Array[TrailDefinition] = []
		for d in scout.kit:
			kit.append(to_world(d, scout.site))
		var errors := TrailBuilder.append_routes(w, kit) # проверка до изменений: при ошибке мир не тронут
		if errors.is_empty():
			plan.state = "found"
			plan.reason = ""
			plan.definition = pack(kit[1])
			plan.access = {inbound = pack(kit[0]), outbound = pack(kit[2]), info = scout.access.last}
			plan.window = scout.window
			plan.variant = scout.flow.variant
		else:
			plan.reason = "трасса найдена, но не добавлена в мир: " + "; ".join(errors)
	w.trail_plan = plan


## Определение участка (локальные метры) в мировых метрах: сдвиг точек на начало участка. Остальное (станции элементов,
## профили) от начала участка не зависит; размеры и форма формирования те же. Участок и мир берут шумы полотна в мировых
## координатах (world_origin), поэтому поверхность не меняется от переноса.
static func to_world(local: TrailDefinition, site: TrailSite) -> TrailDefinition:
	var d := local.duplicate(true) as TrailDefinition
	if d.id == "site_route":
		d.id = ID
		d.title = TITLE
	var shift := site.origin_m()
	var points := PackedVector2Array()
	for p in local.points:
		points.append(p + shift)
	d.points = points
	return d


## После общего finish_paths: запечь формирование и элементы трассы на свежем рельефе. Возвращает отчёт
## {state, applied, variant, errors, ms}. Мир не остаётся частично изменённым: bake_elements публикует результат
## целиком или не меняет ничего. Если версия с элементами не принимается — запекается базовая линия без элементов.
static func apply(h: Heightfield) -> Dictionary:
	var w := h.world
	var plan := w.trail_plan
	var out := {state = str(plan.get("state", "none")), applied = false, variant = "", errors = PackedStringArray(), ms = 0.0}
	if out.state != "found":
		return out
	var started := Time.get_ticks_usec()
	if int(plan.get("version", 0)) != VERSION or not plan.has("definition"):
		out.errors.append("версия плана трассы не совпала с кодом: трасса не запекается")
		return out
	var definition := unpack(plan.definition)
	var kit: Array[TrailDefinition] = [unpack(plan.access.inbound), definition, unpack(plan.access.outbound)]
	var listed := {}
	for route: Dictionary in w.trails:
		listed[route.get("trail_id", "")] = true
	for d in kit:
		if not listed.has(d.id):
			out.errors.append("путь «%s» не найден в мире: трасса не запекается" % d.id)
			return out
	var errors := TrailBuilder.bake_elements(h, kit)
	out.variant = "основной"
	if not errors.is_empty():
		out.errors = errors
		var base := definition.duplicate(true) as TrailDefinition
		base.elements = [] as Array[TrailElement]
		kit[1] = base
		errors = TrailBuilder.bake_elements(h, kit)
		out.variant = "базовая линия"
		if not errors.is_empty():
			out.errors.append_array(errors)
			out.variant = ""
	out.applied = not out.variant.is_empty()
	out.ms = (Time.get_ticks_usec() - started) / 1000.0
	return out


## Определение в словарь для кэша (только простые типы).
static func pack(d: TrailDefinition) -> Dictionary:
	var elements: Array = []
	for e in d.elements:
		elements.append(_fields(e))
	return {id = d.id, title = d.title, kind = d.kind, points = d.points, width = d.width, surface = d.surface,
		earthwork = d.earthwork, elevation_offset = d.elevation_offset, auto_bank = d.auto_bank, closed = d.closed,
		shaping = _fields(d.shaping) if d.shaping != null else {}, elements = elements}


static func unpack(data: Dictionary) -> TrailDefinition:
	var d := TrailDefinition.new()
	for key: String in ["id", "title", "kind", "points", "width", "surface", "earthwork", "elevation_offset", "auto_bank", "closed"]:
		d.set(key, data[key])
	if not (data.shaping as Dictionary).is_empty():
		d.shaping = TrailShaping.new()
		_assign(d.shaping, data.shaping)
	var list: Array[TrailElement] = []
	for fields: Dictionary in data.elements:
		var e := TrailElement.new()
		_assign(e, fields)
		list.append(e)
	d.elements = list
	return d


## Поля @export ресурса: имя -> значение.
static func _fields(res: Resource) -> Dictionary:
	var out := {}
	for property: Dictionary in res.get_property_list():
		if property.usage & PROPERTY_USAGE_SCRIPT_VARIABLE and property.usage & PROPERTY_USAGE_STORAGE:
			out[property.name] = res.get(property.name)
	return out


static func _assign(res: Resource, fields: Dictionary) -> void:
	for name: String in fields:
		res.set(name, fields[name])
