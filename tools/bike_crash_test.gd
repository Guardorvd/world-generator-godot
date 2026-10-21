extends SceneTree
## Падение с велосипеда (7.6): godot --headless --path . --script res://tools/bike_crash_test.gd
## Жёсткое приземление и падение с разгона: потеря равновесия → ragdoll лежит на земле → плавный возврат в седло.

const DT := 1.0 / 60.0

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
var shots: Array = []  # [кадр, имя] — снимки с --capture


func check(ok: bool, label: String) -> void:
	print(("ok   " if ok else "FAIL ") + label)
	if not ok:
		fails += 1


func _initialize() -> void:
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
	bike.dismount(player, w, heights)
	bike.mount(player)
	view.snap(bike)
	view.draw(1.0)
	frames = 0
	phases.clear()
	lowest_head = INF
	max_hips_y = -INF
	bike_tipped = false
	finite = true
	max_jump = 0.0
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
	var was := crash.phase
	var back := crash.tick(DT, bike, w, heights)
	if was == BikeCrash.Phase.RAGDOLL:
		var skel: Skeleton3D = (view.rider as CyclistRig).skeleton
		var head: Vector3 = (skel.global_transform * skel.get_bone_global_pose(skel.find_bone("Head"))).origin
		var hips: Vector3 = crash.focus(bike) + Vector3(0, 0.5, 0)
		lowest_head = minf(lowest_head, head.y - heights.surface_at(head.x, head.z, head.y + 1.0))
		max_hips_y = maxf(max_hips_y, hips.y)
		lie_at = hips
		finite = finite and is_finite(head.y) and is_finite(hips.x)
		bike_tipped = bike_tipped or view.global_transform.basis.y.y < 0.7
	if crash.phase == BikeCrash.Phase.RECOVER:
		crash.draw()
		var skel: Skeleton3D = (view.rider as CyclistRig).skeleton
		var hips: Vector3 = (skel.global_transform * skel.get_bone_global_pose(skel.find_bone("Hips"))).origin
		if last_hips != Vector3.INF:
			max_jump = maxf(max_jump, hips.distance_to(last_hips))
			if OS.has_environment("CRASH_DEBUG"): print("  %.2f %.3f %s" % [crash.t, hips.distance_to(last_hips), hips])
		last_hips = hips
	if capture and case_i == 0:
		var cam_at: Vector3 = crash.focus(bike)
		camera.look_at_from_position(cam_at + Vector3(3.2, 2.2, 3.2), cam_at + Vector3(0, 0.5, 0))
		if crash.phase == BikeCrash.Phase.BALANCE and crash.t > 0.15 and not phases.has("b"):
			phases["b"] = true
			shots.append("balance")
		elif crash.phase == BikeCrash.Phase.RAGDOLL and crash.t > 0.5 and not phases.has("r"):
			phases["r"] = true
			shots.append("ragdoll")
		elif crash.phase == BikeCrash.Phase.RECOVER and crash.t > 0.2 and not phases.has("u"):
			phases["u"] = true
			shots.append("recover")
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
	check(lowest_head < 0.45, "%s: тело легло на землю (голова в %.2f м над землёй)" % [name, lowest_head])
	var flew := Vector2(lie_at.x - start_at.x, lie_at.z - start_at.z).length()
	var want := Vector2(v.x, v.z).length() * 0.12
	check(flew >= want, "%s: тело пролетело по инерции %.1f м (нужно ≥ %.1f)" % [name, flew, want])
	check(bike_tipped, "%s: велосипед завалился набок" % name)
	check(max_jump < 0.25, "%s: возврат в седло плавный (шаг таза за такт %.3f м)" % [name, max_jump])
	check(view.rider.get_parent() == view and (view.rider as CyclistRig).skeleton.get_child_count() > 0 and not _has_sim(), "%s: седок снова на велосипеде, физика убрана" % name)
	check(bike.riding and not bike.airborne and absf(bike.y - heights.surface_at(bike.x, bike.z, bike.y + 1.0)) < 0.05, "%s: велосипед стоит на земле" % name)
	case_i += 1
	if case_i >= cases.size():
		print("FAILS: %d" % fails)
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
		root.get_texture().get_image().save_png("res://tools/control/runs/crash_76_%s.png" % shots.pop_front())
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
	var ground := MeshInstance3D.new()
	ground.mesh = st.commit()
	root.add_child(ground)
