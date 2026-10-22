extends SceneTree
## Падение с велосипеда (7.6): godot --headless --path . --script res://tools/bike_crash_test.gd
## Жёсткое приземление и падение с разгона: потеря равновесия → ragdoll лежит на земле → плавный возврат в седло.

const DT := 1.0 / 60.0

class FlatWorld extends WorldData:
	func accessible(_x: float, _z: float, _margin := 0.0) -> bool:
		return true
	func tile_info(_x: float, _z: float) -> Dictionary:
		return {biome = Biomes.GRASS, path = 0}

class FlatGround extends Heightfield:
	var slope := 0.0
	func _init(world_data: WorldData) -> void:
		super(world_data, false)
	func surface_at(_x: float, z: float, _feet := -INF) -> float:
		return 100.0 + z * slope
	func ground_at(_x: float, z: float, _raw := false) -> float:
		return 100.0 + z * slope
	func depth_at(_x: float, _z: float, _feet := -INF) -> float:
		return 0.0
	func known(_x: float, _z: float) -> bool:
		return true

var fails := 0
var w: WorldData
var heights: Heightfield
var player: PlayerState
var bike: BikeRide
var view: BikeView
var crash: BikeCrash
var case_i := 0
var cases: Array = [["с разгона 12 м/с", Vector3(0, -14, -12)], ["с места, падение сверху", Vector3(0, -16, 0)], ["быстро, 18 м/с", Vector3(0, -6, -18)]]
var frames := 0
var phases := {}
var lowest_head := INF
var max_hips_y := -INF
var start_at := Vector3()
var lie_at := Vector3()
var bike_tipped := false
var finite := true
var last_hips := Vector3()
var max_jump := 0.0
var started := false
var capture := "--capture" in OS.get_cmdline_user_args()
var camera: Camera3D
var capture_ground: MeshInstance3D
var shots: Array = []  # [кадр, имя] — снимки с --capture
var flat := "--flat" in OS.get_cmdline_user_args()
var ground_slide := 0.0
var last_ground_hips := Vector3.INF
var crossed_tree := false
var pose_matches := true


func check(ok: bool, label: String) -> void:
	print(("ok   " if ok else "FAIL ") + label)
	if not ok:
		fails += 1


func _initialize() -> void:
	if flat:
		w = FlatWorld.new()
		heights = FlatGround.new(w)
		player = PlayerState.new()
		player.feet = 100.0
		bike = BikeRide.new()
		bike.y = 100.0
		cases.append_array([["в ствол", Vector3(0, 0, -12)], ["в бревно", Vector3(0, 0, -12)], ["в валун", Vector3(0, 0, -12)], ["на левый бок", Vector3(0, 0, -8)], ["на правый бок", Vector3(0, 0, -8)], ["задним ходом", Vector3(0, 0, 10)], ["на склоне", Vector3(0, 0, -12)]])
	else:
		w = WorldGenerator.generate("abc", 128)
		heights = Heightfield.new(w)
		player = PlayerState.spawn(w, heights)
		bike = BikeRide.park_near(player, 0.0, w, heights)
	bike.mount(player)
	view = load("res://scenes/bike.tscn").instantiate()
	root.add_child(view)
	crash = BikeCrash.new()
	root.add_child(crash)
	if capture:
		_setup_capture()
	# Порог падения: ровное приземление с 2 м держится, в лоб в подъём с той же силой — уже нет
	check(GameConfig.BIKE_CRASH - BikeRide.FACE_CRASH < 9.0 and GameConfig.BIKE_CRASH > 9.0, "в подъём роняет удар слабее, чем на ровном")


