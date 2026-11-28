extends VBoxContainer
## Одна лента для главного меню и вкладки поездок.

signal ride_selected(entry: Dictionary)
signal controls_created(root: Node)

const Feed = preload("res://scripts/game/ride_feed.gd")
const Card = preload("res://scripts/ui/ride_card.gd")
const RideLog = preload("res://scripts/game/ride_log.gd")
const HudStyle = preload("res://scripts/ui/hud_style.gd")
const Config = preload("res://resources/ride_journal.tres")
const Presentation = preload("res://scripts/ui/ride_presentation.gd")
const MENU_THEME = preload("res://resources/ui_theme.tres")
const DETAIL_SURFACE := Color(0.07, 0.11, 0.15, 0.98)
const DETAIL_BORDER := Color(0.52, 0.61, 0.64, 0.6)

var feed = Feed.new()
var settings
var world_seed := ""
var world_template := ""
var _only_world := false
var _list: Container
var _cards := {}
var _group := ButtonGroup.new()
var _wide_cards := false
var _selected := {}
var _map_selected := {}
var _dialog: AcceptDialog
var _pending_paths := {}
var _pending_entries: Array[Dictionary] = []
var _pending_elapsed := 0.0
var _pending_poll := 0.0
var _scroll: ScrollContainer
var _last_scroll := -1
var _walks: CheckButton
var _count_label: Label
var _filter_notice: Label
var _world_filter: OptionButton
var _preview_update_queued := false
var _thumb_generation := 0
var _thumb_dirty := false
var _load_error: Error = OK
var _detail_preview: TextureRect
var _detail_missing: Label
var _detail_legend: Label
var _detail_extra: VBoxContainer
var _detail_toggle: Button
var _detail_preview_path := ""
var _detail_revision := -1
var _failed_previews := {}
var _selection_filtered := false
var _filter_scroll := 0
var _restore_scroll := -1
var _restore_delay := 0
var _focus_after_delete_id := ""
var _slot_height := 0.0
var _cover_thread: Thread
var _cover_path := ""
var _cover_queue := {}
var _cover_cache := {}
var _cover_order: Array[String] = []
var _photo_queue: Array[Dictionary] = []
var _photo_thread: Thread
var _photo_job := {}
const COVER_CACHE_LIMIT := 12


func _ready() -> void:
	Feed.watch_thumbs(_on_thumbs_changed)
	visibility_changed.connect(_on_feed_visibility_changed)
	set_process(false)


func _on_thumbs_changed() -> void:
	_thumb_dirty = true
	if is_visible_in_tree():
		set_process(true)


func _on_feed_visibility_changed() -> void:
	if is_visible_in_tree():
		_thumb_dirty = true
		if is_instance_valid(_scroll):
			_queue_preview_update()
		set_process(true)
	else:
		set_process(false)


func setup(game_settings, seed := "", template_id := "", wide := false) -> void:
	if not seed.is_empty() and not wide:
		theme = HudStyle.theme()
	settings = game_settings
	world_seed = seed
	world_template = template_id
	_only_world = not seed.is_empty()
	_wide_cards = world_seed.is_empty() or wide
	add_theme_constant_override("separation", Config.feed_spacing)
	var title := Label.new()
	title.text = "Журнал поездок" if world_seed.is_empty() else "ПОЕЗДКИ"
	title.add_theme_font_size_override("font_size", Config.feed_wide_title_font if world_seed.is_empty() else Config.feed_title_font)
	if world_seed.is_empty() or not wide:
		add_child(title)
	else:
		title.free() # Заголовок и итоги расположены в общей шапке вкладки.
	if world_seed.is_empty():
		var subtitle := Label.new()
		subtitle.text = "Все миры · до %d последних записей" % Config.entries_limit
		HudStyle.label(subtitle, 14, HudStyle.MUTED)
		add_child(subtitle)
	var filter: OptionButton
	if not world_seed.is_empty():
		filter = OptionButton.new()
		_world_filter = filter
		filter.add_item("Этот мир")
		filter.add_item("Все миры")
		filter.select(0)
		filter.item_selected.connect(func(index: int) -> void:
			_only_world = index == 0
			refresh(false))
		if not _wide_cards:
			add_child(filter)
	var walks := CheckButton.new()
	_walks = walks
	walks.text = "Показывать прогулки" if world_seed.is_empty() else "Прогулки"
	walks.accessibility_name = "Показывать пешие прогулки"
	var filter_row := HBoxContainer.new()
	filter_row.add_theme_constant_override("separation", 8)
	add_child(filter_row)
	if filter != null and _wide_cards:
		filter.custom_minimum_size.x = 128
		filter_row.add_child(filter)
	if world_seed.is_empty():
		walks.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	walks.button_pressed = settings.show_walks
	walks.toggled.connect(func(on: bool) -> void:
		settings.show_walks = on
		var error: Error = settings.save_settings()
		_filter_notice.visible = error != OK
		refresh(false))
	filter_row.add_child(walks)
	_count_label = Label.new()
	_count_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_count_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_count_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_count_label.clip_text = true
	_count_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	HudStyle.label(_count_label, 13, HudStyle.MUTED)
	filter_row.add_child(_count_label)
	_filter_notice = Label.new()
	_filter_notice.text = "Не удалось сохранить настройку. Она действует только сейчас."
	_filter_notice.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	HudStyle.label(_filter_notice, 13, HudStyle.RED)
	_filter_notice.hide()
	add_child(_filter_notice)
	var scroll := ScrollContainer.new()
	_scroll = scroll
	scroll.follow_focus = true
	scroll.custom_minimum_size.y = Config.feed_list_height
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	add_child(scroll)
	scroll.get_v_scroll_bar().value_changed.connect(func(_value: float) -> void: _queue_preview_update())
	scroll.resized.connect(_queue_preview_update)
	_list = VBoxContainer.new()
	_list.add_theme_constant_override("separation", 14 if world_seed.is_empty() else Config.feed_spacing)
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_list)
	if not world_seed.is_empty():
		refresh()


