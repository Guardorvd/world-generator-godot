extends SceneTree
## 14.2: изолированная сцена интерфейса игры без мира на светлом «снежном» фоне: панель сведений, компас,
## сообщение, чипы подсказок, дуга выносливости (трата ниже 20 % с затемнением краёв, истощение, накат)
## и меню выбора мира. Снимки hud_drain.png, hud_coast.png, menu.png. Нужно окно.
##   godot --path . --script res://tools/hud_look.gd -- [--out <папка>]

var out := ""
var failed := 0
var main: Node
var hud: Hud


func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 90)
	var args := OS.get_cmdline_user_args()
	var i := args.find("--out")
	out = args[i + 1] if i >= 0 and i + 1 < args.size() else OS.get_user_data_dir().path_join("hud_look")
	DirAccess.make_dir_recursive_absolute(out)
	root.size = Vector2i(1280, 720)
	_run()


func _check(ok: bool, text: String) -> void:
	print(("ok   " if ok else "FAIL ") + text)
	if not ok:
		failed += 1


func _shot(name: String) -> void:
	await process_frame
	await process_frame
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png(out.path_join(name + ".png"))


## Снег под ярким небом — худший фон для белого текста
func _build() -> void:
	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	var sky := Sky.new()
	sky.sky_material = ProceduralSkyMaterial.new()
	env.environment.background_mode = Environment.BG_SKY
	env.environment.sky = sky
	env.environment.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	root.add_child(env)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-60.0, 30.0, 0.0)
	sun.light_energy = 1.4
	root.add_child(sun)
	var ground := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(400, 400)
	ground.mesh = plane
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(0.95, 0.96, 0.98)
	ground.material_override = m
	root.add_child(ground)
	var camera := Camera3D.new()
	root.add_child(camera)
	camera.look_at_from_position(Vector3(0, 1.6, 0), Vector3(0, 1.2, -10), Vector3.UP)
	camera.current = true
	main = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)


## Прокрутить выносливость n кадров с одним состоянием (дуга сглаживает появление и шлейф)
func _tick(stamina: Stamina, frames: int, ride: bool, throttle: float, boost: bool) -> void:
	for f in frames:
		if ride:
			stamina.tick_ride(1.0 / 60.0, throttle, boost, 12.0, 0.0, false)
		else:
			stamina.tick_foot(1.0 / 60.0, false)
		hud.set_stamina(stamina.value, stamina.exhausted, stamina.state)
		await process_frame


func _run() -> void:
	_build()
	await process_frame
	hud = main.get_node("UI/Root/Hud")
	for path: String in ["UI/Root/Back", "UI/Root/Menu"]:
		main.get_node(path).visible = false
	hud.visible = true
	hud.lock_hint.visible = false
	var world := WorldData.new()
	world.W = 64
	world.H = 64
	world.N = 4096
	var map := Image.create(128, 128, false, Image.FORMAT_RGB8)
	map.fill(Color(0.85, 0.88, 0.9))
	hud.set_world(world, map)
	hud.set_player(128, 128, 0.3)
	Input.action_press("show_hud") # как зажатый Tab: панель сведений, компас и нижние подсказки
	hud.info.text = "Тундра, тропа (снег)\nВысота: 1240 м · -12°C\nБлижайшее поселение: «Ольховка», 1,2 км"
	hud.toast_now("Открыто место: перевал Седой")
	hud.set_hints([["Shift", "Сильнее"], ["Пробел", "Прыжок"], ["R", "Слезть"], ["Y", "Поставить велосипед"]], [["R", "Доска «Ольховка»"]])
	_check(hud.hint.get_child_count() == 4 and hud.prompt.get_child_count() == 1, "чипы: четыре внизу и один у прицела")
	# трата с Shift до 12 %: пульс и затемнение краёв
	var stamina := Stamina.new()
	stamina.value = 0.18
	await _tick(stamina, 75, true, 1.0, true)
	_check(stamina.value < 0.2 and hud._stamina.warning > 0.05 and hud._vignette.visible, "ниже 20 %% при трате — предупреждение (%.2f)" % hud._stamina.warning)
	_check(hud._stamina._ghost > stamina.value, "шлейф отстаёт от заливки")
	await _shot("hud_drain")
	# Brake gauge: normal braking, danger, and contexts where it must disappear.
	var bike := BikeRide.new()
	bike.riding = true
	bike.speed = 12.0
	bike.brakes.pressure = 0.75
	for frame in 30:
		hud.set_brakes(bike)
		await process_frame
	_check(hud._brakes.visible and hud._brakes.pressure > 0.7, "дуга тормоза видна при движении вперёд")
	await _shot("hud_brake")
	bike.brakes.risk = 0.8
	hud.set_brakes(bike)
	await _shot("hud_brake_warning")
	bike.airborne = true
	hud.set_brakes(bike)
	_check(not hud._brakes.visible, "в полёте индикатор скрыт сразу")
	bike.airborne = false
	bike.speed = -2.0
	for frame in 30:
		hud.set_brakes(bike)
		await process_frame
	_check(not hud._brakes.visible, "задний ход не показывает торможение")
	# истощение, потом накат: предупреждение гаснет быстро, ореол наката
	await _tick(stamina, 330, true, 1.0, true)
	_check(stamina.exhausted, "полоска истощена")
	await _tick(stamina, 30, true, 0.0, false)
	_check(stamina.state == Stamina.State.COAST and hud._stamina.warning < 0.05 and hud._stamina._coast > 0.9, "накат: предупреждение погасло, ореол наката")
	await _tick(stamina, 150, true, 0.0, false)
	await _shot("hud_coast")
	# меню: строка списка ставит зерно в поле, кнопка запуска под превью и полем
	hud.visible = false
	main.get_node("UI/Root/Back").visible = true
	main.get_node("UI/Root/Menu").visible = true
	main._show_seed_tab("recommended")
	var start: Button = main.get_node("%Start")
	var edit: LineEdit = main.get_node("%SeedEdit")
	_check(start.get_index() > edit.get_parent().get_parent().get_parent().get_index(), "«Начать путешествие» под полем зерна и превью")
	main._pick_seed("Туман-4821")
	_check(edit.text == "Туман-4821" and main._chosen_seed() == "Туман-4821", "выбор в списке ставит зерно в поле")
	await _shot("menu")
	var panel: Control = main.get_node("UI/Root/Menu/Panel")
	_check(root.get_visible_rect().encloses(panel.get_global_rect()), "меню целиком помещается в 1280×720")
	main.get_node("%InfiniteWarning").show()
	main.get_node("%WorldStatus").text = "Сохранение не читается. Можно создать мир заново; старые файлы сохранятся в архиве."
	await _shot("menu_warning")
	_check(root.get_visible_rect().encloses(panel.get_global_rect()), "меню с предупреждениями целиком помещается в 1280×720")
	print("hud_look: %s, снимки в %s" % ["FAIL %d" % failed if failed else "ok", out])
	quit(1 if failed else 0)
