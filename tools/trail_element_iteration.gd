extends SceneTree
const Source := preload("res://scripts/lab/trail_lab_game_source.gd")
const Sites := preload("res://scripts/lab/trail_lab_sites.gd")
const Audit := preload("res://scripts/lab/trail_lab_surface_audit.gd")
const Project := preload("res://scripts/lab/trail_lab_project.gd")
const Fit := preload("res://scripts/lab/trail_lab_element_fit.gd")
const CASES := [{seed = "7", index = 30}, {seed = "111", index = 0}, {seed = "111", index = 42}]
const CACHE := "res://.godot/trail_element_cases_2026_11_03/"
func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 1800)
	run.call_deferred()
func run() -> void:
	var fitting := "--fit" in OS.get_cmdline_user_args()
	DirAccess.make_dir_recursive_absolute(CACHE)
	var output := {schema = 1, cases = [], iteration = "frozen three accepted bases", base_revision = "7f594f1"}
	var world_seed := ""
	for spec in CASES:
		var path: String = CACHE + spec.seed + "_" + str(spec.index) + ".tres"
		var project: Project
		if FileAccess.file_exists(path): project = ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE) as Project
		else:
			if world_seed != spec.seed:
				var input = Source.open("res://.godot/trail_game_%s.res" % spec.seed).input
				var terrain := Source.terrain(input)
				var scout := preload("res://scripts/lab/trail_lab_scout_job.gd").new(terrain)
				var sites := scout.find(terrain.seed)
				Sites.publish_world({request_id = 0, terrain = terrain, sites = sites, scout = scout.stats, timings = {}}, 0)
				world_seed = spec.seed
			Sites.sites[spec.index].settings._diagnostic_raw_proposals = true
			if not Sites.select(spec.index): push_error("frozen base cannot be rebuilt"); quit(1); return
			project = Sites.project()
			project.settings.erase("_diagnostic_raw_proposals")
			ResourceSaver.save(project, path)
		var record := {seed = spec.seed, site_index = spec.index, trail_seed = project.seed, source_hash = project.source_hash,
			geometry_hash = var_to_bytes(project.routes[0].points).hex_encode().sha256_text()}
		if fitting:
			Sites.current = -1
			record.fitting = Fit.fit(project.source, project.routes[0], project.settings)
			var checked := project.copy_routes()
			var prepared := preload("res://tools/trail_lab_fixture.gd").prepare(checked, true, "generated", project.source)
			record.final_errors = Array(prepared.errors)
			record.accepted = prepared.errors.is_empty() and prepared.heights != null
			record.final_repairs = prepared.get("repairs", [])
			project.routes = checked
			record.elements_kept = project.routes[0].elements.size()
			project.accepted = record.accepted
			project.report.element_fit = record.fitting
			project.report.accepted = record.accepted
			project.report.validation = prepared.get("validation", {})
			project.report.earthwork_audit = prepared.get("earthwork_audit", {})
			if record.accepted: project.report.erase("reason")
			else: project.report.reason = "; ".join(prepared.errors)
			ResourceSaver.save(project, CACHE + "fitted_" + spec.seed + "_" + str(spec.index) + ".tres")
			print("FIT ", spec.seed, "/", spec.index, " kept=", record.elements_kept, " accepted=", record.accepted, " bakes=", record.fitting.bake_count)
		else:
			record.diagnosis = Audit.diagnose(project.source, project.routes[0])
			print("CASE ", spec.seed, "/", spec.index, " elements=", project.routes[0].elements.size(), " base_ride=", record.diagnosis.base.ride.accepted, " full=", record.diagnosis.full.accepted)
		output.cases.append(record)
	var output_path := "res://docs/data/trail_element_fit_2026_11_03.json" if fitting else "res://docs/data/trail_element_diagnosis_2026_11_03.json"
	var file := FileAccess.open(output_path, FileAccess.WRITE)
	file.store_string(JSON.stringify(output, "  "))
	quit()