func same_world(entry: Dictionary) -> bool:
	return not world_seed.is_empty() and entry.get("seed") is String and entry.get("template_id") is String and entry.seed == world_seed and entry.template_id == world_template


func refresh(reload_feed := true) -> void:
	var old_scroll := _scroll.scroll_vertical
	if reload_feed:
		_failed_previews.clear()
		for path: String in _cover_cache.keys():
			if _cover_cache[path] == null:
				_cover_cache.erase(path)
				_cover_order.erase(path)
	_restore_scroll = -1
	var err: Error = feed.load_feed() if reload_feed else _load_error
	_load_error = err
	_pending_paths.clear()
	_cover_queue.clear()
	_pending_entries.clear()
	_pending_elapsed = 0.0
	_pending_poll = 0.0
	set_process(false)
	for child: Node in _list.get_children():
		_list.remove_child(child)
		child.queue_free()
	_cards.clear()
	_slot_height = 0.0
	if err != OK:
		_count_label.text = ""
		var error := Label.new()
		error.text = "Не удалось открыть журнал: файл повреждён. Он сохранён без изменений; новые записи временно отключены. Восстановите журнал из резервной копии и повторите попытку." if err == ERR_FILE_CORRUPT else ("Журнал создан более новой версией игры. Файл сохранён без изменений." if err == ERR_FILE_UNRECOGNIZED else "Не удалось прочитать журнал. Проверьте доступ к файлам.")
		error.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		_list.add_child(error)
		var retry := Button.new()
		retry.text = "Попробовать снова"
		retry.pressed.connect(func() -> void: refresh())
		_list.add_child(retry)
		controls_created.emit(retry)
		return
	var selected_id := str(_selected.get("id", ""))
	var selected_visible := false
	for saved: Dictionary in feed.entries:
		var entry: Dictionary = Presentation.make(saved)
		if (_only_world and not same_world(entry)) or (bool(entry.get("walk", false)) and not settings.show_walks):
			continue
		_pending_entries.append(entry)
		if str(entry.id) == selected_id:
			_selected = entry
			selected_visible = true
	_count_label.text = ("Показано %d из %d" if _wide_cards else "%d / %d") % [_pending_entries.size(), feed.entries.size()] if not feed.entries.is_empty() else ""
	_count_label.accessibility_name = "Показано %d из %d записей" % [_pending_entries.size(), feed.entries.size()]
	if _pending_entries.is_empty():
		var hidden_walks: bool = feed.entries.any(func(item: Dictionary) -> bool: return bool(item.get("walk", false)) and (not _only_world or same_world(item)))
		var empty_panel := PanelContainer.new()
		empty_panel.add_theme_stylebox_override("panel", HudStyle.panel(Color(0.07, 0.10, 0.11, 0.94), Color(0.72, 0.67, 0.55, 0.45), 10, Vector2(20, 18), false))
		_list.add_child(empty_panel)
		var empty_box := VBoxContainer.new()
		empty_box.add_theme_constant_override("separation", 10)
		empty_panel.add_child(empty_box)
		var heading := Label.new()
		heading.text = "Здесь появятся ваши поездки" if feed.entries.is_empty() else ("Пешие прогулки скрыты" if not settings.show_walks and hidden_walks else "По этому фильтру записей нет")
		HudStyle.label(heading, 19, HudStyle.CREAM)
		heading.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		empty_box.add_child(heading)
		var empty := Label.new()
		empty.text = "Запись появится после одной минуты или 200 м пути." if feed.entries.is_empty() else ("Включите прогулки, чтобы увидеть их в журнале." if not settings.show_walks and hidden_walks else "Выберите другой мир или покажите все поездки.")
		empty.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		HudStyle.label(empty, 14, HudStyle.MUTED)
		empty_box.add_child(empty)
		if not settings.show_walks and hidden_walks:
			var show_walks := Button.new()
			show_walks.text = "Показать прогулки"
			show_walks.pressed.connect(func() -> void: _walks.button_pressed = true)
			empty_box.add_child(show_walks)
		if _only_world and not feed.entries.is_empty():
			var all_worlds := Button.new()
			all_worlds.text = "Показать все миры"
			all_worlds.pressed.connect(func() -> void:
				_world_filter.select(1)
				_only_world = false
				refresh(false))
			empty_box.add_child(all_worlds)
	if not selected_id.is_empty() and not selected_visible:
		var still_exists: bool = feed.entries.any(func(item: Dictionary) -> bool: return str(item.id) == selected_id)
		if still_exists:
			if not _selection_filtered:
				_filter_scroll = old_scroll
			_selection_filtered = true
		else:
			_selected = {}
			_map_selected = {}
			_selection_filtered = false
			ride_selected.emit({})
	elif selected_visible:
		if _selection_filtered:
			_restore_scroll = _filter_scroll
		elif reload_feed:
			_restore_scroll = old_scroll
		if _restore_scroll >= 0:
			_restore_delay = 2
		_selection_filtered = false
	_thumb_generation = Feed.thumb_generation()
	_append_cards()
	_last_scroll = -1
	set_process(true)
	controls_created.emit(self)


