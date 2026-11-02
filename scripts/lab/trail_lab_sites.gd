extends RefCounted
## Trail Lab: большой мир генератора местности, места поисковика и трасса каждого места (01.11, v3 генераторов).
## 1. generate_world(seed) — мир размером с план игры (TrailLabTerrain.generate_world) и места на нём (TrailLabScout).
##    Тяжёлое (география игры целиком): лаборатория зовёт его в фоновом потоке; функция пишет только свои поля.
## 2. select(i) — окно земли вокруг места i (TrailLabTerrain.use_window) и его трасса (TrailLabBuilder, сид и стиль
##    места; построенная — из памяти вместе со своими врезками). Fixture.course(16) берёт routes() отсюда.
## 3. reroll(i) — другая трасса на том же месте (новый сид, стиль места).

const TrailLabTerrain := preload("res://scripts/lab/trail_lab_terrain.gd")
const TrailLabBuilder := preload("res://scripts/lab/trail_lab_builder.gd")
const TrailLabScout := preload("res://scripts/lab/trail_lab_scout.gd")
const WorldJob := preload("res://scripts/lab/trail_lab_world_job.gd")
const InputAdapter := preload("res://scripts/lab/trail_lab_input.gd")
const Project := preload("res://scripts/lab/trail_lab_project.gd")
static var world_timings := {}

static var world_seed := 0
static var sites: Array[Dictionary] = []
static var current := -1
static var _built := {} ## номер места -> {routes, cuts, stats, seed}


## Мир и места (в потоке). Возвращает число мест.
static func generate_world(seed_value: int) -> int:
	var job := WorldJob.new(0, seed_value, TrailLabTerrain.world_snapshot())
	publish_world(job.run(), 0)
	return sites.size()

static func publish_world(result: Dictionary, expected_id: int) -> bool:
	if result.get("request_id", -1) != expected_id: return false
	TrailLabTerrain.publish_world(result.terrain)
	sites.assign(result.sites.duplicate(true))
	TrailLabScout.sites = sites.duplicate(true)
	TrailLabScout.stats = result.scout.duplicate(true)
	world_timings = result.timings.duplicate(true)
	world_seed = result.terrain.seed
	_built = {}
	current = 0 if not sites.is_empty() else -1
	return true

static func active() -> bool:
	return current >= 0 and current < sites.size() and TrailLabTerrain.world_seed == world_seed

## Окно и трасса места i (строится при первом выборе).
static func select(i: int) -> bool:
	if i < 0 or i >= sites.size(): return false
	current = i
	var site := sites[i]
	TrailLabTerrain.use_window(site.origin)
	if not _built.has(i): _build(i, int(site.trail_seed))
	TrailLabTerrain.apply_cuts(_built[i].cuts)
	TrailLabBuilder.stats = _built[i].stats.duplicate(true)
	TrailLabBuilder.seed = int(_built[i].seed)
	TrailLabBuilder.style = site.style
	TrailLabBuilder.speeds = PackedFloat32Array()
	if TrailLabBuilder.stats.get("accepted", false):
		var checked: Dictionary = TrailLabBuilder.stats.get("validation", {})
		if not checked.is_empty(): TrailLabBuilder.speeds = checked.values()[0].scenarios.normal.speeds
	return not (_built[i].routes as Array).is_empty()

## Другая трасса на месте i: новый сид, тот же стиль.
static func reroll(i: int, seed_value: int) -> bool:
	if i < 0 or i >= sites.size(): return false
	sites[i].trail_seed = seed_value
	_built.erase(i)
	return select(i)

