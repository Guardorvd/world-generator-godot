extends SceneTree
const GI := preload("res://scripts/trails/trail_generation_input.gd")
const Base := preload("res://scripts/lab/trail_lab_base_surface.gd")
const Contract := preload("res://scripts/lab/trail_lab_route_contract.gd")
var failures := 0
func check(ok: bool, message: String) -> void:
	print("PASS " if ok else "FAIL ", message)
	if not ok: failures += 1
func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 180)
	run.call_deferred()
func run() -> void:
	var input := GI.new()
	input.size = Vector2i(128, 128)
	for key in ["heights", "water", "rivers", "forbidden"]:
		var values = input.get(key); values.resize(128 * 128); input.set(key, values)
	for z in 128:
		for x in 128: input.heights[z * 128 + x] = 200 + (z + 0.5) * 4 * 0.04 + ((x + 0.5) * 4 - 100) * 1.2
	var route := TrailDefinition.new()
	route.id = "generated_construction_policy"
	route.points = PackedVector2Array([Vector2(100, 440), Vector2(100, 60)])
	route.width = 4; route.earthwork = 1
	route.shaping = TrailShaping.preset("mountain")
	route.shaping.strength = 1; route.shaping.side_follow = 0
	var built := Base.bake(input, route)
	check(built.errors.is_empty(), "one standard shaping operation builds the tread")
	if not built.has("heights"): quit(1); return
	var limited := Base.audit(input, built.heights, route)
	check(not limited.accepted and maxf(limited.max_cut, limited.max_fill) > 2, "old two-metre rule rejects the constructed surface")
	input.earthwork_limits.unlimited = true
	var unrestricted := Base.audit(input, built.heights, route)
	check(unrestricted.accepted and input.audit_earthworks(built.heights).is_empty(), "same surface passes without the arbitrary depth cap")
	check(unrestricted.max_cut == limited.max_cut and unrestricted.max_fill == limited.max_fill, "audits still report actual earthwork cost")
	var rough := func(p: Vector2) -> float: return 200 + p.y * 0.45 + p.x * 0.8
	var area := Contract.endpoint(Vector2(200, 200), Vector2(0, -1), rough, func(_p: Vector2) -> bool: return true, 4)
	check(area.suitable and area.estimated_work > 0, "natural endpoint slopes contribute cost without prohibiting construction")
	check(not Contract.endpoint(Vector2(200, 200), Vector2(0, -1), rough, func(_p: Vector2) -> bool: return false, 4).suitable, "physical clearance still matters")
	var ready := preload("res://tools/trail_lab_fixture.gd").prepare([route] as Array[TrailDefinition], true, "generated", input)
	check(ready.errors.is_empty(), "ordinary final pipeline accepts the constructed route: %s" % [ready.errors])
	if ready.errors.is_empty():
		ready.heights.obstacles.set_trail(ready.technical.collide, ready.technical.bumps)
		var ride := preload("res://scripts/lab/trail_lab_ride_probe.gd").run(ready.heights, route, {from = 0.0, speed = 0.0, policy = "careful"})
		check(ride.completed, "real BikeRide finishes on the constructed surface: " + ride.status)
	for z in 128: input.forbidden[z * 128 + 26] = 1
	check(not Base.audit(input, built.heights, route).accepted, "removing depth caps does not suppress protected-footprint checks")
	quit(1 if failures else 0)