func _append_cards() -> void:
	var count := mini(maxi(1, Config.feed_cards_per_frame), _pending_entries.size())
	for i in count:
		var entry: Dictionary = _pending_entries.pop_front()
		_insert_card(entry)
		if not str(entry.get("thumb", "")).is_empty():
			var thumb_path: String = feed.thumb_path(str(entry.id))
			if not FileAccess.file_exists(thumb_path):
				_pending_paths[str(entry.id)] = thumb_path
				_pending_elapsed = 0.0
	_queue_preview_update()


func _insert_card(entry: Dictionary, at := -1) -> Button:
	var card := Card.new()
	card.set_meta(&"ride_entry", entry)
	_list.add_child(card)
	if at >= 0:
		_list.move_child(card, at)
	card.setup(entry, feed, _wide_cards, _failed_previews)
	card.resized.connect(_card_resized.bind(card))
	card.gui_input.connect(_navigate_cards.bind(card))
	card.button_group = _group
	_cards[str(entry.id)] = card
	if str(entry.id) == str(_selected.get("id", "")):
		card.set_pressed_no_signal(true)
	card.pressed.connect(_choose.bind(entry))
	if str(entry.id) == _focus_after_delete_id:
		_focus_after_delete_id = ""
		card.grab_focus.call_deferred()
	controls_created.emit(card)
	return card


func _card_resized(card: Control) -> void:
	if is_instance_valid(card) and card.custom_minimum_size.y > 0.0:
		_slot_height = card.custom_minimum_size.y
	_queue_preview_update()


func _materialize(slot: Control) -> Button:
	var index := slot.get_index()
	var entry: Dictionary = slot.get_meta(&"ride_entry")
	_list.remove_child(slot)
	slot.queue_free()
	return _insert_card(entry, index)


func _navigate_cards(event: InputEvent, current: Button) -> void:
	var direction := int(event.is_action_pressed("ui_down", true) or event.is_action_pressed("ui_focus_next")) - int(event.is_action_pressed("ui_up", true) or event.is_action_pressed("ui_focus_prev"))
	if direction == 0:
		return
	var index := current.get_index() + direction
	if index >= _list.get_child_count() and not _pending_entries.is_empty():
		_append_cards()
	if index < 0 or index >= _list.get_child_count():
		return
	var target := _list.get_child(index) as Control
	if target == null or not target.has_meta(&"ride_entry"):
		return
	var button := target as Button
	if button == null:
		button = _materialize(target)
	current.accept_event()
	button.grab_focus.call_deferred()
	_scroll.ensure_control_visible.call_deferred(button)


func _process(delta: float) -> void:
	if not is_visible_in_tree():
		set_process(false)
		return
	_poll_covers()
	_poll_detail_photos()
	if not _pending_entries.is_empty() and _needs_more_cards():
		_append_cards()
	if _restore_scroll >= 0 and _restore_delay > 0:
		_restore_delay -= 1
	elif _restore_scroll >= 0:
		var bar := _scroll.get_v_scroll_bar()
		var available_scroll := maxi(0, int(bar.max_value - bar.page))
		_scroll.scroll_vertical = mini(_restore_scroll, available_scroll)
		if available_scroll >= _restore_scroll or _pending_entries.is_empty():
			_restore_scroll = -1
	if _last_scroll != _scroll.scroll_vertical:
		_last_scroll = _scroll.scroll_vertical
		_update_visible_previews()
	if not _pending_paths.is_empty():
		_pending_elapsed += delta
	_pending_poll += delta
	if _pending_elapsed >= Config.pending_preview_timeout:
		_pending_paths.clear()
	if _thumb_dirty or _pending_poll >= Config.pending_preview_interval:
		_thumb_dirty = false
		_pending_poll = 0.0
		var generation := Feed.thumb_generation()
		if generation != _thumb_generation:
			_thumb_generation = generation
			for card in _cards.values():
				if not _wide_cards or _card_near_view(card):
					if Feed.thumb_is_preparing(card.preview_path):
						card.unload_preview()
					elif card._preview.texture == null or card.preview_revision != Feed.thumb_revision(card.preview_path):
						card.update_preview(card.preview_path)
					card.update_preview_status()
			if is_instance_valid(_dialog) and _dialog.visible:
				_refresh_detail_preview()
		for id: String in _pending_paths.keys():
			var path: String = _pending_paths[id]
			if FileAccess.file_exists(path):
				if _cards.has(id) and (not _wide_cards or _card_near_view(_cards[id])):
					_cards[id].update_preview(path)
				_pending_paths.erase(id)
	var cards_waiting := not _pending_entries.is_empty() and _needs_more_cards()
	if not cards_waiting and _restore_scroll < 0 and _pending_paths.is_empty() and _cover_thread == null \
			and _cover_queue.is_empty() and _photo_thread == null and _photo_queue.is_empty() and not _preview_update_queued:
		set_process(false)


