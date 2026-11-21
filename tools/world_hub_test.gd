extends SceneTree

const Saves := preload("res://scripts/game/save_game.gd")
var failures := 0

func check(value: bool, message: String) -> void:
	print(("OK " if value else "FAIL ") + message)
	if not value: failures += 1

func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 60)
	_run.call_deferred()

func _run() -> void:
	root.size = Vector2i(1280, 720)
	var settings := GameContext.scope.settings
	var old_path := settings.settings_path
	settings.settings_path = "res://.godot/world_hub_test.cfg"
	settings.reset()
	settings.save_settings()
	var main: Node = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	await process_frame
	await process_frame
	settings.recent_seeds.clear()
	settings.favorite_seeds.clear()
	main._world_cards.clear()
	main._carousel_seeds.clear()
	main._saved_seeds.clear()
	main._previews.clear()
	for i in 20:
		var seed_text := "World-%02d" % i
		settings.recent_seeds.append(seed_text)
		main._carousel_seeds.append(seed_text)
		main._world_cards[seed_text] = {seed = seed_text, saved = i == 0, saved_at = 1, corrupt = false, manual = false, summary = "", ready = false, map_ready = false}
		main._previews[seed_text] = null
	main._saved_seeds.append("World-00")
	settings.favorite_seeds.append("World-10")
	main._selected_seed = "World-00"
	main._update_carousel()
	var input: LineEdit = main.get_node("%SeedEdit")
	input.text = "Незавершённый ввод"
	main._select_world("World-01")
	check(input.text == "Незавершённый ввод", "выбор мира сохраняет введённое зерно")
	# Формирование списка не должно синхронно обходить все файлы миниатюр.
	for i in range(2, 20): main._previews.erase("World-%02d" % i)
	var opening_reads: int = main._card_reads
	main._open_all_worlds()
	check(main._card_reads == opening_reads, "открытие списка не читает все миниатюры с диска")
	await process_frame
	await process_frame
	while not main._hub_build_queue.is_empty():
		await process_frame
	if "--capture-hub" in OS.get_cmdline_user_args():
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png("res://.godot/world_hub_capture.png")
	check(main._is_screen("world_hub") and main.get_node("%WorldSearch").has_focus(), "библиотека открывается с фокусом на поиске")
	check(main._hub_rows.size() == 20 and main.get_node("%SeedList").get_child_count() == 20, "каждому миру соответствует одна строка")
	main._open_storage()
	check(main._confirm != null and not main.get_node("%ClearAllSaves").visible, "массовая очистка перенесена в хранилище")
	main._close_confirm()
	check(main.get_node("%SeedList").get_child(0).get_meta("seed") == "World-00" and main.get_node("%SeedList").get_child(1).get_meta("seed") == "World-10", "сохранения и избранные отсортированы первыми")
	var scroll := main.get_node("%SeedList").get_parent() as ScrollContainer
	var cache := GameContext.scope.cache
	var old_cache_dir: String = cache.dir
	cache.dir = "res://.godot/world_hub_preview_%d" % OS.get_process_id()
	DirAccess.make_dir_recursive_absolute(cache.dir)
	var preview_path: String = cache.dir.path_join(cache._base("World-10", WorldGenerator.START_SIZE) + WorldCache.PREVIEW)
	var test_preview := Image.create(8, 8, false, Image.FORMAT_RGB8)
	test_preview.fill(Color.CORNFLOWER_BLUE)
	test_preview.save_png(preview_path)
	cache.enabled = true
	var reads_before_selection: int = main._card_reads
	main._select_world("World-05")
	check(main._card_reads == reads_before_selection, "выбор мира в списке не читает миниатюру в главном потоке")
	main._select_world("World-01")
	main._hub_preview_scan = true
	var reads_before_tick: int = main._card_reads
	main._tick_hub_previews()
	check(main._card_reads - reads_before_tick <= 1 and not main._previews.has("World-19"), "за раз запускается не больше одного фонового чтения видимой миниатюры")
	main._select_world("World-10")
	cache.enabled = false
	cache.dir = old_cache_dir
	while main._hub_preview_task != -1:
		await process_frame
	var thumb: TextureRect = main._hub_rows["World-10"].get_meta("thumb")
	check(main._previews.get("World-10") is ImageTexture and thumb.texture == main._previews["World-10"], "фоновая миниатюра появляется в нужной строке")
	check(main.get_node("%Preview").texture == thumb.texture, "фоновое превью обновляет выбранный мир в инспекторе")
	main._select_world("World-01")
	DirAccess.remove_absolute(preview_path)
	DirAccess.remove_absolute(preview_path.get_base_dir())
	scroll.scroll_vertical = 400
	await process_frame
	var before_scroll := scroll.scroll_vertical
	var row: Control = main._hub_rows["World-15"]
	var reads: int = main._card_reads
	var preview_count: int = main._previews.size()
	main._on_star("World-15", row.get_meta("star_button"))
	await process_frame
	await process_frame
	check(main._hub_rows["World-15"] == row and main._card_reads == reads and main._previews.size() == preview_count, "звезда сохраняет строки и превью без перечитывания")
	check(scroll.scroll_vertical == before_scroll, "звезда сохраняет позицию прокрутки")
	var carousel = main.get_node("%Carousel")
	var gate := Semaphore.new()
	carousel._loading_seed = "World-01"
	carousel._job_kind = "preview"
	carousel._cancel_flag = carousel.PreviewCancel.new()
	carousel._thread = Thread.new()
	carousel._thread.start(func() -> Array:
		gate.wait()
		return [])
	var preview_job: Thread = carousel._thread
	main._on_star("World-16", main._hub_rows["World-16"].get_meta("star_button"))
	check(carousel._thread == preview_job and not carousel._cancel_flag.is_cancelled(), "звезда не прерывает фоновое построение карты")
	carousel.invalidate_preview("World-01")
	check(carousel._cancel_flag.is_cancelled(), "изменение кэша отменяет публикацию старого расчёта карты")
	gate.post()
	preview_job.wait_to_finish()
	carousel._thread = null
	main._show_seed_tab("favorites")
	check(row.visible and not (main._hub_rows["World-01"] as Control).visible, "фильтр показывает избранные и скрывает остальные")
	main._show_seed_tab("all")
	var search: LineEdit = main.get_node("%WorldSearch")
	var selected: String = main._selected_seed
	search.text = "World-10"
	search.text_changed.emit(search.text)
	check((main._hub_rows["World-10"] as Control).visible and not (main._hub_rows["World-01"] as Control).visible and main._selected_seed == selected, "поиск фильтрует библиотеку, не выбирая и не запуская мир")
	check(main.get_node("%PlaySelected").disabled and main.get_node("%Star").disabled and main.get_node("%OpenWorldDetails").disabled and main.get_node("%HubBuildPreview").disabled and main.get_node("%HubRelief").disabled, "скрытый фильтром мир нельзя запустить, изменить или построить для него карту")
	search.text = ""
	search.text_changed.emit(search.text)
	check(not main.get_node("%PlaySelected").disabled, "после очистки поиска выбранный мир снова доступен")
	main._open_new_world()
	check(input.has_focus() and not main.get_node("%WorldSearch").is_visible_in_tree(), "форма создания открывается отдельно от библиотеки")
	input.text = "World-01"
	main._on_create_world()
	check(not main.busy and main._selected_seed == "World-01" and main.get_node("%WorldSearch").is_visible_in_tree(), "существующее зерно выбирает мир без запуска")
	for child in main.get_children():
		if child is AcceptDialog and child.title == "Мир уже есть":
			child.queue_free()
	await process_frame
	await process_frame
	scroll.scroll_vertical = 0
	var last_button: Button = main._hub_rows["World-19"].get_meta("select_button")
	last_button.grab_focus()
	await process_frame
	await process_frame
	check(scroll.scroll_vertical > 0, "клавиатура и геймпад прокручивают список вслед за фокусом")
	main._set_hub_map_mode(1)
	check(main.get_node("%HubAtlas").button_pressed and main.get_node("%Carousel")._mode == 1, "режим карты синхронизирован с витриной")
	check(not main.get_node("%LoadManual").visible, "ручная загрузка скрыта при отсутствии слота")
	main._world_cards["World-01"].manual = true
	main._update_selection()
	check(not main.get_node("%LoadManual").visible, "ручная загрузка не занимает место в закрытом меню")
	main.get_node("%MoreWorldActions").button_pressed = true
	check(main.get_node("%LoadManual").visible and not main.get_node("%LoadManual").disabled, "ручная загрузка доступна в дополнительных действиях")
	main.get_node("%MoreWorldActions").button_pressed = false
	var map_square := main.get_node("%Preview").get_parent().get_parent() as Control
	await process_frame
	check(absf(map_square.size.x - map_square.size.y) < 1.0, "карта инспектора квадратная")
	var panel := main.get_node("%AllWorlds/Panel") as Control
	check(panel.get_global_rect().end.y <= root.size.y + 1 and panel.get_global_rect().position.y >= -1, "экран помещается по высоте при 1280×720")
	main.get_node("%PlaySelected").grab_focus()
	root.size = Vector2i(800, 600)
	main._fit_menu()
	check(main._hub_show_details and main.get_node("%PlaySelected").has_focus(), "при сужении окна фокус и открытая карточка сохраняются")
	main._show_world_list()
	for dimensions: Vector2i in [Vector2i(800, 600), Vector2i(640, 360)]:
		root.size = dimensions
		main._fit_menu()
		await process_frame
		await process_frame
		check(root.get_visible_rect().encloses(panel.get_global_rect()), "экран помещается при %s" % dimensions)
		if main._hub_narrow:
			check(main.get_node("%Worlds").visible and not main.get_node("%Side").visible, "узкое окно открывает список миров")
			main._select_hub_row("World-01")
			check(main.get_node("%Side").visible and not main.get_node("%Worlds").visible, "выбор открывает карточку мира в узком окне")
			main.get_node("%MoreWorldActions").button_pressed = true
			await process_frame
			await process_frame
			check(main.get_node("%LoadManual").is_visible_in_tree() and root.get_visible_rect().encloses(panel.get_global_rect()), "дополнительные действия с ручным сохранением помещаются в узком окне")
			main.get_node("%MoreWorldActions").button_pressed = false
			main._show_world_list()
			check(main.get_node("%Worlds").visible, "возврат показывает список миров")
		if "--capture-hub" in OS.get_cmdline_user_args():
			print("HUB_LAYOUT ", dimensions, " panel=", panel.size, " scale=", panel.scale, " viewport=", root.get_visible_rect().size)
			await RenderingServer.frame_post_draw
			root.get_texture().get_image().save_png("res://.godot/world_hub_%dx%d.png" % [dimensions.x, dimensions.y])
	root.size = Vector2i(1280, 720)
	main._fit_menu()
	await process_frame
	await process_frame
	panel.custom_minimum_size = Vector2(1600, 1000)
	await process_frame
	await process_frame
	main._fit_hub()
	check(panel.scale.x < 1.0 and root.get_visible_rect().encloses(panel.get_global_rect()), "масштаб панели учитывает доступную область")
	main._fit_menu()
	await process_frame
	await process_frame
	var fake_image := Image.create(4, 4, false, Image.FORMAT_RGB8)
	var fake_texture := ImageTexture.create_from_image(fake_image)
	carousel._generated["World-01"] = fake_texture
	carousel._derived["World-01"] = [fake_texture, fake_texture]
	carousel._provisional_derived["World-01"] = true
	carousel._generated["World-02"] = fake_texture
	carousel.invalidate_preview("World-01")
	check(not carousel._generated.has("World-01") and not carousel._derived.has("World-01")
		and not carousel._provisional_derived.has("World-01") and carousel._generated.has("World-02"),
		"инвалидация удаляет только устаревшие карты изменённого мира")
	var stale_gate := Semaphore.new()
	var stale_result := {seed = "World-05", epoch = main._hub_preview_epoch, image = null}
	main._previews.erase("World-05")
	main._hub_preview_result = stale_result
	main._hub_preview_task = WorkerThreadPool.add_task(func() -> void:
		stale_gate.wait()
		stale_result.image = fake_image)
	main._invalidate_world_preview("World-05")
	stale_gate.post()
	while main._hub_preview_task != -1:
		await process_frame
	check(not main._previews.has("World-05"), "устаревший результат фонового чтения не возвращается после инвалидации")
	var settings_path: String = settings.settings_path
	var favorites_before: Array[String] = settings.favorite_seeds.duplicate()
	settings.settings_path = "res://.godot/missing_world_hub_dir/settings.cfg"
	var failing_star: Button = main._hub_rows["World-03"].get_meta("star_button")
	failing_star.pressed.emit()
	var error_dialog: AcceptDialog
	for child: Node in main.get_children():
		if child is AcceptDialog and child.title == "Не удалось изменить избранное":
			error_dialog = child
			break
	check(settings.favorite_seeds == favorites_before and error_dialog != null and main._ui_audio.last_sound == &"error_deny", "ошибка записи избранного откатывает изменение и показывает сообщение")
	if error_dialog != null: error_dialog.queue_free()
	settings.settings_path = settings_path
	var old_saves: String = Saves.dir
	Saves.dir = "res://.godot/world_hub_corrupt_%d" % OS.get_process_id()
	DirAccess.make_dir_recursive_absolute(Saves.dir)
	var corrupt_path: String = Saves.path_for("Broken")
	var corrupt_file := FileAccess.open(corrupt_path, FileAccess.WRITE)
	corrupt_file.store_string("broken")
	corrupt_file.close()
	main._launch_seed("Broken")
	check(not main.busy and main._selected_seed == "Broken" and main.get_node("%RestartWorld").has_focus()
		and main.get_node("%RestartWorld").modulate.r > main.get_node("%RestartWorld").modulate.g,
		"повреждённое сохранение открывает восстановление с красным акцентом")
	check(not main.get_node("%MoreWorldActions").visible and main.get_node("%WorldActions").visible, "восстановление сразу видно без ложного переключателя действий")
	DirAccess.remove_absolute(corrupt_path)
	DirAccess.remove_absolute(Saves.dir)
	Saves.dir = old_saves
	settings.favorite_seeds.clear()
	for i in GameSettings.FAVORITES_MAX: settings.favorite_seeds.append("Full-%d" % i)
	main._on_star("World-01", main.get_node("%Star"))
	check(main._ui_audio.last_sound == &"error_deny" and main.get_node("%FavoritesNotice").visible, "лимит избранного сообщает об ошибке")
	main._return_to_menu_screen()
	check(main._is_screen("menu") and main.get_node("%OpenWorlds").has_focus(), "возврат восстанавливает фокус на кнопке миров")
	main.queue_free()
	await process_frame
	await _test_large_list(settings)
	if FileAccess.file_exists(settings.settings_path): DirAccess.remove_absolute(settings.settings_path)
	settings.settings_path = old_path
	settings.reset()
	print("world_hub_test failures: ", failures)
	quit(1 if failures else 0)


