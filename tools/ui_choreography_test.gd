extends SceneTree
## Изолированная проверка хореографии UI 5.1–5.3, тактильных звуков, отмены загрузки, паузы и live-preview.

var _fails := 0

class BackdropProbe extends "res://scripts/ui/menu_backdrop.gd":
	var ticks := 0

	func _process(_delta: float) -> void:
		ticks += 1


func _check(ok: bool, label: String) -> void:
	print(("OK " if ok else "FAIL ") + label)
	if not ok:
		_fails += 1


func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 60)
	_run.call_deferred()


func _pad_button(index: int, pressed := true) -> InputEventJoypadButton:
	var ev := InputEventJoypadButton.new()
	ev.button_index = index
	ev.pressed = pressed
	return ev


func _action_event(action_name: StringName, pressed := true) -> InputEventAction:
	var ev := InputEventAction.new()
	ev.action = action_name
	ev.pressed = pressed
	return ev


func _run() -> void:
	var dir_path := "res://.godot/ui_choreography_test"
	DirAccess.make_dir_recursive_absolute(dir_path)
	var settings_file := dir_path + "/settings.cfg"
	if FileAccess.file_exists(settings_file):
		DirAccess.remove_absolute(settings_file)
	GameContext.scope.settings.reset()
	GameContext.scope.settings.settings_path = settings_file
	var fav_seeds: Array[String] = []
	for i in GameSettings.FAVORITES_MAX:
		fav_seeds.append("Fav-%02d" % i)
	var recent_list: Array[String] = ["Extra-99"]
	for i in mini(4, fav_seeds.size()):
		recent_list.append(fav_seeds[i])
	GameContext.scope.settings.favorite_seeds = fav_seeds.duplicate()
	GameContext.scope.settings.recent_seeds = recent_list
	GameContext.scope.settings.last_seed = "Fav-00"
	GameContext.scope.settings.save_settings()

	var main: Node = (load("res://scenes/main.tscn") as PackedScene).instantiate()
	root.add_child(main)
	await process_frame
	await process_frame

	main._ui_stack.force_animate_in_headless = true
	var carousel := main.get_node("%Carousel")
	carousel.force_animate_in_headless = true

	await _test_main_and_carousel(main, carousel)
	await _test_shop(main)
	await _test_loading_and_cancellation(main)
	await _test_pause_settings_and_live_preview(main)

	main._free_game()
	main.queue_free()
	await process_frame

	if FileAccess.file_exists(settings_file):
		DirAccess.remove_absolute(settings_file)
	GameContext.scope.settings.reset()
	GameContext.scope.settings.load_settings()

	print("ui_choreography_test failures: ", _fails)
	quit(1 if _fails else 0)


