extends Resource
## Seed-independent authoring output. Shared meshes/textures only; scene materials stay private.
const VERSION := 1
const PATH := "res://resources/catalog/standard.res"
@export var version := VERSION
@export var trees: Dictionary = {}
@export var grass: ArrayMesh
@export var understory: Array[Mesh] = []
@export var floor_meshes: Array[Mesh] = []
@export var textures: Array[Texture2D] = [] # bark, leaf, needle, ground detail, ground normal
@export var levels: Dictionary = {} # explicit model/part -> all LOD resources
static var _catalog: Resource

static func get_catalog() -> Resource:
	if _catalog == null:
		_catalog = load(PATH)
		assert(_catalog != null and _catalog.version == VERSION, "Rebake standard assets: tools/bake_assets.gd")
	return _catalog