func _test_large_list(settings: GameSettings) -> void:
	var main: Node = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	await process_frame
	settings.recent_seeds.clear()
	settings.favorite_seeds.clear()
	main._world_cards.clear()
	main._saved_seeds.clear()
	main._carousel_seeds.clear()
	main._previews.clear()
	for i in 120:
		var seed_text := "Many-%03d" % i
		main._world_cards[seed_text] = {seed = seed_text, saved = false, summary = "", ready = false, map_ready = false}
		main._carousel_seeds.append(seed_text)
		main._previews[seed_text] = null
	main._selected_seed = "Many-000"
	main._update_carousel()
	main._open_all_worlds()
	check(main._hub_rows.size() < 120 and not main._hub_build_queue.is_empty(), "большой список начинает открываться по частям")
	main.get_node("%WorldSearch").text = "Many-119"
	main._build_hub_rows()
	check(main._selected_seed == "Many-000" and main._hub_rows.has("Many-119"), "поиск подготавливает ещё не построенную строку, не меняя выбор")
	main.get_node("%WorldSearch").text = ""
	main._on_star("Many-119", main._hub_rows["Many-119"].get_meta("star_button"))
	main._show_seed_tab("favorites")
	check((main._hub_rows["Many-119"] as Control).visible, "фильтр работает во время построения списка")
	var focused_star: Button = main._hub_rows["Many-119"].get_meta("star_button")
	focused_star.grab_focus()
	main._on_star("Many-119", focused_star)
	check(not (main._hub_rows["Many-119"] as Control).visible and main.get_node("%Favorites").has_focus(), "скрытие строки избранного безопасно возвращает фокус на фильтр")
	main._on_star("Many-119", main.get_node("%Star"))
	main._show_seed_tab("all")
	while not main._hub_build_queue.is_empty():
		await process_frame
	var previous_rank := -1
	var sorted := true
	var linked := true
	var previous_button: Button
	for row: Control in main.get_node("%SeedList").get_children():
		var rank := int(main._hub_rank[str(row.get_meta("seed"))])
		sorted = sorted and rank > previous_rank
		previous_rank = rank
		var button: Button = row.get_meta("select_button")
		if previous_button != null:
			linked = linked and button.get_node_or_null(button.focus_neighbor_top) == previous_button
			linked = linked and previous_button.get_node_or_null(previous_button.focus_neighbor_bottom) == button
		previous_button = button
	check(main._hub_rows.size() == 120 and sorted and linked, "поэтапное построение сохраняет сортировку и связи фокуса")
	var saved_row: Control = main._hub_rows["Many-119"]
	var reads: int = main._card_reads
	main._return_to_menu_screen()
	main._open_all_worlds()
	check(main._hub_rows["Many-119"] == saved_row and main._card_reads == reads and main._hub_build_queue.is_empty(), "повторное открытие использует готовые строки без перечитывания")
	main.queue_free()
	await process_frame
