extends SceneTree
## 11.11.2026: публикация сети участками (StageTrails._add_trail, docs/ROAD_NETWORK.md) на синтетическом мире без
## генерации: общий участок не копируется, развилка и примыкание — общая вершина на оси хозяина, пересечение проходит
## насквозь, повышение класса делит тропу узлами, рядом с участком нет «призрачной» дешёвой полосы, правило
## параллельных полотен. Секунды, без окна.
##   godot --headless --path . --script res://tools/road_passage_test.gd
const Fixture := preload("res://tools/road_relief_fixture.gd")
var fails := 0


func check(ok: bool, label: String) -> void:
	print("PASS " if ok else "FAIL ", label)
	fails += int(not ok)


func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 60)
	run.call_deferred()


func cells(points: Array) -> PackedInt32Array:
	var out := PackedInt32Array()
	for p: Vector2i in points: out.append(p.y * 96 + p.x)
	return out


func line(from: Vector2i, to: Vector2i) -> Array:
	var out: Array = []
	var at := from
	out.append(at)
	while at != to:
		at += Vector2i(signi(to.x - at.x), signi(to.y - at.y))
		out.append(at)
	return out


func on_polyline(pts: Array, p: Vector2) -> bool:
	for j in pts.size():
		if Vector2(pts[j].x, pts[j].y).distance_to(p) < 0.0001: return true
	return false


func overlap(w: WorldData, a: int, b: int) -> float:
	# длина оси a ближе 0,25 клетки к оси b (дубль полотна), клеток
	var total := 0.0
	var pts: Array = w.trails[a].pts
	for j in range(1, pts.size()):
		var p := (Vector2(pts[j - 1].x, pts[j - 1].y) + Vector2(pts[j].x, pts[j].y)) * 0.5
		var q := StageTrails._nearest_on(w.trails[b].pts, p)
		if p.distance_to(q) < 0.25: total += Vector2(pts[j - 1].x, pts[j - 1].y).distance_to(Vector2(pts[j].x, pts[j].y))
	return total


