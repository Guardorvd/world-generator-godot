extends Resource
## Seed-independent authoring output. Shared meshes/textures only; scene materials stay private.
const VERSION := 7 # высокий лес: возрастные формы сосны, берёзы и дуба (11.11.2026)
const PATH := "res://resources/catalog/standard.res"
@export var version := VERSION
@export var trees: Dictionary = {}
@export var grass: ArrayMesh
@export var understory: Array[Mesh] = []
@export var floor_meshes: Array[Mesh] = []
@export var textures: Array[Texture2D] = [] # bark, leaf, needle, ground detail, ground normal
@export var far_forms: Dictionary = {} # номер формы подлеска (Floor.FIRST + вид) -> упрощённый меш для дальнего подлеска
@export var levels: Dictionary = {} # explicit model/part -> all LOD resources
static var _catalog: Resource

static func get_catalog() -> Resource:
	if _catalog == null:
		_catalog = load(PATH)
		var problem := check()
		if not problem.is_empty():
			push_error(problem)
	return _catalog


## Пустая строка — каталог на месте и нужной версии; иначе причина (работает и в релизной сборке, где assert отключён).
static func check() -> String:
	var catalog: Resource = _catalog if _catalog != null else load(PATH)
	if catalog == null:
		return "Каталог моделей не найден (%s). Пересоберите его: tools/bake_assets.gd" % PATH
	if catalog.version != VERSION:
		return "Каталог моделей устарел (версия %s, нужна %s). Пересоберите его: tools/bake_assets.gd" % [catalog.version, VERSION]
	return ""
