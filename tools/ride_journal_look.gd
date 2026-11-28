extends SceneTree
## Изолированный стенд ленты: синтетическая карта и отдельная папка, без игрового мира.

const Feed = preload("res://scripts/game/ride_feed.gd")
const Writer = preload("res://scripts/game/ride_feed_writer.gd")
const Thumb = preload("res://scripts/ui/ride_thumb.gd")
const View = preload("res://scripts/ui/ride_feed_view.gd")
const Style = preload("res://scripts/ui/hud_style.gd")
var out := "res://.godot/ride-journal-1_1"
var failures := 0


class Settings extends RefCounted:
	var show_walks := false
	var save_error: Error = OK
	func save_settings() -> Error:
		return save_error


func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 45)
	root.size = Vector2i(1280, 720)
	DirAccess.make_dir_recursive_absolute(out)
	_run.call_deferred()


func _check(ok: bool, message: String) -> void:
	print("PASS " if ok else "FAIL ", message)
	if not ok:
		failures += 1


func _shot(name: String) -> void:
	await process_frame
	await process_frame
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png(out.path_join(name + ".png"))


func _run() -> void:
	var folder := "user://ride_journal_look/" + str(Time.get_ticks_usec())
	DirAccess.make_dir_recursive_absolute(folder)
	var feed = Feed.new(folder)
	var map := Image.create(256, 256, false, Image.FORMAT_RGB8)
	map.fill(Color("#d6d7b4"))
	map.fill_rect(Rect2i(0, 0, 100, 256), Color("#b7cba9"))
	map.fill_rect(Rect2i(175, 0, 28, 256), Color("#a9c7c3"))
	var photos: Array[String] = []
	for i in 7:
		var photo_path := folder.path_join("photo_%d.png" % i)
		map.save_png(photo_path)
		photos.append(photo_path)
	var legs := [PackedVector2Array([Vector2(80, 140), Vector2(150, 200), Vector2(310, 240), Vector2(460, 360), Vector2(670, 520), Vector2(850, 750)])]
	var ride := {start = 1795600000.0, end = 1795603600.0, time = 2490.0, bike = 6430.0, foot = 360.0,
		climb = 186.0, descent = 120.0, alt_min = 200.0, alt_max = 412.0, speed_avg = 5.0, speed_max = 12.0,
		photos = 0, quests = 1, places = [], legs = legs, leg_modes = [true],
		profile = [200.0, 245.0, 230.0, 360.0, 412.0], fall_marks = [{x = 310.0, z = 240.0, speed = 7.0, progress = 0.4}], falls = 1}
	for i in 3:
		var source: Dictionary = ride.duplicate(true)
		source.start -= i * 86400.0
		if i == 2:
			source.bike = 0.0
			source.foot = 2400.0
		var entry := Writer.make_entry(source, WorldTemplate.DEFAULT_ID, "Туман-4821", ["Ольховка"], photos if i == 0 else [])
		entry.thumb = Feed.thumb_name(entry.id)
		feed.upsert(entry)
		Thumb.render(map, Vector2(1024, 1024), source).save_png(feed.thumb_path(entry.id))
	var scene := Control.new()
	scene.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	scene.theme = Style.theme()
	root.add_child(scene)
	var ui_audio = preload("res://scripts/ui/ui_audio.gd").new()
	scene.add_child(ui_audio)
	var background := ColorRect.new()
	background.color = Color("#101e1c")
	background.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	scene.add_child(background)
	var dock := PanelContainer.new()
	dock.position = Vector2(32, 30)
	dock.size = Vector2(300, 660)
	dock.add_theme_stylebox_override("panel", Style.sheet(Vector2(16, 16)))
	scene.add_child(dock)
	var compact := View.new()
	compact.feed = Feed.new(folder)
	compact.controls_created.connect(ui_audio.bind_tree)
	dock.add_child(compact)
	compact.setup(Settings.new(), "Туман-4821", WorldTemplate.DEFAULT_ID)
	var paper := ColorRect.new()
	paper.color = Style.PAPER
	paper.position = Vector2(348, 30)
	paper.size = Vector2(900, 660)
	scene.add_child(paper)
	await _shot("compact")
	_check(compact._list.get_child_count() == 2, "пешие прогулки скрыты в узкой ленте")
	dock.size.x = 220
	await _shot("compact_narrow")
	var compact_row := compact._walks.get_parent() as Control
	_check(compact_row.size.x <= 190.0 and compact._count_label.position.x + compact._count_label.size.x <= compact_row.size.x + 1.0, "переключатель и счётчик помещаются в узком игровом доке")
	var compact_card = compact._cards[str(compact.feed.entries[0].id)]
	var compact_labels: Array = compact_card.find_children("*", "Label", true, false)
	var important_fits := 0
	for node: Node in compact_labels:
		var label := node as Label
		if label.text.contains("2026") or label.text.begins_with("Падения"):
			var width := label.get_theme_font("font").get_string_size(label.text, HORIZONTAL_ALIGNMENT_LEFT, -1, label.get_theme_font_size("font_size")).x
			if width <= label.size.x + 1.0:
				important_fits += 1
	_check(important_fits == 2, "дата с годом и падения читаются в узкой карточке")
	dock.size.x = 300
	await process_frame
	_check(compact.same_world({seed = "Туман-4821", template_id = WorldTemplate.DEFAULT_ID}) and not compact.same_world({seed = "Туман-4821", template_id = "other"}), "мир определяется типом и seed")
	var chosen_map := {entry = {}}
	compact.ride_selected.connect(func(entry: Dictionary) -> void: chosen_map.entry = entry)
	compact._choose(compact.feed.entries[0])
	await process_frame
	_check(compact._cards[str(compact.feed.entries[0].id)].button_pressed, "выбранная карточка выделена")
	await _shot("selected")
	await _shot("detail")
	_check(is_instance_valid(compact._dialog) and compact._dialog.visible, "подробная карточка открыта")
	_check(not compact._detail_extra.visible and compact._detail_toggle.text == "Больше о поездке", "расширенная статистика сначала скрыта")
	compact._detail_toggle.button_pressed = true
	_check(compact._detail_extra.visible and compact._detail_toggle.text == "Скрыть подробности", "подробности раскрываются по запросу")
	compact._detail_toggle.button_pressed = false
	_check(chosen_map.entry.is_empty(), "открытие подробностей не меняет карту мира")
	var photo_buttons := compact._dialog.find_children("*", "TextureButton", true, false)
	_check(photo_buttons.size() == 6, "снимки загружаются первой порцией")
	if not photo_buttons.is_empty():
		var deadline := Time.get_ticks_msec() + 5000
		while (photo_buttons[0] as TextureButton).texture_normal == null and Time.get_ticks_msec() < deadline:
			await process_frame
		_check((photo_buttons[0] as TextureButton).texture_normal != null, "миниатюра снимка готовится в фоне")
	var more := compact._dialog.find_children("*", "Button", true, false).filter(func(node: Node) -> bool: return (node as Button).text == "Показать ещё снимки")
	if not more.is_empty():
		(more[0] as Button).pressed.emit()
		photo_buttons = compact._dialog.find_children("*", "TextureButton", true, false)
	_check(photo_buttons.size() == 7, "можно показать оставшиеся снимки")
	if not photo_buttons.is_empty():
		(photo_buttons[0] as TextureButton).pressed.emit()
		await process_frame
		var viewers := compact._dialog.find_children("*", "AcceptDialog", true, false)
		_check(viewers.size() == 1, "снимок открывается крупно")
		if not viewers.is_empty():
			var pictures := (viewers[0] as AcceptDialog).find_children("*", "TextureRect", true, false)
			var picture := pictures[0] as TextureRect if not pictures.is_empty() else null
			var deadline := Time.get_ticks_msec() + 5000
			while is_instance_valid(picture) and picture.texture == null and Time.get_ticks_msec() < deadline:
				await process_frame
			_check(is_instance_valid(picture) and picture.texture != null, "крупный снимок загружается в фоне")
			var close_photo := InputEventAction.new()
			close_photo.action = &"ui_cancel"
			close_photo.pressed = true
			Input.parse_input_event(close_photo)
			await process_frame
			_check(compact._dialog.visible and (not is_instance_valid(viewers[0]) or not viewers[0].visible), "отмена сначала закрывает снимок")
			close_photo.pressed = false
			Input.parse_input_event(close_photo)
	await process_frame
	var cancel_key := InputEventAction.new()
	cancel_key.action = &"ui_cancel"
	cancel_key.pressed = true
	Input.parse_input_event(cancel_key)
	await process_frame
	_check(not compact._dialog.visible, "клавиша отмены закрывает подробности")
	cancel_key.pressed = false
	Input.parse_input_event(cancel_key)
	compact._choose(compact.feed.entries[0])
	await process_frame
	var cancel_pad := InputEventJoypadButton.new()
	cancel_pad.button_index = JOY_BUTTON_B
	cancel_pad.pressed = true
	Input.parse_input_event(cancel_pad)
	await process_frame
	_check(not compact._dialog.visible, "кнопка B закрывает подробности")
	cancel_pad.pressed = false
	Input.parse_input_event(cancel_pad)
	compact._choose(compact.feed.entries[0])
	await process_frame
	var map_buttons := compact._dialog.find_children("*", "Button", true, false).filter(func(node: Node) -> bool: return (node as Button).text == "Показать на карте мира")
	_check(map_buttons.size() == 1 and not (map_buttons[0] as Button).disabled, "действие карты доступно для своего мира")
	if not map_buttons.is_empty():
		(map_buttons[0] as Button).pressed.emit()
	_check(not chosen_map.entry.is_empty() and not compact._dialog.visible, "карта меняется только по явному действию")
	dock.hide()
	paper.hide()
	var panel := PanelContainer.new()
	panel.position = Vector2(330, 24)
	panel.size = Vector2(620, 672)
	panel.add_theme_stylebox_override("panel", Style.sheet(Vector2(20, 16)))
	scene.add_child(panel)
	var menu := View.new()
	menu.feed = Feed.new(folder)
	menu.controls_created.connect(ui_audio.bind_tree)
	panel.add_child(menu)
	var settings := Settings.new()
	menu.setup(settings)
	menu.refresh()
	await _shot("menu")
	_check(menu._list is VBoxContainer, "меню использует одну колонку")
	_check(menu._cards[str(menu.feed.entries[0].id)]._preview.texture != null, "видимая карта загружена после раскладки")
	var header := menu._cards[str(menu.feed.entries[0].id)]._feed_box.get_child(0) as HBoxContainer
	_check((header.get_child(1) as Label).size.x >= 150.0 and (header.get_child(1) as Label).text.contains("2026"), "полная дата остаётся видимой в заголовке")
	_check(menu._cards[str(menu.feed.entries[0].id)].has_meta(&"_ui_audio_bound"), "новые карточки получают звуки интерфейса")
	var walk_switches := menu.find_children("*", "CheckButton", true, false)
	_check(walk_switches.size() == 1, "переключатель прогулок доступен")
	if not walk_switches.is_empty():
		(walk_switches[0] as CheckButton).button_pressed = true
	await process_frame
	await process_frame
	_check(menu._list.get_child_count() == 3, "переключатель показывает прогулки")
	await _shot("walks")
	_check(settings.show_walks, "состояние переключателя сохраняется в настройках")
	settings.save_error = ERR_CANT_CREATE
	(walk_switches[0] as CheckButton).button_pressed = false
	_check(menu._filter_notice.visible and not settings.show_walks, "ошибка сохранения настройки объясняется игроку")
	settings.save_error = OK
	(walk_switches[0] as CheckButton).button_pressed = true
	await process_frame
	await process_frame
	_check(not menu._filter_notice.visible, "успешное сохранение убирает предупреждение")
	var walk_entries: Array = menu.feed.entries.filter(func(item: Dictionary) -> bool: return bool(item.get("walk", false)))
	var walk_id := str(walk_entries[0].id)
	menu._choose(walk_entries[0])
	menu._dialog.hide()
	(walk_switches[0] as CheckButton).button_pressed = false
	await process_frame
	_check(str(menu._selected.get("id", "")) == walk_id, "скрытый фильтром выбор сохраняется")
	(walk_switches[0] as CheckButton).button_pressed = true
	await process_frame
	await process_frame
	_check(menu._cards.has(walk_id) and menu._cards[walk_id].button_pressed, "сброс фильтра возвращает выбор")
	menu._walks.grab_focus()
	menu._scroll.scroll_vertical = 0
	root.size = Vector2i(1920, 1080)
	await process_frame
	panel.position = Vector2((root.get_visible_rect().size.x - 620.0) * 0.5, 24)
	panel.size = Vector2(620, root.get_visible_rect().size.y - 48.0)
	await _shot("menu_1920")
	root.size = Vector2i(720, 1280)
	await process_frame
	panel.position = Vector2((root.get_visible_rect().size.x - 620.0) * 0.5, 24)
	panel.size = Vector2(620, root.get_visible_rect().size.y - 48.0)
	await _shot("menu_portrait")
	_check(root.get_visible_rect().encloses(panel.get_global_rect()), "колонка помещается в портретном окне")
	root.size = Vector2i(1280, 720)
	panel.position = Vector2(330, 24)
	panel.size = Vector2(620, 672)
	await process_frame
	var delayed := ride.duplicate(true)
	delayed.start += 86400.0
	var later := Writer.make_entry(delayed, WorldTemplate.DEFAULT_ID, "Туман-4821", [])
	later.world_title = "Очень длинное название мира, которое должно оставаться доступным целиком в подробностях"
	later.thumb = Feed.thumb_name(later.id)
	feed.load_feed()
	feed.upsert(later)
	menu.refresh()
	menu._scroll.scroll_vertical = 0
	await process_frame
	await process_frame
	menu._choose(menu.feed.entries[0])
	var card = menu._cards[str(later.id)]
	var before: int = card.get_instance_id()
	Feed.begin_thumb(feed.thumb_path(later.id))
	await process_frame
	await process_frame
	_check(card._missing.text == "Подготавливаем карту…", "показывается подготовка отсутствующего превью")
	_check(menu._detail_missing.text == "Подготавливаем карту…", "подготовка видна в открытых подробностях")
	Thumb.render(map, Vector2(1024, 1024), delayed).save_png(feed.thumb_path(later.id))
	Feed.end_thumb(feed.thumb_path(later.id))
	await process_frame
	await process_frame
	_check(is_instance_valid(card._preview.texture) and card.get_instance_id() == before and card.button_pressed, "готовое превью появляется без потери выбора")
	var replacement := Image.create(320, 200, false, Image.FORMAT_RGB8)
	replacement.fill(Color(0.8, 0.1, 0.1))
	var temporary: String = feed.thumb_path(later.id) + ".tmp"
	replacement.save_png(temporary)
	_check(Feed.publish_thumb(folder, str(later.id), temporary, feed.thumb_path(later.id)) == OK, "новая карта атомарно заменяет старую")
	await process_frame
	await process_frame
	_check(card._preview.texture.get_image().get_pixel(0, 0).r > 0.7 and card.get_instance_id() == before, "обновлённая карта появляется без перестроения карточки")
	_check(menu._detail_preview.texture != null and menu._detail_preview.texture.get_image().get_pixel(0, 0).r > 0.7, "открытые подробности получают обновлённую карту")
	if is_instance_valid(menu._dialog):
		menu._dialog.hide()
	await process_frame
	_check(root.gui_get_focus_owner() == card, "фокус возвращается к открытой записи")
	panel.position = Vector2(460, 24)
	panel.size = Vector2(360, 672)
	await _shot("narrow")
	_check(card._feed_metrics.columns == 1 and card._feed_box.get_combined_minimum_size().y <= card.size.y - 31.0, "узкая карточка не обрезает показатели и действие")
	panel.position = Vector2(330, 24)
	panel.size = Vector2(620, 672)
	await process_frame
	var empty_feed = Feed.new(folder.path_join("empty"))
	menu.feed = empty_feed
	menu.refresh()
	await _shot("empty")
	_check(empty_feed.entries.is_empty() and menu._list.get_child_count() == 1, "пустой журнал объясняет порог записи")
	var idle_deadline := Time.get_ticks_msec() + 2000
	while menu.is_processing() and Time.get_ticks_msec() < idle_deadline:
		await process_frame
	_check(not menu.is_processing(), "пустая лента не работает каждый кадр")
	var wake_path := folder.path_join("wake-test.png")
	Feed.begin_thumb(wake_path)
	await process_frame
	await process_frame
	_check(menu._thumb_generation == Feed.thumb_generation(), "фоновая задача будит ленту без постоянного опроса")
	Feed.end_thumb(wake_path)
	var walks_feed = Feed.new(folder.path_join("walk_only"))
	var walk_only := {id = "walk-only", version = Feed.VERSION, start = 42, world_title = "Мир", seed = "Мир", template_id = WorldTemplate.DEFAULT_ID, walk = true, foot = 500}
	_check(walks_feed.upsert(walk_only) == OK, "подготовлена скрытая прогулка")
	settings.show_walks = false
	menu._walks.set_pressed_no_signal(false)
	menu.feed = walks_feed
	menu.refresh()
	await _shot("walks_hidden")
	var show_walks := menu._list.find_children("*", "Button", true, false).filter(func(node: Node) -> bool: return (node as Button).text == "Показать прогулки")
	_check(show_walks.size() == 1 and menu._count_label.text == "Показано 0 из 1", "скрытые прогулки объяснены и доступны одним действием")
	(show_walks[0] as Button).pressed.emit()
	await process_frame
	_check(settings.show_walks and menu._cards.has("walk-only"), "действие показывает скрытые прогулки")
	var partial_feed = Feed.new(folder.path_join("partial"))
	var partial := {id = "partial", version = Feed.VERSION, start = 1.0e20, world_title = "Дальний мир", walk = "bad", bike = "bad", falls = -1,
		profile = [1, "bad"], photo_paths = [null, "user://missing.png"], places = [12, "Поляна"],
		fall_marks = [{x = 1, z = 2, progress = "bad"}, null], track = [[[0, 0], [1, 1], null, [2, 2], [3, 3]]]}
	_check(partial_feed.upsert(partial) == OK, "подготовлена частично повреждённая запись")
	var partial_file := FileAccess.get_file_as_string(partial_feed.directory.path_join("feed.json"))
	menu.feed = partial_feed
	menu.refresh()
	await process_frame
	await process_frame
	menu._choose(partial)
	_check(menu._dialog.visible and not menu._selected.has("bike") and menu._selected.track.size() == 2 and menu._selected.profile.is_empty(), "частично повреждённая запись открывается с достоверными данными")
	_check(FileAccess.get_file_as_string(partial_feed.directory.path_join("feed.json")) == partial_file, "просмотр не переписывает частично повреждённую запись")
	menu._dialog.hide()
	menu.feed = empty_feed
	var old := {id = "old", version = Feed.VERSION, start = 100.0, world_title = "Старый мир", seed = "Старый мир", template_id = "unknown", walk = false}
	_check(empty_feed.upsert(old) == OK, "подготовлена старая запись без дополнительных полей")
	var other: Dictionary = old.duplicate(true)
	other.id = "other"
	other.start = 99.0
	_check(empty_feed.upsert(other) == OK, "подготовлена соседняя запись")
	menu.refresh()
	await _shot("missing")
	var old_card = menu._cards["old"]
	var old_text: Array = old_card.find_children("*", "Label", true, false).map(func(node: Node) -> String: return (node as Label).text)
	_check(old_card._preview.texture == null and "—" in old_text and old_card.tooltip_text.contains("Неизвестный тип мира"), "неизвестные данные и отсутствующая карта не подменяются")
	menu._choose(old)
	var remove_buttons := menu._dialog.find_children("*", "Button", true, false).filter(func(node: Node) -> bool: return (node as Button).text == "Удалить запись")
	(remove_buttons[0] as Button).pressed.emit()
	await process_frame
	var confirms := menu._dialog.find_children("*", "ConfirmationDialog", true, false)
	var cancel_remove := InputEventJoypadButton.new()
	cancel_remove.button_index = JOY_BUTTON_B
	cancel_remove.pressed = true
	Input.parse_input_event(cancel_remove)
	await process_frame
	_check(menu._dialog.visible and (not is_instance_valid(confirms[0]) or not confirms[0].visible) and empty_feed.entries.size() == 2, "отмена удаления сохраняет записи и подробности")
	cancel_remove.pressed = false
	Input.parse_input_event(cancel_remove)
	(remove_buttons[0] as Button).pressed.emit()
	await process_frame
	confirms = menu._dialog.find_children("*", "ConfirmationDialog", true, false).filter(func(node: Node) -> bool: return (node as Window).visible)
	(confirms[0] as ConfirmationDialog).confirmed.emit()
	await process_frame
	await process_frame
	_check(empty_feed.load_feed() == OK and empty_feed.entries.size() == 1 and empty_feed.entries[0].id == "other" and menu._cards["other"].has_focus(), "удаление сохраняет соседнюю запись и переводит на неё фокус")
	menu._choose(other)
	remove_buttons = menu._dialog.find_children("*", "Button", true, false).filter(func(node: Node) -> bool: return (node as Button).text == "Удалить запись")
	(remove_buttons[0] as Button).pressed.emit()
	await process_frame
	confirms = menu._dialog.find_children("*", "ConfirmationDialog", true, false).filter(func(node: Node) -> bool: return (node as Window).visible)
	(confirms[0] as ConfirmationDialog).confirmed.emit()
	await process_frame
	_check(empty_feed.load_feed() == OK and empty_feed.entries.is_empty() and menu._walks.has_focus(), "после удаления последней записи фокус остаётся в журнале")
	var bad_dir := folder.path_join("broken")
	DirAccess.make_dir_recursive_absolute(bad_dir)
	var bad_file := FileAccess.open(bad_dir.path_join("feed.json"), FileAccess.WRITE)
	bad_file.store_string("{broken")
	bad_file.close()
	menu.feed = Feed.new(bad_dir)
	menu.refresh()
	_check(menu._load_error == ERR_FILE_CORRUPT and menu._list.get_child_count() == 2, "ошибка файла показана вместо пустой ленты")
	menu.refresh(false)
	_check(menu._load_error == ERR_FILE_CORRUPT, "смена фильтра не скрывает ошибку")
	var bulk = Feed.new(folder.path_join("bulk"))
	var rows: Array[Dictionary] = []
	for i in 200:
		var id := "bulk-%d" % i
		rows.append({id = id, version = Feed.VERSION, start = 1000 + i, time = 120.0,
			bike = 300.0, foot = 0.0, world_title = "Тест", template_id = WorldTemplate.DEFAULT_ID, seed = "Тест", walk = false, thumb = Feed.thumb_name(id)})
	_check(bulk._save(rows) == OK, "подготовлена лента из 200 записей")
	var copies_ok := true
	for row: Dictionary in rows:
		copies_ok = DirAccess.copy_absolute(feed.thumb_path(later.id), bulk.thumb_path(row.id)) == OK and copies_ok
	_check(copies_ok, "подготовлены 200 отдельных PNG")
	menu.feed = bulk
	var began := Time.get_ticks_usec()
	menu.refresh()
	var batch: int = maxi(1, preload("res://resources/ride_journal.tres").feed_cards_per_frame)
	_check(menu._list.get_child_count() == batch and menu._pending_entries.size() == 200 - batch, "длинная лента начинает заполняться порциями")
	var deadline := Time.get_ticks_msec() + 12000
	var max_frame := 0
	while not menu._pending_entries.is_empty() and Time.get_ticks_msec() < deadline:
		var frame_started := Time.get_ticks_usec()
		menu._scroll.scroll_vertical = int(menu._scroll.get_v_scroll_bar().max_value)
		await process_frame
		max_frame = maxi(max_frame, Time.get_ticks_usec() - frame_started)
	_check(menu._list.get_child_count() == 200, "все 200 карточек доступны при прокрутке")
	await process_frame
	await process_frame
	_check(menu._cards.size() <= 8, "в памяти остаются только карточки рядом с экраном")
	var loaded := 0
	for bulk_card in menu._cards.values():
		if bulk_card._preview.texture != null:
			loaded += 1
	_check(loaded <= 5, "текстуры загружаются только рядом с видимой областью (загружено: %d)" % loaded)
	print("200 карточек меню с PNG: %.1f мс, максимальный интервал кадра %.1f мс" % [float(Time.get_ticks_usec() - began) / 1000.0, float(max_frame) / 1000.0])
	menu._scroll.scroll_vertical = 0
	await process_frame
	await process_frame
	await process_frame
	_check(menu._cards.has("bulk-199") and menu._cards["bulk-199"]._preview.texture != null, "прокрутка вверх восстанавливает первую карточку и карту")
	if menu._cards.has("bulk-199"):
		var first: Button = menu._cards["bulk-199"]
		first.grab_focus()
		menu._scroll.scroll_vertical = int(menu._scroll.get_v_scroll_bar().max_value)
		await process_frame
		await process_frame
		_check(is_instance_valid(first) and first.has_focus(), "виртуализация не освобождает элемент с фокусом")
		var down := InputEventAction.new()
		down.action = &"ui_down"
		down.pressed = true
		Input.parse_input_event(down)
		await process_frame
		await process_frame
		_check(menu._cards.has("bulk-198") and menu._cards["bulk-198"].has_focus(), "клавиатура переводит фокус к выгруженной соседней записи")
		down.pressed = false
		Input.parse_input_event(down)
		panel.size.x = 360
		await process_frame
		await process_frame
		await process_frame
		_check(menu._cards.has("bulk-198") and menu._cards["bulk-198"].has_focus() and menu._cards["bulk-198"]._feed_metrics.columns == 1 and menu._list.get_child_count() == 200, "изменение ширины сохраняет фокус и структуру длинной ленты")
	panel.hide()
	dock.show()
	compact.feed = bulk
	compact._only_world = false
	compact.refresh()
	var compact_deadline := Time.get_ticks_msec() + 12000
	while not compact._pending_entries.is_empty() and Time.get_ticks_msec() < compact_deadline:
		compact._scroll.scroll_vertical = int(compact._scroll.get_v_scroll_bar().max_value)
		await process_frame
	await process_frame
	await process_frame
	_check(compact._list.get_child_count() == 200 and compact._cards.size() <= 16, "игровой док тоже ограничивает число живых карточек")
	var compact_textures := 0
	for compact_item in compact._cards.values():
		if compact_item._preview.texture != null:
			compact_textures += 1
	_check(compact_textures <= 16, "игровой док выгружает дальние карты")
	compact._scroll.scroll_vertical = 0
	await process_frame
	await process_frame
	await process_frame
	_check(compact._cards.has("bulk-199"), "игровой док восстанавливает начало ленты")
	if compact._cards.has("bulk-199"):
		compact._cards["bulk-199"].grab_focus()
		compact._scroll.scroll_vertical = int(compact._scroll.get_v_scroll_bar().max_value)
		await process_frame
		var compact_down := InputEventAction.new()
		compact_down.action = &"ui_down"
		compact_down.pressed = true
		Input.parse_input_event(compact_down)
		await process_frame
		await process_frame
		_check(compact._cards.has("bulk-198") and compact._cards["bulk-198"].has_focus(), "фокус в игровом доке переходит к выгруженной записи")
		compact_down.pressed = false
		Input.parse_input_event(compact_down)
	print("ride_journal_look: %s; снимки: %s" % ["ok" if failures == 0 else "FAIL %d" % failures, out])
	quit(1 if failures else 0)
