extends SceneTree
const Base := preload("res://scripts/lab/trail_lab_base_surface.gd")
const GI := preload("res://scripts/trails/trail_generation_input.gd")
const V := preload("res://scripts/lab/trail_lab_validation.gd")
const F := preload("res://scripts/lab/trail_lab_fixture.gd")
var failures := 0
func check(ok: bool, message: String) -> void:
	print("PASS " if ok else "FAIL ", message)
	if not ok: failures += 1
func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 180)
	run.call_deferred()
func input_for(ground: Callable) -> GI:
	var input := GI.new()
	input.size = Vector2i(128, 128)
	for key in ["heights", "water", "rivers", "forbidden"]:
		var values = input.get(key); values.resize(128 * 128); input.set(key, values)
	for z in 128:
		for x in 128: input.heights[z * 128 + x] = ground.call(Vector2(x + 0.5, z + 0.5) * 4)
	return input
func route() -> TrailDefinition:
	var d := TrailDefinition.new()
	d.id = "base_surface_stand"
	d.points = PackedVector2Array([Vector2(100, 440), Vector2(100, 60)])
	d.width = 4
	d.earthwork = 1
	d.shaping = TrailShaping.preset("mountain")
	return d
func run() -> void:
	var input := input_for(func(p: Vector2) -> float: return 20 + p.y * 0.04)
	var d := route()
	var original := input.fingerprint()
	var checked := func(candidate: TrailDefinition) -> PackedStringArray: return V.footprint(candidate, func(p: Vector2) -> bool: return not input.blocked(p))
	var good := Base.fit(input, d, checked)
	check(good.accepted and good.repairs.is_empty() and good.elements_before_solve == 0, "plain base tread passes before any element is placed")
	check(input.fingerprint() == original, "base solve owns its terrain and does not change source")
	input = input_for(func(p: Vector2) -> float: return 20 + p.y * 0.04 + (p.x - 100) * 0.5 * smoothstep(60, 100, p.y) * (1 - smoothstep(400, 440, p.y)))
	checked = func(candidate: TrailDefinition) -> PackedStringArray: return V.footprint(candidate, func(p: Vector2) -> bool: return not input.blocked(p))
	for z in 128:
		for x in range(26, 128): input.forbidden[z * 128 + x] = 1
	d = route()
	d.shaping.side_follow = 0.0
	var before := Base.bake(input, d)
	var before_audit := Base.audit(input, before.heights, d)
	check(V.footprint(d, func(p: Vector2) -> bool: return not input.blocked(p)).is_empty() and before_audit.protected_vertices > 0, "clear tread still detects forbidden side-slope runout")
	check(not before_audit.intervals.is_empty() and before_audit.intervals[0].to > before_audit.intervals[0].from, "bad vertices are grouped into problem intervals")
	original = input.fingerprint()
	var repaired := Base.fit(input, d, checked)
	check(not repaired.accepted and repaired.attempts.size() == Base.MAX_REPAIRS + 1 and repaired.attempts[-1].protected_vertices > 0, "exhausted repair budget refuses even a small residual forbidden displacement")
	check(input.fingerprint() == original, "repair retains the strict source masks and limits")
	input.forbidden.fill(0)
	for z in range(30, 98):
		for x in range(26, 128): input.forbidden[z * 128 + x] = 1
	d = route()
	d.shaping.side_follow = 0
	repaired = Base.fit(input, d, checked)
	check(repaired.accepted and repaired.repairs.size() > 0 and repaired.attempts.size() <= Base.MAX_REPAIRS + 1, "bounded local repair clears a finite protected side-slope interval: %s" % repaired.get("reason", ""))
	if repaired.accepted:
		var prepared := F.prepare([d] as Array[TrailDefinition], true, "generated", input)
		check(prepared.errors.is_empty() and input.audit_earthworks(prepared.heights).is_empty(), "same repaired route passes the independent final earthworks audit")
		ResourceSaver.save(d, "res://.godot/base_repaired_route.tres")
		var loaded := ResourceLoader.load("res://.godot/base_repaired_route.tres", "", ResourceLoader.CACHE_MODE_IGNORE) as TrailDefinition
		var reloaded := Base.bake(input, loaded)
		check(Base.audit(input, reloaded.heights, loaded).accepted, "local profile repair survives save/load and fresh bake")
	# A protected strip UNDER the tread cannot be repaired by suppressing its audit.
	for z in range(50, 70):
		for x in range(23, 28): input.rivers[z * 128 + x] = 1
	d = route()
	var refused := Base.fit(input, d, checked)
	check(not refused.accepted and refused.attempts.is_empty(), "strict river crossing refuses before the first bake")
	d.elements = [TrailElementLibrary.make(TrailElement.Profile.TABLETOP, 80, 16, 1)]
	check(not Base.fit(input, d, checked).accepted, "base stage refuses a route that already contains elements")
	quit(1 if failures else 0)
