extends SceneTree
## Проверка повреждённых настроек без чтения и изменения пользовательского файла.

var fails := 0


func _check(ok: bool, label: String) -> void:
	print(("✓ " if ok else "✗ ") + label)
	if not ok:
		fails += 1


func _initialize() -> void:
	if "--navigation" in OS.get_cmdline_user_args():
		_navigation_test.call_deferred()
		return
	GameContext.scope.settings.reset_defaults()
	_check(GameContext.scope.settings.day_minutes == 7.0, "стандартная длительность суток — 7 минут")
	var cfg := ConfigFile.new()
	cfg.set_value("time", "day_minutes", 12.0)
	cfg.set_value("time", "start_hour_set", true)
	GameContext.scope.settings._apply_config(cfg)
	_check(GameContext.scope.settings.day_minutes == 12.0, "сохранённая длительность суток сохраняется")
	GameContext.scope.settings.reset_defaults()
	cfg.clear()
	cfg.set_value("input", "mouse", "ошибка")
	cfg.set_value("input", "invert_y", [])
	cfg.set_value("view", "fov", NAN)
	cfg.set_value("view", "head_bob", "false")
	cfg.set_value("view", "fullscreen", 1)
	cfg.set_value("view", "shadows", false)
	cfg.set_value("sound", "volume", INF)
	cfg.set_value("world", "size", {})
	cfg.set_value("world", "seed", "  Север-1234  ")
	GameContext.scope.settings._apply_config(cfg)
	_check(GameContext.scope.settings.mouse == GameSettings.DEFAULT_MOUSE and GameContext.scope.settings.fov == GameSettings.DEFAULT_FOV
		and GameContext.scope.settings.volume == GameSettings.DEFAULT_VOLUME, "строки, NaN и бесконечность заменяются безопасными значениями")
	_check(not GameContext.scope.settings.invert_y and GameContext.scope.settings.head_bob and not GameContext.scope.settings.fullscreen,
		"переключатели принимают только логические значения")
	_check(not GameContext.scope.settings.shadows and GameContext.scope.settings.last_seed == "Север-1234",
		"исправные поля читаются даже при повреждении соседних")
	cfg.set_value("input", "mouse", 100)
	cfg.set_value("view", "fov", 1.0)
	cfg.set_value("sound", "volume", -2.0)
	GameContext.scope.settings._apply_config(cfg)
	_check(GameContext.scope.settings.mouse == GameSettings.MAX_MOUSE and GameContext.scope.settings.fov == GameSettings.MIN_FOV
		and GameContext.scope.settings.volume == 0.0, "числа ограничены диапазонами, старый ключ размера мира не мешает")
	print("Настройки: ошибок %d" % fails)
	quit(0 if fails == 0 else 1)


