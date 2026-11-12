extends SceneTree
const B := preload("res://scripts/lab/trail_lab_builder.gd")
const C := preload("res://scripts/lab/trail_lab_composition.gd")
const F := preload("res://scripts/lab/trail_lab_fixture.gd")
const V := preload("res://scripts/lab/trail_lab_validation.gd")
const T := TrailElement.Profile
var failures := 0
func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 120)
	run.call_deferred()
func check(ok: bool, message: String) -> void:
	print(("PASS " if ok else "FAIL ") + message)
	if not ok: failures += 1
func straight() -> TrailDefinition:
	var d := TrailDefinition.new()
	d.id = "character_stand"
	d.width = 4.5
	d.points = PackedVector2Array([Vector2(100, 450), Vector2(100, 50)])
	return d
func run() -> void:
	var ground := func(p: Vector2) -> float: return 12 + p.y * 0.05
	var all_inside := func(p: Vector2) -> bool: return p.x > 28 and p.y > 28 and p.x < 484 and p.y < 484
	var layouts := []
	for layout: String in B.PARK_LAYOUTS:
		var rng := RandomNumberGenerator.new()
		rng.seed = 8
		var pts := B._park_points(ground, all_inside, 512, rng, layout)
		check(pts.size() > 80 and (pts[0].distance_to(pts[-1]) < 0.01) == (layout == "oval"), "%s has a complete distinct layout" % layout)
		layouts.append(pts)
	check(layouts[0] != layouts[1] and layouts[1] != layouts[2], "park layouts differ geometrically")
	var low := B.build(ground, 512, 8, "park", Callable(), Callable(), {difficulty = 0.2, modification = 0.5, park_layout = "horseshoe"})
	var low_stats := B.stats.duplicate(true)
	var high := B.build(ground, 512, 8, "park", Callable(), Callable(), {difficulty = 0.85, modification = 0.5, park_layout = "horseshoe"})
	check(not low.is_empty() and not high.is_empty() and low[0].points == high[0].points and low[0].earthwork == high[0].earthwork and low_stats.difficulty != B.stats.difficulty, "difficulty varies independently of style, layout and earthwork")
	var natural := B.build(ground, 512, 8, "park", Callable(), Callable(), {difficulty = 0.85, modification = 0.0, park_layout = "horseshoe"})
	check(not natural.is_empty() and natural[0].earthwork == 0 and natural[0].elements.all(func(e: TrailElement) -> bool: return TrailElement.places_objects(e.profile)) and B.cuts.is_empty(), "zero modification never creates earthworks, jumps or cuts")
	var light := B.build(ground, 512, 8, "park", Callable(), Callable(), {difficulty = 0.85, modification = 0.15, park_layout = "horseshoe"})
	check(not light.is_empty() and light[0].earthwork == 0.15, "light construction controls shaping strength without an unrelated element-height ban")
	check(C.profile_for("tech", 0.5, 0.5).difficulty == C.profile_for("park", 0.5, 0.5).difficulty, "style does not silently choose difficulty")
	var counts := {}
	for style: String in B.ORDER:
		var d := straight()
		var state := {recovery = 0.0, refused = {}, chains = []}
		var proposed := TrailComposer.compose(d, C.profile_for(style, 0.55, 0.6), 417, ground, func(e: TrailElement) -> bool: return C.fits(d, e, ground, state, false, 0.6))
		counts[style] = proposed.elements.filter(func(e: TrailElement) -> bool: return e.profile in [T.TABLETOP, T.GAP, T.DROP]).size()
		check(proposed.elements.all(func(e: TrailElement) -> bool: return e.profile != T.GAP), "%s: no mandatory gaps without opt-in" % style)
	print("Jump counts by style: ", counts)
	check(counts.tech == 0 and counts.park > counts.tech and counts.flow > counts.tech, "technical and park characters produce different element families")
	check(C.gap_allowed("enduro", 0.2, 0.15, true) and not C.gap_allowed("park", 0.9, 1, false) and not C.gap_allowed("park", 0.9, 0, true), "gap opt-in is independent of style and percentages; explicit zero construction remains respected")
	var d := straight()
	var state := {recovery = 0.0, refused = {}, chains = []}
	var jump := TrailElementLibrary.make(T.TABLETOP, 100, 16, 1.0)
	check(C.fits(d, jump, ground, state, false, 0.6), "jump reserves acceleration and recovery")
	check(not C.fits(d, TrailElementLibrary.make(T.ROLLER, 115, 8, 0.2), ground, state, false, 0.6), "next feature cannot consume recovery space")
	check(C.fits(d, TrailElementLibrary.make(T.ROLLER, 160, 8, 0.2), ground, state, false, 0.6), "next feature fits after recovery")
	var f := {cuts = [], ditches = 0}
	var rng := RandomNumberGenerator.new()
	rng.seed = 4
	B._plan_ditches(d, ground, f, rng, 1.0)
	check(f.cuts.is_empty(), "no purposeless ditch on a slope without cross drainage")
	var cross_ground := func(p: Vector2) -> float: return 12 + p.y * 0.05 + p.x * 0.10
	B._plan_ditches(d, cross_ground, f, rng, 1.0)
	check(not f.cuts.is_empty() and f.cuts[0].points[0].x > 100 and (f.cuts[0].depth as PackedFloat32Array)[2] <= 0.35, "drainage lies uphill, has a downhill outlet and limited depth")
	d = straight()
	d.points = PackedVector2Array([Vector2(100, 220), Vector2(100, 40)])
	var prepared := F.prepare([d] as Array[TrailDefinition])
	check(prepared.errors.is_empty(), "difficulty comparison has a valid prepared surface")
	if not prepared.errors.is_empty():
		quit(1)
		return
	d.sections = [{from = 0.0, to = d.route_length(), difficulty = 0.1}]
	var easy := V.measure(prepared.heights, d)
	d.sections = [{from = 0.0, to = d.route_length(), difficulty = 0.9}]
	var hard := V.measure(prepared.heights, d)
	check(easy.scenarios.normal.top < hard.scenarios.normal.top, "final ride assessment honours difficulty independently of the unchanged geometry")
	print("RESULT: %s" % ("PASS" if failures == 0 else "FAIL (%d)" % failures))
	quit(0 if failures == 0 else 1)
