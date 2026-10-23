extends SceneTree
## 10.9+: Y, безопасное место, прерывание падения и пограничные случаи посадки.

class TestWorld extends WorldData:
	func tile_info(_x: float, _z: float) -> Dictionary:
		return {biome = Biomes.GRASS, path = 0, surface = RoadSurface.NONE}

class TestGround extends Heightfield:
	var flooded := false
	var wet_before := -INF
	var cliff := false
	var gap := false
	var roof := INF
	func _init(w: WorldData) -> void:
		super()
		world = w
	func ground_at(x: float, _z: float, _raw := false) -> float:
		return 80.0 if (cliff and x >= 40.0) or (gap and absf(x - 40.0) < 0.3) else 100.0
	func surface_at(x: float, z: float, feet := -INF) -> float:
		return maxf(ground_at(x, z), deck_at(x, z, feet))
	func depth_at(x: float, z: float, feet := -INF) -> float:
		return 0.0 if deck_at(x, z, feet) > -INF else (2.0 if flooded or x < wet_before else 0.0)
	func known(x: float, z: float) -> bool:
		return x >= 4.0 and z >= 4.0 and x < 252.0 and z < 252.0
	func ceiling_at(x: float, z: float, feet: float) -> float:
		return minf(roof, super.ceiling_at(x, z, feet))

var fails := 0
var w: TestWorld
var h: TestGround


func check(ok: bool, label: String) -> void:
	print(("ok   " if ok else "FAIL ") + label)
	if not ok:
		fails += 1


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	w = TestWorld.new()
	w.W = 64
	w.H = 64
	w.N = 4096
	h = TestGround.new(w)
	h.obstacles = ForestObstacles.new(w, h)
	w.settlements = [{x = 30.0, y = 10.0, name = "Дальнее", huts = []}]
	w.sites = [{x = 10.0, y = 10.0, name = "Башня", huts = []}]
	var before := h.obstacles
	var spot := BikeRecovery.find(w, h, Vector3(44, 90, 40), 0.0)
	check(not spot.is_empty() and spot.name == "Башня", "выбрано ближайшее уникальное место без дорог и истории посещений")
	check(h.obstacles == before and before.data.is_empty(), "поиск не меняет действующий кэш препятствий")
	h.wet_before = 80.0
	spot = BikeRecovery.find(w, h, Vector3(44, 90, 40), 0.0)
	check(not spot.is_empty() and spot.name == "Дальнее", "затопленное место пропускается в пользу безопасного поселения")
	h.flooded = true
	check(BikeRecovery.find(w, h, Vector3(44, 100, 40), 0.0).is_empty(), "нет безопасного места — нет произвольного переноса")
	h.flooded = false
	h.wet_before = -INF
	w.available_rect = Rect2i(20, 4, 20, 20)
	spot = BikeRecovery.find(w, h, Vector3(44, 100, 40), 0.0)
	check(not spot.is_empty() and spot.name == "Дальнее", "не выбираются места за границей открытой территории")
	w.available_rect = Rect2i()
	var obstacle := ForestObstacles.new(w, h)
	obstacle._add(40, 40, 40, 40, 5.0, 100, INF)
	spot = BikeRecovery.find(w, h, Vector3(44, 100, 40), 0.0, obstacle.data)
	check(not spot.is_empty() and Vector2(spot.position.x - 40, spot.position.z - 40).length() > 5.0, "занятый центр места заменяется свободной площадкой рядом")
	h.cliff = true
	check(BikeRecovery.placement(w, h, Vector3(40, INF, 40), 0.0, null, true).is_empty(), "габарит велосипеда не нависает над обрывом")
	h.cliff = false
	h.roof = 101.5
	check(BikeRecovery.find(w, h, Vector3(40, 100, 40), 0.0).is_empty(), "низкий свод не позволяет появиться с головой в потолке")
	h.roof = INF
	h.gap = true
	check(not BikeRecovery.clear_path(w, h, Vector3(39, 100, 40), Vector3(41, 100, 40)), "посадка не переносит через узкий провал между равными опорами")
	h.gap = false
	_check_bridge()
	_check_mount()
	_check_dismount()
	_check_rescue()
	var key := InputEventKey.new()
	key.physical_keycode = KEY_Y
	key.pressed = true
	check(InputMap.event_is_action(key, "recover_bike"), "Y привязана по физической клавише независимо от раскладки")
	if "--generated" in OS.get_cmdline_user_args():
		_check_generated()
	print("FAILS: %d" % fails)
	quit(1 if fails > 0 else 0)