func _navigation_test() -> void:
	var w := WorldData.new()
	w.W = 64
	w.H = 64
	w.N = 4096
	w.expand_territory(64)
	var main_road: Array = []
	for y in range(30, 4, -1):
		main_road.append({x = 10.5, y = y + 0.5})
	var branch: Array = []
	for x in range(10, 31):
		branch.append({x = x + 0.5, y = 15.5})
	w.trails = [{kind = "road", pts = main_road}, {kind = "trail", pts = branch},
		{kind = "road", pts = [{x = 50.5, y = 50.5}, {x = 51.5, y = 50.5}]},
		{kind = "animal", pts = [{x = 30.5, y = 15.5}, {x = 50.5, y = 50.5}]}]
	var roads := preload("res://scripts/game/road_navigation.gd").new()
	roads.build(w)
	var route := roads.route_to(Vector2(42, 122), Vector2(122, 62))
	_check(route.size() > 20 and route.has(Vector2(42, 62)) and route[-1] == Vector2(122, 62), "путь проходит по дороге через развилку к цели")
	var from := Vector2(20, 122) # игрок в стороне от дороги
	var far := Vector2(202, 202) # цель на несвязанной дороге, звериная тропа не связывает их
	var fallback := roads.route_to(from, far)
	_check(fallback[0] == from and fallback[-1] == far and roads.complete,
		"несвязанная дорожная сеть не мешает доступному более короткому подходу")
	_check(roads.road_last == -1, "прямой подход не помечен как готовая дорога")
	var none := preload("res://scripts/game/road_navigation.gd").new()
	none.build(WorldData.new())
	_check(none.route_to(Vector2(0, 0), Vector2(40, 30)) == PackedVector2Array([Vector2(0, 0), Vector2(40, 30)]),
		"14.9: без дорог путь — прямая от игрока к цели")
	var shell: Node = load("res://scenes/main.tscn").instantiate()
	shell.set_script(null) # только готовый HUD, без генерации фона меню
	root.add_child(shell)
	var hud: Hud = shell.get_node("%Hud")
	for child in hud.get_parent().get_children():
		if child is Control and child != hud:
			child.hide()
	var map_image := Image.create(128, 128, false, Image.FORMAT_RGB8)
	map_image.fill(Color(0.25, 0.35, 0.25))
	hud.set_world(w, map_image)
	var ground := NavigationGround.new(w)
	var line: MeshInstance3D = preload("res://scripts/render/navigation_line.gd").new()
	root.add_child(line)
	line.setup(w, ground)
	hud.goal_changed.connect(func(goal: Dictionary) -> void: line.set_goal(goal, Vector2(42, 122)))
	hud.set_goal({key = "test", kind = "site", name = "Поворот", x = 30.5, y = 15.5})
	line.update_line(Vector3(42, 100, 122), 0.3, true)
	_check(line.mesh.get_surface_count() == 1, "цель с доски/карты включает видимый пунктир")
	var vertices: PackedVector3Array = line.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	_check(vertices.size() < 800, "короткая линия имеет ограниченное число вершин: %d" % vertices.size())
	var near := true
	for p: Vector3 in vertices:
		near = near and Vector2(p.x - 42, p.z - 122).length() < 72.0 and p.y >= 100.09
	_check(near, "пунктир приподнят над опорой и ограничен ближними 70 м")
	var cached: RefCounted = line.roads
	var searches: int = line.roads.searches
	for i in 40:
		line.update_line(Vector3(42, 100, 122), 0.25, true)
	_check(line.roads.searches == searches, "при движении по маршруту поиск не запускается каждый кадр")
	# 15.2: движение против маршрута
	line.set_goal({key = "test", kind = "site", name = "Поворот", x = 30.5, y = 15.5}, Vector2(42, 80))
	line.update_line(Vector3(42, 100, 95), 0.3, true) # шаг назад от начала пути
	var warned: PackedColorArray = line.mesh.surface_get_arrays(0)[Mesh.ARRAY_COLOR]
	var red := false
	for c: Color in warned:
		red = red or (c.r > 0.9 and c.g < 0.5)
	_check(red, "15.2: движение против маршрута красит штрихи в предупреждающий цвет")
	line.update_line(Vector3(42, 100, 70), 0.3, true)
	line.update_line(Vector3(42, 100, 60), 0.3, true)
	var calm: PackedColorArray = line.mesh.surface_get_arrays(0)[Mesh.ARRAY_COLOR]
	var gold := true
	for c: Color in calm:
		gold = gold and c.g > 0.5
	_check(gold, "15.2: возврат на маршрут снимает предупреждение")
	line.update_line(Vector3(202, 100, 202), 2.1, true)
	line.update_line(Vector3(202, 100, 202), 0.3, true)
	_check(line.path.size() >= 2 and line.path[0] == Vector2(202, 202) and line.path[-1] == Vector2(122, 62)
		and line.mesh.get_surface_count() == 1, "14.9: после отклонения путь заново ведёт от нового места к цели, последний участок — по прямой")
	# 15.2: вне дороги — парящие стрелки
	line.set_goal({key = "field", kind = "marker", name = "Поле", x = 50.5, y = 50.5}, Vector2(150, 150))
	line.update_line(Vector3(150, 100, 150), 0.3, true)
	var arrows: PackedVector3Array = line.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	var lifted := true
	for p: Vector3 in arrows:
		lifted = lifted and p.y > 100.5 and Vector2(p.x - 150, p.z - 150).length() < 72.0
	_check(line.mesh.get_surface_count() == 1 and arrows.size() > 24 and lifted,
		"15.2: вне дороги путь — парящие стрелки над опорой, а не штрихи на земле")
	hud.set_goal({key = "lake:test", kind = "lake", name = "Озеро", x = 20.5, y = 5.5, src = {sx = 10.5, sy = 5.5}})
	_check(line.path[-1] == Vector2(42, 22), "озёрная цель ведёт к берегу, не в середину воды")
	_check(is_same(cached, line.roads), "новая цель использует уже собранную дорожную сеть")
	# Свободная метка: используем тот же обработчик, что у клика по карте.
	var frame: Array = hud.big_map._frame()
	var click := InputEventMouseButton.new()
	click.button_index = MOUSE_BUTTON_LEFT
	click.pressed = true
	click.position = frame[0] + Vector2(10.5, 5.5) * float(frame[2])
	hud.big_map._gui_input(click)
	click.pressed = false # карта выбирает при отпускании без перетаскивания
	hud.big_map._gui_input(click)
	_check(hud.goal.get("kind") == "marker" and not line.path.is_empty(), "щелчок по пустому месту карты ставит метку и включает навигацию")
	line.update_line(Vector3(42, 100, 122), 0.3, false)
	_check(not line.visible, "линия скрыта на карте/паузе/вступлении")
	line.update_line(Vector3(42, 100, 122), 0.3, true)
	if "--capture" in OS.get_cmdline_user_args():
		hud.hide()
		var camera := Camera3D.new()
		root.add_child(camera)
		camera.look_at_from_position(Vector3(42, 104.5, 130), Vector3(42, 100, 95))
		var environment := WorldEnvironment.new()
		environment.environment = Environment.new()
		environment.environment.background_mode = Environment.BG_COLOR
		environment.environment.background_color = Color(0.32, 0.43, 0.53)
		root.add_child(environment)
		_navigation_plane(Vector3(42, 99.99, 74), Vector2(90, 140), Color(0.20, 0.29, 0.18))
		_navigation_plane(Vector3(42, 100.0, 74), Vector2(3.6, 104), Color(0.35, 0.30, 0.23))
		var directory := "res://tools/control/runs/11.2"
		DirAccess.make_dir_recursive_absolute(directory)
		await process_frame
		await RenderingServer.frame_post_draw
		_check(preload("res://tools/shot_util.gd").save_png(root, directory, "navigation"), "снимок навигации")
		# 15.2: стрелки вне дороги
		var shots := "res://tools/control/runs/15.2"
		DirAccess.make_dir_recursive_absolute(shots)
		line.set_goal({key = "field", kind = "marker", name = "Поле", x = 10.5, y = 5.5}, Vector2(80, 120))
		line.update_line(Vector3(80, 100, 120), 0.3, true)
		camera.look_at_from_position(Vector3(86, 101.6, 122), Vector3(46, 100.8, 120))
		await process_frame
		await RenderingServer.frame_post_draw
		_check(preload("res://tools/shot_util.gd").save_png(root, shots, "navigation_offroad"), "снимок пути вне дороги")
		# 15.2: движение против маршрута
		line.set_goal({key = "test", kind = "site", name = "Поворот", x = 30.5, y = 15.5}, Vector2(42, 118))
		line.update_line(Vector3(42, 100, 124), 0.3, true)
		camera.look_at_from_position(Vector3(42, 101.7, 126), Vector3(42, 100.7, 80))
		await process_frame
		await RenderingServer.frame_post_draw
		_check(preload("res://tools/shot_util.gd").save_png(root, shots, "navigation_wrongway"), "снимок движения против маршрута")
	hud.set_goal({})
	_check(line.path.is_empty() and line.mesh.get_surface_count() == 0, "снятие цели сразу убирает линию")
	hud.set_goal({key = "marker", kind = "marker", name = "Метка", x = 10.5, y = 5.5})
	_check(not hud.check_goal(42, 22).is_empty() and hud.goal.is_empty() and line.path.is_empty(), "прибытие снимает свободную метку и навигацию")
	await _place_names_test(hud, w)
	quit(1 if fails > 0 else 0)


