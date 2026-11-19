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
			stamina.tick_ride(1.0 / 60.0, boost, throttle, false)
		else:
			stamina.tick_foot(1.0 / 60.0, false)
		hud.set_stamina(stamina.value, stamina.exhausted, stamina.state)
		await process_frame


func _map_fixture() -> WorldData:
	var world := WorldData.new()
	world.W = 256
	world.H = 256
	world.N = world.W * world.H
	var biomes := PackedByteArray()
	biomes.resize(world.N)
	var heights := PackedFloat32Array()
	heights.resize(world.N)
	for y in world.H:
		for x in world.W:
			var at := Vector2(x, y)
			var biome := Biomes.GRASS
			if x < 113 + sin(y * 0.07) * 9 or (x > 143 and y < 127):
				biome = Biomes.FOREST
			if ((at - Vector2(154, 147)) / Vector2(15, 11)).length_squared() < 1.0:
				biome = Biomes.LAKE
			biomes[y * world.W + x] = biome
			heights[y * world.W + x] = (40.0 + 210.0 * exp(-at.distance_squared_to(Vector2(120, 101)) / 2300.0)) / GameConfig.HS
	world.biome = biomes
	world.h = heights
	var wet := PackedByteArray()
	wet.resize(world.N)
	world.river = wet
	var paths := PackedByteArray()
	paths.resize(world.N)
	paths[128 * world.W + 128] = 3
	world.path_mask = paths
	var weather := PackedFloat32Array()
	weather.resize(world.N)
	weather.fill(13.0 / 60.0)
	world.temp = weather
	world.moist = weather
	world.elev = weather
	world.slope = weather
	world.rivers = [[{x = 145, y = 80}, {x = 136, y = 102}, {x = 138, y = 115},
		{x = 145, y = 130}, {x = 153, y = 139}]]
	world.trails = [
		{kind = "road", pts = [{x = 79.0, y = 148.0}, {x = 110.0, y = 141.0},
			{x = 125.0, y = 133.0}, {x = 129.0, y = 116.0}, {x = 147.0, y = 105.0}, {x = 163.0, y = 80.0}]},
		{kind = "trail", pts = [{x = 129.0, y = 116.0}, {x = 143.0, y = 120.0},
			{x = 155.0, y = 116.0}, {x = 171.0, y = 119.0}]},
	]
	var village := SettlementData.new()
	village.x = 126
	village.y = 114
	village.name = "Ольховка"
	world.settlements = [village]
	world.outer = OuterLand.new()
	return world


func _tap_hud() -> void:
	var event := InputEventAction.new()
	event.action = &"show_hud"
	event.pressed = true
	Input.parse_input_event(event)
	await process_frame
	await process_frame
	event = InputEventAction.new()
	event.action = &"show_hud"
	Input.parse_input_event(event)


