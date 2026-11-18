extends SceneTree
## Проверка настроек на отдельном файле, без изменения профиля игрока.

const DayTiming := preload("res://scripts/game/day_timing.gd")
var fails := 0


func _check(ok: bool, label: String) -> void:
	print(("✓ " if ok else "✗ ") + label)
	if not ok:
		fails += 1


func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 120)
	if "--navigation" in OS.get_cmdline_user_args():
		_navigation_test.call_deferred()
		return
	_run.call_deferred()


func _run() -> void:
	GameContext.scope.settings.reset_defaults()
	_check(GameContext.scope.settings.day_minutes == 7.0, "стандартная длительность суток — 7 минут")
	var cfg := ConfigFile.new()
	cfg.set_value("time", "day_minutes", 12.0)
	cfg.set_value("time", "start_hour_set", true)
	GameContext.scope.settings._apply_config(cfg)
	_check(GameContext.scope.settings.day_minutes == 12.0, "сохранённая длительность суток сохраняется")
	_check(GameContext.scope.settings.long_twilight, "длинные рассветы и закаты включены для старых настроек")
	cfg.set_value("time", "long_twilight", false)
	GameContext.scope.settings._apply_config(cfg)
	_check(not GameContext.scope.settings.long_twilight, "из настроек читается равномерный ход часов")
	_check_day_timing()
	GameContext.scope.settings.reset_defaults()
	_check(GameContext.scope.settings.long_twilight, "сброс возвращает длинные рассветы и закаты")
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
	_check(GameContext.scope.settings.trail_clutter, "выключатель препятствий на тропах по умолчанию включён и не ломается от соседних полей")
	var clutter_cfg := ConfigFile.new()
	clutter_cfg.set_value("view", "trail_clutter", false)
	GameContext.scope.settings._apply_config(clutter_cfg)
	_check(not GameContext.scope.settings.trail_clutter, "выключатель препятствий читается из файла")
	GameContext.scope.settings.reset_defaults()
	_check(GameContext.scope.settings.trail_clutter, "сброс настроек возвращает препятствия на тропах")
	# 16.0: качество растительности — в файле, в пределах списка, в сбросе и в состоянии графики
	var flora_cfg := ConfigFile.new()
	flora_cfg.set_value("view", "flora", 0)
	GameContext.scope.settings._apply_config(flora_cfg)
	_check(GameContext.scope.settings.flora == 0 and GameContext.scope.settings.display_state().flora == 0, "качество растительности читается из файла")
	flora_cfg.set_value("view", "flora", 99)
	GameContext.scope.settings._apply_config(flora_cfg)
	_check(GameContext.scope.settings.flora == GameSettings.FLORA_LEVELS.size() - 1, "качество растительности ограничено списком")
	GameContext.scope.settings.flora = 0
	GameContext.scope.settings.reset_defaults()
	_check(GameContext.scope.settings.flora == GameSettings.DEFAULT_FLORA, "сброс настроек возвращает качество растительности")
	var particles_cfg := ConfigFile.new()
	particles_cfg.set_value("view", "particles", 0)
	GameContext.scope.settings._apply_config(particles_cfg)
	_check(GameContext.scope.settings.particles == 0 and GameContext.scope.settings.display_state().particles == 0, "частицы окружения читаются из файла")
	particles_cfg.set_value("view", "particles", 99)
	GameContext.scope.settings._apply_config(particles_cfg)
	_check(GameContext.scope.settings.particles == GameSettings.PARTICLE_LEVELS.size() - 1, "частицы окружения ограничены списком")
	GameContext.scope.settings.reset_defaults()
	_check(GameContext.scope.settings.particles == GameSettings.DEFAULT_PARTICLES, "сброс настроек возвращает частицы окружения")
	# 13.11: визуальный стиль — выключатель и сила каждого эффекта
	var style_cfg := ConfigFile.new()
	style_cfg.set_value("style", "grade_on", false)
	style_cfg.set_value("style", "depth_amount", 0.25)
	style_cfg.set_value("style", "grain_amount", 7.0)
	style_cfg.set_value("style", "highlights_on", "нет")
	GameContext.scope.settings._apply_config(style_cfg)
	var style_state := GameContext.scope.settings.display_state()
	_check(not style_state.style_on.grade and is_equal_approx(style_state.style_amount.depth, 0.25), "визуальный стиль читается из файла")
	_check(is_equal_approx(style_state.style_amount.grain, 1.0) and style_state.style_on.highlights, "сила стиля ограничена 0..1, испорченный флаг не мешает")
	# без привязанного мира (инструменты со своим окружением) множители DayCycle нейтральны, как бы ни стояли настройки
	_check(VisualStyle.exposure_scale() == 1.0 and VisualStyle.saturation_scale() == 1.0, "без мира множители выдержки и насыщенности равны 1")
	VisualStyle.configure(style_state.style_on, style_state.style_amount)
	_check(VisualStyle.strength("grade") == 0.0 and is_equal_approx(VisualStyle.strength("depth"), 0.25), "выключенный эффект имеет силу 0")
	VisualStyle.configure(VisualStyle.DEFAULT_ON, {grade = 0.0})
	_check(VisualStyle.strength("grade") == 0.0, "сила 0 равна выключению")
	GameContext.scope.settings.reset_defaults()
	var reset_state := GameContext.scope.settings.display_state()
	_check(reset_state.style_on == VisualStyle.DEFAULT_ON and reset_state.style_amount == VisualStyle.DEFAULT_AMOUNT, "сброс настроек возвращает визуальный стиль")
	VisualStyle.configure(VisualStyle.DEFAULT_ON, VisualStyle.DEFAULT_AMOUNT)
	GameContext.scope.settings._apply_config(cfg)
	_check(not GameContext.scope.settings.shadows and GameContext.scope.settings.last_seed == "Север-1234",
		"исправные поля читаются даже при повреждении соседних")
	cfg.set_value("input", "mouse", 100)
	cfg.set_value("view", "fov", 1.0)
	cfg.set_value("sound", "volume", -2.0)
	GameContext.scope.settings._apply_config(cfg)
	_check(GameContext.scope.settings.mouse == GameSettings.MAX_MOUSE and GameContext.scope.settings.fov == GameSettings.MIN_FOV
		and GameContext.scope.settings.volume == 0.0, "числа ограничены диапазонами, старый ключ размера мира не мешает")
	_check_time_settings_ui()
	_check_world_clock()
	print("Настройки: ошибок %d" % fails)
	quit(0 if fails == 0 else 1)


