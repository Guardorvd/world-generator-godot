extends SceneTree
const GI := preload("res://scripts/trails/trail_generation_input.gd")
const A := preload("res://scripts/lab/trail_lab_surface_audit.gd")
const Fit := preload("res://scripts/lab/trail_lab_element_fit.gd")
const V := preload("res://scripts/lab/trail_lab_validation.gd")
var failures := 0
func check(ok: bool, message: String) -> void:
	print("PASS " if ok else "FAIL ", message)
	if not ok: failures += 1
func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 240)
	run.call_deferred()
func run() -> void:
	var issues := {issues = []}
	for pair in [[12, 0.1], [20, 2.0], [30, 0.2]]: V._issue(issues, "normal", -1, pair[0], "test", "safety", {deviation = pair[1]})
	check(issues.issues.size() == 1 and issues.issues[0].samples.size() == 3 and issues.issues[0].worst_station == 20 and issues.issues[0].max_deviation == 2, "full ride audit retains later stations and numeric peak")
	var input := GI.new()
	input.size = Vector2i(128, 128)
	for key in ["heights", "water", "rivers", "forbidden"]:
		var values = input.get(key); values.resize(128 * 128); input.set(key, values)
	for z in 128:
		for x in 128: input.heights[z * 128 + x] = 20 + (z + 0.5) * 4 * 0.035
	input.earthwork_limits.max_fill = 0.4
	var source_hash := input.fingerprint()
	var route := TrailDefinition.new()
	route.id = "generated_element_stand"
	route.points = PackedVector2Array([Vector2(100, 440), Vector2(100, 60)])
	route.width = 4.5
	route.earthwork = 0.5
	route.elements = [TrailElementLibrary.make(TrailElement.Profile.TABLETOP, 100, 16, 2)]
	var before := A.diagnose(input, route)
	check(before.base.accepted and not before.full.accepted and before.full.earthworks.new_bad_vertices > 0 and before.full.earthworks.inherited_bad_vertices == 0, "full surface distinguishes new element earthworks from safe base")
	var fitted := Fit.fit(input, route)
	check(fitted.accepted and route.elements.size() == 1 and route.elements[0].profile == TrailElement.Profile.ROLLER, "unsafe tall jump can become a suitable small roller")
	check(fitted.bake_count <= Fit.MAX_BAKES and fitted.decisions[0].trials.size() <= Fit.MAX_VARIANTS, "bounded variants and bake budget")
	var jump_trials := 0
	for trial in fitted.decisions[0].trials:
		if trial.has("ride") and trial.element.profile == "TABLETOP":
			jump_trials += 1
			check(trial.ride.scenarios.normal.windows.size() == 1 and trial.ride.scenarios.normal.has("feature_entry_speeds"), "resized jump receives fresh speed window, flight and approach speed")
	check(jump_trials >= 2, "several actual jump sizes were baked and evaluated")
	check(input.fingerprint() == source_hash, "fitting keeps source heights, masks and limits unchanged")
	var combo := route.duplicate(true) as TrailDefinition
	combo.elements = [TrailElementLibrary.make(TrailElement.Profile.ROLLER, 120, 16, 0.3), TrailElementLibrary.make(TrailElement.Profile.ROLLER, 120, 16, 0.3)]
	var combination := A.diagnose(input, combo)
	check(combination.attribution[0].alone.earthworks.accepted and combination.attribution[1].alone.earthworks.accepted and not combination.full.earthworks.accepted and combination.pairs[0].earthwork_interaction, "two individually legal elements can violate combined fill allowance")
	var solved := Fit.fit(input, combo)
	check(solved.accepted and solved.kept > 0, "placement changes resolve an unsafe combination without deleting the whole set")
	var berm := route.duplicate(true) as TrailDefinition
	berm.elements = [TrailElementLibrary.make(TrailElement.Profile.BERM, 100, 20, 2)]
	input.earthwork_limits.max_fill = 0.01
	var supported := Fit.fit(input, berm)
	for decision in supported.decisions:
		if not decision.accepted: check(decision.has("support") and decision.support.checked_without_element, "declining an auto-berm explicitly checks turn safety without it")
	quit(1 if failures else 0)
