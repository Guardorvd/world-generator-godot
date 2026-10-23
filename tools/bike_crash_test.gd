extends SceneTree
## Падение с велосипеда (7.6): godot --headless --path . --script res://tools/bike_crash_test.gd
## Потеря равновесия → ragdoll → подъём пешком; лежащая рама, ручная посадка и повторные падения.

const DT := 1.0 / 60.0

class FlatWorld extends WorldData:
	var road_surface_kind := RoadSurface.NONE
	func accessible(_x: float, _z: float, _margin := 0.0) -> bool:
		return true
	func tile_info(_x: float, _z: float) -> Dictionary:
		return {biome = Biomes.GRASS, path = 3 if road_surface_kind != RoadSurface.NONE else 0, surface = road_surface_kind}

class FlatGround extends Heightfield:
	var slope := 0.0
	var water := false
	var water_depth := 1.0
	func _init(world_data: WorldData) -> void:
		super()
		world = world_data # синтетическая опора не требует массивов генератора
	func surface_at(x: float, z: float, feet := -INF) -> float:
		return maxf(100.0 + z * slope, deck_at(x, z, feet))
	func ground_at(_x: float, z: float, _raw := false) -> float:
		return 100.0 + z * slope
	func depth_at(x: float, z: float, feet := -INF) -> float:
		if feet > -INF and deck_at(x, z, feet) > -INF:
			return 0.0
		return water_depth if water and absf(x - 32.0) < 3.0 and absf(z - 32.0) < 8.0 else 0.0
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
var crossed_wall := false
var max_hips_y := -INF
var start_at := Vector3()
var lie_at := Vector3()
var bike_tipped := false
var finite := true
var started := false
var capture := "--capture" in OS.get_cmdline_user_args()
var camera: Camera3D
var capture_ground: MeshInstance3D
var capture_objects: Node3D
var environment_checked := false
var shots: Array = []  # [кадр, имя] — снимки с --capture
var flat := "--flat" in OS.get_cmdline_user_args()
var ground_slide := 0.0
var last_ground_hips := Vector3.INF
var crossed_tree := false
var pose_matches := true
var recovery_stable := true


func check(ok: bool, label: String) -> void:
	print(("ok   " if ok else "FAIL ") + label)
	if not ok:
		fails += 1