func _begin_case() -> void:
	if flat:
		bike.x = 0.0
		bike.z = 0.0
		bike.heading = 0.0
		(heights as FlatGround).slope = 0.2 if case_i == 9 else 0.0
		if heights.obstacles != null:
			heights.obstacles.heights = null
		heights.obstacles = ForestObstacles.new(w, heights)
		if case_i == 3:
			heights.obstacles._add(0, -1.8, 0, -1.8, 0.6, 100, INF)
		elif case_i == 4:
			heights.obstacles._add(-2, -2, 2, -2, 0.2, 100, 100.4)
		elif case_i == 5:
			heights.obstacles._add(0, -2, 0, -2, 0.6, 100, 101)
	bike.dismount(player, w, heights)
	bike.mount(player)
	if flat:
		bike.lean = -0.28 if case_i == 6 else (0.28 if case_i == 7 else 0.0)
	view.snap(bike)
	view.draw(1.0)
	if capture:
		_update_capture_ground()
	frames = 0
	phases.clear()
	lowest_head = INF
	max_hips_y = -INF
	bike_tipped = false
	finite = true
	max_jump = 0.0
	ground_slide = 0.0
	last_ground_hips = Vector3.INF
	crossed_tree = false
	pose_matches = true
	last_hips = Vector3.INF
	start_at = Vector3(bike.x, bike.y, bike.z)
	crash.start(view, bike, cases[case_i][1], heights)
	started = true


func _physics_process(_delta: float) -> bool:
	if not started:
		_begin_case()
		return false
	frames += 1
	phases[crash.phase] = true
	var back := crash.tick(DT, bike, w, heights)
	if crash.phase == BikeCrash.Phase.RAGDOLL:
		var skel: Skeleton3D = (view.rider as CyclistRig).skeleton
		var head: Vector3 = (skel.global_transform * skel.get_bone_global_pose(skel.find_bone("Head"))).origin
		var hips: Vector3 = crash.focus(bike) + Vector3(0, 0.5, 0)
		for bone_name: String in crash._bones:
			var physical: PhysicalBone3D = crash._bones[bone_name]
			var visible := skel.global_transform * skel.get_bone_global_pose(skel.find_bone(bone_name)) * physical.body_offset
			pose_matches = pose_matches and visible.origin.distance_to(physical.global_position) < 0.005
		lowest_head = minf(lowest_head, head.y - heights.surface_at(head.x, head.z, head.y + 1.0))
		max_hips_y = maxf(max_hips_y, hips.y)
		lie_at = hips
		finite = finite and is_finite(head.y) and is_finite(hips.x)
		bike_tipped = bike_tipped or view.global_transform.basis.y.y < 0.7
		if crash.phase == BikeCrash.Phase.RAGDOLL:
			if hips.y - heights.surface_at(hips.x, hips.z, hips.y + 1) < 0.55:
				if last_ground_hips != Vector3.INF:
					ground_slide += Vector2(hips.x - last_ground_hips.x, hips.z - last_ground_hips.z).length()
				last_ground_hips = hips
			if flat and case_i == 3:
				crossed_tree = crossed_tree or (absf(hips.x) < 0.5 and hips.z < -1.8)
	if crash.phase == BikeCrash.Phase.RECOVER:
		crash.draw()
		var skel: Skeleton3D = (view.rider as CyclistRig).skeleton
		var hips: Vector3 = (skel.global_transform * skel.get_bone_global_pose(skel.find_bone("Hips"))).origin
		if last_hips != Vector3.INF:
			max_jump = maxf(max_jump, hips.distance_to(last_hips))
			if OS.has_environment("CRASH_DEBUG"): print("  %.2f %.3f %s" % [crash.t, hips.distance_to(last_hips), hips])
		last_hips = hips
	if capture:
		var cam_at: Vector3 = crash.focus(bike)
		camera.look_at_from_position(cam_at + Vector3(3.2, 2.2, 3.2), cam_at + Vector3(0, 0.5, 0))
		if crash.phase == BikeCrash.Phase.BALANCE and crash.t > 0.15 and not phases.has("b"):
			phases["b"] = true
			shots.append(str(case_i) + "_balance")
		elif crash.phase == BikeCrash.Phase.RAGDOLL and crash.t > 0.5 and not phases.has("r"):
			phases["r"] = true
			shots.append(str(case_i) + "_ragdoll")
		elif crash.phase == BikeCrash.Phase.RAGDOLL and crash.t > 0.8 and crash._settled_time > 0.05 and not phases.has("l"):
			phases["l"] = true
			shots.append(str(case_i) + "_lying")
		elif crash.phase == BikeCrash.Phase.RECOVER and crash.t > 0.2 and not phases.has("u"):
			phases["u"] = true
			shots.append(str(case_i) + "_recover")
	if back or frames > 600:
		_finish_case(back)
	return false


