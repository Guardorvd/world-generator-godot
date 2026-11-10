class_name StageTrailPlan
extends RefCounted
## Prepared-world trail network. The shared search/layout and TrailSite preparation are also used by Trail Lab.
## Discovery runs once; accepted metre patches are handed to WorldLoader and its normal surface cache.
const NETWORK_SCRIPT := "res://scripts/trails/trail_world_network.gd"
const VERSION := 30 # стыки метровых патчей и сохранение готовых примыканий
const ID := "start_trail"
const TITLE := "Трасса у дома"

static func run(w: WorldData, on_progress := Callable()) -> void:
	w.trail_plan = {version = VERSION, state = "none", reason = "этап не запускался"}
	if w.base_heights == null: return
	if on_progress.is_valid(): on_progress.call(0.79, "Подготовка поверхности велосипедных трасс")
	var started := Time.get_ticks_msec()
	RoadSurface.run(w)
	w.generation.surface_rock = RockRelief.field_of(w)
	var h := w.base_heights.copy()
	h.finish_paths()
	var surface_ms := Time.get_ticks_msec() - started
	var area := Rect2i(0, 0, w.W, w.H)
	# Обычная игра — только велопарки; прежняя универсальная сеть маршрутов осталась для опытов (`-- --trail-network`, QuickTrails)
	var options := {on_progress = on_progress, mode = "network" if QuickTrails.network() else "parks"}
	if QuickTrails.active(): # только разработка: сеть на средней части мира и короче (scripts/core/quick_trails.gd)
		area = QuickTrails.area(area)
		options.merge(QuickTrails.options())
	w.trail_plan = load(NETWORK_SCRIPT).build(w, h, area, options)
	w.trail_plan.stats.base_surface_ms = surface_ms
	w.trail_plan.version = VERSION
	# Generation-only handoff, never part of the canonical cache fields; avoid a WorldData reference cycle.
	h.weaken_world()
	w.generation.trail_surface = h

## Prepare once on cold generation, or replay saved definitions if only the derived surface is missing.
## Legacy regional kits retain their existing application contract.
static func prepare(h: Heightfield) -> Dictionary:
	var w := h.world
	var plan := w.trail_plan
	var consistency := consistency_errors(w)
	if not consistency.is_empty():
		return {state = str(plan.get("state", "none")), applied = false, variant = "", errors = consistency, ms = 0.0, earthworks = {}}
	if plan.get("mode", "") != "terrain_network" or stale(plan):
		h.finish_paths()
		return apply(h)
	var started := Time.get_ticks_usec()
	var errors := PackedStringArray()
	if w.generation.trail_surface != null:
		var ready: Heightfield = w.generation.trail_surface
		copy_surface(h, ready)
		w.generation.trail_surface = null
	else:
		errors = load(NETWORK_SCRIPT).restore(h, plan)
	var out := {state = plan.state, applied = plan.state == "found" and errors.is_empty(), variant = "основной",
		errors = errors, ms = 0.0, earthworks = {}}
	if out.applied:
		_build_technical(h, _kit(plan), out)
		out.earthworks = h.road_refinement.trail_shaping.duplicate(true)
	out.ms = (Time.get_ticks_usec() - started) / 1000.0
	return out

static func copy_surface(h: Heightfield, ready: Heightfield) -> void:
	for field in ["hv", "hv_raw", "water_level", "ribbons", "_river_cells", "_seg_pts", "_pair_cells", "_pair_segs",
		"structures", "_cells", "_deck_keys", "road_refinement", "path_timings"]:
		h.set(field, ready.get(field))


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
	if h.world.trail_plan.get("mode", "") == "terrain_network" and not stale(h.world.trail_plan):
		# Compatibility for tools that already called finish_paths. The loader calls prepare directly.
		if h.world.generation.trail_surface == null and h.road_refinement != null:
			copy_surface(h, Heightfield.base_of(h.world))
		return prepare(h)
	var w := h.world
	var plan := w.trail_plan
	var out := {state = str(plan.get("state", "none")), applied = false, variant = "", errors = PackedStringArray(), ms = 0.0, earthworks = {}}
	if stale(plan):
		out.state = "stale"
		out.errors.append("план трассы версии %d, код — %d: мир нужно подготовить заново" % [int(plan.get("version", 0)), VERSION])
		return out
	if out.state != "found":
		return out
	var started := Time.get_ticks_usec()
	if not plan.has("definition"):
		out.errors.append("в плане нет определения трассы: трасса не запекается")
		return out
	var kit := _kit(plan)
	var main := 0 if plan.has("routes") else 1 # номер трассы с элементами, которую при неудаче запекаем без них
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
		for k in kit.size():
			if not plan.has("routes") and k != main: continue
			var base := kit[k].duplicate(true) as TrailDefinition
			base.elements = [] as Array[TrailElement]
			kit[k] = base
		errors = TrailBuilder.bake_elements(h, kit)
		out.variant = "базовая линия"
		if not errors.is_empty():
			out.errors.append_array(errors)
			out.variant = ""
	out.applied = not out.variant.is_empty()
	if out.applied:
		_build_technical(h, kit, out)
		for d in kit: out.earthworks[d.id] = h.road_refinement.trail_shaping.get(d.id, {}).duplicate()
		out.earthworks.patches_added = h.road_refinement.build_timings.get("trail_patches_added", 0)
		out.earthworks.zone_patches = h.road_refinement.build_timings.get("trail_zone_patches", 0)
	out.ms = (Time.get_ticks_usec() - started) / 1000.0
	return out