func run() -> void:
	var w := Fixture.world()
	w.trails = []
	w.cost.resize(w.N)
	w.cost.fill(1.0)
	StageTrails._net_reset(w)
	# Хозяин: дорога по ряду 48
	var host := StageTrails._add_trail(w, cells(line(Vector2i(8, 48), Vector2i(88, 48))), "road")
	check(host.size() == 1 and w.trails.size() == 1, "first route is one segment")
	var host_id: String = w.trails[0].road_id
	# Сходится на дорогу, идёт по ней 20 клеток и уходит: два новых участка, общий участок не копируется
	var path: Array = line(Vector2i(14, 30), Vector2i(30, 46)) + line(Vector2i(30, 47), Vector2i(30, 48)).slice(1) \
		+ line(Vector2i(31, 48), Vector2i(50, 48)) + line(Vector2i(51, 49), Vector2i(66, 64))
	var added := StageTrails._add_trail(w, cells(path), "trail")
	check(added.size() == 2, "merge-and-leave makes two new segments (%d)" % added.size())
	var shared := 0.0
	for k: int in added: shared += overlap(w, k, 0)
	check(shared < 1.0, "no duplicated axis along the shared road (%.2f cells)" % shared)
	var nodes := 0
	for k: int in added:
		for end: Dictionary in [w.trails[k].pts[0], w.trails[k].pts[-1]]:
			if on_polyline(w.trails[0].pts, Vector2(end.x, end.y)): nodes += 1
	check(nodes == 2, "each branch ends on an exact vertex of the host axis (node)")
	check(not host_id.is_empty() and w.trails[0].road_id == host_id, "physical ID survives insertion of branch vertices")
	# Пересечение: вертикальный путь через дорогу — один участок насквозь
	var before := w.trails.size()
	var cross := StageTrails._add_trail(w, cells(line(Vector2i(72, 30), Vector2i(72, 66))), "trail")
	check(cross.size() == 1 and w.trails.size() == before + 1, "a crossing passes through as one segment")
	# Путь целиком по готовой сети — ничего нового
	before = w.trails.size()
	check(StageTrails._add_trail(w, cells(line(Vector2i(12, 48), Vector2i(80, 48))), "trail").is_empty() and w.trails.size() == before,
		"a route that runs entirely on the network publishes nothing")
	# Стоимость: на участке дешевле, рядом — не дешевле свободной земли
	check(w.cost[48 * 96 + 40] < 0.5 and w.cost[47 * 96 + 40] >= 1.0, "trodden discount only on the segment, not a ghost strip beside it")
	# Повышение класса: часть тропы, по которой идёт дорога-связь, — дорога; тропа делится узлами
	StageTrails._net_reset(w)
	w.trails = []
	StageTrails._add_trail(w, cells(line(Vector2i(8, 20), Vector2i(88, 20))), "trail")
	var length := StageTrails._kind_length_of(w.trails[0])
	StageTrails._upgrade_path(w, cells(line(Vector2i(30, 20), Vector2i(60, 20))))
	var kinds := {}
	var total := 0.0
	for t: Dictionary in w.trails:
		kinds[t.kind] = int(kinds.get(t.kind, 0)) + 1
		total += StageTrails._kind_length_of(t)
	check(kinds.get("road", 0) == 1 and kinds.get("trail", 0) == 2, "promotion splits the trail into trail-road-trail (%s)" % str(kinds))
	check(absf(total - length) < 0.01, "promotion keeps the axis (%.3f / %.3f cells)" % [total, length])
	var road: Dictionary = w.trails[0]
	check(road.kind == "road" and road.pts.all(func(p: Dictionary) -> bool: return p.w == StageTrails.WIDTHS.road), "promoted part has one road width")
	# Параллельное полотно в 3 клетках вдоль сети на той же высоте — не новое; далеко — новое
	var near := StageTrails._net_near(w)
	var beside := cells(line(Vector2i(8, 23), Vector2i(88, 23)))
	var far := cells(line(Vector2i(8, 60), Vector2i(88, 60)))
	check(not StageTrails._adds_network(w, beside, near), "a parallel tread 12 m beside the network is rejected")
	check(StageTrails._adds_network(w, far, near), "a route 160 m away is a real addition")
	turns()
	junction()
	print("ROAD PASSAGE RESULT ", fails, " failures")
	quit(1 if fails else 0)


class TestGround extends Heightfield:
	var grade_x := 0.0
	var wet := Rect2()

	func ground_at(x: float, _z: float, _refined := true) -> float:
		return 20.0 + grade_x * x

	func depth_at(x: float, z: float, _feet := -INF) -> float:
		return 0.5 if wet.has_point(Vector2(x, z) / GameConfig.TILE) else 0.0

	func fast_water() -> Object:
		return null


func points(positions: Array, width := 0.9) -> Array:
	return positions.map(func(p: Vector2) -> Dictionary: return {x = p.x, y = p.y, w = width})


