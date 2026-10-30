extends SceneTree
const Fixture = preload("res://tools/trail_lab_fixture.gd")
const Floor = preload("res://scripts/render/forest_floor.gd")
const Polygon = preload("res://scripts/lab/trail_lab_polygon.gd")
const Epic = preload("res://scripts/lab/trail_lab_epic.gd")
var failures := 0
func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 180)
	run.call_deferred()
func run() -> void:
	# The same production placement API must reject random decorations on every authored route.
	var checked := 0
	for preset in TrailLabCatalog.LIST.size():
		var authored := TrailLabCatalog.routes(preset, Fixture)
		var w := WorldData.new()
		var records: Array = []
		for route in authored: records.append(route.path_record())
		w.trails = records
		var placement := RoadObstacles.new(w)
		for route in records.size():
			for n in records[route].pts.size():
				if not placement.pick(null, null, route, n).is_empty(): failures += 1
		checked += authored.size()
	print("AUTHORED ROUTES protected=", checked, " failures=", failures)
	for number in [15, 16, 18]:
		var routes := TrailLabCatalog.routes(number - 1, Fixture)
		var kit := Fixture.prepare(routes, true, TrailLabCatalog.LIST[number - 1].ground)
		var h: Heightfield = kit.heights
		var d: TrailDefinition = routes[0]
		var road := RoadObstacles.new(h.world)
		var surface := Floor.surface_image(h.world)
		var targets := [Vector2(340.743, 469.527)] if number == 15 else [Vector2(114.271, 458.906), Vector2(132.612, 450.828)]
		for target in targets:
			var pairs := road.around(target.x, target.y, 6)
			for i in range(0, pairs.size(), 2):
				var o := road.pick(h, surface, pairs[i], pairs[i + 1])
				if not o.is_empty() and target.distance_to(Vector2(o.x, o.z)) < 4:
					print("UNEXPECTED DECORATIVE_OBJECT track=", number, " target=", target, " object=", o)
					failures += 1
		if number == 16: continue
		var gap: float = Polygon._crossing(d) if number == 15 else Epic.crossing(d)
		for offset in [-2.0, -1.0, 0.0, 1.0, 2.0]:
			var player := PlayerState.new()
			var b := BikeRide.new()
			var s := gap - 25.0
			var at := d.point_at(s)
			b.heading = d.heading_at(s)
			b.x = at.x + cos(b.heading) * offset
			b.z = at.y - sin(b.heading) * offset
			b.y = h.ground_at(b.x, b.z)
			b.mount(player)
			b.speed = 17.0
			var takeoff := -999.0
			var worst := 0.0
			for tick in 240:
				h.obstacles.update(b.x, b.z, PackedFloat32Array(), 1)
				var air := b.airborne
				b.step(player, 0, 0, false, false, 1.0 / 60, h.world, h)
				if not air and b.airborne: takeoff = b.vy
				worst = maxf(worst, b.land_impact)
				b.land_impact = 0
				if b.crashed: break
			print("GAP track=", number, " offset=", offset, " crash=", b.crashed, " takeoff_vy=", takeoff, " impact=", worst)
			if b.crashed: failures += 1
	print("trail_collision: ", failures, " failures")
	quit(1 if failures else 0)
