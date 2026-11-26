extends Resource
## Seed-independent authoring output. Shared meshes/textures only; scene materials stay private.
const VERSION := 23 # Кроны хвойных экспедиции
const PATH := "res://resources/catalog/standard.res"
@export var version := 0 # Запекание записывает версию явно; ResourceSaver пропускает значение по умолчанию.
@export var trees: Dictionary = {}
@export var grass: ArrayMesh
@export var forest_carpet: Dictionary = {}
@export var understory: Array[Mesh] = []
@export var floor_meshes: Array[Mesh] = []
@export var textures: Array[Texture2D] = [] # bark, leaf, needle, ground detail, ground normal
@export var far_forms: Dictionary = {} # номер формы подлеска (Floor.FIRST + вид) -> упрощённый меш для дальнего подлеска
@export var levels: Dictionary = {} # explicit model/part -> all LOD resources
@export var settlements: Dictionary = {} # id -> {lods: [LOD0, LOD1, LOD2], size, category, half, flat, height}
@export var settlement_textures: Array[Texture2D] = [] # [albedo atlas, emission atlas]
@export var settlement_details: Dictionary = {} # flower_box, bench, fire_logs, lantern_post, fence_section, wooden_jetty
@export var site_lods: Dictionary = {} # id -> [LOD0, LOD1, LOD2] для вершин и сооружений StageSites
static var _catalog: Resource

static func get_catalog() -> Resource:
	if _catalog == null:
		_catalog = load(PATH)
		var problem := check()
		if not problem.is_empty():
			push_error(problem)
		elif _catalog != null and _catalog.settlements is Dictionary and not _catalog.settlements.is_empty():
			SettlementSets.apply_catalog(_catalog.settlements)
	return _catalog


## Пустая строка — каталог на месте и нужной версии; иначе причина (работает и в релизной сборке, где assert отключён).
static func check() -> String:
	var catalog: Resource = _catalog if _catalog != null else load(PATH)
	if catalog == null:
		return "Каталог моделей не найден (%s). Пересоберите его: tools/bake_assets.gd" % PATH
	if catalog.version != VERSION:
		return "Каталог моделей устарел (версия %s, нужна %s). Пересоберите его: tools/bake_assets.gd" % [catalog.version, VERSION]
	return ""