static func _build(i: int, trail_seed: int) -> void:
	var site := sites[i]
	var hint := PackedVector2Array()
	for p: Vector2 in site.probe.points: hint.append(p - Vector2(site.origin) * GameConfig.TILE)
	var options: Dictionary = site.settings.duplicate(true)
	options.merge({bounds = site.bounds, route_hint = hint})
	var started := Time.get_ticks_usec()
	var input := InputAdapter.snapshot()
	var result := TrailLabBuilder.build_project(input, trail_seed, site.style, options)
	TrailLabBuilder.publish_project(result)
	var routes: Array[TrailDefinition] = []
	routes.assign(result.routes)
	for d in routes:
		d.id = "site%d_%s" % [i + 1, d.id]
		d.title = "%d · %s" % [i + 1, d.title]
	var project := Project.new()
	project.title = "%d · %s" % [i + 1, TrailLabBuilder.STYLES[site.style].title]
	project.seed = trail_seed
	project.style = site.style
	project.settings = options.duplicate(true)
	project.source = input.duplicate(true)
	project.source_hash = input.fingerprint()
	project.routes = routes.duplicate(true)
	project.cuts = result.cuts.duplicate(true)
	project.report = result.stats.duplicate(true)
	project.timings = {project_ms = (Time.get_ticks_usec() - started) / 1000.0}
	_built[i] = {routes = routes, cuts = result.cuts.duplicate(true), stats = result.stats.duplicate(true), seed = trail_seed, label = TrailLabBuilder.label(), project = project}

static func project() -> Project:
	if not _built.has(current): return null
	return _built[current].project.detached() as Project

static func source_for(checked: Array[TrailDefinition]):
	if not active() or not _built.has(current) or checked.is_empty(): return null
	var cached: Array = _built[current].routes
	if cached.is_empty() or cached[0].id != checked[0].id: return null
	var input = _built[current].project.source.duplicate(true)
	input.apply_cuts(_built[current].cuts)
	return input

## Трасса текущего места (копии: лаборатория их правит).
static func routes() -> Array[TrailDefinition]:
	var out: Array[TrailDefinition] = []
	if not _built.has(current): return out
	for d: TrailDefinition in _built[current].routes: out.append(d.duplicate(true) as TrailDefinition)
	return out

## Final preparation can repair a feature or reject the line: keep the site's cached report honest.
static func publish_validation(checked: Array[TrailDefinition], final_stats: Dictionary) -> void:
	if not active() or not _built.has(current) or checked.is_empty(): return
	var cached: Array = _built[current].routes
	if cached.is_empty() or cached[0].id != checked[0].id: return
	if final_stats.has("source_hash") and final_stats.source_hash != _built[current].project.source_hash: return
	_built[current].stats = final_stats.duplicate(true)
	_built[current].label = TrailLabBuilder.label()
	var saved: Project = _built[current].project
	saved.report = final_stats.duplicate(true)
	saved.accepted = final_stats.get("accepted", false)
	if final_stats.get("accepted", false):
		var copies: Array[TrailDefinition] = []
		for d in checked: copies.append(d.duplicate(true) as TrailDefinition)
		_built[current].routes = copies
		saved.routes = copies.duplicate(true)

## Подпись места i для списка: номер, стиль, перепад; у построенного — длина и особенности.
static func title(i: int) -> String:
	var site := sites[i]
	var style_title: String = TrailLabBuilder.STYLES[site.style].title
	if _built.has(i):
		var st: Dictionary = _built[i].stats
		if st.has("reason"): return "%d · %s · %s" % [i + 1, style_title, st.reason]
		var extra := PackedStringArray()
		if st.get("loop", false): extra.append("петля")
		if int(st.get("ravines", 0)) > 0: extra.append("овражков %d" % st.ravines)
		return "%d · %s · %.0f м, %+.0f м · прыжков %d%s" % [i + 1, style_title, st.length, -float(st.drop), st.get("jumps", 0), (" · " + ", ".join(extra)) if not extra.is_empty() else ""]
	var alternatives := PackedStringArray()
	for key: String in site.styles: alternatives.append(TrailLabBuilder.STYLES[key].title)
	return "%d · %s · %.0f×%.0f м · перепад %.0f м · проба %.0f м · %s" % [i + 1, style_title, site.bounds.size.x, site.bounds.size.y, site.fall, site.probe.length, ", ".join(alternatives)]

## Итог текущего места для подписи под списком.
static func label() -> String:
	if not active(): return ""
	return "Мир %d · мест %d · место %d · участок %.0f×%.0f м\n%s" % [world_seed, sites.size(), current + 1, sites[current].bounds.size.x, sites[current].bounds.size.y,
		str(_built[current].label) if _built.has(current) else ""]