func _map_checks(world: WorldData) -> void:
	# 18.11.2026: три вида — лёгкий (основной: мини-карта на 75 % и навигация), полный, скрытый
	_check(not hud.summary_visible() and hud.navigation_visible() and hud.minimap.visible and not hud.compass.visible
		and is_equal_approx(hud.minimap.modulate.a, Hud.LIGHT_ALPHA), "при старте лёгкий вид: мини-карта на 75 %, навигация видна")
	await _tap_hud()
	await create_timer(Hud.SUMMARY_FADE + 0.1).timeout
	_check(hud.summary_visible() and hud.compass.visible and is_equal_approx(hud.minimap.modulate.a, 1.0), "Tab — полная сводка")
	await _tap_hud()
	_check(not hud.summary_visible() and hud.minimap.visible, "Tab запускает плавное скрытие")
	await create_timer(Hud.SUMMARY_FADE + 0.1).timeout
	_check(not hud.minimap.visible and not hud.navigation_visible() and hud._summary_hint.text.ends_with("показать сводку"), "скрытие оставляет подсказку и прячет навигацию")
	await _tap_hud()
	await create_timer(Hud.SUMMARY_FADE + 0.1).timeout
	_check(not hud.summary_visible() and hud.navigation_visible() and is_equal_approx(hud.minimap.modulate.a, Hud.LIGHT_ALPHA), "Tab возвращает лёгкий вид")
	await _tap_hud()
	await create_timer(Hud.SUMMARY_FADE + 0.1).timeout
	_check(hud.summary_visible() and is_equal_approx(hud.minimap.modulate.a, 1.0), "Tab возвращает сводку")
	hud.set_map_visible(true)
	_check(not hud.summary_visible() and not hud.minimap.visible and not hud._summary_hint.visible, "большая карта скрывает сводку и подсказку")
	hud.set_map_visible(false)
	hud.set_photo_mode(true)
	_check(not hud.minimap.visible and not hud._summary_hint.visible, "фоторежим скрывает сводку и подсказку")
	hud.set_photo_mode(false)
	hud.notification(NOTIFICATION_APPLICATION_FOCUS_OUT)
	_check(hud.summary_visible(), "потеря фокуса сохраняет выбор игрока")
	var original := InputMap.action_get_events("interact")
	var remap := InputEventKey.new()
	remap.physical_keycode = KEY_F
	InputMap.action_erase_events("interact")
	InputMap.action_add_event("interact", remap)
	var game := GameWorld.new()
	game._bag_label = Label3D.new()
	game.add_child(game._bag_label)
	game._update_bag_label()
	main._update_control_hint()
	var action_row: bool = main._control_rows().any(func(row: Array) -> bool:
		return row[0] == "F" and row[1].begins_with("взаимодействовать"))
	_check(game._bag_label.text.ends_with("F") and action_row and main.get_node("%ActionBindings").text.begins_with("F "),
		"сумка, пауза и настройки используют переназначенную клавишу")
	InputMap.action_erase_events("interact")
	for event in original:
		InputMap.action_add_event("interact", event)
	game.services.controls.joypad = true
	game._update_bag_label()
	var pad_key := game.services.controls.label("interact")
	_check(not pad_key.is_empty() and game._bag_label.text.ends_with(pad_key), "надпись обновляется при переходе на геймпад")
	game.services.controls.joypad = false
	game.free()
	var landmark := Vector2(560, 512)
	var before: Vector2 = hud.minimap.world_to_map(landmark)
	hud.set_player(552, 512, PI * 0.5)
	var after: Vector2 = hud.minimap.world_to_map(landmark)
	_check(is_equal_approx(before.x - after.x, 40.0 * hud.minimap.PIXELS_PER_METER)
		and is_equal_approx(before.y, after.y), "движение сдвигает окрестности в постоянном масштабе при любом курсе")
	var view := Rect2(372, 332, 360, 360)
	hud.minimap._data.update(view)
	var key := Vector2i(2, 2)
	var cached: Texture2D = hud.minimap._data.tiles[key].texture
	_check(not hud.minimap._data.update(view), "неподвижная карта плана пропускает обновление подложки")
	hud.minimap._data.release_view()
	_check(hud.minimap._data.update(view) and hud.minimap._data.tiles[key].texture == cached,
		"при возврате карты в той же области используется готовая текстура")
	hud.set_player(1040, 512, 0.0)
	await process_frame
	await process_frame
	var outer_key := Vector2i(4, 2)
	var biome := PackedByteArray()
	biome.resize((OuterLand.C + 3) * (OuterLand.C + 3))
	biome.fill(Biomes.FOREST)
	world.outer.chunks[outer_key] = {biome = biome}
	await process_frame
	await process_frame
	_check(hud.minimap._data.tiles.has(outer_key), "карта подхватывает соседний кусок на месте")
	var forest := PackedByteArray()
	forest.resize(OuterLand.C * OuterLand.C)
	forest.fill(Biomes.FOREST)
	var dry := PackedByteArray()
	dry.resize(forest.size())
	var region := {
		rect = Rect2i(256, 128, OuterLand.C, OuterLand.C),
		fields = {biome = forest, lake = dry, river = dry},
	}
	world.outer.set_ledger({regions = {Vector2i(1, 0): region}})
	await process_frame
	await process_frame
	_check(is_same(hud.minimap._data.tiles[outer_key].fields, region.fields), "карта применяет опубликованные поля соседней области")
	hud.set_player(512, 512, 0.3)
	hud.set_bike(480, 548, true)
	hud.set_goal(Hud.marker_goal(Vector2(139, 122)))
	hud.visited[WorldData.place_id("settlement", 126, 114)] = true