func _initialize() -> void:
	if flat:
		w = FlatWorld.new()
		w.W = 64
		w.H = 64
		w.N = 4096
		heights = FlatGround.new(w)
		player = PlayerState.new()
		player.feet = 100.0
		bike = BikeRide.new()
		bike.y = 100.0
		cases.append_array([["в ствол", Vector3(0, 0, -12)], ["в бревно", Vector3(0, 0, -12)], ["в валун", Vector3(0, 0, -12)], ["на левый бок", Vector3(0, 0, -8)], ["на правый бок", Vector3(0, 0, -8)], ["задним ходом", Vector3(0, 0, 10)], ["на склоне", Vector3(0, 0, -12)]])
		cases.append_array([["стена дома", Vector3(0, 0, -12)], ["настил моста", Vector3(0, -6, -10)], ["под мостом", Vector3(0, 0, -8)], ["стена туннеля", Vector3(12, 0, 0)], ["вода у берега", Vector3(6, -6, -8)], ["с края досок", Vector3(6, 0, 0)]])
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
		bike.crash_cause = BikeRide.CrashCause.FALL
		bike.crash_normal = Vector3.UP
		w.settlements.clear()
		w.sites.clear()
		heights.structures.clear()
		heights._cells.clear()
		(heights as FlatGround).water = case_i == 14
		(heights as FlatGround).slope = 0.2 if case_i == 9 else 0.0
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
	if flat and case_i >= 10:
		bike.x = 32
		bike.z = 32
		if case_i == 10:
			w.settlements.append({x = 8.0, y = 7.5, huts = [{x = 8.0, y = 7.5, a = 0.0, v = 0, t = "house"}]})
			bike.crash_cause = BikeRide.CrashCause.COLLISION
			bike.crash_normal = Vector3.BACK
		if case_i in [11, 12, 13, 15]:
			var tunnel := case_i == 13
			var level_y := 100.0 if tunnel else (103.0 if case_i == 15 else 104.0)
			heights.structures.append({tunnel = tunnel, ax = 32.0, az = 16.0, ay = level_y, bx = 32.0, bz = 48.0, by = level_y, len = 32.0, ux = 0.0, uz = 1.0, half = 2.5 if tunnel else (0.9 if case_i == 15 else 2.2), arch = 0.0, style = "planks" if case_i == 15 else "wood", rails = case_i != 15})
			for z in range(3, 14):
				for x in range(6, 11):
					heights._cells[z * w.W + x] = [0]
		if case_i == 13:
			bike.x = 33
			bike.heading = -PI * 0.5
			bike.crash_cause = BikeRide.CrashCause.COLLISION
			bike.crash_normal = Vector3.LEFT
		if case_i == 15:
			bike.heading = -PI * 0.5
		bike.y = 104.0 if case_i == 11 else (103.0 if case_i == 15 else 100.0)
	view.snap(bike)
	view.draw(1.0)
	if capture:
		_update_capture_ground()
	frames = 0
	environment_checked = false
	phases.clear()
	lowest_head = INF
	crossed_wall = false
	max_hips_y = -INF
	bike_tipped = false
	finite = true
	ground_slide = 0.0
	last_ground_hips = Vector3.INF
	crossed_tree = false
	pose_matches = true
	recovery_stable = true
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
		if not environment_checked and crash.t > 0.1:
			environment_checked = true
			_check_environment()
		var head: Vector3 = (skel.global_transform * skel.get_bone_global_pose(skel.find_bone("Head"))).origin
		var hips: Vector3 = crash.focus(bike) + Vector3(0, 0.5, 0)
		for bone_name: String in crash._bones:
			var physical: PhysicalBone3D = crash._bones[bone_name]
			var visible := skel.global_transform * skel.get_bone_global_pose(skel.find_bone(bone_name)) * physical.body_offset
			pose_matches = pose_matches and visible.origin.distance_to(physical.global_position) < 0.005
		lowest_head = minf(lowest_head, head.y - crash._support_height(head, heights))
		max_hips_y = maxf(max_hips_y, hips.y)
		if flat and case_i == 10:
			crossed_wall = crossed_wall or (absf(hips.x - 32.0) < 1.5 and hips.z < 31.5)
		if flat and case_i == 13:
			crossed_wall = crossed_wall or hips.x > 35.0
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
		var held := view.rider.capture_pose()
		var held_view := view.global_transform
		crash.draw()
		recovery_stable = recovery_stable and held_view.is_equal_approx(view.global_transform)
		var repeated := view.rider.capture_pose()
		for i in held.size():
			recovery_stable = recovery_stable and held[i].is_equal_approx(repeated[i])
	if capture:
		var cam_at: Vector3 = crash.focus(bike)
		if crash.phase == BikeCrash.Phase.RECOVER:
			camera.look_at_from_position(cam_at + Vector3.UP * GameConfig.EYE, bike.fallen_transform.origin + Vector3.UP * 0.3)
			if case_i in [0, 11] and crash.t > 0.2 and not phases.has("fp"):
				phases["fp"] = true
				shots.append(str(case_i) + "_first_person")
		else:
			camera.look_at_from_position(cam_at + Vector3(3.2, 2.2, 3.2), cam_at + Vector3(0, 0.5, 0))
		if flat and case_i in [10, 15] and crash.phase == BikeCrash.Phase.RAGDOLL and crash.t > 0.5 and not phases.has("r"):
			phases["r"] = true
			shots.append(str(case_i) + "_ragdoll")
	if back or frames > 600:
		_finish_case(back)
	return false


