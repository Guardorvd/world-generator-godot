extends SceneTree
## Water below decks, mesh/support agreement and crossing in both directions.
## -- --site uses the saved real bridge site without world generation.
const DT := 1.0 / 60.0
const SelfTest := preload("res://tools/selftest.gd")
var fails := 0
static var last_cross := {}

func check(ok: bool, label: String) -> void:
	if not ok:
		fails += 1
		printerr(label)

func _init() -> void:
	preload("res://tools/watchdog.gd").arm(self, 300)
	var w: WorldData
	var h: Heightfield
	if "--site" in OS.get_cmdline_user_args():
		var opened := TrailSite.open("res://resources/trails/sites/ushchelye_bridge.tsite")
		check(not opened.has("error"), "Не прочитана сохранённая площадка моста")
		if opened.has("error"): quit(1); return
		h = opened.site.surface()
		w = h.world
	else:
		# Bridge geometry belongs to the road stage. Do not spend the bridge-test
		# deadline discovering unrelated bicycle trails or generating vegetation.
		w = WorldGenerator._geography("Ущелье", WorldGenerator.PLAN_SIZE)
		StageLandmarks.run(w)
		StageTrails.run(w, func(_p: float, _label: String) -> void: pass)
		RoadSurface.run(w)
		h = w.base_heights.copy()
		h.finish_paths()
		w.base_heights = null
		w.clear_noise_fields()
		w.outer = OuterLand.new(w)
		check(SelfTest.settlement_network_valid(w), "Некорректная связь поселений")
	# This test teleports to every bridge; it does not run WorldData.open_around.
	# A 512-cell window on a 768-cell plan blocked valid bridges outside that window.
	w.available_rect = Rect2i(0, 0, w.W, w.H)
	h.obstacles = ForestObstacles.new(w, h)
	var report := audit(w, h)
	for problem: String in report.errors: check(false, problem)
	print("Мостов: %d; проездов: %d/%d; ошибок: %d" % [w.bridges.size(), report.passed, w.bridges.size() * 4, fails])
	quit(1 if fails else 0)


static func audit(w: WorldData, h: Heightfield) -> Dictionary:
	var errors := PackedStringArray()
	var verify := func(ok: bool, label: String) -> void:
		if not ok: errors.append(label)
	var passed := 0
	var seen := {}
	for b: BridgeData in w.bridges:
		verify.call(StageTrails._crosses_water(h, b.a, b.b), "Мост без воды: %s" % b)
		var key := Vector2i(mini(b.a, b.b), maxi(b.a, b.b))
		verify.call(not seen.has(key), "Дубликат моста: %s" % b)
		seen[key] = true
	for s: Dictionary in h.structures:
		if s.tunnel: continue
		var batch := MeshBatch.new()
		var n := maxi(1, ceili(s.len / Heightfield.BRIDGE_SECTION))
		for k in n:
			var t0: float = s.len * k / n
			var t1: float = s.len * (k + 1) / n
			var a := Vector3(s.ax + s.ux * t0, h.level(s, t0), s.az + s.uz * t0)
			var b := Vector3(s.ax + s.ux * t1, h.level(s, t1), s.az + s.uz * t1)
			StructuresBuilder._deck(batch, a, b, s.half, null)
		# С 9.8 сборка делится на квадраты мира: проверяются все части
		var built := batch.build("DeckTest")
		for part: MeshInstance3D in built.get_children():
			var arrays := part.mesh.surface_get_arrays(0)
			var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
			for k in vertices.size():
				if normals[k].y < 0.9: continue
				var v := vertices[k]
				var t: float = (v.x - s.ax) * s.ux + (v.z - s.az) * s.uz
				verify.call(absf(v.y - h.level(s, t)) < 0.001, "Меш и опора расходятся")
		built.free()
		for reverse in [false, true]:
			var span: Dictionary = s.duplicate()
			if reverse:
				span.ax = s.bx; span.az = s.bz; span.ay = s.by
				span.bx = s.ax; span.bz = s.az; span.by = s.ay
				span.ux = -s.ux; span.uz = -s.uz
			for ride in [false, true]:
				var ok := _cross(w, h, span, ride)
				verify.call(ok, "Мост (%s,%s), reverse=%s bike=%s" % [s.ax, s.az, reverse, ride])
				if ok: passed += 1
	verify.call(w.bridges.size() > 0, "Контрольный мир без мостов")
	return {passed = passed, errors = errors}


