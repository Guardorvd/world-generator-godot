extends RefCounted
const Terrain := preload("res://scripts/lab/trail_lab_terrain.gd")
const Job := preload("res://scripts/lab/trail_lab_scout_job.gd")
const STRIDE := 32
const SAMPLE := 8
const SHAPES := [Vector2i(64, 96), Vector2i(96, 64), Vector2i(96, 128), Vector2i(128, 96), Vector2i(128, 128)]
const PROBE_STEP := 4 # world cells, 16 m
const CORRIDOR_CELL := 4 # world cells; only a corridor is reserved, never the whole rectangle
const OVERLAP := 0.45
const WATER_MAX := 0.25
static var sites: Array[Dictionary] = []
static var stats := {}

static func snapshot() -> Dictionary:
	return {input = Terrain.world_input, size = Terrain.world_size, seed = Terrain.world_seed, heights = Terrain.world_h, water = Terrain.world_wet}

static func find(seed_value: int) -> Array[Dictionary]:
	var job := Job.new(snapshot())
	sites = job.find(seed_value)
	stats = job.stats
	return sites

static func measure(region: Rect2i) -> Dictionary:
	return Job.new(snapshot()).measure(region)
static func probe(region: Rect2i) -> Dictionary:
	return Job.new(snapshot()).probe(region)
static func capabilities(c: Dictionary, trial: Dictionary) -> Array[String]:
	return Job.new().capabilities(c, trial)
static func corridor(points: PackedVector2Array) -> Dictionary:
	return Job.new().corridor(points)
static func overlap(a: Dictionary, b: Dictionary) -> float:
	return Job.new().overlap(a, b)
