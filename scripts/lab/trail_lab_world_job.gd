extends RefCounted
const Terrain := preload("res://scripts/lab/trail_lab_terrain.gd")
const ScoutJob := preload("res://scripts/lab/trail_lab_scout_job.gd")
var request_id := 0
var seed := 0
var source := {}
var _mutex := Mutex.new()
var _updates: Array[Dictionary] = []
var _cancelled := false

func take_updates() -> Array[Dictionary]:
	_mutex.lock()
	var result := _updates
	_updates = []
	_mutex.unlock()
	return result

func cancel() -> void:
	_mutex.lock()
	_cancelled = true
	_mutex.unlock()

func _is_cancelled() -> bool:
	_mutex.lock()
	var result := _cancelled
	_mutex.unlock()
	return result

func _post(update: Dictionary) -> void:
	update.request_id = request_id
	_mutex.lock()
	_updates.append(update)
	_mutex.unlock()

func _init(id: int, seed_value: int, snapshot := {}) -> void:
	request_id = id
	seed = seed_value
	source = snapshot.duplicate(true)

func run() -> Dictionary:
	var started := Time.get_ticks_usec()
	var terrain: Dictionary
	if source.has("game_seed") or source.has("snapshot_path"):
		var adapter := preload("res://scripts/lab/trail_lab_game_source.gd")
		var input
		if source.has("snapshot_path"):
			var opened := adapter.open(source.snapshot_path)
			if opened.has("error"): return {request_id = request_id, error = opened.error}
			input = opened.input
		else: input = adapter.generate(source.game_seed)
		terrain = adapter.terrain(input, source.get("dry_channels", false))
	else: terrain = Terrain.prepare_world(seed, source)
	var geography_ms := (Time.get_ticks_usec() - started) / 1000.0
	_post({terrain = terrain})
	var scout := ScoutJob.new(terrain)
	var sites := scout.find(terrain.seed, func(site: Dictionary) -> void: _post({site = site.duplicate(true)}), _is_cancelled)
	return {request_id = request_id, terrain = terrain, sites = sites, scout = scout.stats,
		timings = {geography_ms = geography_ms, search_ms = scout.stats.ms, total_ms = (Time.get_ticks_usec() - started) / 1000.0}}