func _check_bridge() -> void:
	h.structures = [{tunnel = false, ax = 40.0, az = 20.0, ay = 104.0, bx = 40.0, bz = 60.0, by = 104.0, len = 40.0, ux = 0.0, uz = 1.0, half = 2.2, arch = 0.0, style = "wood", rails = true}]
	for z in range(4, 17):
		for x in range(8, 13):
			h._cells[z * w.W + x] = [0]
	var spot := BikeRecovery.find(w, h, Vector3(40, 100, 40), 0.0)
	check(not spot.is_empty() and is_equal_approx(spot.position.y, 104.0), "восстановление у моста выбирает верх настила, а не воду под ним")
	h.structures[0].ay = 101.5
	h.structures[0].by = 101.5
	check(not BikeRecovery.headroom(h, 40, 40, 100.0), "учитывается нижняя сторона низкого моста")
	check(not BikeRecovery.headroom(h, 40, 40, 100.9), "допуск шага на мост не превращает его низ в свободный потолок")
	h.structures.clear()
	h._cells.clear()


func _check_mount() -> void:
	var p := PlayerState.new()
	p.x = 39.0
	p.z = 40.0
	p.feet = 100.0
	var b := BikeRide.new()
	b.x = 41.0
	b.z = 40.0
	b.y = 100.0
	h.obstacles._add(40, 20, 40, 60, 0.1, 100, INF)
	check(not b.prepare_mount(p, w, h), "стоячий велосипед тоже нельзя оседлать через стену")
	h.obstacles = ForestObstacles.new(w, h)
	h.gap = true
	check(not b.prepare_mount(p, w, h), "стоячий велосипед нельзя оседлать через провал")
	h.gap = false
	check(b.prepare_mount(p, w, h), "обычная посадка на свободном месте работает")


func _check_dismount() -> void:
	var b := BikeRide.new()
	b.x = 40.4
	b.z = 40.0
	b.y = 100.0
	var p := PlayerState.new()
	h.obstacles = ForestObstacles.new(w, h)
	# Тонкая стена между рамой и свободной точкой слева.
	h.obstacles._add(39.95, 20, 39.95, 60, 0.05, 100, INF)
	b.mount(p)
	b.bottom_out = 2.0
	b.dismount(p, w, h)
	check(p.x > 40.0 and not b.riding, "сход не переносит пешехода сквозь тонкую стену")
	check(b.bottom_out == 0.0, "сход очищает отложенный стук подвески")
	h.obstacles = ForestObstacles.new(w, h)
	h.cliff = true
	b.x = 39.6
	b.heading = PI
	b.mount(p)
	b.dismount(p, w, h)
	check(p.x < 40.0 and p.feet == 100.0, "сход у обрыва выбирает опору на прежнем уровне")
	h.cliff = false
	h.gap = true
	b.x = 40.4
	b.heading = 0.0
	b.mount(p)
	b.dismount(p, w, h)
	check(p.x > 40.0, "сход не перескакивает узкий провал")
	h.gap = false
	b.mount(p)
	b.dismount(p, w, h)
	check(is_equal_approx(p.x, b.x - 0.9), "на свободной земле сохраняется обычный сход слева")