func _place_names_test(hud: Hud, w: WorldData) -> void:
	var camera := Camera3D.new()
	root.add_child(camera)
	camera.current = true
	var parent := Node3D.new()
	root.add_child(parent)
	var near := SettlementsBuilder._label("Ближняя деревня", Color.WHITE, Vector3(0, 8, -100), "near")
	var far := SettlementsBuilder._label("Целевая вершина", Color.WHITE, Vector3(0, 16, -200), "far")
	var distant := SettlementsBuilder._label("Дальняя башня", Color.WHITE, Vector3(100, 8, -350), "distant")
	var faded := SettlementsBuilder._label("Лесное озеро", Color.WHITE, Vector3(-70, 8, -230), "faded")
	for label: Label3D in [near, far, distant, faded]:
		parent.add_child(label)
	var names := preload("res://scripts/render/place_names.gd").new()
	names.setup(parent)
	names.update(camera, 1.0, {})
	_check(not near.visible and not faded.visible, "11.8: названия непосещённых мест скрыты")
	var seen := {near = true, far = true, distant = true, faded = true}
	names.update(camera, 1.0, seen)
	_check(near.visible and not far.visible, "при наложении ближнее название остаётся, дальнее затухает")
	_check(not distant.visible and faded.visible and faded.modulate.a < 0.8, "названия бледнеют после 180 м и скрыты за 300 м")
	names.set_goal({key = "far"})
	names.update(camera, 1.0, seen)
	_check(far.visible and not near.visible and far.outline_size == 12, "выбранное название имеет обводку и приоритет над ближним")
	names.set_goal({key = "distant"})
	names.update(camera, 1.0, seen)
	_check(distant.visible and distant.modulate.a > 0.1, "для выбранной цели дальность увеличивается до 450 м")
	distant.position.z = -500
	names.update(camera, 1.0, seen)
	_check(not distant.visible, "даже выбранная цель не видна через всю карту")
	names.set_goal({})
	names.update(camera, 1.0, seen)
	_check(near.visible and near.outline_size == 8 and not far.visible, "снятие цели возвращает обычное выделение и приоритет расстояния")
	if "--capture" in OS.get_cmdline_user_args():
		names.set_goal({key = "far"})
		names.update(camera, 1.0, seen)
		await process_frame
		await RenderingServer.frame_post_draw
		_check(preload("res://tools/shot_util.gd").save_png(root, "res://tools/control/runs/11.2", "place_names"), "снимок названий в мире")
		parent.hide()
		w.settlements = [{x = 10.5, y = 15.5, i = 970, name = "Ближняя деревня"},
			{x = 11.5, y = 16.5, i = 1035, name = "Деревня у холма"}]
		w.peaks = [{x = 12.5, y = 17.5, name = "Соседняя вершина"}]
		hud.show()
		hud.set_player(42, 122, 0)
		var goal: Dictionary = hud.all_places()[1]
		hud.set_goal(goal)
		hud.set_map_visible(true)
		await process_frame
		await RenderingServer.frame_post_draw
		_check(preload("res://tools/shot_util.gd").save_png(root, "res://tools/control/runs/11.2", "map_names"), "снимок близких названий на карте")


class NavigationGround extends Heightfield:
	func _init(w: WorldData) -> void:
		super()
		world = w
	func surface_at(_x: float, _z: float, _feet: float) -> float:
		return 100.0
	func known(_x: float, _z: float) -> bool:
		return true
	func depth_at(_x: float, _z: float, _feet := -INF) -> float:
		return 0.0


func _navigation_plane(at: Vector3, size: Vector2, color: Color) -> void:
	var plane := MeshInstance3D.new()
	var geometry := PlaneMesh.new()
	geometry.size = size
	plane.mesh = geometry
	plane.position = at
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = color
	plane.material_override = material
	root.add_child(plane)