func _check_day_timing() -> void:
	_check(is_equal_approx(DayTiming.advance(4.0, 0.13, true), 6.5)
		and is_equal_approx(DayTiming.advance(6.5, 0.39, true), 17.5)
		and is_equal_approx(DayTiming.advance(17.5, 0.13, true), 20.0)
		and is_equal_approx(DayTiming.advance(20.0, 0.35, true), 28.0), "доли фаз суток и переход через полночь")
	_check(is_equal_approx(DayTiming.advance(21.0, 0.25, false), 27.0)
		and is_equal_approx(DayTiming.advance(2.0, 3.0, true), 74.0)
		and is_equal_approx(DayTiming.advance(2.0, -3.0, true), -70.0)
		and DayTiming.advance(5.37, 0.0, true) == 5.37, "равномерный ход времени и остановка часов")
	var hour := 23.625
	for step in 25200: # Seven minutes at 60 physics ticks per second.
		hour = DayTiming.advance(hour, 1.0 / 25200.0, true)
	_check(absf(hour - 47.625) < 0.00001, "длительность суток не накапливает ошибку от шага физики")
	var smooth := true
	var step := 0.00001
	for boundary in [4.0, 6.5, 17.5, 20.0]:
		var before := DayTiming.advance(boundary, -step, true)
		var after := DayTiming.advance(boundary, step, true)
		smooth = smooth and before < boundary and after > boundary and absf((after - boundary) - (boundary - before)) < 0.000001
	_check(smooth, "скорость часов непрерывна на границах фаз")


func _check_time_settings_ui() -> void:
	var settings := GameContext.scope.settings
	settings.reset_defaults()
	var menu: Node = load("res://scenes/main.tscn").instantiate()
	var toggle: CheckBox = menu.get_node("%LongTwilight")
	var slider: HSlider = menu.get_node("%DaySlider")
	_check(toggle.button_pressed, "в меню длинные рассветы и закаты включены при первом запуске")
	# Emit the scene's signals without starting the animated menu in this fixture.
	toggle.set_pressed_no_signal(false)
	toggle.toggled.emit(false)
	slider.set_value_no_signal(12.0)
	slider.value_changed.emit(12.0)
	_check(not settings.long_twilight and settings.day_minutes == 12.0, "переключатель и ползунок меняют настройки времени")
	settings.settings_path = "user://settings_time_test_%s.cfg" % OS.get_process_id()
	var saved := settings.save_settings()
	var restored := GameSettings.new()
	restored.settings_path = settings.settings_path
	restored.load_settings()
	_check(saved == OK and not restored.long_twilight and restored.day_minutes == 12.0,
		"режим времени и длина суток сохраняются и читаются с диска")
	DirAccess.remove_absolute(settings.settings_path)
	settings.settings_path = GameSettings.PATH
	menu.free()
	settings.reset_defaults()