func _check_rescue() -> void:
	var view := load("res://scenes/bike.tscn").instantiate() as BikeView
	root.add_child(view)
	var crash := BikeCrash.new()
	root.add_child(crash)
	var game := GameWorld.new()
	game.world = w
	game.heights = h
	game.crash = crash
	game.bike_view = view
	game.camera = Camera3D.new()
	game.add_child(game.camera)
	game.bike = BikeRide.new()
	for phase: int in [BikeCrash.Phase.NONE, BikeCrash.Phase.BALANCE, BikeCrash.Phase.RAGDOLL, BikeCrash.Phase.RECOVER]:
		game.time += 2.0
		game.player = PlayerState.new()
		game.player.x = 32.0
		game.player.z = 32.0
		game.player.feet = 100.0
		game.bike.x = 32.0
		game.bike.z = 32.0
		game.bike.y = 100.0
		game.bike.mount(game.player)
		view.snap(game.bike)
		view.draw(1.0)
		view.set_lamp(true)
		if phase != BikeCrash.Phase.NONE:
			crash.start(view, game.bike, Vector3(0, -6, -8), h)
		if phase >= BikeCrash.Phase.RAGDOLL:
			crash._begin_ragdoll()
		if phase == BikeCrash.Phase.RECOVER:
			crash._begin_recover(game.bike, w, h)
		game.bike.airborne = true
		game.player.vy = -30.0
		var same_bike := game.bike
		check(game.restore_at_place(), "Y доступна в фазе %d и в воздухе" % phase)
		check(not crash.active() and crash._bones.is_empty() and view.rider.get_parent() == view and view.rider.procedural_pose, "Y убирает физику и возвращает управление моделью, фаза %d" % phase)
		check(game.bike == same_bike and game.bike.riding and not game.bike.fallen and not game.bike.airborne and game.player.vy == 0.0 and view.lamp_on(), "Y сохраняет велосипед/фару и очищает инерцию, фаза %d" % phase)
		var held := game.player
		check(not game.restore_at_place() and game.player == held, "повторное Y не запускает новый перенос")
	game.time += 2.0
	game.paused = true
	check(not game.restore_at_place(), "на паузе Y не меняет мир")
	game.paused = false
	crash.start(view, game.bike, Vector3(0, -6, -8), h)
	crash._begin_ragdoll()
	for bone: PhysicalBone3D in crash._bones.values():
		bone.global_position += Vector3(24, 20, 0)
	crash._bike_body.global_position.y = 90.0
	crash.t = BikeCrash.LIE_MAX + 1.0
	crash.tick(1.0 / 60.0, game.bike, w, h)
	var hips: Vector3 = crash._bones["Hips"].global_position
	check(crash.phase == BikeCrash.Phase.RAGDOLL and Vector2(hips.x - crash._ground.global_position.x, hips.z - crash._ground.global_position.z).length() < 2.0, "долгий полёт за край участка продолжает рэгдолл и переносит локальную землю")
	check(crash._bike_body.global_position.y >= 99.5, "страховка возвращает раму над землёй после пропущенного контакта")
	check(game.restore_at_place(), "Y выводит из долгого падения за пределами исходного участка")
	game.time += 2.0
	w.sites.clear()
	w.settlements.clear()
	crash.start(view, game.bike, Vector3(0, 0, -8), h)
	crash._begin_ragdoll()
	check(not game.restore_at_place() and crash.active() and not crash._bones.is_empty(), "при отсутствии мест Y не уничтожает текущий рэгдолл")
	crash.abort()
	game.free()
	crash.free()
	view.free()


func _check_generated() -> void:
	var generated := WorldGenerator.generate("abc", 128)
	var ground := Heightfield.new(generated)
	ground.obstacles = ForestObstacles.new(generated, ground)
	var p := PlayerState.spawn(generated, ground)
	for origin: Vector3 in [Vector3(p.x, p.feet, p.z), Vector3(-1000, -500, -1000)]:
		var spot := BikeRecovery.find(generated, ground, origin, 0.0)
		check(not spot.is_empty(), "сгенерированный мир: есть безопасное место, исходная точка %s" % origin)
		if not spot.is_empty():
			check(not BikeRecovery.placement(generated, ground, spot.position, spot.heading, null, true).is_empty(), "сгенерированный мир: полная повторная проверка площадки")
