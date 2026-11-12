extends SceneTree
## Real public project builder → site ID → independent final fixture on the frozen successful case.
const B := preload("res://scripts/lab/trail_lab_builder.gd")
const F := preload("res://scripts/lab/trail_lab_fixture.gd")
const P := preload("res://scripts/lab/trail_lab_project.gd")
func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 300)
	run.call_deferred()
func run() -> void:
	var project := ResourceLoader.load("res://resources/trails/lab/game_example_111_44101.tres", "", ResourceLoader.CACHE_MODE_IGNORE) as P
	if project == null: push_error("bundled real-world example is missing"); quit(1); return
	var hash_before := project.source.fingerprint()
	var result := B.build_project(project.source, project.seed, project.style, project.settings)
	var geometry_same: bool = result.routes.size() == 1 and result.routes[0].points == project.routes[0].points
	var routes: Array[TrailDefinition] = []
	routes.assign(result.routes)
	for route in routes: route.id = "site43_" + route.id
	B.publish_project(result)
	var prepared := F.prepare(routes, true, "generated", project.source)
	var report := {seed = "111", site_index = 42, trail_seed = project.seed, source_hash = hash_before,
		same_source = project.source.fingerprint() == hash_before, same_geometry = geometry_same,
		accepted = prepared.errors.is_empty() and prepared.heights != null, errors = Array(prepared.errors),
		elements = routes[0].elements.size() if not routes.is_empty() else 0,
		earthwork_audit = prepared.get("earthwork_audit", {}), base_ride = result.stats.get("element_fit", {}).get("base", {}).get("ride", {}).get("accepted", false)}
	var file := FileAccess.open("res://docs/data/trail_element_rebuild_2026_11_03.json", FileAccess.WRITE)
	file.store_string(JSON.stringify(report, "  "))
	print("REBUILD ", JSON.stringify(report))
	quit(0 if report.same_source and report.same_geometry and report.accepted else 1)