## 18.11.2026: экран «Путешествие» — вкладки «Путь» и «Альбом» (одна страница со снимком, остальные — серые силуэты)
func _journal_checks() -> void:
	var image := Image.create(640, 360, false, Image.FORMAT_RGB8)
	image.fill(Color(0.35, 0.55, 0.75))
	image.fill_rect(Rect2i(0, 210, 640, 150), Color(0.3, 0.5, 0.25))
	var shot_path := OS.get_user_data_dir().path_join("hud_look_shot.jpg")
	image.save_jpg(shot_path, 0.9)
	hud.map_journal.foot = 4200.0
	hud.map_journal.bike = 31800.0
	hud.explore.play_s = 5400.0
	hud.explore.max_alt = 812.0
	var keys := Exploration.classify({}, Biomes.FOREST, {dark = 0.9, up = 0.4, aurora = 0.8})
	hud.explore.add_photo({path = shot_path, place = ""}, keys, "2026-11-18 12:00:00")
	_check(keys.has("biome:%d" % Biomes.FOREST) and keys.has("night:aurora"), "снимок ночью: страницы биома и сияния")
	var village := hud.world.settlements[0] as SettlementData
	var id := WorldData.place_id("settlement", village.x, village.y)
	hud.visited[id] = true
	hud.map_journal.read[id] = true
	hud.explore.record_place_photo(id, shot_path)
	var snapshot := hud.explore.save_state()
	var restored := Exploration.new()
	restored.restore(snapshot)
	snapshot.erase("place_photos")
	_check(restored.place_photos.get(id) == shot_path and Exploration.valid_save(snapshot),
		"снимок места переживает сохранение, прежний формат тоже читается")
	hud.show_tablet(Hud.Tablet.Tab.PATH)
	_check(hud.journal_panel.visible and hud.journal_panel._path_page.visible and not hud.journal_panel._album_page.visible, "«Путешествие» открывается на вкладке «Путь»")
	_check(root.get_visible_rect().encloses(hud.journal_panel.get_global_rect()), "экран помещается в 1280×720")
	await process_frame
	if not hud.big_map.places.is_empty():
		hud.big_map._set_hover(hud.big_map.places[0])
	await _shot("hud_journal_path")
	var atlas := hud.big_map
	_check(atlas.places.size() > 0 and int(atlas.places[0].map_status) & Hud.Atlas.Status.PHOTO != 0
		and hud.journal_panel._cache.has(shot_path), "место со снимком получает статус и миниатюру")
	var center := atlas._center
	var zoom := atlas._scale
	hud.show_tablet(Hud.Tablet.Tab.MAP)
	hud.show_tablet(Hud.Tablet.Tab.PATH)
	_check(hud.big_map == atlas and atlas._center == center and atlas._scale == zoom, "Карта и Путь сохраняют один вид")
	hud.show_tablet(Hud.Tablet.Tab.ALBUM)
	var filters := hud.journal_panel._album_page.get_child(0).get_children()
	_check(hud.journal_panel._album_page.visible and filters.any(func(node: Node) -> bool:
		return node is Button and node.text.begins_with("Ночь")), "вкладка «Альбом»: группы страниц")
	await _shot("hud_journal_album")
	var card_buttons: Array[Node] = hud.journal_panel._album_content.find_children("*", "Button", true, false)
	_check(card_buttons.size() >= 2, "открытые страницы альбома интерактивны")
	if not card_buttons.is_empty():
		(card_buttons[0] as Button).pressed.emit()
		await process_frame
		_check(hud.journal_panel._lightbox != null and hud.journal_panel._lightbox.visible, "клик по карточке открывает лайтбокс")
		_check(root.get_visible_rect().encloses(hud.journal_panel._lightbox.get_global_rect()), "лайтбокс помещается в 1280×720")
		await _shot("hud_journal_lightbox")
		# 19.11.2026: листание меняет карточку, затемнение (само окно) остаётся тем же
		var shade: Control = hud.journal_panel._lightbox
		for b: Node in shade.find_children("*", "Button", true, false):
			if (b as Button).text.begins_with("Следующий") and not (b as Button).disabled:
				(b as Button).pressed.emit()
				await process_frame
				_check(hud.journal_panel._lightbox == shade and shade.get_child_count() == 1, "листание лайтбокса не пересоздаёт окно")
				break
		_check(hud.journal_panel.close_lightbox() and hud.journal_panel._lightbox == null, "лайтбокс закрывается")
	# 19.11.2026: Tab под «Путешествием» не переключает вид сводки вслепую
	var mode_before: int = hud.view_mode
	await _tap_hud()
	_check(hud.view_mode == mode_before and not hud.summary_visible(), "Tab под «Путешествием» не меняет вид сводки")
	var old_scale := root.content_scale_size
	var old_size := root.size
	root.content_scale_size = Vector2i.ZERO
	root.size = Vector2i(720, 560)
	hud.show_tablet(Hud.Tablet.Tab.PATH)
	await _shot("hud_tablet_narrow")
	_check(hud.journal_panel._map_row.vertical and root.get_visible_rect().encloses(hud.journal_panel.get_global_rect()),
		"на узком экране док переезжает под карту")
	hud.show_tablet(Hud.Tablet.Tab.ALBUM)
	await _shot("hud_album_narrow")
	_check(root.get_visible_rect().encloses(hud.journal_panel.get_global_rect()) and hud.journal_panel._album_columns() < 5,
		"сетка альбома сужается вместе с планшетом")
	root.content_scale_size = old_scale
	root.size = old_size
	await process_frame
	# сообщения: пролежавшее под окном дольше TOAST_STALE некритичное сгорает, задание остаётся
	hud._toast_queue.clear()
	hud._toast_kinds.clear()
	hud._toast_left = 0.0
	hud.toast("Открыто: проба", &"discovery")
	hud.toast("Задание: проба", &"quest")
	hud._toast_hidden_for = Hud.TOAST_STALE + 1.0
	hud.journal_panel.clear()
	_check(not hud.journal_panel.visible, "закрытие прячет экран")
	await process_frame
	_check(hud.toast_label.text == "Задание: проба" and hud._toast_queue.is_empty(), "устаревшее сообщение не всплывает после окна, задание остаётся")
	# переполненная очередь теряет неважное, а не последнее пришедшее задание
	hud._toast_left = Hud.TOAST_TIME
	hud.toast_label.text = "текущее"
	hud._toast_queue.clear()
	hud._toast_kinds.clear()
	for i in 3:
		hud.toast("Открыто место %d" % i, &"discovery")
	hud.toast("Задание выполнено: проба", &"quest")
	_check(hud._toast_queue.size() == Hud.TOAST_QUEUE and hud._toast_queue.has("Задание выполнено: проба"), "очередь сообщений сохраняет задание при переполнении")
	hud._toast_queue.clear()
	hud._toast_kinds.clear()
	hud._toast_left = 0.0
	hud.explore = Exploration.new()


