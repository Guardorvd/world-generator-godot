extends SceneTree
## Изолированная проверка меню: без генерации и без профиля игрока.

const Saves := preload("res://scripts/game/save_game.gd")
const Main := preload("res://scenes/main.tscn")
const OUT := "res://.godot/menu_v2_test"
var _main: Node
var _failures := 0
var _old_saves := ""


func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 60)
	_run.call_deferred()


func _check(value: bool, message: String) -> void:
	print(("OK " if value else "FAIL ") + message)
	if not value: _failures += 1


func _run() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT))
	_old_saves = Saves.dir
	Saves.dir = OUT.path_join("saves-%d" % OS.get_process_id())
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(Saves.dir))
	GameContext.scope.settings.settings_path = OUT.path_join("settings-%d.cfg" % OS.get_process_id())
	_main = Main.instantiate()
	root.add_child(_main)
	await process_frame
	await process_frame
	var carousel = _main.get_node("%Carousel")
	var initial_type: String = carousel.selected_type_id()
	var initial_seed: String = _main._selected_seed
	_check(carousel.WORLD_TYPES.size() >= 4 and carousel._showcase_title.text == "Горная долина", "готовые типы и будущие пункты получены из каталога")
	_check(carousel._showcase_art.texture != null and carousel._showcase_description.text.length() > 0, "первый тип имеет изображение и описание")
	carousel._carousel_next.grab_focus()
	_check(carousel._carousel_next.get_node("Highlight").visible, "рамка стрелки видна поверх миниатюры при фокусе")
	carousel.show_world("")
	_check(carousel.selected_index() == -1 and "Мир ещё не выбран" in carousel._showcase_world.text, "пустой выбор не показывает посторонний мир")
	carousel.show_world(initial_seed)
	var reads: int = _main._card_reads
	_main._open_type_catalog(carousel._showcase_all)
	_check(_main._is_screen("type_catalog") and _main._type_catalog._rows.size() >= 4, "полный каталог содержит готовые и будущие варианты")
	_main._type_catalog._choose("future_3", false)
	_check(_main._is_screen("type_catalog") and carousel.selected_type_id() == initial_type and _main._selected_seed == initial_seed and _main._card_reads == reads, "заглушка не меняет мир и не вызывает чтение")
	_main._close_type_catalog()
	carousel._select_type_from_ui("river_expedition")
	_check(carousel.selected_type_id() == "river_expedition" and carousel._showcase_art.texture != null, "подтверждение переключает тип и изображение")
	if DisplayServer.get_name() != "headless":
		await process_frame
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png(OUT.path_join("expedition.png"))
	reads = _main._card_reads
	carousel._select_type_from_ui("river_expedition")
	_check(_main._card_reads == reads, "повторный выбор не читает сохранения")
	carousel.move_type(1)
	_check(not carousel.displayed_type_available() and carousel.selected_type_id() == "river_expedition"
		and _main.get_node("%Start").disabled and _main._card_reads == reads, "будущий тип в карусели нельзя запустить и он не меняет активный тип")
	_main._open_type_catalog(carousel._showcase_all)
	_check(_main._type_catalog._focus_target != null and "Будущий тип 3" in _main._type_catalog._focus_target.text,
		"каталог сохраняет контекст просматриваемой заглушки")
	_main._type_catalog._rows[0].grab_focus()
	await process_frame
	await process_frame
	_check(_main._type_catalog._rows[0].has_focus(), "отложенная прокрутка не перехватывает новый фокус")
	_main._close_type_catalog()
	if DisplayServer.get_name() != "headless":
		_check(carousel._carousel_tween != null and carousel._carousel_tween.is_valid() and is_instance_valid(carousel._carousel_ghost),
			"переключение анимирует уменьшение прошлой карточки")
	if DisplayServer.get_name() != "headless":
		await create_timer(0.25).timeout
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png(OUT.path_join("future.png"))
	carousel.move_type(1)
	carousel.move_type(-1)
	_check(not carousel.displayed_type_available() and carousel.WORLD_TYPES[carousel._displayed_type].id == "future_3", "быстрое листание оставляет последний показанный тип")
	carousel.move_type(-1)
	_check(carousel.displayed_type_available() and not _main.get_node("%Start").disabled, "возврат к готовому типу снова разрешает запуск")
	carousel._select_type_from_ui(initial_type)
	var quests := preload("res://scripts/game/quests.gd").new()
	var save_data := {format = 1, seed = "Занятый-1234", signature = "menu-v2", saved_at = 1700000000,
		visited = {}, goal = "", quest = quests.save_state(),
		player = {x = 0.0, z = 0.0, feet = 0.0, yaw = 0.0, pitch = 0.0, hour = 9.0},
		bike = {x = 0.0, z = 0.0, y = 0.0, heading = 0.0, riding = true}}
	_check(Saves.write_slot(save_data) == OK, "создано изолированное сохранение")
	_main._open_new_world()
	_check(_main._draft_active and _main._is_screen("menu") and _main._draft_seed.has_focus(), "создание открывается в меню")
	_main._draft_seed.text = "Занятый-1234"
	_main._on_create_world()
	_check(_main._confirm != null and not _main.busy, "совпавшее зерно не перезаписывает сохранение")
	_main._cancel_confirm()
	_main._draft_seed.text = "Проверка-1234"
	_main._draft_seed.text_changed.emit("Проверка-1234")
	_check("Проверка-1234" in carousel._showcase_world.text and "НОВЫЙ МИР" in carousel._showcase_world.text,
		"витрина показывает зерно черновика, а не прежнее сохранение")
	carousel._select_type_from_ui("river_expedition")
	_check(_main._draft_seed.text == "Проверка-1234", "смена типа сохраняет зерно черновика")
	_check(not _main._has_save("Занятый-1234"), "одинаковое зерно другого типа не считается сохранением")
	carousel.move_type(1)
	_check(_main._draft_create.disabled and _main._draft_seed.text == "Проверка-1234", "будущий тип блокирует запуск, но не теряет черновик")
	_check(carousel._carousel_next.get_node(carousel._carousel_next.focus_neighbor_bottom) == _main._draft_seed,
		"фокус стрелки в создании возвращается к видимому полю")
	_main._cancel_new_world()
	_check(not _main._draft_active and carousel.selected_type_id() == initial_type and _main._selected_seed == initial_seed, "отмена восстанавливает исходную пару")
	_main._open_new_world()
	_main._draft_seed.text = "Проверка-1234"
	_main._launch_from_draft = true
	_main._finish_load()
	_check(_main._draft_active and _main._draft_seed.text == "Проверка-1234", "возврат из загрузки сохраняет черновик")
	_main._cancel_new_world()
	_main._open_all_worlds()
	var hub_type := _main.get_node("%AllWorlds/Panel/Box/HubType") as Button
	_main._open_type_catalog(hub_type)
	_main._type_catalog._choose("river_expedition", true)
	_check(_main._is_screen("world_hub") and carousel.selected_type_id() == "river_expedition" and "Речная экспедиция" in hub_type.text,
		"каталог библиотеки выбирает тот же тип и возвращает к списку")
	_main._return_to_menu_screen()
	carousel._select_type_from_ui(initial_type)
	var synthetic: Array[Dictionary] = []
	for i in 8: synthetic.append({id = "fixture_%d" % i, title = "Длинное название путешествия %d" % i, available = i < 6, description = "Путь и ландшафт"})
	_main._type_catalog.populate(synthetic, "fixture_5")
	_check(_main._type_catalog._rows.size() == 8 and _main._type_catalog._selected != null
		and _main._type_catalog._rows[0].autowrap_mode == TextServer.AUTOWRAP_WORD_SMART, "каталог масштабируется и переносит длинные названия")
	for dimensions: Vector2i in [Vector2i(1280, 720), Vector2i(960, 720), Vector2i(800, 600), Vector2i(640, 360)]:
		root.size = dimensions
		_main._fit_menu()
		await process_frame
		await process_frame
		var area: Rect2 = root.get_visible_rect()
		_check(area.encloses(_main._menu_scroll.get_global_rect()) and area.encloses(_main.get_node("%TrailLab").get_global_rect()), "меню и лаборатория помещаются при %s" % dimensions)
		if dimensions == Vector2i(1280, 720):
			_check(_main._menu_scroll.get_global_rect().encloses(_main.get_node("%MenuExit").get_global_rect()), "все пункты видны без прокрутки при 1280×720")
		if DisplayServer.get_name() != "headless":
			await RenderingServer.frame_post_draw
			var img := root.get_texture().get_image()
			img.save_png(OUT.path_join("menu_%dx%d.png" % [dimensions.x, dimensions.y]))
	root.size = Vector2i(1280, 720)
	_main._fit_menu()
	_main._open_new_world()
	await process_frame
	await process_frame
	if DisplayServer.get_name() != "headless":
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png(OUT.path_join("create.png"))
	_main._cancel_new_world()
	_main._open_type_catalog(carousel._showcase_all)
	await process_frame
	await process_frame
	await create_timer(0.25).timeout
	_check(_main._type_catalog._scroll.get_global_rect().encloses(_main._type_catalog._selected.get_global_rect()), "выбранный тип виден при открытии каталога")
	_check(_main._type_catalog._scroll.get_global_rect().encloses(_main._type_catalog._rows[-1].get_global_rect()),
		"готовые типы и обе заглушки целиком видны в каталоге при 1280×720")
	if DisplayServer.get_name() != "headless":
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png(OUT.path_join("catalog.png"))
	_main._close_type_catalog()
	_main.queue_free()
	await process_frame
	Saves.dir = _old_saves
	print("MENU_V2 failures=", _failures)
	quit(int(_failures > 0))
