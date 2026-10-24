extends SceneTree
class TestWorld extends WorldData:
	var rocky := false
	func tile_info(_x: float, _z: float) -> Dictionary:
		return {biome = Biomes.ROCK if rocky else Biomes.GRASS, path = 0}

class TestGround extends Heightfield:
	var depth := 0.6
	var flow := Vector2(2.8, 0)
	var bridge := false
	var wall := false
	var grade := 0.0
	func _init() -> void:
		super(WorldData.new(), false)
	func ground_at(_x: float, z: float, _raw := false) -> float:
		return -z * grade
	func depth_at(_x: float, _z: float, _feet := -INF) -> float:
		return 0.0 if bridge else depth
	func current_at(_x: float, _z: float) -> Vector2:
		return flow
	func known(_x: float, _z: float) -> bool:
		return true
	func wall_at(x: float, _z: float, _feet: float, _r := 0.0) -> bool:
		return wall and x > 0.15

var fails := 0
func check(ok: bool, label: String) -> void:
	print(("OK " if ok else "FAIL ") + label)
	fails += int(not ok)

func ride(h: TestGround, w: TestWorld, hz := 60, pace := 3.0) -> BikeRide:
	var b := BikeRide.new()
	b.speed = pace
	b._water_rng.seed = 37
	var p := PlayerState.new()
	for i in hz:
		b.step(p, 0, 0, false, false, 1.0 / hz, w, h)
	return b

func _init() -> void:
	var h := TestGround.new()
	var w := TestWorld.new()
	var cross := ride(h, w)
	check(cross.x > 0.05 and cross._water_drift.x > 0, "Current moves the bike sideways")
	h.flow.x = -2.8
	check(ride(h, w).x < -0.05, "Opposite flow reverses drift")
	h.flow = Vector2.ZERO
	var still := ride(h, w)
	h.flow = Vector2(0, -2.8)
	var downstream := ride(h, w)
	h.flow = Vector2(0, 2.8)
	check(downstream.speed > still.speed and ride(h, w).speed < still.speed, "Drag uses velocity relative to flow")
	h.flow = Vector2.ZERO
	var slow := BikeRide.new()
	slow.speed = 2
	slow._step_water(h, w, RoadSurface.NONE, 0, 0.001)
	var fast := BikeRide.new()
	fast.speed = 4
	fast._step_water(h, w, RoadSurface.NONE, 0, 0.001)
	check((4 - fast.speed) / (2 - slow.speed) > 3.9, "Hydrodynamic resistance is quadratic")
	h.flow = Vector2(2.8, 0)
	h.depth = 0.15
	check(ride(h, w).x < cross.x, "Shallow water causes less drift")
	h.depth = 0.6
	var b30 := ride(h, w, 30)
	var b120 := ride(h, w, 120)
	print("Hz comparison: ", b30.x, " / ", b120.x, " speed ", b30.speed, " / ", b120.speed)
	check(absf(b30.x - b120.x) < 0.03 and absf(b30.speed - b120.speed) < 0.05, "30/120 Hz remain close")
	h.bridge = true
	check(ride(h, w).x == 0, "Bridge prevents flow forces")
	h.bridge = false
	var air := BikeRide.new()
	air.airborne = true
	air.speed = 3
	air._step_water(h, w, RoadSurface.NONE, 0, 0.1)
	check(air.speed == 3 and air._water_drift == Vector2.ZERO, "Airborne wheels ignore water below")
	h.wall = true
	check(ride(h, w).x <= 0.15, "Drift respects collisions")
	h.wall = false
	var slip := BikeRide.new()
	slip.speed = 2
	slip._water_rng.seed = 17
	var events := 0
	w.rocky = true
	h.depth = 0.9
	for i in 1800:
		slip._step_water(h, w, RoadSurface.NONE, 0, 1.0 / 60.0)
		if slip._water_slip_wait > 0.64: events += 1
	check(events > 0 and events < 50, "Deep rocky ford causes occasional bounded front-wheel slip")
	slip.reset_motion()
	check(slip._water_drift == Vector2.ZERO and slip._water_yaw == 0 and slip._water_slip_wait == 0, "Reset clears water motion")
	for condition in [0, 1, 2]:
		w.rocky = condition == 0
		h.depth = 0.35 if condition == 0 else 0.9
		h.flow = Vector2.ZERO if condition == 1 else Vector2(2.8, 0)
		for i in 600: slip._step_water(h, w, RoadSurface.NONE, 0, 1.0 / 60.0)
		check(slip._water_yaw == 0, "No slip in shallow, still, or smooth flat water")
	w.rocky = false
	h.depth = 0.9
	h.flow = Vector2(2.8, 0)
	slip.reset_motion()
	slip.speed = 2
	slip._water_rng.seed = 17
	events = 0
	for i in 1800:
		slip._step_water(h, w, RoadSurface.NONE, 0.3, 1.0 / 60.0)
		if slip._water_slip_wait > 0.64: events += 1
	check(events > 0, "Steep non-rocky ford can also disturb the front wheel")
	var standing := ride(h, w, 60, 0.0)
	check(standing.x > 0, "Flow can move a stationary bike sideways")
	h.flow = Vector2.ZERO
	var rapid := BikeRide.new()
	rapid.speed = 40
	rapid._step_water(h, w, RoadSurface.NONE, 0, 0.5)
	check(rapid.speed > 0 and rapid.speed < 40, "Long water step brakes without reversing velocity")
	print("Bike water failures: ", fails)
	quit(fails)