func _test_shop(main: Node) -> void:
	var previous_size := root.size
	root.size = Vector2i(1280, 800)
	var shop_button := main.get_node("%OpenShop") as Button
	var backdrop := BackdropProbe.new()
	main.add_child(backdrop)
	main._backdrop = backdrop
	main._backdrop_mode = "live"
	main._progress_enabled = true
	shop_button.pressed.emit()
	var frozen_ticks := backdrop.ticks
	await process_frame
	await process_frame
	var shop: Control = main._shop
	_check(main._ui_stack.is_open("shop") and shop._rows.ember.has_focus() and shop._preview.texture != null,
		"магазин в меню показывает стартовую расцветку и ставит фокус на неё")
	_check(backdrop.process_mode == Node.PROCESS_MODE_DISABLED and backdrop.ticks == frozen_ticks,
		"при открытом магазине фон не получает обновления кадра")
	var preview: Texture2D = shop._preview.texture
	await process_frame
	_check(shop._preview.texture == preview and not shop.is_processing(), "витрина не обновляет превью в простое")
	root.push_input(_pad_button(JOY_BUTTON_DPAD_DOWN))
	_check(shop._rows.glacier.has_focus() and shop._selection == "glacier",
		"крестовина выбирает на превью расцветку в фокусе")
	root.push_input(_pad_button(JOY_BUTTON_DPAD_RIGHT))
	_check(shop._goal_action.has_focus(), "вправо переводит фокус к цели, когда очков на покупку мало")
	shop._rows.moss.pressed.emit()
	_check(shop._action.disabled and shop._note.text.contains("50"), "магазин показывает, сколько очков не хватает")
	_check(shop._rows.moss.button_pressed and not shop._rows.ember.button_pressed,
		"подсвечена только расцветка на превью")
	shop._goal_action.pressed.emit()
	main._shop_progress.award("Тест-1000", ["start:home"])
	_check(shop._goal_card.visible and shop._goal_bar.value == 20.0 and shop._goal_status.text.contains("Осталось 30"),
		"выбранная цель показывает прогресс после задания")
	shop._rows.glacier.pressed.emit()
	_check(shop._goal_action.text == "Сменить цель" and main._shop_progress.purchase_goal == "moss",
		"просмотр другой расцветки сам по себе не меняет цель")
	shop._goal_action.pressed.emit()
	_check(main._shop_progress.purchase_goal == "glacier" and shop._goal_bar.value == 20.0,
		"смена цели переносит прогресс без списания очков")
	shop._goal_action.pressed.emit()
	_check(not shop._goal_card.visible and main._shop_progress.balance == 20, "цель можно снять без потери очков")
	shop._rows.moss.pressed.emit()
	shop._goal_action.pressed.emit()
	main._shop_progress.award("Тест-1000", ["supplies:home>farm"])
	_check(shop._goal_status.text.begins_with("Можно купить") and not shop._action.disabled, "цель отмечается доступной при достижении суммы")
	shop._rows.night.pressed.emit()
	_check(shop._note.text.contains("На «Мох» нужно будет ещё 50"), "покупка вне цели заранее показывает новый остаток до цели")
	shop._rows.moss.pressed.emit()
	shop._action.pressed.emit()
	shop._action.pressed.emit()
	await process_frame
	_check(shop._cancel_buy.has_focus() and main._shop_progress.balance == 50 and not main._shop_progress.owns("moss"),
		"повторный ввод на покупке не списывает очки, фокус стоит на отмене")
	_check(shop.get_global_rect().encloses(shop._review_actions.get_global_rect())
		and shop._note.get_theme_font_size("font_size") >= 16 and shop._note.text.contains("«Мох» за 50"),
		"подтверждение и итог покупки видны в интерфейсе 1280×800")
	var double_click := InputEventMouseButton.new()
	double_click.position = shop._confirm_buy.get_global_rect().get_center()
	double_click.button_index = MOUSE_BUTTON_LEFT
	double_click.pressed = true
	double_click.double_click = true
	root.push_input(double_click, true)
	var release := double_click.duplicate() as InputEventMouseButton
	release.pressed = false
	release.double_click = false
	root.push_input(release, true)
	_check(main._shop_progress.balance == 50 and shop._review_actions.visible,
		"второй щелчок поверх появившейся кнопки подтверждения не списывает очки")
	root.push_input(_pad_button(JOY_BUTTON_B))
	_check(main._ui_stack.is_open("shop") and not shop._review_actions.visible and main._shop_progress.balance == 50,
		"B отменяет покупку и оставляет магазин открытым")
	shop._action.pressed.emit()
	await process_frame
	root.push_input(_pad_button(JOY_BUTTON_DPAD_RIGHT))
	_check(shop._confirm_buy.has_focus(), "подтверждение доступно с крестовины")
	shop._confirm_buy.pressed.emit()
	shop._confirm_buy.pressed.emit()
	_check(shop._action.text == "Надеть" and main._shop_progress.balance == 0 and not shop._goal_card.visible
		and shop._collection.text.ends_with("2 из 4") and main._shop_progress.equipped == "ember"
		and main._ui_audio.last_sound == &"confirm", "покупка пополняет коллекцию один раз и подтверждается звуком")
	shop._action.pressed.emit()
	_check(main._shop_progress.equipped == "moss", "купленную расцветку можно надеть")
	root.push_input(_pad_button(JOY_BUTTON_B))
	_check(main._ui_stack.is_open("menu") and shop_button.has_focus(), "возврат из магазина восстанавливает фокус меню")
	await create_timer(0.24).timeout
	_check(main._backdrop == backdrop and backdrop.ticks > frozen_ticks, "фон продолжает работу без пересоздания")
	main._progress_enabled = false
	main._backdrop = null
	main._backdrop_mode = ""
	backdrop.queue_free()
	root.size = previous_size


