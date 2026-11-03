extends SceneTree
const Job := preload("res://scripts/lab/trail_lab_world_job.gd")
const Sites := preload("res://scripts/lab/trail_lab_sites.gd")
class PausedJob extends Job:
	var gate := Semaphore.new()
	var held := false
	func _post(update: Dictionary) -> void:
		super._post(update)
		if update.has("site") and not held:
			held = true
			gate.wait()
var failures := 0
func check(ok: bool, message: String) -> void:
	print("PASS " if ok else "FAIL ", message)
	if not ok: failures += 1
func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 90)
	run.call_deferred()
func run() -> void:
	var heights := PackedFloat32Array(); heights.resize(384 * 384)
	var wet := PackedByteArray(); wet.resize(heights.size())
	for z in 384:
		for x in 384: heights[z * 384 + x] = 12 + z * 0.24
	var lab = load("res://scenes/trail_lab.tscn").instantiate()
	root.add_child(lab)
	await process_frame
	var before = lab.heights
	var job := PausedJob.new(9001, 13, {seed = 13, size = 384, heights = heights, water = wet})
	lab._world_request = 9001; lab._world_job = job
	lab._world_started = Time.get_ticks_msec()
	lab._world_thread = Thread.new(); lab._world_thread.start(job.run)
	var deadline := Time.get_ticks_msec() + 5000
	while (Sites.published_request != 9001 or Sites.sites.is_empty()) and Time.get_ticks_msec() < deadline: await process_frame
	check(lab._world_thread != null and lab._world_thread.is_alive(), "catalogue is still running while its first proposal is visible")
	check(Sites.published_request == 9001 and Sites.sites.size() == 1 and lab.project_panel.map.sites.size() == 1, "first proposal reaches the actual map before completion")
	check(lab.draft_project == null and lab.heights == before, "publishing proposals does not construct a project or replace the scene")
	var first_seed: int = Sites.sites[0].trail_seed
	check(lab.preview_site(0) and lab.draft_project != null and lab._world_thread.is_alive(), "the chosen place can be built before the catalogue finishes")
	var chosen = lab.draft_project
	job.gate.post()
	while lab._world_thread != null: await process_frame
	check(Sites.sites.size() > 1 and Sites.sites[0].trail_seed == first_seed, "later proposals append without reordering the selected index")
	check(lab.draft_project == chosen and Sites._built.has(0), "finishing the catalogue preserves the chosen project and its cache")
	check(not Sites.append_sites([], 9000), "stale batches cannot alter the active world")
	lab.shutdown(); lab.queue_free()
	quit(1 if failures else 0)