func _finish_case(back: bool) -> void:
	var name: String = cases[case_i][0]
	var v: Vector3 = cases[case_i][1]
	var seconds := frames * DT
	check(back and seconds < 3.6, "%s: пешее управление через %.2f с" % [name, seconds])
	check(phases.has(BikeCrash.Phase.BALANCE) and phases.has(BikeCrash.Phase.RAGDOLL) and phases.has(BikeCrash.Phase.RECOVER), "%s: потеря равновесия → ragdoll → подъём" % name)
	check(finite, "%s: позы конечны" % name)
	check(pose_matches, "%s: видимые кости совпадают с физическими телами" % name)
	var head_limit := 1.4 if flat and case_i == 14 else (0.7 if flat and case_i == 4 else 0.45) # голова может лежать на бревне
	check(lowest_head < head_limit, "%s: тело легло на землю (голова в %.2f м над землёй)" % [name, lowest_head])
	check(lowest_head > -0.05, "%s: голова не провалилась под поверхность" % name)
	var flew := Vector2(lie_at.x - start_at.x, lie_at.z - start_at.z).length()
	var want := Vector2(v.x, v.z).length() * 0.12 if not flat or case_i < 3 else 0.0
	check(flew >= want, "%s: тело пролетело по инерции %.1f м (нужно ≥ %.1f)" % [name, flew, want])
	# Вода гасит импульс: рама может остаться на колёсах, это допустимый исход.
	if not flat or case_i != 14:
		check(bike_tipped, "%s: велосипед завалился набок" % name)
	check(recovery_stable, "%s: повторная отрисовка восстановления не меняет позу" % name)
	check(view.rider.procedural_pose, "%s: процедурная анимация восстановлена" % name)
	check(not view.rider.visible and view.global_transform.is_equal_approx(bike.fallen_transform), "%s: рама сохранена, сидящего дубля игрока нет" % name)
	check(view.rider.get_parent() == view and (view.rider as CyclistRig).skeleton.get_child_count() > 0 and not _has_sim(), "%s: модель возвращена владельцу, временная физика убрана" % name)
	check(PlayerState.is_passable(w, heights, crash.standing_position.x, crash.standing_position.z, crash.standing_position.y, PlayerState.BODY_R), "%s: игрок встал в свободном месте" % name)
	if flat and case_i in [10, 13]:
		check(not crossed_wall, "%s: тело не прошло сквозь стену" % name)
	if flat and case_i == 12:
		check(max_hips_y < 103.0, "под мостом тело не вытолкнуто на настил")
	check(not bike.riding and bike.fallen and not bike.airborne, "%s: игрок пешком, велосипед лежит отдельно" % name)
	if not flat or case_i < 3:
		check(Vector2(crash.standing_position.x - lie_at.x, crash.standing_position.z - lie_at.z).length() < 0.4, "%s: встаём у тела, не у велосипеда" % name)
	var parked := bike.fallen_transform
	player.x = crash.standing_position.x
	player.z = crash.standing_position.z
	player.feet = crash.standing_position.y
	player.vx = 0.0
	player.vy = 0.0
	player.vz = 0.0
	player.on_ground = true
	player.step(1, 0, false, false, 0, DT, w, heights)
	view.tick(bike)
	view.draw(0.5)
	check(view.global_transform.is_equal_approx(parked), "%s: пешее движение не поднимает и не перемещает раму" % name)
	if flat and case_i in [0, 2]:
		check(ground_slide > 0.05 and ground_slide < 3.0, "%s: короткое скольжение по земле %.2f м" % [name, ground_slide])
	if flat and case_i == 3:
		check(not crossed_tree, "при падении таз не прошёл насквозь через ствол")
	case_i += 1
	if case_i >= cases.size():
		if flat:
			_check_on_foot()
			_check_impact_contract()
		_check_lifecycle()
		print("FAILS: %d" % fails)
		quit(1 if fails > 0 else 0)
		return
	_begin_case()