func _needs_more_cards() -> bool:
	return _list.get_child_count() == 0 or float(_scroll.scroll_vertical) + _scroll.size.y + 500.0 >= _list.size.y


func _card_near_view(card: Control) -> bool:
	# Предзагрузка чуть за пределами экрана, без декодирования дальних карточек.
	return _scroll.get_global_rect().grow_individual(0, 200, 0, 200).intersects(card.get_global_rect())


func _queue_preview_update() -> void:
	if not _preview_update_queued:
		_preview_update_queued = true
		_apply_preview_update.call_deferred()
	if is_visible_in_tree():
		set_process(true)


func _apply_preview_update() -> void:
	_preview_update_queued = false
	_update_visible_previews()


func _update_visible_previews() -> void:
	if not is_visible_in_tree():
		return
	_cover_queue.clear()
	for child: Node in _list.get_children():
		var row := child as Control
		if row == null or not row.has_meta(&"ride_entry") or row.size.y <= 0.0:
			continue
		var card := row as Button
		if card == null:
			if _slot_height > 0.0 and not is_equal_approx(row.custom_minimum_size.y, _slot_height):
				row.custom_minimum_size.y = _slot_height
			if _card_near_view(row):
				card = _materialize(row)
			else:
				continue
		elif not _card_near_view(card) and not card.has_focus() and not (is_instance_valid(_dialog) and _dialog.visible and str(row.get_meta(&"ride_entry").id) == str(_selected.get("id", ""))):
			var index := card.get_index()
			var slot := Control.new()
			slot.set_meta(&"ride_entry", row.get_meta(&"ride_entry"))
			slot.custom_minimum_size.y = card.size.y
			slot.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			slot.mouse_filter = Control.MOUSE_FILTER_IGNORE
			_cards.erase(str(row.get_meta(&"ride_entry").id))
			card.button_group = null
			_list.remove_child(card)
			_list.add_child(slot)
			_list.move_child(slot, index)
			card.queue_free()
			continue
		# Карточка с фокусом остаётся в дереве, но её карта не нужна далеко за экраном.
		if not _card_near_view(card):
			card.unload_preview()
			continue
		if card._preview.texture == null:
			card.update_preview(card.preview_path)
		if _wide_cards:
			_queue_cover(card, row.get_meta(&"ride_entry"))


func _queue_cover(card: Button, entry: Dictionary) -> void:
	var photos: Array = entry.get("photo_paths", [])
	for value: Variant in photos:
		if not value is String or value.is_empty():
			continue
		var path: String = value
		if _cover_cache.has(path):
			if _cover_cache[path] != null:
				card.set_cover(_cover_cache[path])
				return
			continue
		if path != _cover_path:
			_cover_queue[path] = true
		return
	card.set_cover(null)


func _poll_covers() -> void:
	if _cover_thread != null and not _cover_thread.is_alive():
		var image: Variant = _cover_thread.wait_to_finish()
		_cover_thread = null
		var texture: Texture2D = ImageTexture.create_from_image(image) if image is Image and not image.is_empty() else null
		_cover_cache[_cover_path] = texture
		_cover_order.erase(_cover_path)
		_cover_order.append(_cover_path)
		while _cover_order.size() > COVER_CACHE_LIMIT:
			_cover_cache.erase(_cover_order.pop_front())
		for card: Button in _cards.values():
			var entry: Dictionary = card.get_meta(&"ride_entry")
			var photos: Array = entry.get("photo_paths", [])
			if _cover_path in photos:
				_queue_cover(card, entry)
		_cover_path = ""
	if _cover_thread == null and not _cover_queue.is_empty():
		_cover_path = str(_cover_queue.keys()[0])
		_cover_queue.erase(_cover_path)
		_cover_thread = Thread.new()
		if _cover_thread.start(_load_cover.bind(_cover_path)) != OK:
			_cover_thread = null
			_cover_cache[_cover_path] = null
			_cover_path = ""


static func _load_cover(path: String) -> Image:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null or file.get_length() > 24 * 1024 * 1024:
		return null
	file.close()
	var image := Image.load_from_file(path)
	if image == null or image.is_empty():
		return null
	var longest := maxi(image.get_width(), image.get_height())
	if longest > 640:
		var factor := 640.0 / longest
		image.resize(maxi(1, roundi(image.get_width() * factor)), maxi(1, roundi(image.get_height() * factor)), Image.INTERPOLATE_BILINEAR)
	return image


func _exit_tree() -> void:
	Feed.unwatch_thumbs(_on_thumbs_changed)
	if _cover_thread != null:
		_cover_thread.wait_to_finish()
		_cover_thread = null
	if _photo_thread != null:
		_photo_thread.wait_to_finish()
		_photo_thread = null


func _choose(entry: Dictionary) -> void:
	entry = Presentation.make(entry)
	_selected = entry
	if _cards.has(str(entry.id)):
		_cards[str(entry.id)].set_pressed_no_signal(true)
	_show_detail(entry)


func _input(event: InputEvent) -> void:
	_handle_detail_cancel(event, get_viewport())
	if not is_visible_in_tree() or (is_instance_valid(_dialog) and _dialog.visible):
		return
	var focus := get_viewport().gui_get_focus_owner() as Button
	if focus != null and focus.get_parent() == _list and focus.has_meta(&"ride_entry"):
		_navigate_cards(event, focus)


