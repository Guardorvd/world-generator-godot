extends SceneTree
const T := preload("res://scripts/lab/trail_lab_terrain.gd")
const B := preload("res://scripts/lab/trail_lab_builder.gd")
const I := preload("res://scripts/trails/trail_generation_input.gd")
const P := preload("res://scripts/lab/trail_lab_project.gd")
const F := preload("res://scripts/lab/trail_lab_fixture.gd")
const W := preload("res://scripts/lab/trail_lab_world_job.gd")
const Sites := preload("res://scripts/lab/trail_lab_sites.gd")
const Map := preload("res://scripts/lab/trail_lab_map.gd")
var failures := 0
func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 90)
	run.call_deferred()
func check(ok: bool, message: String) -> void:
	print(("PASS " if ok else "FAIL ") + message)
	if not ok: failures += 1
func source() -> I:
	var input := I.new()
	input.size = Vector2i(128,128)
	input.heights.resize(128*128)
	input.water.resize(128*128)
	input.rivers.resize(128*128)
	input.forbidden.resize(128*128)
	input.earthwork_limits = {max_cut = 3.5, max_fill = 12.0, modification = 1.0}
	input.provenance = {source="Trail Lab",world_seed=91,origin=Vector2i(10,30),kind="mountain",dry_rivers=true}
	input.river_policy = I.RiverPolicy.LAB_DRY_CHANNELS
	input.existing_paths = [{points=PackedVector2Array([Vector2(20,10),Vector2(40,10)]),half_width=1.0}]
	for z in 128:
		for x in 128: input.heights[z*128+x] = 12 + z * 0.2
	return input
func run() -> void:
	var input := source()
	var facade := var_to_bytes([B.seed,B.style,B.stats,B.cuts,B.speeds,T.cells,T.world_h])
	var generated := B.build_project(input, 8, "park", {park_layout = "horseshoe"})
	check(not generated.routes.is_empty(), "light project builds without a scene")
	check(facade == var_to_bytes([B.seed,B.style,B.stats,B.cuts,B.speeds,T.cells,T.world_h]), "data job leaves active generator facade and terrain untouched")
	var d := TrailDefinition.new()
	d.id = "generated_project_stand"
	d.points = PackedVector2Array([Vector2(100,400),Vector2(100,100)])
	var routes: Array[TrailDefinition] = [d]
	var prepared := F.prepare(routes,true,"generated",input)
	check(prepared.errors.is_empty(), "project validated on its owned source")
	var project := P.new()
	project.source = input
	project.source_hash = input.fingerprint()
	project.routes = routes
	project.accepted = prepared.errors.is_empty()
	project.timings = prepared.timings
	var path := "user://project_roundtrip.tres"
	check(project.save_to(path) == OK, "accepted project saved without mesh/Heightfield")
	var opened := P.open(path)
	check(opened.has("project") and opened.project.source_hash == project.source_hash and opened.project.routes[0].points == d.points, "project survives disk round-trip")
	var copy = project.detached()
	copy.routes[0].width = 6
	copy.source.heights[0] += 2
	check(d.width != copy.routes[0].width and input.heights[0] != copy.source.heights[0], "A/B copies own routes and terrain")
	var compared := P.compare(project, opened.get("project"))
	check(compared.same_source and compared.delta_length == 0, "A/B compares the same saved source")
	var snapshot := {size = 128, seed = 91, heights = input.heights, water = input.water}
	var a := W.new(41,91,snapshot)
	var b := W.new(42,92,{size=128,seed=92,heights=input.heights,water=input.water})
	var before := var_to_bytes([T.world_h,T.world_wet,Sites.sites,Sites.current])
	var ta := Thread.new()
	var tb := Thread.new()
	ta.start(a.run)
	tb.start(b.run)
	var ra: Dictionary = ta.wait_to_finish()
	var rb: Dictionary = tb.wait_to_finish()
	check(ra.request_id == 41 and rb.request_id == 42 and before == var_to_bytes([T.world_h,T.world_wet,Sites.sites,Sites.current]), "parallel world jobs have isolated state")
	check(not Sites.publish_world(rb,41) and before == var_to_bytes([T.world_h,T.world_wet,Sites.sites,Sites.current]), "stale result cannot replace active world")
	var map := Map.new()
	root.add_child(map)
	map.size = Vector2(500,350)
	map.set_world(snapshot,ra.sites)
	check(map.texture != null and map.sites.size() == ra.sites.size(), "map overview uses lightweight terrain and corridor data")
	map.queue_free()
	print("RESULT: %s" % ("PASS" if failures == 0 else "FAIL (%d)" % failures))
	quit(0 if failures == 0 else 1)
