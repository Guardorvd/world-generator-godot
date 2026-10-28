extends SceneTree
const Fixture = preload("res://tools/trail_lab_fixture.gd")
const Line = preload("res://scripts/render/navigation_line.gd")
const Roads = preload("res://scripts/game/road_navigation.gd")
const Snapshot = preload("res://scripts/game/navigation_snapshot.gd")
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