func _handle_detail_cancel(event: InputEvent, viewport: Viewport) -> void:
	if not is_visible_in_tree() or not is_instance_valid(_dialog) or not _dialog.visible or event.is_echo():
		return
	var pad := event as InputEventJoypadButton
	if not (event.is_action_pressed("ui_cancel") or event.is_action_pressed("back") or event.is_action_pressed("pause") or (pad != null and pad.pressed and pad.button_index == JOY_BUTTON_B)):
		return
	var children := _dialog.find_children("*", "Window", true, false)
	children.reverse()
	for child: Node in children:
		var window := child as Window
		if window != null and window.visible:
			window.hide()
			window.queue_free()
			viewport.set_input_as_handled()
			return
	_dialog.hide()
	viewport.set_input_as_handled()


func _show_detail(entry: Dictionary) -> void:
	if entry.is_empty():
		return
	_photo_queue.clear()
	if is_instance_valid(_dialog):
		_dialog.hide()
		_dialog.queue_free()
	_dialog = AcceptDialog.new()
	_dialog.title = "Пешая прогулка" if bool(entry.get("walk", false)) else "Поездка"
	_dialog.theme = MENU_THEME
	_dialog.add_theme_stylebox_override("panel", HudStyle.panel(DETAIL_SURFACE, DETAIL_BORDER, 12, Vector2(20, 16)))
	_dialog.add_theme_stylebox_override("embedded_border", _window_border())
	_dialog.add_theme_color_override("title_color", HudStyle.CREAM)
	_dialog.window_input.connect(func(event: InputEvent) -> void: _handle_detail_cancel(event, _dialog))
	var available := Vector2i(get_viewport().get_visible_rect().size) - Vector2i(32, 32)
	_dialog.min_size = Config.detail_min_size.min(available)
	add_child(_dialog)
	_dialog.get_ok_button().text = "Закрыть"
	_dialog.visibility_changed.connect(func() -> void:
		if not _dialog.visible and is_visible_in_tree() and _cards.has(str(entry.id)):
			_cards[str(entry.id)].grab_focus())
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Config.detail_scroll_size.min(Vector2(available - Vector2i(32, 80)))
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.follow_focus = true
	_dialog.add_child(scroll)
	var box := VBoxContainer.new()
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_theme_constant_override("separation", Config.feed_spacing)
	scroll.add_child(box)
	var title := Label.new()
	title.text = ("ПЕШАЯ ПРОГУЛКА · " if bool(entry.get("walk", false)) else "ПОЕЗДКА · ") + (RideLog.journal_date_text(float(entry.start)) if entry.has("start") else "Дата неизвестна")
	HudStyle.label(title, 20, HudStyle.CREAM)
	title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(title)
	var world := Label.new()
	var tid := str(entry.get("template_id", ""))
	var type_title: String = WorldTemplate.config(tid).title if WorldTemplate.exists(tid) else "Неизвестный тип мира (%s)" % tid
	world.text = "%s · %s" % [Presentation.world_name(entry), type_title]
	HudStyle.label(world, 14, HudStyle.MUTED)
	world.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(world)
	var show_map: Button
	if same_world(entry):
		show_map = Button.new()
		show_map.text = "Показать на карте мира"
		show_map.disabled = entry.get("track", []).is_empty()
		if show_map.disabled:
			show_map.tooltip_text = "В этой записи нет координат маршрута"
		show_map.pressed.connect(func() -> void:
			_map_selected = entry
			ride_selected.emit(entry)
			_dialog.hide())
	var preview_path: String = feed.thumb_path(str(entry.id))
	_detail_preview_path = preview_path
	_detail_revision = -1
	var route_title := Label.new()
	route_title.text = "МАРШРУТ ПОЕЗДКИ"
	HudStyle.label(route_title, 12, HudStyle.AMBER)
	box.add_child(route_title)
	var preview_box := PanelContainer.new()
	preview_box.add_theme_stylebox_override("panel", HudStyle.panel(HudStyle.PAPER, HudStyle.BORDER, 6, Vector2(4, 4), false))
	box.add_child(preview_box)
	var preview := TextureRect.new()
	_detail_preview = preview
	preview.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	preview.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	preview.custom_minimum_size = Vector2(0, Config.detail_preview_height)
	preview_box.add_child(preview)
	_detail_missing = Label.new()
	_detail_missing.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_detail_missing.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	HudStyle.label(_detail_missing, 14, HudStyle.SURFACE)
	preview.add_child(_detail_missing)
	_detail_missing.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_detail_legend = Label.new()
	_detail_legend.text = "Линия — маршрут · × — доступные отметки падений"
	HudStyle.label(_detail_legend, 12, HudStyle.MUTED)
	_detail_legend.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(_detail_legend)
	if show_map != null:
		box.add_child(show_map)
	_refresh_detail_preview()
	var summary := HFlowContainer.new()
	summary.add_theme_constant_override("h_separation", 24)
	summary.add_theme_constant_override("v_separation", 6)
	box.add_child(summary)
	var distance := Label.new()
	var distance_value := float(entry.get("bike", 0.0)) + float(entry.get("foot", 0.0))
	distance.text = "Путь · %s" % Util.distance_text(distance_value) if entry.has("bike") or entry.has("foot") else "Путь · —"
	HudStyle.label(distance, 16, HudStyle.CREAM)
	summary.add_child(distance)
	var duration := Label.new()
	duration.text = "Время · %s" % RideLog.duration_text(float(entry.time)) if entry.has("time") else "Время · —"
	HudStyle.label(duration, 16, HudStyle.CREAM)
	summary.add_child(duration)
	_detail_toggle = Button.new()
	_detail_toggle.text = "Больше о поездке"
	_detail_toggle.toggle_mode = true
	_detail_toggle.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	box.add_child(_detail_toggle)
	_detail_extra = VBoxContainer.new()
	_detail_extra.add_theme_constant_override("separation", Config.feed_spacing)
	_detail_extra.hide()
	box.add_child(_detail_extra)
	_detail_toggle.toggled.connect(func(on: bool) -> void:
		_detail_extra.visible = on
		_detail_toggle.text = "Скрыть подробности" if on else "Больше о поездке")
	var marked := 0
	for mark: Dictionary in entry.get("fall_marks", []):
		if mark.has("x") and mark.has("z") and (mark.x is float or mark.x is int) and (mark.z is float or mark.z is int) and Vector2(float(mark.x), float(mark.z)).is_finite():
			marked += 1
	if entry.has("falls") and int(entry.falls) > marked:
		var partial := Label.new()
		partial.text = "Координаты сохранены для %d из %d падений." % [marked, int(entry.falls)]
		HudStyle.label(partial, 12, HudStyle.MUTED)
		partial.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		_detail_extra.add_child(partial)
	var statistics_title := Label.new()
	statistics_title.text = "СТАТИСТИКА"
	HudStyle.label(statistics_title, 12, HudStyle.AMBER)
	_detail_extra.add_child(statistics_title)
	var labels := [
		["Велосипед", Util.distance_text(float(entry.bike)) if entry.has("bike") else "—"],
		["Пешком", Util.distance_text(float(entry.foot)) if entry.has("foot") else "—"],
		["Длительность", RideLog.duration_text(float(entry.time)) if entry.has("time") else "—"],
		["В движении", RideLog.duration_text(float(entry.moving_time)) if entry.has("moving_time") else "—"],
		["Набор / сброс", _metric(entry, "climb", " м") + " / " + _metric(entry, "descent", " м")],
		["Высота мин. / макс.", _metric(entry, "alt_min", " м") + " / " + _metric(entry, "alt_max", " м")],
		["Скорость средняя / макс.", _speed(entry, "speed_avg") + " / " + _speed(entry, "speed_max")],
		["Прыжки / полёт", _metric(entry, "jumps", "") + " / " + _metric(entry, "air_max", " с")],
		["Падения", _metric(entry, "falls", "")],
		["Снимки / задания", _metric(entry, "photos", "") + " / " + _metric(entry, "quests", "")],
	]
	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", Config.detail_grid_gap)
	grid.add_theme_constant_override("v_separation", Config.feed_spacing)
	_detail_extra.add_child(grid)
	for item: Array in labels:
		var cell := VBoxContainer.new()
		cell.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		cell.add_theme_constant_override("separation", 1)
		grid.add_child(cell)
		var caption := Label.new()
		caption.text = str(item[0])
		HudStyle.label(caption, 12, HudStyle.MUTED)
		caption.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		cell.add_child(caption)
		var value := Label.new()
		value.text = str(item[1])
		HudStyle.label(value, 16, HudStyle.CREAM)
		value.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		cell.add_child(value)
	var profile_title := Label.new()
	profile_title.text = "ПРОФИЛЬ ВЫСОТЫ"
	HudStyle.label(profile_title, 12, HudStyle.AMBER)
	_detail_extra.add_child(profile_title)
	var profile := Profile.new()
	profile.values = entry.get("profile", [])
	profile.marks = entry.get("fall_marks", [])
	profile.custom_minimum_size.y = Config.detail_profile_height
	_detail_extra.add_child(profile)
	if profile.values.size() >= 2:
		var limits := Label.new()
		limits.text = "мин. %d м    ·    макс. %d м" % [roundi(float(profile.values.min())), roundi(float(profile.values.max()))]
		HudStyle.label(limits, 12, HudStyle.MUTED)
		_detail_extra.add_child(limits)
	var places := Label.new()
	places.text = "Места: " + (", ".join(entry.get("places", [])) if not entry.get("places", []).is_empty() else "—")
	places.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(places)
	var paths: Array[String] = []
	for path: String in entry.get("photo_paths", []):
		if FileAccess.file_exists(path):
			paths.append(path)
	var missing_photos: int = entry.get("photo_paths", []).size() - paths.size()
	if missing_photos > 0:
		var photo_status := Label.new()
		photo_status.text = "Недоступных файлов снимков: %d" % missing_photos
		HudStyle.label(photo_status, 12, HudStyle.MUTED)
		box.add_child(photo_status)
	if not paths.is_empty():
		var photos_title := Label.new()
		photos_title.text = "СНИМКИ · %d" % paths.size()
		HudStyle.label(photos_title, 12, HudStyle.AMBER)
		box.add_child(photos_title)
		var photos := GridContainer.new()
		photos.columns = 3 if available.x >= 600 else 2
		photos.add_theme_constant_override("h_separation", Config.feed_spacing)
		photos.add_theme_constant_override("v_separation", Config.feed_spacing)
		box.add_child(photos)
		var more := Button.new()
		more.text = "Показать ещё снимки"
		box.add_child(more)
		var state := {next = 0}
		more.pressed.connect(func() -> void: _append_photos(photos, paths, state, more))
		_append_photos(photos, paths, state, more)
	var remove := Button.new()
	remove.text = "Удалить запись"
	remove.theme_type_variation = &"DangerButton"
	remove.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	box.add_child(remove)
	remove.pressed.connect(func() -> void:
		var confirm := ConfirmationDialog.new()
		confirm.title = "Удалить запись?"
		confirm.dialog_text = "Запись и её превью будут удалены. Мир и исходные снимки сохранятся."
		_dialog.add_child(confirm)
		confirm.window_input.connect(func(event: InputEvent) -> void: _handle_detail_cancel(event, confirm))
		controls_created.emit(confirm)
		confirm.confirmed.connect(func() -> void:
			confirm.hide()
			confirm.queue_free()
			var visible_ids: Array[String] = []
			for item: Dictionary in feed.entries:
				if (not _only_world or same_world(item)) and (settings.show_walks or not bool(item.get("walk", false))):
					visible_ids.append(str(item.id))
			var removed_index := visible_ids.find(str(entry.id))
			var next_focus := ""
			if removed_index >= 0:
				visible_ids.remove_at(removed_index)
				if not visible_ids.is_empty():
					next_focus = visible_ids[mini(removed_index, visible_ids.size() - 1)]
			var previous_scroll := _scroll.scroll_vertical
			if feed.load_feed() == OK and feed.erase(str(entry.id)) == OK:
				_selected = {}
				if str(_map_selected.get("id", "")) == str(entry.id):
					_map_selected = {}
					ride_selected.emit({})
				_dialog.hide()
				_focus_after_delete_id = next_focus
				refresh()
				if next_focus.is_empty():
					_walks.grab_focus()
				else:
					_restore_scroll = previous_scroll
					_restore_delay = 2
			else:
				var error := AcceptDialog.new()
				error.title = "Не удалось удалить запись"
				error.dialog_text = "Запись сохранена. Проверьте доступ к файлам и попробуйте снова."
				_dialog.add_child(error)
				error.window_input.connect(func(event: InputEvent) -> void: _handle_detail_cancel(event, error))
				error.popup_centered())
		confirm.popup_centered())
	controls_created.emit(_dialog)
	_dialog.popup_centered(Config.detail_window_size.min(available))