func turns() -> void:
	var w := Fixture.world()
	var ground := TestGround.new(w, false)
	var elbow := Vector2(40.5, 40.5)
	var right_angle := points([Vector2(28.5, 40.5), elbow, Vector2(40.5, 52.5)])
	var flat := StageTrails._road_line(w, right_angle, PackedByteArray(), ground)
	check(not on_polyline(flat, elbow) and flat[0] == right_angle[0] and flat[-1] == right_angle[-1],
		"ordinary bend is rounded and keeps its endpoints")
	ride_bend(w, flat)
	var trimmed := StageTrails._road_line(w, right_angle, PackedByteArray(), ground, "road", {},
		func(curve: Array) -> bool: return curve[0].x > 38.5)
	check(not on_polyline(trimmed, elbow) and trimmed != flat, "blocked long entry retries with a shifted curve")
	ground.wet = Rect2(36.0, 39.0, 6.0, 6.0)
	var wet := StageTrails._road_line(w, right_angle, PackedByteArray(), ground)
	check(on_polyline(wet, elbow), "a wet corridor keeps the original bend")
	ground.wet = Rect2()

	var pins := PackedByteArray()
	pins.resize(w.N)
	pins[40 * w.W + 40] = 1
	check(on_polyline(StageTrails._road_line(w, right_angle, pins, ground), elbow), "structure axis is pinned")
	var dogleg := points([Vector2(34.5, 40.5), elbow, Vector2(41.5, 41.5), Vector2(47.5, 41.5)])
	var relaxed := StageTrails._road_line(w, dogleg, PackedByteArray(), ground)
	check(not on_polyline(relaxed, elbow) and not on_polyline(relaxed, Vector2(41.5, 41.5)),
		"opposite grid turns share one transition")
	var hairpin := points([Vector2(28.5, 40.5), elbow, Vector2(30.5, 50.5)], StageTrails.WIDTHS.mountain)
	check(not on_polyline(StageTrails._road_line(w, hairpin, PackedByteArray(), ground, "mountain"), elbow),
		"switchback fits at the lower design speed")

	var control := [Vector2(38.5, 40.5), Vector2(39.6, 40.5), Vector2(40.5, 41.4), Vector2(40.5, 42.5)]
	var corridor := [Vector2(38.5, 40.5), elbow, Vector2(40.5, 42.5)]
	var rules := {grade = 0.28, cross = 0.65, accel = 5.4, axis = PackedByteArray(), probe = null, corridor = Callable()}
	ground.grade_x = 0.24
	var slow := StageTrails._road_curve(ground, control, corridor, 0.9, 3.0, rules)
	var fast := StageTrails._road_curve(ground, control, corridor, 0.9, 6.3, rules)
	ground.grade_x = 0.0
	var fast_flat := StageTrails._road_curve(ground, control, corridor, 0.9, 6.3, rules)
	check(not slow.is_empty() and fast.is_empty() and not fast_flat.is_empty(), "same radius and grade fit separately but exceed the combined budget")
	ground.wet = Rect2(38.38, 40.0, 0.28, 0.18)
	var wide := StageTrails._road_curve(ground, control, corridor, 0.9, 3.0, rules)
	var narrow := StageTrails._road_curve(ground, control, corridor, 0.42, 3.0, rules)
	check(wide.is_empty() and not narrow.is_empty(), "water at the outer edge rejects the wide curve")


func ride_bend(w: WorldData, axis: Array) -> void:
	w.trails = [{kind = "road", pts = axis}]
	RoadSurface.run(w)
	var h := Heightfield.new(w, false)
	RoadBed.refine(h)
	h.build_structures()
	h.road_refinement = RoadRefinement.build(h)
	var line_points := PackedVector2Array()
	for p: Dictionary in axis:
		line_points.append(Vector2(p.x, p.y) * GameConfig.TILE)
	var course := Curve2D.new()
	course.bake_interval = 0.5
	for p: Vector2 in line_points: course.add_point(p)
	var start := course.sample_baked(18.0)
	var bike := BikeRide.new()
	var player := PlayerState.new()
	var control := BikeController.new()
	bike.x = start.x
	bike.z = start.y
	bike.y = h.ground_at(bike.x, bike.z)
	bike.heading = -PI * 0.5
	bike.mount(player)
	bike.speed = 5.0
	var air := 0
	var lateral := 0.0
	var offset := 0.0
	var progress := 0.0
	for tick in 60 * 18:
		var pos := Vector2(bike.x, bike.z)
		progress = course.get_closest_offset(pos)
		if progress >= course.get_baked_length() - 6.0: break
		offset = maxf(offset, pos.distance_to(course.sample_baked(progress)))
		var goal := course.sample_baked(progress + 3.0) - pos
		var steer := clampf(-wrapf(atan2(-goal.x, -goal.y) - bike.heading, -PI, PI) * 2.5, -1.0, 1.0)
		control.ride(1.0 / 60.0, player, bike, w, h, clampf((5.0 - bike.speed) * 0.8, -1.0, 1.0), steer, false, false, false)
		air += int(bike.airborne)
		lateral = maxf(lateral, absf(bike.lateral_speed))
		if bike.crashed: break
	check(not bike.crashed and progress >= course.get_baked_length() - 6.0 and air == 0 and offset < 1.5 and lateral < 0.5,
		"ride around bend: %d airborne ticks, %.2f m/s lateral speed, %.2f m maximum offset" % [air, lateral, offset])


