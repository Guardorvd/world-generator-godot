extends SceneTree
const V := preload("res://scripts/lab/trail_lab_validation.gd")
const F := preload("res://tools/trail_lab_fixture.gd")
const A := preload("res://scripts/lab/trail_ride_analysis.gd")
const S := preload("res://scripts/trails/trail_standards.gd")
const B := preload("res://scripts/lab/trail_lab_builder.gd")
var failures := 0

func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 120)
	run.call_deferred()

func check(ok: bool, message: String) -> void:
	print(("PASS " if ok else "FAIL ") + message)
	if not ok: failures += 1

func line() -> TrailDefinition:
	var d := TrailDefinition.new()
	d.id = "validation_stand"
	d.points = PackedVector2Array([Vector2(100, 220), Vector2(100, 40)])
	d.width = 3.5
	return d

func run() -> void:
	var d := line()
	var deck := TrailElementLibrary.make(TrailElement.Profile.NORTHSHORE, 60, 24, 1.2, 1, 3, 0.75)
	deck.gap = minf(3.2, d.width - 0.5)
	d.elements = [deck]
	check(d.validate().is_empty(), "narrowest generator style: loop deck fits validator")
	var jump := TrailElementLibrary.make(TrailElement.Profile.TABLETOP, 60, 16, 1.0)
	d.elements = [jump]
	var analysis := A.new()
	var slope := func(p: Vector2) -> float: return p.y * 0.12
	analysis.prepare(d, slope)
	var w := S.window(jump, d, -0.12, 2)
	check(analysis.features[0].get("speed_hi") == w.get("speed_hi"), "ride report uses actual slope")
	check(not V.footprint(d, func(p: Vector2) -> bool: return p.x < 101.0).is_empty(), "forbidden edge detected even with clear centre")
	d.elements = []
	var routes: Array[TrailDefinition] = [d]
	var result := F.prepare(routes)
	check(result.errors.is_empty(), "test surface baked")
	var h: Heightfield = result.heights
	var report := V.measure(h, d)
	check(report.accepted, "continuous straight is accepted: %s" % report.errors)
	check(report.scenarios.size() == 3, "all three ride scenarios evaluated")
	check(report.scenarios.calm.top < report.scenarios.fast.top, "calm and fast are distinct")
	var table := TrailElementLibrary.make(TrailElement.Profile.TABLETOP, 60, 18, 0.35)
	d.elements = [table]
	check(V._rollable_table(d, table), "continuous table has a safe roll option")
	d.open_spans = PackedVector3Array([Vector3(58, 62, 2)])
	check(not V._rollable_table(d, table), "table over an open span cannot bypass jump safety")
	d.open_spans = PackedVector3Array()
	d.elements = []
	var blocked := V.measure(h, d, func(p: Vector2) -> bool: return p.y > 100)
	check(not blocked.accepted and not blocked.errors.is_empty(), "final surface forbidden zone rejects with reason")
	# The same incoming speed, but different FINISHED landing height.
	var y := PackedFloat32Array()
	y.resize(100)
	y.fill(0.0)
	for i in range(15, 26): y[i] = (i - 15) * 0.12
	var flight := V.fly_surface(y, 10, 12, 80)
	var raised := y.duplicate()
	for i in range(30, 100): raised[i] = 0.8
	var raised_flight := V.fly_surface(raised, 10, 12, 80)
	check(flight.flew and raised_flight.flew and raised_flight.land < flight.land, "landing follows finished surface, not ideal element")
	var drop := TrailElementLibrary.make(TrailElement.Profile.DROP, 45, 12, 0.8)
	d.elements = [drop, jump]
	var fake := {issues = [{element = 0, reason = "скорость ниже окна"}]}
	var fixed := {}
	var fix := V.repair(d, fake, fixed)
	check(not fix.is_empty() and d.elements.size() == 2 and d.elements[1] == jump, "repair changes only identified element")
	check(V.repair(d, fake, fixed).is_empty(), "same element cannot be repaired repeatedly")
	# Generated lines go through the real prepare gate; invalid objects never silently disappear.
	d = line()
	d.id = "generated_validation_stand"
	deck.gap = 3.1 # invalid for width 3.5
	d.elements = [deck]
	routes = [d]
	result = F.prepare(routes)
	check(not result.errors.is_empty() and d.elements.size() == 1, "invalid final definition rejects without mass removal")
	# A generated line with no risky features exercises successful publication through the same gate.
	d = line()
	d.id = "generated_validation_stand"
	routes = [d]
	result = F.prepare(routes)
	check(result.errors.is_empty() and result.has("validation") and result.heights != null, "generated line accepted only after final validation")
	check(B.stats.get("accepted", false) and B.speeds.size() > 0, "published stats describe final checked line")
	d = line()
	d.id = "generated_repair_stand"
	d.elements = [TrailElementLibrary.make(TrailElement.Profile.DROP, 4, 8, 0.5)]
	routes = [d]
	result = F.prepare(routes)
	check(result.errors.is_empty() and result.repairs.size() == 1 and d.elements[0].profile == TrailElement.Profile.ROLLER, "local repair gets a fresh bake and final acceptance: %s" % result.errors)
	check(B.stats.jumps == 0, "jump count recomputed after local repair")
	d = line()
	d.id = "generated_budget_stand"
	for station: float in [4.0, 4.2, 4.4]: d.elements.append(TrailElementLibrary.make(TrailElement.Profile.DROP, station, 8, 0.5))
	routes = [d]
	result = F.prepare(routes)
	check(not result.errors.is_empty() and result.repairs.size() == V.MAX_REPAIRS and result.heights == null, "repair budget exhausted: reject with final reasons")
	check(not B.stats.accepted and B.speeds.is_empty(), "rejection clears published speed profile")
	check(B.stats.jumps == 1 and B.stats.elements == 3, "rejected result also reports final element counts")
	# Neighbour dependency is checked even when each feature is structurally valid on its own.
	d = line()
	d.elements = [TrailElementLibrary.make(TrailElement.Profile.LOG, 60, 12, 0.2), TrailElementLibrary.make(TrailElement.Profile.ROLLER, 68, 8, 0.2)]
	d.elements[0].gap = 1.2
	routes = [d]
	result = F.prepare(routes)
	report = V.measure(result.heights, d)
	check(report.issues.any(func(issue: Dictionary) -> bool: return issue.reason.contains("предыдущий элемент")), "previous feature constrains the next approach")
	print("RESULT: %s" % ("PASS" if failures == 0 else "FAIL (%d)" % failures))
	quit(0 if failures == 0 else 1)