func _check_on_foot() -> void:
	var test_world := FlatWorld.new()
	test_world.W = 64
	test_world.H = 64
	var ground := FlatGround.new(test_world)
	var p := PlayerState.new()
	p.feet = 100.0
	p.x = 5.0
	var b := BikeRide.new()
	b.y = 100.0
	b.fallen = true
	b.fallen_transform = Transform3D(Basis(Vector3.FORWARD, 1.4), Vector3(0, 100, 0))
	var parked := b.fallen_transform
	check(not b.prepare_mount(p, test_world, ground) and b.fallen_transform == parked, "дальняя посадка не притягивает велосипед")
	for i in 180:
		if b.can_mount(p):
			break
		p.step(1, 0, false, false, PI * 0.5, DT, test_world, ground)
	check(b.can_mount(p) and b.fallen and not b.riding, "к лежащему велосипеду можно подойти пешком")
	check(b.prepare_mount(p, test_world, ground), "на свободной земле раму можно поднять")
	b.mount(p)
	check(b.riding and not b.fallen and p.vx == 0 and p.vz == 0, "ручная посадка возвращает езду без пешей инерции")
	b.step(p, 1, 0, false, false, DT, test_world, ground)
	check(not b.crashed, "после подъёма нет повторного удара от старого состояния")
	b.reset_motion()
	b.fallen = true
	p.x = b.x
	p.z = b.z
	p.feet = b.y - 4.0
	check(not b.prepare_mount(p, test_world, ground), "нельзя сесть с другого уровня моста")
	p.feet = b.y
	p.on_ground = false
	check(not b.prepare_mount(p, test_world, ground), "нельзя поднять велосипед в прыжке")
	p.on_ground = true
	test_world.sites.append({x = 0.0, y = 0.0, huts = [{x = 0.0, y = 0.0, a = 0.0, t = "house"}]})
	check(not b.prepare_mount(p, test_world, ground) and b.fallen and not b.riding, "заблокированная посадка сохраняет лежащую раму")
	test_world.sites.clear()
	ground.obstacles = ForestObstacles.new(test_world, ground)
	ground.obstacles._add(0, -10, 0, 10, 0.1, 100, INF)
	b.x = 0.8
	b.z = 0.0
	p.x = -0.8
	p.z = 0.0
	check(not b.prepare_mount(p, test_world, ground) and b.x == 0.8, "при подъёме нельзя перенести раму на свою сторону стены")
	# Камера после рэгдолла использует координаты пешехода, даже если рама далеко.
	var game := GameWorld.new()
	game.player = p
	game.bike = b
	game.camera = Camera3D.new()
	game.add_child(game.camera)
	game._prev = Vector3(p.x, p.feet, p.z)
	game._update_camera(1.0, DT)
	check(game.camera.position.is_equal_approx(Vector3(p.x, p.feet + GameConfig.EYE, p.z)), "после падения камера от первого лица на месте игрока")
	game.free()


func _check_environment() -> void:
	if not flat or case_i < 10:
		return
	var space := crash.get_world_3d().direct_space_state
	if case_i == 10:
		var wall := space.intersect_ray(PhysicsRayQueryParameters3D.create(Vector3(32, 101, 32), Vector3(32, 101, 28), BikeCrash.LAYER_GROUND))
		check(not wall.is_empty() and absf(wall.position.z - 31.6) < 0.03, "коллайдер дома совпадает с границей PlayerState")
	if case_i == 11:
		var deck := space.intersect_ray(PhysicsRayQueryParameters3D.create(Vector3(32, 105, 30.13), Vector3(32, 102, 30.13), BikeCrash.LAYER_GROUND))
		check(not deck.is_empty() and absf(deck.position.y - 104.0) < 0.03, "верх настила совпадает с Heightfield.level: %s" % deck.get("position", "нет контакта"))
	if case_i == 12:
		var clear := space.intersect_ray(PhysicsRayQueryParameters3D.create(Vector3(32, 102, 30), Vector3(32, 103.5, 30), BikeCrash.LAYER_GROUND))
		check(clear.is_empty(), "под мостом нет ложной стены из карты высот")
	if case_i == 13:
		var ceiling := space.intersect_ray(PhysicsRayQueryParameters3D.create(Vector3(32, 103, 30), Vector3(32, 106, 30), BikeCrash.LAYER_GROUND))
		check(not ceiling.is_empty() and absf(ceiling.position.y - 104.5) < 0.03, "свод туннеля совпадает с Heightfield.TUNNEL_HEIGHT")
	if case_i == 15:
		var rail := space.intersect_ray(PhysicsRayQueryParameters3D.create(Vector3(32, 104, 30), Vector3(34, 104, 30), BikeCrash.LAYER_GROUND))
		check(rail.is_empty(), "у дощатой переправы нет выдуманных перил")