func _test_main_and_carousel(main: Node, carousel: Node) -> void:
	var open_worlds := main.get_node("%OpenWorlds") as Button
	var open_new := main.get_node("%OpenNew") as Button
	var dimmer := main.get_node("%Dimmer") as ColorRect

	_check(not dimmer.visible and is_equal_approx(dimmer.color.a, 0.0), "5.1 Dimmer скрыт в главном меню")

	open_worlds.grab_focus()
	main._open_all_worlds()
	await process_frame
	await process_frame
	await create_timer(0.04).timeout
	_check(main._ui_stack.is_open("all_worlds"), "5.1 AllWorlds добавлен в стек")
	_check(dimmer.visible and dimmer.color.a > 0.0 and dimmer.color.a <= 0.36, "5.1 Dimmer поднимает alpha к 0.35 над Backdrop")
	_check(main._ui_audio.last_sound == &"panel_open", "5.1 открытие AllWorlds играет panel_open")

	# Немедленная отмена в середине открытия через Joypad B возвращает фокус на OpenWorlds
	root.push_input(_pad_button(JOY_BUTTON_B))
	_check(main._ui_stack.is_open("menu"), "5.1 B во время открытия AllWorlds сразу возвращает стек в Menu")
	_check(open_worlds.has_focus(), "5.1 стек фокуса возвращает фокус на OpenWorlds")
	_check(main._ui_audio.last_sound == &"panel_close", "5.1 закрытие подэкрана играет panel_close")
	await create_timer(0.24).timeout
	_check(not main.get_node("%AllWorlds").visible and not dimmer.visible and is_equal_approx(dimmer.color.a, 0.0), "5.1 после отката AllWorlds и Dimmer полностью скрыты")

	# То же для NewWorld -> OpenNew
	open_new.grab_focus()
	main._open_new_world()
	await create_timer(0.05).timeout
	_check(main._ui_stack.is_open("new_world"), "5.1 NewWorld открыт поверх Menu")
	root.push_input(_pad_button(JOY_BUTTON_B))
	_check(main._ui_stack.is_open("menu") and open_new.has_focus(), "5.1 B из NewWorld возвращает фокус на OpenNew")
	await create_timer(0.24).timeout

	# WorldCarousel: направленный сдвиг и устойчивость к быстрому спаму
	var step_dirs: Array[int] = []
	carousel.stepped.connect(func(d: int) -> void: step_dirs.append(d))
	var card := carousel._card as Control
	var before_ticks := int(main._ui_audio.play_counts.get(&"carousel_step", 0))
	carousel.move(1)
	_check(step_dirs.size() == 1 and step_dirs[0] == 1, "5.1 WorldCarousel move(1) шлёт stepped(1)")
	_check(int(main._ui_audio.play_counts.get(&"carousel_step", 0)) > before_ticks, "5.1 переключение карусели играет carousel_step")
	await create_timer(0.03).timeout
	_check(card.position.x < -0.5, "5.1 старая карточка уезжает влево (-24 * dir)")
	await create_timer(0.09).timeout
	_check(card.position.x > 0.5, "5.1 новая карточка въезжает справа (+24 * dir -> 0)")

	# Быстрый спам переключений убивает прошлый Tween и чисто доходит до 0 / alpha=1
	carousel.move(1)
	await process_frame
	carousel.move(-1)
	await process_frame
	carousel.move(-1)
	await create_timer(0.35).timeout
	_check(is_zero_approx(card.position.x) and is_equal_approx(card.modulate.a, 1.0) and carousel._fade == null,
		"5.1 после быстрого спама карусель чисто останавливается в 0 с alpha=1")

	# _seed_row без «кнопки внутри кнопки» + отклик при заполненном избранном (12)
	main._open_all_worlds()
	await create_timer(0.22).timeout
	main._show_seed_tab("recent")
	var list := main.get_node("%SeedList") as VBoxContainer
	_check(list.get_child_count() > 0, "5.1 список недавних миров содержит строки")
	var first_row := list.get_child(0)
	_check(first_row is PanelContainer, "5.1 строка _seed_row построена как PanelContainer")
	var sel_btn := first_row.get_meta("select_button") as Button if first_row.has_meta("select_button") else null
	var star_btn := first_row.get_meta("star_button") as Button if first_row.has_meta("star_button") else null
	_check(sel_btn != null and star_btn != null and not sel_btn.is_ancestor_of(star_btn) and not star_btn.is_ancestor_of(sel_btn),
		"5.1 select_button и star_button являются sibling-узлами, а не кнопкой внутри кнопки")
	_check(sel_btn.get_node_or_null(sel_btn.focus_neighbor_right) == star_btn and star_btn.get_node_or_null(star_btn.focus_neighbor_left) == sel_btn,
		"5.1 фокус навигации чётко связан вправо/влево между строкой и звёздочкой")

	var extra_star: Button = null
	for row in list.get_children():
		if row.has_meta("seed") and str(row.get_meta("seed")) == "Extra-99":
			extra_star = row.get_meta("star_button") as Button if row.has_meta("star_button") else null
			break
	_check(extra_star != null and not extra_star.disabled and extra_star.modulate.a < 0.9,
		"5.1 при заполненном избранном кнопка звёздочки остаётся доступной для фокуса/нажатия и визуально приглушена")
	if extra_star != null:
		extra_star.pressed.emit()
		var notice := main.get_node("%FavoritesNotice") as Label
		_check(main._ui_audio.last_sound == &"error_deny", "5.1 нажатие звёздочки при 12 избранных играет error_deny")
		_check(notice.visible and "Избранное заполнено (12)" in notice.text, "5.1 показывается краткая подпись о заполненном избранном (12)")

	main._return_to_menu_screen()
	await create_timer(0.20).timeout