## 18.11.2026: доска поселения и табличка обелиска — та же палитра HudStyle, что у остального HUD
func _panel_shots(world: WorldData) -> void:
	hud.settlement_panel.open(world.settlements[0], world, [], false, hud.quests)
	_check(hud.settlement_panel.visible, "доска поселения открывается")
	await _shot("hud_board")
	_check(root.get_visible_rect().encloses(hud.settlement_panel.get_global_rect()), "доска помещается в 1280×720")
	hud.settlement_panel.clear()
	hud.plaque_panel.open("Обелиск у брода", "Здесь в старину переправлялись гурты: камень ставили, чтобы брод находили и в половодье.", "Снимите табличку — она попадёт в альбом", {form = 4, in_album = false, series = Vector2i(2, 5)})
	await _shot("hud_plaque")
	_check(root.get_visible_rect().encloses(hud.plaque_panel.get_global_rect()), "табличка помещается в 1280×720")
	_check(hud.plaque_panel._close.size.x < 220.0 and hud.plaque_panel._close.size.y >= 44.0, "кнопка закрытия таблички компактная (≥44 px по высоте)")
	hud.plaque_panel.clear()


func _run() -> void:
	_build()
	await process_frame
	hud = main.get_node("UI/Root/Hud")
	for path: String in ["UI/Root/Back", "UI/Root/Menu"]:
		main.get_node(path).visible = false
	hud.visible = true
	hud.lock_hint.visible = false
	var world := _map_fixture()
	var map := Image.create(128, 128, false, Image.FORMAT_RGB8)
	map.fill(Color(0.85, 0.88, 0.9))
	hud.set_world(world, map)
	hud.set_player(512, 512, 0.3)
	await process_frame
	await _map_checks(world)
	var player := PlayerState.new()
	player.x = 512
	player.z = 512
	player.feet = 1240
	hud.update_info(player, 0.3, 0.0)
	hud.set_clock(5.5)
	_check(hud._clock_label.text == "05:30" and hud._clock_label.get_parent().visible
		and hud._altitude.text == "1240 м" and hud._temperature.text == "−12 °C", "часы и показания местности выведены отдельными полями")
	hud.quests = Hud.Quests.new()
	var delivery := QuestData.new("hud", "delivery")
	delivery.title = "Письма для Каменки"
	delivery.steps.append({do = "pickup", place = {name = "Ольховка", kind = "settlement", x = 126, y = 114}})
	delivery.steps.append({do = "carry", place = {name = "Каменка", kind = "settlement", x = 139, y = 120}})
	delivery.step = 1
	hud.quests.active = delivery
	hud.quests.cargo = true
	hud.quest_changed()
	_check(hud.tracker.visible and hud._tracker_count.text == "2 / 2" and hud._tracker_note.visible, "карточка задания показывает ход доставки")
	await _shot("hud_map")
	# 18.11.2026: маршрут на мини-карте и цель за краем круга — значок на ободке с расстоянием
	var far_goal := Hud.marker_goal(Vector2(260, 60))
	hud.set_goal(far_goal)
	# маршрут по настоящей дороге фикстуры: подход от игрока, затем её точки
	var road_pts := PackedVector2Array([Vector2(512, 512)])
	for t: Dictionary in world.trails:
		if t.kind == "road":
			for p: Variant in t.pts.slice(2):
				road_pts.append(Vector2(p.x, p.y) * GameConfig.TILE)
			break
	road_pts.append(Vector2(1040, 240))
	var mini_draws := {terrain = 0, route = 0}
	hud.minimap._lines_canvas.draw.connect(func() -> void: mini_draws.terrain += 1)
	hud.minimap._route_canvas.draw.connect(func() -> void: mini_draws.route += 1)
	hud.minimap.set_route(road_pts, 1, road_pts.size() - 2)
	var icons: Array[Dictionary] = [{at = Vector2(470, 470), kind = "peak"}, {at = Vector2(474, 472), kind = "site"},
		{at = Vector2(600, 560), kind = "site"}]
	hud.minimap.set_places(icons)
	await process_frame
	_check(hud.minimap._route.size() > 3 and not hud.minimap._fits(hud.minimap.world_to_map(Vector2(1040, 240)), 8.0), "маршрут на мини-карте, цель за краем круга")
	_check(mini_draws.terrain == 0 and mini_draws.route > 0, "a new minimap route retains the road and river geometry")
	await _shot("hud_minimap_route")
	hud.minimap.set_route(PackedVector2Array())
	hud.set_goal(Hud.marker_goal(Vector2(139, 122)))
	# 18.11.2026: личная карта в стиле нацпарка — открыто только вокруг пройденного пути и открытых мест
	for i in 40:
		hud.map_journal.record(Vector2(400 + i * 8.0, 470 + sin(i * 0.3) * 30.0), 0.3, true)
	hud.set_map_visible(true)
	await create_timer(0.6).timeout
	_check(hud.big_map._fog != null and hud.big_map._fog.get_pixelv(Vector2i(Vector2(512, 512) / hud.big_map.FOG_CELL)).a < 0.1
		and hud.big_map._fog.get_pixel(0, 0).a > 0.9, "личная карта: у пути открыто, вдали бумага")
	await _shot("hud_big_map")
	# 19.11.2026: «прыжок» на открытой карте возвращает обзор к игроку (геймпад и клавиатура без СКМ)
	hud.big_map._center += Vector2(300, 200)
	var jump := InputEventAction.new()
	jump.action = &"jump"
	jump.pressed = true
	_check(hud.big_map.map_action(jump) and hud.big_map._center.is_equal_approx(hud.big_map.player.clamp(hud.big_map._bounds.position, hud.big_map._bounds.end)),
		"карта: «прыжок» — к себе")
	hud.big_map.controls.joypad = true
	await process_frame
	await process_frame
	_check(hud.big_map._pad_cross and hud.big_map.move_hint.begins_with("Левый стик"), "карта с геймпада: прицел и подсказка под геймпад")
	await _shot("hud_big_map_pad")
	hud.big_map.controls.joypad = false
	if hud.big_map._data.atlas_texture != null:
		_check(hud.big_map._data.atlas_relief.size() == 3 and hud.big_map._tiles.material != null,
			"атлас использует высоты для отмывки и изолиний")
		var road_mesh: ArrayMesh = hud.big_map._data.atlas_strokes[hud.big_map.Data.Line.ROAD]
		_check(road_mesh != null and road_mesh.surface_get_array_index_len(0) > 0,
			"личная карта использует готовый меш дорог")
		hud.big_map._zoom_at(root.size * 0.5, 1.4)
		await process_frame
		await process_frame
		_check(hud.big_map._atlas_layers[2 * hud.big_map.Data.Line.ROAD].mesh == road_mesh,
			"масштаб меняет толщину штриха без пересборки меша")
		hud.set_map_visible(false)
		hud.set_map_visible(true)
		await process_frame
		_check(hud.big_map._atlas_layers[2 * hud.big_map.Data.Line.ROAD].mesh == road_mesh,
			"повторное открытие использует тот же меш дорог")
	var close_map: Button = hud.journal_panel._close
	_check(close_map != null and close_map.icon == Hud.UiIcons.CLOSE and close_map.size.x >= 44.0 and close_map.size.y >= 44.0,
		"кнопка закрытия карты имеет иконку и размер >= 44x44 px")
	var atlas_draws := {track = 0}
	hud.big_map._track.draw.connect(func() -> void: atlas_draws.track += 1)
	hud.set_player(515, 512, 0.6)
	await process_frame
	await process_frame
	_check(atlas_draws.track == 0 and is_equal_approx(hud.big_map._player_arrow.rotation, -0.6),
		"moving or turning the atlas player arrow retains the trip geometry")
	hud.set_map_visible(false)
	await _journal_checks()
	await _panel_shots(world)
	var seen_icons := {}
	for qkind: String in Hud.Quests.KINDS:
		var tex := Hud.UiIcons.quest(qkind)
		_check(tex != null and not seen_icons.has(tex), "вид задания %s имеет уникальную иконку" % qkind)
		if tex != null:
			seen_icons[tex] = qkind
	hud.toast_now("Открыто место: перевал Седой", &"discovery")
	hud.toast("Достигнута цель", &"discovery")
	hud.toast_now("Открыто место: перевал Седой", &"discovery")
	_check(hud._toast_queue.size() == 1 and hud.toast_label.text.begins_with("Открыто"), "очередь сохраняет событие без дубля")
	var expected_toasts := {
		discovery = [Hud.UiIcons.QUESTS.visit, Hud.HudStyle.MINT],
		album = [Hud.UiIcons.ALBUM, Hud.HudStyle.AMBER],
		warning = [Hud.UiIcons.ALERT, Hud.HudStyle.RED],
		quest = [Hud.UiIcons.quest("delivery"), hud.quest_color()],
		info = [Hud.UiIcons.INFO, Hud.HudStyle.MUTED],
	}
	for tkind_str: String in expected_toasts:
		var tkind := StringName(tkind_str)
		hud._toast_left = 0.0
		hud._toast_queue.clear()
		hud._toast_kinds.clear()
		hud.toast("Проверка: " + tkind_str, tkind)
		var spec: Array = expected_toasts[tkind_str]
		_check(hud._toast_icon.texture == spec[0] and hud._toast_panel_style.border_color.is_equal_approx(Color(spec[1], 0.9)),
			"тост %s задаёт иконку и акцент" % tkind_str)
	hud._toast_left = 0.0
	hud.toast_now("Груз разбит\nПосылка повреждена", &"warning")
	await create_timer(0.25).timeout
	await _shot("hud_toast_warning")
	# 19.11.2026: карточка сообщения — постоянной ширины колонки и по высоте под текст (после длинного короткое не стоит
	# в высокой пустой карточке); тот же текст в течение TOAST_REPEAT не повторяется
	var toast_card: Control = hud.get_node("Toast")
	hud._toast_left = 0.0
	hud.toast_now("Новое место: «Старая мельница у брода», заброшенная мельница. Отмечено на карте; до ближайшей деревни около двух километров по лесной дороге")
	await process_frame
	await process_frame
	var tall := toast_card.size.y
	hud._toast_left = 0.0
	hud.toast_now("Велосипед ждёт рядом с костром")
	await process_frame
	await process_frame
	_check(is_equal_approx(toast_card.size.x, Hud.LEFT_WIDTH) and toast_card.size.y < tall
		and toast_card.size.y <= toast_card.get_combined_minimum_size().y + 0.5,
		"сообщение: ширина %.0f, высота %.0f после длинного %.0f — по тексту" % [toast_card.size.x, toast_card.size.y, tall])
	await _shot("hud_toast_short")
	hud._toast_left = 0.0
	hud.toast("Велосипед ждёт рядом с костром")
	_check(hud._toast_left == 0.0, "то же сообщение сразу не повторяется")
	hud._toast_left = 0.0
	hud.get_node("Toast").hide()
	hud.set_hints([["Shift", "Сильнее"], ["Пробел", "Прыжок"], ["F", "Слезть"], ["Y", "Поставить велосипед"]], [["F", "Доска «Ольховка»"]])
	_check(hud.hint.get_child_count() == 4 and hud.prompt.get_child_count() == 1, "чипы: четыре внизу и один у прицела")
	_check(hud._reticle_on_target, "прицел обозначает доступное действие")
	# 15.0: рывок (Shift) берёт треть полоски: с 40 % остаётся ~7 % — пульс и затемнение краёв в приливе
	var stamina := Stamina.new()
	stamina.value = 0.4
	await _tick(stamina, 75, true, 1.0, true)
	_check(stamina.value < 0.2 and hud._ride.warning > 0.05 and hud._vignette.visible and hud._ride.visible, "ниже 20 %% при трате — предупреждение (%.2f)" % hud._ride.warning)
	_check(hud._ride._ghost > stamina.value, "шлейф отстаёт от заливки")
	await _shot("hud_drain")
	# Brake gauge: normal braking, danger, and contexts where it must disappear.
	var bike := BikeRide.new()
	bike.riding = true
	bike.speed = 12.0
	bike.brakes.pressure = 0.75
	for frame in 30:
		hud.set_brakes(bike)
		await process_frame
	_check(hud._ride.visible and hud._ride.brake_alpha > 0.9 and hud._ride.pressure > 0.7 and hud._ride.riding, "дуга тормоза и скорость на приборе при движении вперёд")
	await _shot("hud_brake")
	bike.brakes.risk = 0.8
	hud.set_brakes(bike)
	await _shot("hud_brake_warning")
	bike.airborne = true
	hud.set_brakes(bike)
	_check(hud._ride.brake_alpha == 0.0, "в полёте дуга тормоза скрыта сразу")
	bike.airborne = false
	bike.speed = -2.0
	for frame in 30:
		hud.set_brakes(bike)
		await process_frame
	_check(hud._ride.brake_alpha < 0.01, "задний ход не показывает торможение")
	# истощение, потом накат: предупреждение гаснет быстро, ореол наката
	await _tick(stamina, 330, true, 1.0, true)
	_check(stamina.exhausted, "полоска истощена")
	await _tick(stamina, 30, true, 0.0, false)
	_check(stamina.state == Stamina.State.COAST and hud._ride.warning < 0.05 and hud._ride._coast > 0.9, "накат: предупреждение погасло, ореол наката")
	await _tick(stamina, 150, true, 0.0, false)
	await _shot("hud_coast")
	hud.set_hints([["Правый бампер", "Поставить велосипед"], ["Треугольник", "Открыть меню"],
		["Левый стик", "Повернуть велосипед"], ["Крестик", "Подтвердить"],
		["Кружок", "Отменить размещение"], ["Левый бампер", "Переключить карту"]], [])
	await process_frame
	await process_frame
	_check(hud.hint.get_line_count() > 1 and hud.get_global_rect().encloses(hud.hint.get_global_rect()),
		"длинные подсказки переносятся внутри экрана")
	# меню: карточка над кнопкой запуска, зерно можно изменить на отдельном экране
	hud.visible = false
	main.get_node("UI/Root/Back").visible = true
	main.get_node("UI/Root/Menu").visible = true
	main._show_seed_tab("recommended")
	var start: Button = main.get_node("%Start")
	var edit: LineEdit = main.get_node("%SeedEdit")
	_check(start.get_index() > main.get_node("%Carousel").get_index(), "«Начать путешествие» под карточкой")
	main._pick_seed("Туман-4821")
	_check(edit.text == "Туман-4821" and main._chosen_seed() == "Туман-4821", "выбор в списке ставит зерно в поле")
	await _shot("menu")
	var panel: Control = main.get_node("UI/Root/Menu/Panel")
	_check(root.get_visible_rect().encloses(panel.get_global_rect()), "меню целиком помещается в 1280×720")
	main.get_node("%InfiniteWarning").show()
	main.get_node("%WorldStatus").text = "Сохранение не читается. Можно создать мир заново; старые файлы сохранятся в архиве."
	await _shot("menu_warning")
	_check(root.get_visible_rect().encloses(panel.get_global_rect()), "меню с предупреждениями целиком помещается в 1280×720")
	var journey_btn: Button = main.get_node("%Journey")
	_check(journey_btn.icon != null, "кнопка «Путешествие» в меню паузы имеет иконку")
	print("hud_look: %s, снимки в %s" % ["FAIL %d" % failed if failed else "ok", out])
	quit(1 if failed else 0)