## Загрузка из кэша (поверхность уже запечена): собрать те же объекты трассы, что apply() на холодной загрузке, —
## тем же кодом на том же рельефе. Настилы уже в сохранённых сооружениях: add_decks их пропускает.
static func restore_technical(h: Heightfield, report: Dictionary) -> void:
	var plan := h.world.trail_plan
	if not report.get("applied", false) or stale(plan) or not plan.has("definition"):
		return
	var kit := _kit(plan)
	if report.get("variant", "") != "основной":
		for k in kit.size():
			if not plan.has("routes") and k != 1: continue
			kit[k].elements = [] as Array[TrailElement]
	_build_technical(h, kit, report)


## Камни, корни, брёвна, слалом и настилы технических элементов (как в Trail Lab): в h.trail_technical, его берёт
## ForestObstacles (препятствия и кочки) и GameWorld (изображение). Число объектов — в отчёт.
static func _build_technical(h: Heightfield, kit: Array[TrailDefinition], out: Dictionary) -> void:
	var started := Time.get_ticks_usec()
	h.trail_technical = TrailTechnical.build(h, kit)
	out.technical = {solids = h.trail_technical.collide.size() / ForestObstacles.STRIDE,
		bumps = h.trail_technical.bumps.size() / ForestObstacles.BUMP_STRIDE, props = h.trail_technical.props.size(),
		decks = h.trail_technical.decks.size(), ms = (Time.get_ticks_usec() - started) / 1000.0}


static func _kit(plan: Dictionary) -> Array[TrailDefinition]:
	var kit: Array[TrailDefinition] = []
	if plan.has("routes"):
		for data: Dictionary in plan.routes: kit.append(unpack(data))
	else:
		kit.assign([unpack(plan.access.inbound), unpack(plan.definition), unpack(plan.access.outbound)])
	return kit


## trails is the complete civil path network; the plan adds authoring data for its bicycle subset.
## Check their shared geometry before using either the cold handoff or a cached surface.
static func consistency_errors(w: WorldData) -> PackedStringArray:
	var plan := w.trail_plan
	var errors := PackedStringArray()
	if plan.get("state") != "found" or stale(plan): return errors
	var definitions: Variant = plan.get("routes")
	if definitions == null:
		var access: Dictionary = plan.get("access", {})
		definitions = [access.get("inbound"), plan.get("definition"), access.get("outbound")]
	if not definitions is Array or definitions.is_empty():
		return PackedStringArray(["В плане нет определений принятых трасс"])
	var ids := {}
	var routes := {}
	for route: Dictionary in w.trails:
		var id: String = route.get("trail_id", "")
		if id.is_empty(): continue
		if routes.has(id): errors.append("Повтор пути в сети: " + id)
		routes[id] = route
	var defaults := pack(TrailDefinition.new())
	for data: Variant in definitions:
		if not data is Dictionary: return PackedStringArray(["Повреждено определение трассы в плане"])
		# Required fields used by unpack; optional fields retain their legacy defaults.
		for field: String in ["id", "title", "kind", "points", "width", "surface", "earthwork", "elevation_offset", "auto_bank", "closed", "shaping", "elements"]:
			var value: Variant = data.get(field)
			var expected := typeof(defaults[field])
			if typeof(value) != expected and not (expected == TYPE_FLOAT and (value is int or value is float)):
				return PackedStringArray(["Повреждено поле определения трассы: " + field])
		if ids.has(data.id): errors.append("Повтор трассы в плане: " + str(data.id))
		ids[data.id] = true
		var d := unpack(data)
		errors.append_array(d.validate())
		if not routes.has(d.id):
			errors.append("Трасса плана отсутствует в сети: " + d.id)
			continue
		var expected := d.path_record()
		var actual: Dictionary = routes[d.id]
		for field: String in ["kind", "pts", "surface_override", "formation", "closed"]:
			if actual.get(field, false if field == "closed" else null) != expected[field]:
				errors.append("Трасса плана расходится с сетью (%s): %s" % [field, d.id])
	if plan.get("mode") == "terrain_network":
		var base_mask: Variant = plan.get("base_path_mask")
		if not base_mask is PackedByteArray or base_mask.size() != w.N:
			errors.append("В плане отсутствует исходная маска путей")
		var entries: Variant = plan.get("entries")
		if not entries is Array or entries.size() != definitions.size():
			errors.append("Число участков поверхности не совпадает с числом трасс")
		else:
			for i in entries.size():
				if not entries[i] is Dictionary or not entries[i].get("rect") is Rect2i or entries[i].get("route") != definitions[i]:
					errors.append("Участок поверхности расходится с определением трассы: %d" % i)
		if plan.get("definition") != definitions[0]: errors.append("Главная трасса расходится со списком трасс")
	return errors


## План сохранён другой версией кода (в том числе пустой — до этапа трассы): его результат не соответствует нынешней
## генерации: кэш пересчитывает зависимые слои, сохраняя географию.
static func stale(plan: Dictionary) -> bool:
	return int(plan.get("version", 0)) != VERSION


## Определение в словарь для кэша (только простые типы).
static func pack(d: TrailDefinition) -> Dictionary:
	var elements: Array = []
	for e in d.elements:
		elements.append(_fields(e))
	return {id = d.id, title = d.title, kind = d.kind, points = d.points, width = d.width, surface = d.surface,
		earthwork = d.earthwork, elevation_offset = d.elevation_offset, auto_bank = d.auto_bank, closed = d.closed,
		shaping = _fields(d.shaping) if d.shaping != null else {}, elements = elements,
		sections = d.sections.duplicate(true), open_spans = d.open_spans}


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
	d.sections.assign(data.get("sections", []))
	d.open_spans = data.get("open_spans", PackedVector3Array())
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