static func _cross(w: WorldData, heights: Heightfield, s: Dictionary, ride: bool) -> bool:
	# Entry and exit follow the saved road, which can turn immediately at the deck.
	# Half throttle at rest cannot climb every legal trail approach.
	const EXIT := 1.0
	var plan := _cross_route(w, s)
	if plan.is_empty():
		last_cross = {passed = false, reason = "no saved road through the bridge"}
		return false
	var route: TrailDefinition = plan.route
	var progress: float = maxf(0, plan.entry - 2.0)
	var start := route.point_at(progress)
	var tangent := route.tangent_at(progress)
	var yaw := atan2(-tangent.x, -tangent.y)
	var p := PlayerState.new()
	p.x = start.x
	p.z = start.y
	p.feet = heights.surface_at(p.x, p.z, s.ay)
	var b := _bike_for(p, yaw, ride)
	var mounted := not ride
	if ride:
		# The rider can already be riding down a steep approach where mounting at
		# exactly two metres is prohibited. Start at a valid point on that SAME road.
		for distance: float in [2.0, 4.0, 6.0, 8.0, 10.0, 12.0]:
			progress = maxf(0, plan.entry - distance)
			start = route.point_at(progress)
			tangent = route.tangent_at(progress)
			p.x = start.x; p.z = start.y; p.feet = heights.surface_at(p.x, p.z, s.ay)
			yaw = atan2(-tangent.x, -tangent.y)
			b = _bike_for(p, yaw, true)
			if BikeRecovery.placement(w, heights, Vector3(p.x, p.feet, p.z), yaw).is_empty(): continue
			if b.prepare_mount(p, w, heights):
				b.mount(p)
				mounted = true
				break
	var outcome := func(ok: bool, reason: String) -> bool:
		last_cross = {passed = ok, reason = reason, x = p.x, z = p.z, feet = p.feet,
			along = (p.x - s.ax) * s.ux + (p.z - s.az) * s.uz,
			known = heights.known(p.x, p.z), accessible = w.accessible(p.x / GameConfig.TILE, p.z / GameConfig.TILE),
			crashed = b.crashed, crash = b.crash_info, speed = b.speed, grade = b.grade_now,
			heading = b.heading, forward_support = b._sup_f, rear_support = b._sup_r}
		return ok
	if not mounted: return outcome.call(false, "no valid game bike placement on the saved approach")
	for k in 60 * 120:
		var here := Vector2(p.x, p.z)
		var near := route.nearest_along(here, progress, 12.0, 8.0)
		if not is_finite(near.z): return outcome.call(false, "left the saved road")
		progress = maxf(progress, near.x)
		var target := route.point_at(progress + (clampf(absf(b.speed) * 0.7, 1.2, 3.0) if ride else 1.2)) - here
		var desired := atan2(-target.x, -target.y)
		if ride:
			var turn := clampf(-wrapf(desired - b.heading, -PI, PI) * 2.0, -1, 1)
			var throttle := 1.0 if b.speed < 3.0 else (-0.3 if b.speed > 4.0 else 0.0)
			b.step(p, throttle, turn, false, false, DT, w, heights)
		else:
			p.step(1.0, 0.0, false, false, desired, DT, w, heights)
		var t: float = (p.x - s.ax) * s.ux + (p.z - s.az) * s.uz
		if progress > plan.exit + EXIT:
			return outcome.call(true, "crossed")
		if ride and b.crashed:
			outcome.call(false, "bike crash")
			print("  CROSS DETAIL ", JSON.stringify(last_cross))
			return false
		# у концов настил может уходить под берег, а пол туннеля — под землю у входа
		if t > 3.0 and t < s.len - 3.0:
			var level := heights.level(s, t)
			if p.feet < level - 0.6 or (s.tunnel and p.feet > level + 0.6):
				print("  на %.0f м из %.0f: ноги на %.1f м, настил или пол на %.1f м" % [t, s.len, p.feet, level])
				return outcome.call(false, "support below the deck")
	var t: float = (p.x - s.ax) * s.ux + (p.z - s.az) * s.uz
	print("  не дошли: застряли на %.1f м из %.0f, ноги на %.1f м, вода %.1f м, стена %s" % [t, s.len, p.feet, heights.depth_at(p.x, p.z, p.feet), heights.wall_at(p.x, p.z, p.feet)])
	return outcome.call(false, "no crossing within simulated time")


static func _cross_route(w: WorldData, s: Dictionary) -> Dictionary:
	for path: Dictionary in w.trails:
		if not RoadBed.KINDS.has(path.kind): continue
		var a := -1
		var b := -1
		for index in path.pts.size():
			var point := Vector2(path.pts[index].x, path.pts[index].y) * GameConfig.TILE
			if point.distance_to(Vector2(s.ax, s.az)) < 0.01: a = index
			if point.distance_to(Vector2(s.bx, s.bz)) < 0.01: b = index
		if a < 0 or b < 0 or a == b: continue
		var direction := 1 if b > a else -1
		var first := a
		var last := b
		var run_in := 0.0
		var run_out := 0.0
		while first - direction >= 0 and first - direction < path.pts.size() and run_in < 12.0:
			var p: Dictionary = path.pts[first]
			var q: Dictionary = path.pts[first - direction]
			run_in += Vector2(p.x - q.x, p.y - q.y).length() * GameConfig.TILE
			first -= direction
		while last + direction >= 0 and last + direction < path.pts.size() and run_out < 12.0:
			var p: Dictionary = path.pts[last]
			var q: Dictionary = path.pts[last + direction]
			run_out += Vector2(p.x - q.x, p.y - q.y).length() * GameConfig.TILE
			last += direction
		if run_in < 1.0 or run_out < 1.01: continue
		var points := PackedVector2Array()
		var entry := 0.0
		var exit := 0.0
		var length := 0.0
		for index in range(first, last + direction, direction):
			var point := Vector2(path.pts[index].x, path.pts[index].y) * GameConfig.TILE
			if not points.is_empty(): length += points[-1].distance_to(point)
			points.append(point)
			if index == a: entry = length
			if index == b: exit = length
		var route := TrailDefinition.new()
		route.points = points
		return {route = route, entry = entry, exit = exit}
	return {}


static func _bike_for(p: PlayerState, yaw: float, ride: bool) -> BikeRide:
	var b := BikeRide.new()
	if ride:
		b.x = p.x
		b.z = p.z
		b.y = p.feet
		b.heading = yaw
		b.mount(p)
	return b


