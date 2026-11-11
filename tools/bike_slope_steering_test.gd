extends SceneTree
## No generation: production BikeRide on analytic slopes, plus frame/tyre clearance.
class Ground extends Heightfield:
	var grade := 0.0
	var cross := 0.0
	func ground_at(x: float, z: float, _raw := false) -> float:
		return 100.0 - grade * z + cross * x
	func depth_at(_x: float, _z: float, _feet := -INF) -> float: return 0.0
	func known(_x: float, _z: float) -> bool: return true

class World extends WorldData:
	func tile_info(_x: float, _z: float) -> Dictionary:
		return {biome = Biomes.GRASS, path = 3, surface = RoadSurface.PACKED}

var failures := 0

func check(ok: bool, message: String) -> void:
	print(("PASS " if ok else "FAIL ") + message)
	failures += int(not ok)

func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 60)
	run.call_deferred()

func ride(grade: float, cross: float, hz: int, script: Script = null) -> Dictionary:
	var w := World.new()
	var h := Ground.new()
	h.world = w
	h.grade = grade
	h.cross = cross
	var b: BikeRide = BikeRide.new() if script == null else script.new()
	b.riding = true
	b.y = 100.0
	b.speed = 18.0
	var p := PlayerState.new()
	for tick in hz * 3:
		b.step(p, 0.0, 1.0 if tick >= hz else 0.0, false, false, 1.0 / hz, w, h)
		if b.crashed: break
	return {heading = b.heading, velocity = b.horizontal_velocity().angle_to(Vector2(0, -1)),
		speed = b.speed, crashed = b.crashed, front = b.load_f}

func check_steering() -> void:
	# Front is lightly loaded on a crest; adverse bank used to subtract all steering.
	var b := BikeRide.new()
	b.speed = 18.0
	b.load_f = 0.1
	b.load_r = 0.4
	b.side_f = 0.1
	b.side_r = 0.4
	b.bank_slope = 0.8
	for i in 120: b._step_turn(1.0, 1.0, 1.0 / 120.0)
	check(b._yaw_rate < -0.03, "adverse slope does not lock a loaded front wheel")
	b.lift_f = 0.1
	for i in 120: b._step_turn(1.0, 1.0, 1.0 / 120.0)
	check(absf(b._yaw_rate) < 0.001, "raised front wheel cannot steer through rear traction")
	var args := OS.get_cmdline_user_args()
	var at := args.find("--before")
	var old: Script = load(args[at + 1]) if at >= 0 else null
	for profile: Vector2 in [Vector2.ZERO, Vector2(0.4, 0), Vector2(-0.4, 0), Vector2(0, 0.5)]:
		var reference := ride(profile.x, profile.y, 120)
		print("PROFILE ", profile, " after=", reference)
		if old != null: print("BEFORE ", profile, " ", ride(profile.x, profile.y, 120, old))
		check(not reference.crashed and reference.heading < -0.03, "steers on profile %s" % profile)
		for hz in [30, 60]:
			var result := ride(profile.x, profile.y, hz)
			check(absf(result.heading - reference.heading) < 0.02 and absf(result.speed - reference.speed) < 0.1,
				"profile %s agrees at %d/120 Hz" % [profile, hz])

func run() -> void:
	if not "--geometry-only" in OS.get_cmdline_user_args(): check_steering()
	# Sample actual triangle edges against a conservative solid tyre envelope.
	var model := load("res://scenes/bike.tscn").instantiate() as BikeView
	root.add_child(model)
	var frame := model.get_node("Frame") as MeshInstance3D
	var minimum := INF
	for travel: float in [0.0, 0.08, BikeRide.SAG_MAX]:
		for steer: float in [-BikeView.STEER_VIEW, 0.0, BikeView.STEER_VIEW]:
			var inverse := Basis(Vector3.UP, steer).inverse()
			for surface in frame.mesh.get_surface_count():
				var data := frame.mesh.surface_get_arrays(surface)
				var vertices: PackedVector3Array = data[Mesh.ARRAY_VERTEX]
				var ids: PackedInt32Array = data[Mesh.ARRAY_INDEX] if data[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
				for tri in range(0, ids.size() if not ids.is_empty() else vertices.size(), 3):
					for edge in 3:
						var a: Vector3 = vertices[ids[tri + edge] if not ids.is_empty() else tri + edge]
						var c: Vector3 = vertices[ids[tri + (edge + 1) % 3] if not ids.is_empty() else tri + (edge + 1) % 3]
						var steps := maxi(1, ceili(a.distance_to(c) / 0.01))
						for sample in steps + 1:
							var point := inverse * (frame.transform * a.lerp(c, float(sample) / steps) - Vector3(0, BikeView.WHEEL_Y + travel, -BikeRide.HUB))
							var clearance := maxf(Vector2(point.y, point.z).length() - 0.354, absf(point.x) - 0.035)
							minimum = minf(minimum, clearance)
	print("FRAME minimum conservative clearance m=", minimum)
	check(minimum > 0.015, "frame clears front tyre at full travel and steering lock")
	check(BikeView.FORK_CROWN_Y - BikeView.WHEEL_Y - BikeRide.SAG_MAX - 0.036 - 0.354 > 0.005,
		"fork crown clears the compressed tyre")
	if "--capture" in OS.get_cmdline_user_args(): await capture(model)
	model.queue_free()
	await process_frame
	quit(1 if failures else 0)

func capture(model: BikeView) -> void:
	root.size = Vector2i(900, 600)
	var environment := WorldEnvironment.new()
	environment.environment = Environment.new()
	environment.environment.background_mode = Environment.BG_COLOR
	environment.environment.background_color = Color("b7c5cd")
	environment.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.environment.ambient_light_color = Color.WHITE
	environment.environment.ambient_light_energy = 0.7
	root.add_child(environment)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-40, -35, 0)
	root.add_child(sun)
	var camera := Camera3D.new()
	root.add_child(camera)
	camera.make_current()
	camera.fov = 40.0
	model.idle_life = false
	var state := BikeRide.new()
	state.riding = true
	var sheet := Image.create(1800, 1200, false, Image.FORMAT_RGB8)
	for i in 4:
		state.squash_f = BikeRide.SAG_MAX if i in [1, 2] else 0.0
		state.steer = 1.0 if i == 2 else 0.0
		model.snap(state)
		model.draw(1.0)
		camera.position = Vector3(3.0, 1.1, -0.15) if i < 2 else Vector3(2.1, 1.7, -1.95)
		camera.look_at(Vector3(0, 0.9, 0))
		await process_frame
		await process_frame
		await RenderingServer.frame_post_draw
		var shot := root.get_texture().get_image()
		shot.convert(Image.FORMAT_RGB8)
		sheet.blit_rect(shot, Rect2i(0, 0, 900, 600), Vector2i((i % 2) * 900, (i / 2) * 600))
	var error := sheet.save_png("res://.godot/bike_clearance.png")
	check(error == OK, "clearance contact sheet saved")