func _check_impact_contract() -> void:
	var saved_structures := heights.structures.duplicate()
	var saved_cells := heights._cells.duplicate()
	heights.structures.clear()
	heights._cells.clear()
	w.settlements.append({x = 8.0, y = 7.0, huts = [{x = 8.0, y = 7.0, a = 0.0, v = 0, t = "house"}]})
	for in_air in [false, true]:
		var moving := BikeRide.new()
		moving.x = 32
		moving.z = 32
		moving.y = 100.4 if in_air else 100.0
		moving.speed = 16
		moving.riding = true
		moving.airborne = in_air
		for i in 20:
			moving.step(player, 0, 0, false, false, DT, w, heights)
			if moving.crashed:
				break
		check(moving.crashed and moving.crash_cause == BikeRide.CrashCause.COLLISION and moving.crash_normal.z > 0.8, "езда распознаёт стену и нормаль удара, прыжок=%s" % in_air)
	w.settlements.clear()
	(heights as FlatGround).water = true
	(heights as FlatGround).water_depth = GameConfig.FORD_DEPTH + 0.5
	check(not PlayerState.is_passable(w, heights, 32, 32, 100.0, 0.3) and PlayerState.is_passable(w, heights, 32, 32, 100.0, 0.3, true), "глубокая вода блокирует езду, но не считается твёрдой стеной")
	(heights as FlatGround).water = false
	(heights as FlatGround).water_depth = 1.0
	heights.structures = saved_structures
	heights._cells = saved_cells
	var sample := BikeRide.new()
	sample.speed = 12
	sample._crash(-2, Vector3.BACK, BikeRide.CrashCause.COLLISION)
	check(sample.crash_cause == BikeRide.CrashCause.COLLISION and sample.crash_normal == Vector3.BACK and sample.crash_velocity.z == -12, "удар хранит причину, нормаль и исходную скорость")
	view.snap(bike)
	view.draw(1)
	bike.crash_cause = BikeRide.CrashCause.COLLISION
	bike.crash_normal = Vector3.BACK
	crash.start(view, bike, Vector3(0, 0, -12), heights)
	check(crash.style == BikeCrash.FallStyle.OVER_BARS, "лобовой удар выбирает опрокидывание через руль")
	crash.abort()
	crash.start(view, bike, Vector3(12, 0, -4), heights)
	check(crash.style == BikeCrash.FallStyle.GLANCING, "косой удар выбирает скользящее падение")
	crash.abort()
	bike.crash_cause = BikeRide.CrashCause.FALL
	bike.lean = 0.28
	crash.start(view, bike, Vector3(0, -5, -8), heights)
	check(crash.style == BikeCrash.FallStyle.SIDE_SLIDE, "крен выбирает боковой завал")
	crash.abort()
	bike.lean = 0
	var water_velocity := BikeCrash._water_velocity(Vector3(10, -10, 0), 1.0, DT)
	check(water_velocity.x < 10 and water_velocity.y > -10, "вода гасит пролёт и падение")
	(heights.world as FlatWorld).road_surface_kind = RoadSurface.DIRT
	var dirt_drag := BikeCrash._surface_drag(Vector3.ZERO, heights)
	(heights.world as FlatWorld).road_surface_kind = RoadSurface.SAND
	check(BikeCrash._surface_drag(Vector3.ZERO, heights) < dirt_drag, "покрытие использует сцепление RoadSurface")
	(heights.world as FlatWorld).road_surface_kind = RoadSurface.NONE