func _check_world_clock() -> void:
	var game := GameWorld.new()
	var settings := game.services.settings
	var sun := DirectionalLight3D.new()
	var day := DayCycle.new(Environment.new(), sun)
	game.day = day
	var dt := 1.0 / 60.0
	game.hour = 23.5
	game._apply_render_clock(1.0)
	settings.day_minutes = 0.0
	game._advance_clock(dt)
	_check(game.hour == 23.5 and is_equal_approx(game.time, dt),
		"остановка часов сохраняет ход времени симуляции")
	var night := day._night
	game._hour_skip = 1.0
	for tick in 60:
		game._advance_clock(dt)
	game._apply_render_clock(1.0)
	var cloud_time: float = day.sky_mat.get_shader_parameter("cloud_time")
	_check(game._hour_skip == 0.0 and is_equal_approx(game.hour, 0.5)
		and day._night == night and is_equal_approx(day._clock, 24.5)
		and is_equal_approx(cloud_time, game.time), "T проходит через полночь без смены ночи и скачка облаков")
	game._hour_skip = -1.0
	for tick in 60:
		game._advance_clock(dt)
	game._apply_render_clock(1.0)
	_check(game._hour_skip == 0.0 and is_equal_approx(game.hour, 23.5) and is_equal_approx(day._clock, 23.5),
		"Shift+T возвращает ровно на час через полночь")
	settings.day_minutes = 7.0
	game.hour = 5.9
	game._hour_skip = 1.0
	var manual_total := 0.0
	for tick in 60:
		var expected := DayTiming.advance(game.hour, dt / (settings.day_minutes * 60.0), true)
		game._advance_clock(dt)
		manual_total += wrapf(game.hour - expected, -12.0, 12.0)
	_check(is_equal_approx(manual_total, 1.0), "ход часов во время рассвета не искажает ручной сдвиг")
	var hour := game.hour
	var time := game.time
	settings.long_twilight = false
	game._advance_clock(dt)
	_check(is_equal_approx(game.hour, hour + dt * 24.0 / 420.0) and is_equal_approx(game.time, time + dt),
		"переключение темпа в мире сохраняет текущий час и время симуляции")
	settings.long_twilight = true
	for crossing in [6.0, 18.0]:
		game.hour = crossing - 0.1
		var smooth := true
		game._apply_render_clock(1.0)
		var previous_energy := sun.light_energy
		for tick in 540:
			game._advance_clock(dt)
			game._apply_render_clock(1.0)
			smooth = smooth and absf(sun.light_energy - previous_energy) < 0.02
			previous_energy = sun.light_energy
		_check(smooth and game.hour > crossing, "свет плавно меняется при прохождении %s" % DayCycle.clock(crossing))
	_check_render_clock(game)
	game.free()
	sun.free()
	settings.reset_defaults()


func _check_render_clock(game: GameWorld) -> void:
	var shell: Node = load("res://scenes/main.tscn").instantiate()
	shell.set_script(null)
	root.add_child(shell)
	game.hud = shell.get_node("%Hud")
	game.time = 0.0
	game._restore_clock({player = {hour = 23.99, clock_day = 7, sky_seconds = 430.0}})
	game._apply_render_clock(1.0)
	var day := game.day
	var night := day._night
	_check(DayCycle.clock(day._clock) == "23:59" and night == 7
		and is_equal_approx(day.sky_mat.get_shader_parameter("cloud_time"), 430.0)
		and game.time == 0.0, "загрузка восстанавливает час, ночь и небо отдельно от времени движения")
	game.services.settings.day_minutes = 0.0
	game._hour_skip = 0.24
	game._advance_clock(1.0 / 60.0)
	game._apply_render_clock(0.5)
	_check(game.hud._clock_label.text == DayCycle.clock(day._clock) and day._night == night
		and day._clock >= 192.0 and day._clock < game._clock_hour, "HUD и небо показывают один кадр при переходе через полночь")
	var shown := day._clock
	game._apply_render_clock(0.25)
	_check(day._clock == shown, "кадр после паузы не возвращает часы назад")
	game._restore_clock({player = {hour = 4.5}})
	game._apply_render_clock(1.0)
	_check(day._clock == 4.5 and game.hud._clock_label.text == "04:30", "старое сохранение загружается по исходному часу")
	_check(DayCycle.clock(24.0 - 1.0e-12) == "00:00", "погрешность вычислений не оставляет часы на 23:59 в полночь")
	game.hud = null
	shell.free()


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
	var click := InputEventMouseButton.new()
	click.button_index = MOUSE_BUTTON_LEFT
	click.ctrl_pressed = true
	click.pressed = true
	click.position = hud.big_map.world_to_screen(Vector2(10.5, 5.5) * GameConfig.TILE)
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
