extends SceneTree
const Fixture = preload("res://scripts/lab/trail_lab_fixture.gd")
const Line = preload("res://scripts/render/navigation_line.gd")
const Roads = preload("res://scripts/game/road_navigation.gd")
const Snapshot = preload("res://scripts/game/navigation_snapshot.gd")
const Topology := preload("res://scripts/world/road_topology.gd")
const RoadFixture := preload("res://tools/road_relief_fixture.gd")
class CountRoads extends Roads:
	var calls := 0
	var longest := 0.0
	func _segment(a: Vector2, b: Vector2, feet: float) -> float:
		calls += 1
		longest = maxf(longest, a.distance_to(b))
		return feet
var failures := 0
var checks := 0
func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 120)
	run.call_deferred()
func check(ok: bool, message: String) -> void:
	checks += 1
	print("navigation_async: ", "PASS " if ok else "FAIL ", message)
	if not ok: failures += 1
func run() -> void:
	topology()
	overpass()
	diagonal_bridge()
	var h := Fixture.build(Fixture.definitions())
	var copy := Snapshot.capture(h)
	check(copy.world != h.world and copy != h, "private snapshot owns its world")
	check(copy.ground_at(40,142) == h.ground_at(40,142), "snapshot retains refined roller geometry")
	var y := copy.ground_at(12,12)
	h.hv[2*h.world.W+2] += 2
	check(copy.ground_at(12,12) == y, "snapshot coarse heights independent")
	h.obstacles.data = PackedFloat32Array([40,100,40,100,1,0,100])
	h.obstacles._grid = {Vector2i(20,50): PackedInt32Array([0])}
	copy = Snapshot.capture(h)
	h.obstacles.data.clear()
	h.obstacles._grid.clear()
	check(copy.obstacles.hits(40,100,20,0.25), "snapshot obstacles survive live cache rebuild")
	# Compare the spatial filter against the existing exact collision query across cell boundaries.
	var collision_h := Fixture.build(Fixture.definitions())
	var collision_w := collision_h.world
	collision_w.settlements = [{x=16.0,y=16.0,huts=[{x=16.0,y=16.0,t="house",a=0.7}]}]
	collision_w.sites = [{x=32.0,y=16.0,huts=[{x=32.0,y=16.0,t="barn",a=0.4}]}]
	var indexed := Roads.new()
	indexed._world = collision_w
	indexed._heights = collision_h
	var matches := true
	var blocked := 0
	for z in range(58,71):
		for x in range(58,135):
			var at := Vector2(x,z)
			var feet := collision_h.ground_at(x,z)
			var exact := PlayerState.is_passable(collision_w,collision_h,x,z,feet,0.25)
			matches = matches and indexed._passable(at,feet) == exact
			blocked += int(not exact)
	check(matches and blocked > 0, "local building index matches exact rotated house and site collisions across chunk edges")
	var line := Line.new()
	root.add_child(line)
	line.setup(h.world,h)
	var count := CountRoads.new()
	line.roads = count
	line._goal = {kind="marker"}
	line._target = Vector2(220,100)
	check(not line.can_arrive(Vector3(40,20,100)) and count.calls == 0, "distant marker never traces long connector in physics")
	line._goal = {kind="site"}
	line._revision = line._network_revision()
	line.path = PackedVector2Array([Vector2(40,100),Vector2(220,100)])
	line._cum = PackedFloat32Array([0,180])
	line._road_first = 0
	line._road_last = 1
	line.update_line(Vector3(40,h.ground_at(40,100),100),0.1,true)
	check(count.calls > 0 and count.longest <= Line.REACH + 0.001, "line validates only visible 70m, not entire long edge")
	line.setup(h.world,h)
	line.background_search = true
	var from := Vector2(40,200)
	var target := {kind="marker", x=10.0, y=25.0}
	var before := Time.get_ticks_usec()
	line.set_goal(target, from, h.ground_at(from.x,from.y))
	check(line._search_task != -1 and line.path.is_empty(), "set_goal schedules worker instead of synchronous search")
	print("navigation_async: request_ms=",(Time.get_ticks_usec()-before)/1000.0)
	var ticks := 0
	while line._search_task != -1 and ticks < 600:
		await process_frame
		line._poll_search(from)
		ticks += 1
	check(line._search_task == -1 and not line.path.is_empty() and line.path[-1].distance_to(Vector2(40,100)) < 0.01, "background route published")
	check(line.roads._heights == h, "accepted path validates against live terrain")
	line.set_goal({kind="marker",x=50.0,y=50.0}, from,h.ground_at(from.x,from.y))
	line.set_goal({},from)
	while line._search_task != -1:
		await process_frame
		line._poll_search(from)
	check(line.path.is_empty() and line._goal.is_empty(), "clearing goal rejects in-flight result")
	line.set_goal({kind="marker",x=50.0,y=50.0},from,h.ground_at(from.x,from.y))
	line.set_goal(target,from,h.ground_at(from.x,from.y))
	ticks = 0
	while (line._search_task != -1 or not line._request.is_empty()) and ticks < 600:
		await process_frame
		line._poll_search(from)
		ticks += 1
	check(not line.path.is_empty() and line.path[-1].distance_to(Vector2(40,100)) < 0.01, "newest goal wins over cancelled request")
	line.set_goal(target,from,h.ground_at(from.x,from.y))
	h.world.territory_revision += 1
	while line._search_task != -1:
		await process_frame
		line._poll_search(from)
	check(line.path.is_empty(), "terrain revision rejects old in-flight result")
	line.update_line(Vector3(from.x,h.ground_at(from.x,from.y),from.y),0.25,true)
	while line._search_task != -1:
		await process_frame
		line._poll_search(from)
	check(not line.path.is_empty() and line._revision == line._network_revision(), "new terrain revision gets a fresh background graph")
	line.set_goal(target,from,h.ground_at(from.x,from.y))
	line.free()
	check(true,"scene exit joins cancelled worker without dangling nodes")
	print("navigation_async: ",failures," failures / ",checks," checks")
	quit(1 if failures else 0)


