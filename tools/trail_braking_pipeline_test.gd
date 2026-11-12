extends SceneTree
## Public builder, automatic base repair, final fixture and production motion on a frozen game source.
const B := preload("res://scripts/lab/trail_lab_builder.gd")
const F := preload("res://scripts/lab/trail_lab_fixture.gd")
const Probe := preload("res://scripts/lab/trail_lab_ride_probe.gd")
func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 600)
	run.call_deferred()
func run() -> void:
	var p = load("res://resources/trails/lab/braking_case_7_30.tres")
	var fingerprint: String = p.source.fingerprint()
	var result := B.build_project(p.source, p.seed, p.style, p.settings)
	var routes: Array[TrailDefinition] = []
	routes.assign(result.routes)
	var report := {accepted = false, source_unchanged = p.source.fingerprint() == fingerprint, source_hash = fingerprint,
		world_seed = "7", site_index = 30, seed = p.seed, routes = routes.size(),
		base_repaired = result.stats.get("base_surface", {}).get("braking_repair", {}).get("accepted", false)}
	if not routes.is_empty():
		routes[0].id = "site31_" + routes[0].id
		B.publish_project(result)
		var ready := F.prepare(routes, true, "generated", p.source)
		report.final_errors = Array(ready.errors)
		report.earthworks = ready.get("earthwork_audit", {})
		report.elements = routes[0].elements.size()
		if ready.errors.is_empty() and ready.heights != null:
			ready.heights.obstacles.set_trail(ready.technical.collide, ready.technical.bumps)
			var ride := Probe.run(ready.heights, routes[0], {from = 0.0, speed = 0.0, policy = "careful"})
			report.ride = ride
			report.accepted = ride.completed and report.source_unchanged and report.base_repaired
	var file := FileAccess.open("res://docs/data/trail_braking_pipeline_2026_11_03.json", FileAccess.WRITE)
	file.store_string(JSON.stringify(report, "  "))
	print("PUBLIC BRAKING PIPELINE accepted=", report.accepted, " repaired=", report.base_repaired, " routes=", routes.size(), " errors=", report.get("final_errors", []))
	quit(0 if report.accepted else 1)