func junction() -> void:
	var w := Fixture.world()
	var ground := TestGround.new(w, false)
	var node := Vector2(40.5, 40.5)
	var branch := points([node, Vector2(52.5, 43.5)])
	var shaped := StageTrails._road_line(w, branch, PackedByteArray(), ground, "road", {0: {tangent = Vector2.RIGHT}})
	var heading := (Vector2(shaped[1].x, shaped[1].y) - node).angle()
	check(shaped[0] == branch[0] and heading > deg_to_rad(24), "merge keeps the node and opens a readable approach angle")

	# The main road climbs along X. The branch approaches obliquely, so the common plane has
	# both a longitudinal grade and a crossfall in branch coordinates.
	var tile := GameConfig.TILE
	for y in w.H:
		for x in w.W:
			w.h[y * w.W + x] = (20.0 + tile * (0.12 * x + 0.08 * absf(y - 40))) / GameConfig.HS
	w.trails = [
		{kind = "road", pts = points([Vector2(22.5, 40.5), node, Vector2(59.5, 40.5)])},
		{kind = "trail", pts = points([node, Vector2(49.5, 55.5)], 0.55)},
	]
	var heights := Heightfield.new(w, false)
	var profiles := [RoadBed._profile(heights, w.trails[0].pts, RoadBed.KINDS.road),
		RoadBed._profile(heights, w.trails[1].pts, RoadBed.KINDS.trail)]
	var p: Dictionary = profiles[1]
	var grade_before: float = (p.prof[1] - p.prof[0]) / p.along[1]
	RoadBed._join(heights, [0, 1], [0, 1], profiles, RoadBed._pins(w))
	var q := RoadBed._nearest(profiles[0], node.x * tile, node.y * tile)
	var grade_after: float = (p.prof[1] - p.prof[0]) / p.along[1]
	var target := 0.12 * Vector2(9, 15).normalized().x
	check(absf(p.prof[0] - profiles[0].prof[q]) < 0.001 and absf(grade_after - target) < absf(grade_before - target)
		and absf(p.cross_x[0]) > 0.04 and p.cross_x[-1] == 0.0, "junction matches height and blends longitudinal grade and crossfall")
	if Grid.fast_grid() != null:
		var reference := Heightfield.new(w, false)
		RoadBed.allow_fast = false
		RoadBed.refine(reference)
		RoadBed.allow_fast = true
		RoadBed.refine(heights)
		check(heights.hv.to_byte_array() == reference.hv.to_byte_array(), "junction bed matches native implementation byte for byte")
	else:
		RoadBed.refine(heights)

	RoadSurface.run(w)
	heights.build_structures()
	heights.road_refinement = RoadRefinement.build(heights)
	var bike := BikeRide.new()
	var player := PlayerState.new()
	var control := BikeController.new()
	bike.x = node.x * tile - 12.0
	bike.z = node.y * tile
	bike.heading = -PI * 0.5
	bike.y = heights.ground_at(bike.x, bike.z)
	bike.mount(player)
	bike.speed = 5.0
	var lateral := 0.0
	var suspension := 0.0
	var air := 0
	for tick in 60 * 6:
		control.ride(1.0 / 60.0, player, bike, w, heights, clampf((5.0 - bike.speed) * 0.8, -1.0, 1.0), 0.0, false, false, false)
		lateral = maxf(lateral, absf(bike.lateral_speed))
		suspension = maxf(suspension, maxf(absf(bike.squash_f), absf(bike.squash_r)))
		air += int(bike.airborne)
		if bike.crashed: break
	check(not bike.crashed and bike.x > node.x * tile + 5.0 and air == 0 and lateral < 0.5 and suspension < 0.10,
		"ride through junction: %d airborne ticks, %.2f m/s lateral speed, %.2f m suspension" % [air, lateral, suspension])
