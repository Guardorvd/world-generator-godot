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
	var invalid := Fit.fit(GI.new(), TrailDefinition.new())
	check(not invalid.accepted and invalid.bake_count == 0, "invalid source is refused before building or reading speeds")
	var crossing := TrailDefinition.new()
	crossing.open_spans = PackedVector3Array([Vector3(95, 105, 1.8)])
	var gap := TrailElementLibrary.make(TrailElement.Profile.GAP, 100, 24, 1.2)
	var protected := preload("res://scripts/lab/trail_lab_element_local.gd").adapt(gap, crossing, {}, null)
	check(protected.size() == 1 and protected[0].station == gap.station and protected[0].length == gap.length and protected[0].height == gap.height, "a crossing is not resized independently of its open span")
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
	check(fitted.accepted and route.elements.size() == 1 and route.elements[0].height <= 0.4, "unsafe tall jump is adapted to local earthwork headroom")
	check(fitted.mode == "local" and fitted.bake_count == 2, "ordinary selection bakes only the base and the assembled result")
	check(input.fingerprint() == source_hash, "fitting keeps source heights, masks and limits unchanged")
	var combo := route.duplicate(true) as TrailDefinition
	combo.elements = [TrailElementLibrary.make(TrailElement.Profile.ROLLER, 120, 16, 0.3), TrailElementLibrary.make(TrailElement.Profile.ROLLER, 120, 16, 0.3)]
	var combination := A.diagnose(input, combo)
	check(combination.attribution[0].alone.earthworks.accepted and combination.attribution[1].alone.earthworks.accepted and not combination.full.earthworks.accepted and combination.pairs[0].earthwork_interaction, "two individually legal elements can violate combined fill allowance")
	var solved := Fit.fit(input, combo)
	check(solved.accepted and solved.kept > 0, "placement changes resolve an unsafe combination without deleting the whole set")
	check(solved.bake_count <= 4, "combined elements do not trigger per-variant full rebuilds")
	var berm := route.duplicate(true) as TrailDefinition
	berm.elements = [TrailElementLibrary.make(TrailElement.Profile.BERM, 100, 20, 2)]
	input.earthwork_limits.max_fill = 0.01
	var supported := Fit.fit(input, berm)
	for decision in supported.decisions:
		if not decision.accepted: check(decision.has("support") and decision.support.checked_without_element, "declining an auto-berm explicitly checks turn safety without it")
	quit(1 if failures else 0)