func _test_loading_and_cancellation(main: Node) -> void:
	var loading := main.get_node("%Loading") as Control
	var panel := loading.get_node("Panel") as Control
	var back := main.get_node("%Back") as Control
	var previous_step := main.get_node("%PreviousStep") as Label
	var cancel := main.get_node("%CancelLoad") as Button
	main.busy = true
	main._load_started_ms = Time.get_ticks_msec()
	main._load_cancel_requested = false
	main._load_quit_requested = false
	main._load_cancel_flag = main.CancelFlag.new()
	main._set_progress(0.0, "Фаза 1", true)
	main._show("loading", {enter_duration = main.LOAD_ENTER_SECONDS})
	_check(loading.visible and is_zero_approx(loading.modulate.a) and cancel.has_focus(),
		"5.2 Loading проявляется из прозрачного состояния и получает фокус")
	await create_timer(0.22).timeout
	var bottom_left := panel.position + Vector2(0.0, panel.size.y)
	_check(bottom_left.is_equal_approx(Vector2(48.0, loading.size.y - 48.0)),
		"5.2 карточка Loading привязана к левому нижнему углу с отступом 48")

	main._set_progress(0.8, "Фаза 2")
	_check(is_zero_approx(main.bar.value) and previous_step.visible and previous_step.text == "Фаза 1",
		"5.2 Progress получает цель, предыдущая подпись остаётся видимой")
	main._tick_loading(0.05)
	_check(is_equal_approx(main.bar.value, 0.8 * Util.damp(8.0, 0.05)),
		"5.2 Progress плавно догоняет цель с дробной точностью")
	main._load_step_tween.custom_step(0.06)
	_check(is_equal_approx(previous_step.modulate.a, 0.5) and is_equal_approx(main.load_step.modulate.a, 0.5),
		"5.2 обе подписи видны на середине cross-fade")
	main._set_progress(0.9, "Фаза 3")
	await create_timer(0.16).timeout
	_check(not previous_step.visible and main.load_step.text == "Фаза 3" and is_equal_approx(main.load_step.modulate.a, 1.0),
		"5.2 быстрая смена этапа завершает cross-fade последней подписью")

	var dissolve: Tween = main._ui_stack.dissolve_to_world(back, loading, main.LOAD_DISSOLVE_SECONDS)
	dissolve.custom_step(0.07)
	var sine_alpha := 0.5 + cos(PI / 4.0) * 0.5
	_check(is_equal_approx(loading.modulate.a, sine_alpha) and is_equal_approx(back.modulate.a, sine_alpha)
		and is_zero_approx(loading.offset_top), "5.2 карточка и фон растворяются на месте по EaseInOutSine")
	dissolve.custom_step(0.22)
	_check(not loading.visible and not back.visible, "5.2 dissolve скрывает оба слоя по завершении")
	main._show("loading", {instant = true})

	# Управляемая неделимая фаза. После B поток остаётся жив, а отложенный прогресс игнорируется.
	var gate := Semaphore.new()
	main.gen_thread = Thread.new()
	main.gen_thread.start(func() -> WorldLoader:
		gate.wait()
		return null)
	root.push_input(_pad_button(JOY_BUTTON_B))
	_check(main._load_cancel_requested and main._load_cancel_flag.is_cancelled() and cancel.disabled,
		"5.2 B запрашивает отмену и блокирует повторное нажатие кнопки")
	var cancel_text: String = main.load_step.text
	main._report_load_progress(0.95, "Поздний этап", main._load_cancel_flag)
	await process_frame
	_check(main.busy and main.gen_thread.is_alive() and main.load_step.text == cancel_text,
		"5.2 ожидание не блокирует кадры, запоздалый прогресс не стирает статус")
	main._notification(Node.NOTIFICATION_WM_CLOSE_REQUEST)
	_check(main._load_quit_requested and "Выход" in main.load_step.text,
		"5.2 закрытие окна меняет уже запрошенную отмену на выход")
	main._load_quit_requested = false # Продолжить тест в том же SceneTree.
	gate.post()
	while main.busy:
		await process_frame
	_check(main.gen_thread == null and main._is_screen("menu"), "5.2 поток присоединён, меню восстановлено")

	# Esc в начале dissolve возвращает карточку и фоновый слой для статуса отмены.
	main.busy = true
	main._load_cancel_flag = main.CancelFlag.new()
	main._show("loading", {instant = true})
	dissolve = main._ui_stack.dissolve_to_world(back, loading, main.LOAD_DISSOLVE_SECONDS)
	dissolve.custom_step(0.07)
	root.push_input(_action_event(&"pause"))
	_check(main._is_screen("loading") and main._load_cancel_requested and loading.visible
		and is_equal_approx(loading.modulate.a, 1.0), "5.2 Esc отменяет переход до передачи управления")
	main.busy = false
	main._load_cancel_requested = false
	main._load_cancel_flag = null
	main._show("menu", {instant = true})

	var gen: WorldData = WorldGenerator.generate("cancel-test", 128, Callable(), Callable(), func() -> bool: return true)
	_check(gen == null, "5.2 WorldGenerator.generate немедленно прерывается при should_cancel=true")
	var loaded: WorldLoader = WorldLoader.load_world("cancel-test", 128, Callable(), null, Vector2.INF, func() -> bool: return true)
	_check(loaded != null and loaded.cancelled, "5.2 WorldLoader.load_world возвращает cancelled=true при should_cancel=true")