func _refresh_detail_preview() -> void:
	if not is_instance_valid(_detail_preview):
		return
	var revision := Feed.thumb_revision(_detail_preview_path)
	var preparing := Feed.thumb_is_preparing(_detail_preview_path)
	if preparing:
		_detail_preview.texture = null
		_detail_revision = -1
	elif revision != int(_failed_previews.get(_detail_preview_path, -2)) and (_detail_preview.texture == null or _detail_revision != revision) and FileAccess.file_exists(_detail_preview_path):
		var image := Image.load_from_file(_detail_preview_path)
		if image != null and not image.is_empty():
			_detail_preview.texture = ImageTexture.create_from_image(image)
			_detail_revision = revision
			_failed_previews.erase(_detail_preview_path)
		else:
			_failed_previews[_detail_preview_path] = revision
	var available := _detail_preview.texture != null
	_detail_missing.visible = not available
	_detail_missing.text = "Подготавливаем карту…" if preparing else "Карта поездки недоступна"
	_detail_legend.visible = available


func _append_photos(grid: GridContainer, paths: Array[String], state: Dictionary, more: Button) -> void:
	var last := mini(paths.size(), int(state.next) + maxi(1, Config.detail_photos_per_batch))
	while int(state.next) < last:
		var path := paths[int(state.next)]
		state.next += 1
		var button := TextureButton.new()
		button.ignore_texture_size = true
		button.stretch_mode = TextureButton.STRETCH_KEEP_ASPECT_CENTERED
		button.custom_minimum_size = Vector2(Config.detail_photo_width / 3.0, Config.detail_photo_height)
		button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		button.tooltip_text = "Открыть снимок"
		button.accessibility_name = "Открыть снимок " + path.get_file()
		button.pressed.connect(_open_photo.bind(path))
		grid.add_child(button)
		var status := Label.new()
		status.text = "Загрузка снимка…"
		status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		status.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		status.mouse_filter = Control.MOUSE_FILTER_IGNORE
		status.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		HudStyle.label(status, 13, HudStyle.MUTED)
		button.add_child(status)
		_queue_detail_photo(path, button, status, _dialog, Config.detail_photo_width)
		controls_created.emit(button)
	more.visible = int(state.next) < paths.size()