func _road(axis: Array) -> Dictionary:
	return {kind = "road", pts = axis.map(func(p: Vector2) -> Dictionary: return {x = p.x, y = p.y, w = 0.9})}


func topology() -> void:
	var w := RoadFixture.world()
	var main := _road([Vector2(8.5, 40.2), Vector2(70.5, 40.2)])
	var branch := _road([Vector2(38.5, 40.2), Vector2(38.5, 58.5)])
	var near := _road([Vector2(8.5, 40.8), Vector2(20.5, 40.8)])
	var duplicate := _road([Vector2(70.5, 40.2), Vector2(8.5, 40.2)])
	w.trails = [main]
	var pixels := PackedByteArray()
	pixels.resize(w.N * 3)
	var painted: Array[PackedByteArray] = [pixels]
	var map := MapBaker.finish(w, 1, painted)[0]
	w.trails.append(duplicate)
	check(Topology.sections(w).size() == 1 and MapBaker.finish(w, 1, painted)[0].get_data() == map.get_data(),
		"map draws a legacy physical section once, including a reversed duplicate")
	w.trails = [main, branch, near]
	var nav := Roads.new()
	nav.build(w)
	var home := nav.component_near(Vector2(8.5, 40.2) * 4.0)
	var other := nav.component_near(Vector2(8.5, 40.8) * 4.0)
	check(home == nav.component_near(Vector2(38.5, 58.5) * 4.0), "a T junction splits the interior chord of its host")
	check(home != other and nav.component_at(Vector2i(8, 40), other) == other
		and nav.component_cells(home).has(Vector2i(8, 40)), "two unconnected roads can have nodes in the same cell")
	var id := Topology.section_id(main.pts, w.world_origin)
	var start := Vector2(8.5, 40.2) * 4.0
	var finish := Vector2(70.5, 40.2) * 4.0
	nav.route_to(start, finish)
	var forward: Array[Dictionary] = nav.road_route.duplicate(true)
	nav.route_to(finish, start)
	var backward := nav.road_route
	check(forward.size() == 1 and backward.size() == 1 and forward[0].section == id and backward[0].section == id
		and forward[0].from_node == backward[0].to_node and is_equal_approx(forward[0].to_m, backward[0].from_m),
		"two routes reference the same physical section with opposite directed intervals")
	nav.route_to(start, Vector2(38.5, 58.5) * 4.0)
	check(nav.road_route.size() == 2 and nav.road_route[0].to_node == nav.road_route[1].from_node,
		"route switches sections at a shared node")
	var keys: Array = nav._node_keys.values()
	keys.sort()
	w.trails = bytes_to_var(var_to_bytes([near, branch, main]))
	nav.build(w)
	var reordered: Array = nav._node_keys.values()
	reordered.sort()
	check(keys == reordered and Topology.sections(w).has(id), "legacy IDs survive serialization and record reordering")
	var crossing := _road([Vector2(60.5, 32.5), Vector2(60.5, 48.5)])
	w.outer = OuterLand.new()
	w.outer._ledger = {trails = [crossing]}
	nav.build(w)
	check(nav.component_near(Vector2(60.5, 32.5) * 4.0) == nav.component_near(finish),
		"ledger and plan share an at-grade intersection between chord interiors")


func overpass() -> void:
	var w := RoadFixture.world()
	var crossing := Vector2(40.5, 40.5)
	w.trails = [
		_road([Vector2(16.5, 40.5), crossing, Vector2(68.5, 40.5)]),
		_road([Vector2(40.5, 30.5), crossing, Vector2(40.5, 50.5)]),
	]
	w.bridges = [{a = 40 * w.W + 24, b = 40 * w.W + 56}]
	RoadSurface.run(w)
	var h := Heightfield.new(w)
	var from := Vector2(16.5, 40.5) * 4.0
	var to := Vector2(68.5, 40.5) * 4.0
	var lower := Vector2(40.5, 30.5) * 4.0
	var nav := Roads.new()
	nav.build(w)
	check(nav.component_near(from) == nav.component_near(to) and nav.component_near(from) != nav.component_near(lower),
		"bridge portals split a sparse legacy chord and the crossing stays separate without heights")
	var copy := Snapshot.capture(h)
	nav.build(copy.world, copy)
	var heights: Array[float] = []
	for n: int in nav.points:
		if nav.points[n].is_equal_approx(crossing * 4.0):
			heights.append(nav.levels[n])
	check(heights.size() == 2 and absf(heights[0] - heights[1]) > 0.5
		and nav.component_near(from) == nav.component_near(to) and nav.component_near(from) != nav.component_near(lower),
		"snapshot uses the deck height and ground height at the same coordinates")

func diagonal_bridge() -> void:
	var w := RoadFixture.world()
	var a := Vector2(10.5, 63.5)
	var b := Vector2(86.5, 20.5)
	var stations: Array = []
	for i in 181:
		stations.append(a.lerp(b, float(i) / 180.0))
	w.trails = [_road(stations)]
	w.bridges = [{a = 63 * w.W + 10, b = 20 * w.W + 86}]
	var graph := Topology.compile(w)
	var deck_nodes := 0
	for n: Dictionary in graph.nodes:
		deck_nodes += int(not n.passage.is_empty())
	var nav := Roads.new()
	nav.build(w)
	check(deck_nodes == 179 and nav.component_near(a * 4.0) == nav.component_near(b * 4.0),
		"rounded stations of a long diagonal bridge stay on the same deck")