## Переходы и владение позой проверяем в той же изолированной сцене.
func _check_lifecycle() -> void:
	var rig := view.rider
	var player_animation := rig.get_node("AnimationPlayer") as AnimationPlayer
	var original := rig.capture_pose()
	# Неполный снимок и NaN не должны менять скелет частично.
	var short_pose: Array[Transform3D] = [Transform3D.IDENTITY]
	rig.restore_pose(short_pose)
	rig.pose(NAN, 0, Vector3.ZERO, Vector3.ZERO)
	check(rig.capture_pose() == original, "неверные данные анимации оставляют позу целой")
	for target_phase in [BikeCrash.Phase.BALANCE, BikeCrash.Phase.RAGDOLL, BikeCrash.Phase.RECOVER]:
		crash.start(view, bike, Vector3(0, 0, -8), heights)
		check(not rig.procedural_pose and not player_animation.active, "рэгдолл блокирует обоих авторов анимации")
		crash.tick(0, bike, w, heights)
		crash.tick(NAN, bike, w, heights)
		check(crash.t == 0, "неверное время не сдвигает падение")
		if target_phase >= BikeCrash.Phase.RAGDOLL:
			crash._begin_ragdoll()
		if target_phase == BikeCrash.Phase.RECOVER:
			crash._begin_recover(bike, w, heights)
		var held := rig.capture_pose()
		rig.pose(2, 0.2, Vector3.ZERO, Vector3.ZERO)
		check(rig.capture_pose() == held, "процедурная поза не перезаписывает фазу %s" % target_phase)
		crash.abort()
		crash.abort()
		check(not crash.active() and rig.get_parent() == view and not _has_sim() and crash._bones.is_empty(), "прерывание фазы %s возвращает седока и убирает физику" % target_phase)
		check(rig.procedural_pose and player_animation.active, "прерывание возвращает прежнее управление анимацией")
		check(crash._seated_pose.is_empty(), "снимки падения освобождены")
	check(crash.focus(bike).is_finite() and not crash.tick(DT, bike, w, heights), "завершённое падение безопасно для камеры и tick")
	# Внешняя анимация была выключена до падения — такой и должна остаться.
	rig.procedural_pose = false
	player_animation.active = false
	crash.start(view, bike, Vector3.ZERO, heights)
	crash._begin_ragdoll()
	crash._begin_recover(bike, w, heights)
	crash.tick(crash._recover_time, bike, w, heights)
	check(not rig.procedural_pose and not player_animation.active, "возврат сохраняет исходно выключенную анимацию")
	rig.procedural_pose = true
	player_animation.active = true
	# Новый start должен полностью убрать прежнее падение, даже при отделённом седоке.
	crash.start(view, bike, Vector3.ZERO, heights)
	crash._begin_ragdoll()
	crash.start(view, bike, Vector3.ZERO, heights)
	check(crash.phase == BikeCrash.Phase.BALANCE and not _has_sim() and rig.get_parent() == view, "повторный start освобождает прежний рэгдолл")
	crash.abort()


func _has_sim() -> bool:
	for c: Node in (view.rider as CyclistRig).skeleton.get_children():
		if c is PhysicalBoneSimulator3D:
			return true
	return false


func _process(_delta: float) -> bool:
	if not shots.is_empty():
		# снимок предыдущего кадра: отрисовка отстаёт от такта на кадр
		root.get_texture().get_image().save_png("res://tools/control/runs/crash_109_%s.png" % shots.pop_front())
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
	capture_objects = Node3D.new()
	root.add_child(capture_objects)
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
				quad.append(Vector3(px, heights.ground_at(px, pz), pz))
			for v: Vector3 in quad:
				st.add_vertex(v)
	st.generate_normals()
	capture_ground.mesh = st.commit()
	for child in capture_objects.get_children():
		child.queue_free()
	StructuresBuilder.build(capture_objects, heights)
	for settlement: Dictionary in w.settlements:
		for hut: Dictionary in settlement.huts:
			var visual := MeshInstance3D.new()
			var box := BoxMesh.new()
			var half := PlayerState.hut_half(hut)
			box.size = Vector3(half.x * 2, 2.5, half.y * 2)
			visual.mesh = box
			visual.position = Vector3(hut.x * GameConfig.TILE, heights.ground_at(hut.x * GameConfig.TILE, hut.y * GameConfig.TILE) + 1.25, hut.y * GameConfig.TILE)
			visual.rotation.y = PlayerState.hut_angle(settlement, hut)
			capture_objects.add_child(visual)
