extends RefCounted
const Terrain := preload("res://scripts/lab/trail_lab_terrain.gd")
const ScoutJob := preload("res://scripts/lab/trail_lab_scout_job.gd")
var request_id := 0
var seed := 0
var source := {}

func _init(id: int, seed_value: int, snapshot := {}) -> void:
	request_id = id
	seed = seed_value
	source = snapshot.duplicate(true)

func run() -> Dictionary:
	var started := Time.get_ticks_usec()
	var terrain := Terrain.prepare_world(seed, source)
	var geography_ms := (Time.get_ticks_usec() - started) / 1000.0
	var scout := ScoutJob.new(terrain)
	var sites := scout.find(seed)
	return {request_id = request_id, terrain = terrain, sites = sites, scout = scout.stats,
		timings = {geography_ms = geography_ms, search_ms = scout.stats.ms, total_ms = (Time.get_ticks_usec() - started) / 1000.0}}