func _open_photo(path: String) -> void:
	var dialog := AcceptDialog.new()
	dialog.title = "Снимок поездки"
	dialog.theme = MENU_THEME
	dialog.add_theme_stylebox_override("panel", HudStyle.panel(DETAIL_SURFACE, DETAIL_BORDER, 12, Vector2(22, 18)))
	dialog.add_theme_stylebox_override("embedded_border", _window_border())
	dialog.add_theme_color_override("title_color", HudStyle.CREAM)
	_dialog.add_child(dialog)
	dialog.window_input.connect(func(event: InputEvent) -> void: _handle_detail_cancel(event, dialog))
	var view := TextureRect.new()
	view.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	view.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	var available := Vector2i(get_viewport().get_visible_rect().size) - Vector2i(80, 100)
	view.custom_minimum_size = Vector2(available)
	dialog.add_child(view)
	var status := Label.new()
	status.text = "Загрузка снимка…"
	status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	status.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	status.mouse_filter = Control.MOUSE_FILTER_IGNORE
	status.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	HudStyle.label(status, 16, HudStyle.MUTED)
	view.add_child(status)
	dialog.close_requested.connect(dialog.queue_free)
	dialog.confirmed.connect(dialog.queue_free)
	controls_created.emit(dialog)
	dialog.popup_centered(available)
	_queue_detail_photo(path, view, status, dialog, maxi(800, available.x), true)


