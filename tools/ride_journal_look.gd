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
	func save_settings() -> Error:
		return OK


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
	compact._choose(compact.feed.entries[0])
	await process_frame
	_check(compact._cards[str(compact.feed.entries[0].id)].button_pressed, "выбранная карточка выделена")
	await _shot("selected")
	compact._detail_button.pressed.emit()
	await _shot("detail")
	_check(is_instance_valid(compact._dialog) and compact._dialog.visible, "подробная карточка открыта")
	var photo_buttons := compact._dialog.find_children("*", "TextureButton", true, false)
	_check(photo_buttons.size() == 6, "снимки загружаются первой порцией")
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
			viewers[0].queue_free()
	compact._dialog.hide()
	dock.hide()
	paper.hide()
	var panel := PanelContainer.new()
	panel.position = Vector2(190, 24)
	panel.size = Vector2(900, 672)
	panel.add_theme_stylebox_override("panel", Style.sheet(Vector2(20, 16)))
	scene.add_child(panel)
	var menu := View.new()
	menu.feed = Feed.new(folder)
	menu.controls_created.connect(ui_audio.bind_tree)
	panel.add_child(menu)
	var settings := Settings.new()
	menu.setup(settings)
	await _shot("menu")
	_check(menu._list is GridContainer and menu._list.columns == 2, "меню использует две колонки")
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
	var delayed := ride.duplicate(true)
	delayed.start += 86400.0
	var later := Writer.make_entry(delayed, WorldTemplate.DEFAULT_ID, "Туман-4821", [])
	later.thumb = Feed.thumb_name(later.id)
	feed.load_feed()
	feed.upsert(later)
	menu.refresh()
	menu._choose(menu.feed.entries[0])
	var card = menu._cards[str(later.id)]
	var before: int = card.get_instance_id()
	Thumb.render(map, Vector2(1024, 1024), delayed).save_png(feed.thumb_path(later.id))
	menu._process(2.0)
	_check(is_instance_valid(card._preview.texture) and card.get_instance_id() == before and card.button_pressed, "готовое превью появляется без потери выбора")
	if is_instance_valid(menu._dialog):
		menu._dialog.hide()
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
		await process_frame
		max_frame = maxi(max_frame, Time.get_ticks_usec() - frame_started)
	_check(menu._list.get_child_count() == 200, "все 200 карточек появляются без загрузки в одном кадре")
	print("200 карточек с PNG: %.1f мс, максимальный интервал кадра %.1f мс" % [float(Time.get_ticks_usec() - began) / 1000.0, float(max_frame) / 1000.0])
	print("ride_journal_look: %s; снимки: %s" % ["ok" if failures == 0 else "FAIL %d" % failures, out])
	quit(1 if failures else 0)
