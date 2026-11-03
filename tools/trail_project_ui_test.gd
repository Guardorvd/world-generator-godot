extends SceneTree
const P := preload("res://scripts/lab/trail_lab_project.gd")
const I := preload("res://scripts/trails/trail_generation_input.gd")
const T := preload("res://scripts/lab/trail_lab_terrain.gd")
const Sites := preload("res://scripts/lab/trail_lab_sites.gd")
var failures := 0
func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 90)
	run.call_deferred()
func check(ok: bool, message: String) -> void:
	print(("PASS " if ok else "FAIL ") + message)
	if not ok: failures += 1
func run() -> void:
	var input := I.new()
	input.size = Vector2i(128,128)
	for field in ["heights","water","rivers","forbidden"]:
		var array = input.get(field)
		array.resize(128*128)
		input.set(field,array)
	for z in 128:
		for x in 128: input.heights[z*128+x] = 12 + z * 0.2
	input.earthwork_limits = {max_cut=3.5,max_fill=12.0,modification=1.0}
	var result := Sites.WorldJob.new(50,91,{seed=91,size=128,heights=input.heights,water=input.water}).run()
	Sites.publish_world(result,50)
	var lab = load("res://scenes/trail_lab.tscn").instantiate()
	root.add_child(lab)
	await process_frame
	var before = lab.heights
	check(lab.generate_world(91), "background world job starts")
	while lab._world_thread != null: await process_frame
	check(not Sites.sites.is_empty() and lab.draft_project == null and lab.heights == before, "catalogue publication leaves construction for the chosen place")
	check(lab.preview_site(0) and lab.draft_project != null and lab.heights == before, "map preview prepares a project without replacing the scene")
	var project := P.new()
	project.source = input
	project.source_hash = input.fingerprint()
	project.title = "UI roundtrip"
	var d := TrailDefinition.new()
	d.id = "generated_ui_project"
	d.points = PackedVector2Array([Vector2(100,400),Vector2(100,100)])
	project.routes = [d]
	lab.draft_project = project
	check(lab.build_draft_project() and lab.active_project.accepted, "explicit action builds and checks the project's heavy scene")
	check(lab.save_project_slot("A"), "successful variant A persists")
	lab.draft_project = lab.active_project.detached()
	lab.draft_project.routes[0].width = 5
	check(lab.build_draft_project() and lab.save_project_slot("B"), "variant B builds and saves independently")
	check(lab.variants.A.routes[0].width == 4 and lab.variants.B.routes[0].width == 5, "A and B retain independent definitions")
	check(lab.restore_project_slot("A") and lab.routes[0].width == 4, "opening A revalidates and restores its own scene")
	check(lab.build_timings.get("validation_ms",0) > 0 and lab.build_timings.total_ms >= lab.build_timings.prepare_total_ms, "scene report includes prepared data and ride validation time")
	lab.shutdown()
	lab.queue_free()
	await process_frame
	print("RESULT: %s" % ("PASS" if failures == 0 else "FAIL (%d)" % failures))
	quit(0 if failures == 0 else 1)