## Изображения читаются и уменьшаются вне главного потока; на нём создаётся только текстура.
func _queue_detail_photo(path: String, target: Control, status: Label, owner: Window, width: int, priority := false) -> void:
	var job := {path = path, target = weakref(target), status = weakref(status), owner = weakref(owner), width = width}
	if priority:
		_photo_queue.push_front(job)
	else:
		_photo_queue.append(job)
	set_process(true)


static func _decode_detail_photo(path: String, width: int) -> Image:
	var image := Image.load_from_file(path)
	if image == null or image.is_empty():
		return null
	if image.get_width() > width:
		image.resize(width, maxi(1, roundi(float(width) * image.get_height() / image.get_width())), Image.INTERPOLATE_BILINEAR)
	return image


func _poll_detail_photos() -> void:
	if _photo_thread != null and not _photo_thread.is_alive():
		var image: Variant = _photo_thread.wait_to_finish()
		_photo_thread = null
		var target: Control = (_photo_job.target as WeakRef).get_ref()
		var status: Label = (_photo_job.status as WeakRef).get_ref()
		var owner: Window = (_photo_job.owner as WeakRef).get_ref()
		if is_instance_valid(target) and is_instance_valid(status) and is_instance_valid(owner) and owner.visible and not owner.is_queued_for_deletion():
			if image is Image and not image.is_empty():
				var texture := ImageTexture.create_from_image(image)
				if target is TextureButton:
					(target as TextureButton).texture_normal = texture
				elif target is TextureRect:
					(target as TextureRect).texture = texture
				status.hide()
			else:
				status.text = "Снимок недоступен"
		_photo_job.clear()
	while _photo_thread == null and not _photo_queue.is_empty():
		var job: Dictionary = _photo_queue.pop_front()
		var target: Control = (job.target as WeakRef).get_ref()
		var owner: Window = (job.owner as WeakRef).get_ref()
		if not is_instance_valid(target) or not is_instance_valid(owner) or not owner.visible or owner.is_queued_for_deletion():
			continue
		_photo_job = job
		_photo_thread = Thread.new()
		if _photo_thread.start(_decode_detail_photo.bind(str(job.path), int(job.width))) != OK:
			_photo_thread = null
			var status: Label = (job.status as WeakRef).get_ref()
			if is_instance_valid(status):
				status.text = "Снимок недоступен"
			_photo_job.clear()


static func _window_border() -> StyleBoxFlat:
	var border := HudStyle.panel(DETAIL_SURFACE, DETAIL_BORDER, 12, Vector2.ZERO, false)
	border.expand_margin_left = 16.0
	border.expand_margin_right = 16.0
	border.expand_margin_top = 40.0
	border.expand_margin_bottom = 16.0
	return border


static func _metric(entry: Dictionary, key: String, unit: String) -> String:
	return ("%.1f" % float(entry[key])).trim_suffix(".0") + unit if entry.has(key) else "—"


static func _speed(entry: Dictionary, key: String) -> String:
	return "%.1f км/ч" % (float(entry[key]) * 3.6) if entry.has(key) else "—"


class Profile extends Control:
	var values: Array = []
	var marks: Array = []

	func _draw() -> void:
		if values.size() < 2:
			draw_string(ThemeDB.fallback_font, Vector2(8, 28), "Профиль высоты недоступен", HORIZONTAL_ALIGNMENT_LEFT, -1, 14, HudStyle.MUTED)
			return
		var low := float(values.min())
		var high := float(values.max())
		var span := maxf(high - low, 1.0)
		var points := PackedVector2Array()
		for i in values.size():
			points.append(Vector2(float(i) / float(values.size() - 1) * size.x, size.y - (float(values[i]) - low) / span * (size.y - Config.profile_padding * 2.0) - Config.profile_padding))
		draw_polyline(points, HudStyle.MINT, Config.profile_line_width, true)
		for mark: Dictionary in marks:
			if not mark.has("progress") or not (mark.progress is float or mark.progress is int) or not is_finite(float(mark.progress)) or float(mark.progress) < 0.0 or float(mark.progress) > 1.0:
				continue
			var x := clampf(float(mark.get("progress", 0.0)), 0.0, 1.0) * (values.size() - 1)
			var index := mini(floori(x), values.size() - 2)
			var p := points[index].lerp(points[index + 1], x - index)
			var radius: float = Config.profile_fall_radius
			draw_line(p + Vector2(-radius, -radius), p + Vector2(radius, radius), Config.map_fall_color, Config.profile_fall_width)
			draw_line(p + Vector2(-radius, radius), p + Vector2(radius, -radius), Config.map_fall_color, Config.profile_fall_width)
