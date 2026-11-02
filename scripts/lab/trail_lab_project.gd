extends Resource
## A portable project contains data and a validation result, never a Heightfield, mesh or live scene node.
const GenerationInput := preload("res://scripts/trails/trail_generation_input.gd")
@export var version := 1
@export var title := "Вариант"
@export var seed := 1
@export var style := "flow"
@export var settings := {}
@export var source: GenerationInput
@export var source_hash := ""
@export var routes: Array[TrailDefinition] = []
@export var cuts: Array = []
@export var report := {}
@export var timings := {}
@export var accepted := false

func copy_routes() -> Array[TrailDefinition]:
	var result: Array[TrailDefinition] = []
	for d in routes: result.append(d.duplicate(true) as TrailDefinition)
	return result

func detached():
	var result = get_script().new()
	result.version = version
	result.title = title
	result.seed = seed
	result.style = style
	result.settings = settings.duplicate(true)
	result.source = source.duplicate(true) if source != null else null
	result.source_hash = source_hash
	result.routes = copy_routes()
	result.cuts = cuts.duplicate(true)
	result.report = report.duplicate(true)
	result.timings = timings.duplicate(true)
	result.accepted = accepted
	return result

func save_to(path: String) -> Error:
	if not accepted or source == null or routes.is_empty(): return ERR_INVALID_DATA
	return ResourceSaver.save(self, path)

static func open(path: String) -> Dictionary:
	var resource = ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE)
	if resource == null or resource.get_script() != load("res://scripts/lab/trail_lab_project.gd"): return {error = "неверный файл проекта"}
	if resource.version != 1 or resource.source == null or not resource.source.validate().is_empty() or resource.source.fingerprint() != resource.source_hash:
		return {error = "проект повреждён или его источник изменён"}
	for d in resource.routes:
		if not d.validate().is_empty(): return {error = "неверная трасса в проекте"}
	return {project = resource}

static func compare(a, b) -> Dictionary:
	if a == null or b == null: return {error = "сохраните оба варианта А и Б"}
	return {same_source = a.source_hash == b.source_hash, a = metrics(a), b = metrics(b),
		delta_length = metrics(b).length - metrics(a).length, delta_elements = metrics(b).elements - metrics(a).elements,
		delta_cut_m3 = metrics(b).cut_m3 - metrics(a).cut_m3, delta_fill_m3 = metrics(b).fill_m3 - metrics(a).fill_m3}

static func metrics(project) -> Dictionary:
	var length := 0.0
	var elements := 0
	var cut := 0.0
	var fill := 0.0
	for record: Dictionary in project.report.get("earthworks", {}).values():
		cut += float(record.get("cut_m3", 0.0))
		fill += float(record.get("fill_m3", 0.0))
	for d in project.routes:
		length += d.route_length()
		elements += d.elements.size()
	return {title = project.title, seed = project.seed, style = project.style, length = snappedf(length, 0.1), elements = elements, cut_m3 = cut, fill_m3 = fill,
		accepted = project.accepted, difficulty = project.settings.get("difficulty", 0.5), modification = project.settings.get("modification", 0.5), timings = project.timings}