func _finish_case(back: bool) -> void:
	var name: String = cases[case_i][0]
	var v: Vector3 = cases[case_i][1]
	var seconds := frames * DT
	check(back and seconds < 3.6, "%s: снова в седле через %.2f с" % [name, seconds])
	check(phases.has(BikeCrash.Phase.BALANCE) and phases.has(BikeCrash.Phase.RAGDOLL) and phases.has(BikeCrash.Phase.RECOVER), "%s: потеря равновесия → ragdoll → возврат" % name)
	check(finite, "%s: позы конечны" % name)
	check(pose_matches, "%s: видимые кости совпадают с физическими телами" % name)
	var head_limit := 0.7 if flat and case_i == 4 else 0.45 # голова может лежать на бревне
	check(lowest_head < head_limit, "%s: тело легло на землю (голова в %.2f м над землёй)" % [name, lowest_head])
	check(lowest_head > -0.05, "%s: голова не провалилась под поверхность" % name)
	var flew := Vector2(lie_at.x - start_at.x, lie_at.z - start_at.z).length()
	var want := Vector2(v.x, v.z).length() * 0.12 if not flat or case_i < 3 else 0.0
	check(flew >= want, "%s: тело пролетело по инерции %.1f м (нужно ≥ %.1f)" % [name, flew, want])
	check(bike_tipped, "%s: велосипед завалился набок" % name)
	check(max_jump < 0.25, "%s: возврат в седло плавный (шаг таза за такт %.3f м)" % [name, max_jump])
	check(view.rider.get_parent() == view and (view.rider as CyclistRig).skeleton.get_child_count() > 0 and not _has_sim(), "%s: седок снова на велосипеде, физика убрана" % name)
	check(bike.riding and not bike.airborne and absf(bike.y - heights.surface_at(bike.x, bike.z, bike.y + 1.0)) < 0.05, "%s: велосипед стоит на земле" % name)
	if flat and case_i in [0, 2]:
		check(ground_slide > 0.05 and ground_slide < 3.0, "%s: короткое скольжение по земле %.2f м" % [name, ground_slide])
	if flat and case_i == 3:
		check(not crossed_tree, "при падении таз не прошёл насквозь через ствол")
	case_i += 1
	if case_i >= cases.size():
		print("FAILS: %d" % fails)
		if heights.obstacles != null:
			heights.obstacles.heights = null
			heights.obstacles = null
		quit(1 if fails > 0 else 0)
		return
	_begin_case()


func _has_sim() -> bool:
	for c: Node in (view.rider as CyclistRig).skeleton.get_children():
		if c is PhysicalBoneSimulator3D:
			return true
	return false


func _process(_delta: float) -> bool:
	if not shots.is_empty():
		# снимок предыдущего кадра: отрисовка отстаёт от такта на кадр
		root.get_texture().get_image().save_png("res://tools/control/runs/crash_89plus_%s.png" % shots.pop_front())
	return false


## Снимки (godot --path . --rendering-method gl_compatibility --script res://tools/bike_crash_test.gd -- --capture):
## земля — отладочная сетка куска рельефа под падением
func _setup_capture() -> void:
	camera = Camera3D.new()
	root.add_child(camera)
	var light := DirectionalLight3D.new()
	root.add_child(light)
	light.rotation_degrees = Vector3(-50, -30, 0)
	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	env.environment.background_mode = Environment.BG_COLOR
	env.environment.background_color = Color("a6bbc5")
	env.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.environment.ambient_light_color = Color.WHITE
	env.environment.ambient_light_energy = 0.6
	root.add_child(env)
	capture_ground = MeshInstance3D.new()
	root.add_child(capture_ground)
	_update_capture_ground()


func _update_capture_ground() -> void:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var cx := roundf(bike.x)
	var cz := roundf(bike.z)
	for j in range(-30, 30):
		for i in range(-30, 30):
			var quad: Array[Vector3] = []
			for d: Vector2 in [Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, 0), Vector2(1, 1), Vector2(0, 1)]:
				var px := cx + i + d.x
				var pz := cz + j + d.y
				quad.append(Vector3(px, heights.surface_at(px, pz, bike.y + 1.0), pz))
			for v: Vector3 in quad:
				st.add_vertex(v)
	st.generate_normals()
	capture_ground.mesh = st.commit()