func _test_pause_settings_and_live_preview(main: Node) -> void:
	# 1) Плавное приглушение шины World + LPF на паузе
	var wa := WorldAudio.new()
	root.add_child(wa)
	await process_frame
	wa._roll.play()
	wa._water.play()
	var bus_idx := AudioServer.get_bus_index(WorldAudio.WORLD_BUS)
	_check(bus_idx != -1 and wa._water.bus == WorldAudio.WORLD_BUS and wa._fire.bus == WorldAudio.WORLD_BUS,
		"5.3 WorldAudio маршрутизирует источники через шину World")
	wa.set_ducked(true, 0.0)
	var lpf := AudioServer.get_bus_effect(bus_idx, 0) as AudioEffectLowPassFilter
	_check(is_equal_approx(AudioServer.get_bus_volume_db(bus_idx), WorldAudio.DUCK_DB)
		and AudioServer.is_bus_effect_enabled(bus_idx, 0) and is_equal_approx(lpf.cutoff_hz, WorldAudio.DUCK_CUTOFF_HZ),
		"5.3 пауза приглушает World на -18 dB и включает LPF 900 Гц")
	_check(wa._roll.stream_paused and not wa._water.stream_paused,
		"5.3 на паузе замирают звуки движения, но фон природы остаётся под фильтром")
	wa.set_ducked(false, 0.0)
	_check(is_equal_approx(AudioServer.get_bus_volume_db(bus_idx), 0.0) and not AudioServer.is_bus_effect_enabled(bus_idx, 0),
		"5.3 снятие паузы возвращает 0 dB и отключает LPF")
	wa.queue_free()
	await process_frame

	# 2) Изолированный GameWorld без генерации мира для проверки Alt+Tab бага и live-preview
	var gw := (load("res://scenes/game_world.tscn") as PackedScene).instantiate() as GameWorld
	main.add_child(gw)
	gw.set_process(false)
	gw.set_physics_process(false)
	gw.world = WorldData.new()
	gw.world.W = 64
	gw.world.H = 64
	gw.world.N = 4096
	gw.world.seed_text = "Тест-1000"
	gw.player = PlayerState.new()
	gw.player.x = 100.0
	gw.player.z = 100.0
	gw.player.feet = 10.0
	gw.bike = BikeRide.new()
	gw.crash = BikeCrash.new()
	gw.add_child(gw.crash)
	gw.photo = GameWorld.PhotoCamera.new()
	gw.add_child(gw.photo)
	gw.quests = GameWorld.Quests.new()
	gw.local_mist = preload("res://scripts/render/local_mist.gd").new()
	gw.local_mist.visible = false
	gw.add_child(gw.local_mist)
	gw.hud = main.hud
	gw.services = GameContext.scope
	main.hud.set_world(gw.world, Image.create(8, 8, false, Image.FORMAT_RGB8))
	main.game = gw
	gw.pause_requested.connect(main._toggle_pause)
	main._show("", {instant = true})
	main.hud.show()

	# Регрессия Alt+Tab: открытый Дневник -> пауза -> Esc/E/J в GameWorld не должны закрывать его и красть мышь
	gw.open_journal()
	var atlas: Hud.Atlas = main.hud.big_map
	root.push_input(_action_event(&"toggle_map"))
	_check(main.hud.journal_panel.active_tab == Hud.Tablet.Tab.MAP and main.hud.big_map == atlas and gw.show_map,
		"5.3 M переключает открытый планшет на ту же карту")
	root.push_input(_action_event(&"journal"))
	_check(main.hud.journal_panel.active_tab == Hud.Tablet.Tab.PATH and main.hud.big_map == atlas and gw.show_map,
		"5.3 J возвращает к пути без закрытия планшета")
	root.push_input(_pad_button(JOY_BUTTON_RIGHT_SHOULDER))
	_check(main.hud.journal_panel.active_tab == Hud.Tablet.Tab.ALBUM and not atlas.is_visible_in_tree(),
		"5.3 RB переключает планшет с пути на альбом")
	root.push_input(_pad_button(JOY_BUTTON_RIGHT_SHOULDER))
	var shop: Control = main.hud.journal_panel.shop_panel
	_check(main.hud.journal_panel.active_tab == Hud.Tablet.Tab.SHOP and not atlas.is_visible_in_tree()
		and shop._rows.moss.has_focus() and shop._action.text == "Надето",
		"RB открывает магазин в планшете с экипировкой из стартового меню (виден=%s, кнопка=%s)" % [
			shop.is_visible_in_tree(), shop._action.text])
	root.push_input(_action_event(&"journal"))
	gw._captured_at = 0
	_check(gw._journal_open() and Input.mouse_mode == Input.MOUSE_MODE_VISIBLE,
		"5.3 Дневник открывается с видимым курсором до паузы")
	main._toggle_pause()
	_check(gw.paused and main._is_screen("pause") and not main.hud.visible and main.get_node("%Resume").has_focus(),
		"5.3 пауза ставит игру на паузу, скрывает Hud и ставит фокус на Продолжить")
	_check(gw._journal_open() and Input.mouse_mode == Input.MOUSE_MODE_VISIBLE and gw._captured_at == 0,
		"5.3 при входе в паузу курсор остаётся свободным")
	for action_name: StringName in [&"pause", &"journal", &"interact"]:
		gw._unhandled_input(_action_event(action_name, true))
	_check(gw._journal_open() and Input.mouse_mode == Input.MOUSE_MODE_VISIBLE and gw._captured_at == 0,
		"5.3 ввод Esc/J/E на паузе не закрывает скрытый Дневник и не захватывает мышь поверх меню паузы")

	# Снятие паузы сохраняет MOUSE_MODE_VISIBLE пока открыт Дневник, и захватывает после его закрытия
	main._resume()
	_check(not gw.paused and gw._journal_open() and Input.mouse_mode == Input.MOUSE_MODE_VISIBLE and gw._captured_at == 0,
		"5.3 после снятия паузы при открытом Дневнике курсор не теряется")
	gw.close_journal()
	_check(not gw._journal_open() and gw._captured_at > 0 and (DisplayServer.get_name() == "headless" or Input.mouse_mode == Input.MOUSE_MODE_CAPTURED),
		"5.3 после закрытия Дневника управление взглядом корректно возвращает захват мыши")

	# Пауза -> B возвращает в игру; Пауза -> Настройки -> B возвращает в Паузу с фокусом на Настройках
	main._toggle_pause()
	var pause_settings := main.get_node("UI/Root/Pause/Panel/Box/Settings") as Button
	pause_settings.grab_focus()
	main._open_settings()
	_check(main._is_screen("settings") and main.get_node("%Done").has_focus(),
		"5.3 Настройки из паузы открываются со стартовым фокусом на Готово")

	# Выключенные ползунки VisualStyle получают FOCUS_NONE
	var grade_cb := main.display_options.style_on["grade"] as CheckBox
	var grade_slider := main.display_options.style_amount["grade"] as HSlider
	grade_cb.button_pressed = false
	_check(not grade_slider.editable and grade_slider.focus_mode == Control.FOCUS_NONE,
		"5.3 выключенный ползунок VisualStyle имеет focus_mode == FOCUS_NONE")
	grade_cb.button_pressed = true
	_check(grade_slider.editable and grade_slider.focus_mode == Control.FOCUS_ALL,
		"5.3 включение эффекта VisualStyle возвращает focus_mode == FOCUS_ALL")

	# LB / RB перелистывают вкладки настроек
	var tabs: TabContainer = main.display_options.tabs
	tabs.current_tab = 0
	root.push_input(_pad_button(JOY_BUTTON_RIGHT_SHOULDER))
	_check(tabs.current_tab == 1, "5.3 RB переключает вкладку настроек вперёд")
	root.push_input(_pad_button(JOY_BUTTON_LEFT_SHOULDER))
	_check(tabs.current_tab == 0, "5.3 LB переключает вкладку настроек назад")

	# Peek диммера (0.55 -> 0.25 -> 0.55) при перетаскивании FovSlider и volume_tick на VolumeSlider
	var fov_slider := main.get_node("%FovSlider") as HSlider
	fov_slider.drag_started.emit()
	_check(main._ui_stack._peek_active and is_equal_approx(main._ui_stack._effective_dimmer_alpha(), 0.25),
		"5.3 удержание FovSlider снижает Dimmer до peek alpha 0.25")
	fov_slider.drag_ended.emit(true)
	_check(not main._ui_stack._peek_active and is_equal_approx(main._ui_stack._effective_dimmer_alpha(), 0.55),
		"5.3 отпускание FovSlider возвращает Dimmer на 0.55")
	main._on_volume_changed(0.62)
	_check(main._ui_audio.last_sound == &"volume_tick",
		"5.3 ползунок громкости даёт нейтральный отклик volume_tick")

	# Live-preview FOV / частиц сразу на паузе и debounce растительности (200 мс)
	var before_veg_draw := GameContext.scope.settings.draw
	main._on_fov_changed(88.0)
	_check(is_equal_approx(gw.camera.fov, 88.0), "5.3 FOV применяется на камере мгновенно во время паузы")
	main.display_options.draw.select((before_veg_draw + 1) % main.display_options.draw.item_count)
	main.display_options.apply_graphics(&"vegetation")
	_check(gw._live_veg_dirty and gw._live_veg_due_ms > Time.get_ticks_msec() + 50,
		"5.3 смена качества растительности на паузе запускает 200 мс debounce пересборки")
	gw._live_veg_dirty = false
	main.display_options.draw.select(before_veg_draw)
	main.display_options.apply_graphics(&"vegetation")
	gw._live_veg_dirty = false

	# Joypad B из Настроек -> Пауза (фокус на кнопке Настройки), затем B из Паузы -> Игра
	root.push_input(_pad_button(JOY_BUTTON_B))
	_check(main._is_screen("pause") and pause_settings.has_focus(),
		"5.3 B в Настройках возвращает в Паузу и восстанавливает фокус на кнопке Настройки")

	# ConfirmationDialog для ToMenu / Exit: отмена по B и _cancel_confirm возвращает фокус на вызвавшую кнопку
	main._confirm_to_menu()
	_check(main._confirm != null, "5.3 диалог выхода в меню открывается")
	root.push_input(_pad_button(JOY_BUTTON_B))
	await process_frame
	_check(main._confirm == null and main.get_node("%ToMenu").has_focus(),
		"5.3 отмена диалога выхода в меню возвращает фокус на кнопку В меню")

	main._confirm_exit()
	_check(main._confirm != null, "5.3 диалог выхода из игры открывается")
	main._cancel_confirm()
	await process_frame
	_check(main._confirm == null and main.get_node("%Exit").has_focus(),
		"5.3 отмена диалога выхода из игры возвращает фокус на кнопку Выйти")

	# B из Паузы снимает паузу
	root.push_input(_pad_button(JOY_BUTTON_B))
	_check(not gw.paused and not main._is_screen("pause") and main.hud.visible,
		"5.3 B в меню паузы возвращает управление обратно в игру")
