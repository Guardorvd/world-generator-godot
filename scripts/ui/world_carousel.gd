extends PanelContainer
## Витрина показывает только выбранный мир; география без кэша строится явно по запросу.
signal world_selected(seed_text: String)
signal play_requested
signal create_requested(seed_text: String)
signal preview_ready(seed_text: String, texture: Texture2D)
signal map_changed
signal stepped(direction: int)
signal favorite_requested(seed_text: String, source: Control)
signal type_changed
signal catalog_requested(source: Control)
signal displayed_type_changed

const MapPreview := preload("res://scripts/ui/menu_map_preview.gd")
const Icons := preload("res://scripts/ui/ui_icons.gd")
const MAX_DERIVED_MAPS := 8
var WORLD_TYPES: Array[Dictionary] = WorldTemplate.menu_types()

class PreviewCancel extends RefCounted:
	var mutex := Mutex.new()
	var cancelled := false
	func cancel() -> void:
		mutex.lock()
		cancelled = true
		mutex.unlock()
	func is_cancelled() -> bool:
		mutex.lock()
		var result := cancelled
		mutex.unlock()
		return result

@onready var _card: Control = $Card
@onready var _slide: Control = $Card/Slide
@onready var _artwork: Control = $Card/Slide/Frame/Artwork
@onready var _map: TextureRect = $Card/Slide/Frame/Artwork/Art/Map
@onready var _old_map: TextureRect = $Card/Slide/Frame/Artwork/Art/OldMap
@onready var _pattern: Control = $Card/Slide/Frame/Pattern
@onready var _preview_note: Label = $Card/Slide/Frame/Artwork/Art/PreviewNote
@onready var _placeholder: Control = $Card/Slide/Frame/Placeholder
@onready var _hint: Label = $Card/Slide/Frame/Placeholder/Hint
@onready var _quick_seed: LineEdit = $Card/Slide/Frame/Placeholder/QuickSeed
@onready var _create_first: Button = $Card/Slide/Frame/Placeholder/CreateFirst
@onready var _build_preview: Button = $Card/Slide/Frame/Placeholder/BuildPreview
@onready var _name: Label = $Card/Slide/Header/WorldName
@onready var _favorite: Button = $Card/Slide/Header/Favorite
@onready var _previous: Button = $Card/Slide/Header/Previous
@onready var _next: Button = $Card/Slide/Header/Next
@onready var _count: Label = $Card/Slide/Header/Count
@onready var _modes: Array[Button] = [$Card/Slide/Frame/Modes/Buttons/Relief, $Card/Slide/Frame/Modes/Buttons/Atlas, $Card/Slide/Frame/Modes/Buttons/Heights]
@onready var _indicator: Panel = $Card/Slide/Frame/Modes/Indicator
@onready var _mode_panel: Control = $Card/Slide/Frame/Modes
@onready var _mode_buttons: Control = $Card/Slide/Frame/Modes/Buttons

var force_animate_in_headless := false
var _entries: Array[Dictionary] = []
var _index := -1
var _mode := 0
var _type_index := 0
var _zoom: Tween
var _indicator_tween: Tween
var _slide_tween: Tween
var _map_tween: Tween
var _thread: Thread
var _loading_seed := ""
var _job_kind := ""
var _cancel_flag: PreviewCancel
var _derived := {}
var _derived_order: Array[String] = []
var _generated := {}
var _provisional_derived := {}
var _preview_errors := {}
var _type_buttons: Array[Button] = []
var _showcase_art: TextureRect
var _showcase_title: Label
var _showcase_description: Label
var _showcase_world: Label
var _showcase_status: Label
var _showcase_all: Button
var _displayed_type := 0
var _showcase_counter: Label
var _showcase_note: Label
var _hero_center: Control
var _carousel_previous: Button
var _carousel_next: Button
var _carousel_tween: Tween
var _carousel_ghost: TextureRect
var _art_cache := {}
var _art_order: Array[String] = []
var _draft_mode := false
var _draft_seed := ""

func setup(start_button: Button, actions: Array[Button], trail_lab: Button) -> void:
	set_process(false)
	_build_showcase()
	_previous.pressed.connect(move_type.bind(-1))
	_next.pressed.connect(move_type.bind(1))
	_favorite.pressed.connect(func() -> void:
		if _index >= 0: favorite_requested.emit(str(_entries[_index].seed), _favorite))
	_card.resized.connect(_layout_slide)
	_layout_slide.call_deferred()
	_artwork.gui_input.connect(_card_input)
	_placeholder.gui_input.connect(_card_input)
	_artwork.mouse_entered.connect(_set_zoom.bind(1.02))
	_artwork.mouse_exited.connect(_set_zoom.bind(1.0))
	_create_first.set_meta(&"ui_sound_custom", true)
	_create_first.pressed.connect(_create_world)
	_quick_seed.text_submitted.connect(func(_value: String) -> void: _create_world())
	_build_preview.pressed.connect(_request_preview)
	var highlight := StyleBoxFlat.new()
	highlight.bg_color = Color(0.77, 0.67, 0.40, 0.34)
	highlight.set_corner_radius_all(12)
	_indicator.add_theme_stylebox_override("panel", highlight)
	var track := StyleBoxFlat.new()
	track.bg_color = Color(0.03, 0.07, 0.08, 0.42)
	track.set_corner_radius_all(12)
	$Card/Slide/Frame/Modes/Track.add_theme_stylebox_override("panel", track)
	var clear := StyleBoxEmpty.new()
	for i in _modes.size():
		for state: String in ["normal", "hover", "pressed", "hover_pressed"]:
			_modes[i].add_theme_stylebox_override(state, clear)
		_modes[i].set_meta(&"ui_sound_custom", true)
		_modes[i].resized.connect(_position_indicator.bind(false))
		_modes[i].pressed.connect(_set_mode.bind(i))
	_previous.set_meta(&"ui_sound_custom", true)
	_next.set_meta(&"ui_sound_custom", true)
	_mode_buttons.resized.connect(_position_indicator.bind(false))
	var chain: Array[Control] = [_showcase_all, start_button]
	chain.append_array(actions)
	chain.append(trail_lab)
	for i in chain.size():
		chain[i].focus_neighbor_top = chain[i].get_path_to(chain[posmod(i - 1, chain.size())])
		chain[i].focus_neighbor_bottom = chain[i].get_path_to(chain[(i + 1) % chain.size()])
	for button: Button in _type_buttons:
		button.focus_neighbor_bottom = button.get_path_to(start_button)
		button.focus_neighbor_top = button.get_path_to(trail_lab)
	for button in actions:
		button.mouse_entered.connect(_hover_link.bind(button, true))
		button.mouse_exited.connect(_hover_link.bind(button, false))
	_set_mode(0)


func _build_showcase() -> void:
	# Старый узел карты остаётся источником превью для библиотеки, но не занимает витрину.
	_slide.hide()
	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	for edge: String in ["left", "top", "right", "bottom"]:
		margin.add_theme_constant_override("margin_" + edge, 12)
	_card.add_child(margin)
	_card.resized.connect(_refresh_showcase)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 6)
	margin.add_child(box)
	var header := HBoxContainer.new()
	box.add_child(header)
	_showcase_counter = Label.new()
	_showcase_counter.theme_type_variation = &"MenuFootnote"
	_showcase_counter.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_showcase_counter.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	header.add_child(_showcase_counter)
	_showcase_all = Button.new()
	_showcase_all.text = "Все типы  ▾"
	_showcase_all.tooltip_text = "Все типы путешествий"
	_showcase_all.theme_type_variation = &"MenuLink"
	_showcase_all.custom_minimum_size.y = 36
	_showcase_all.pressed.connect(func() -> void: catalog_requested.emit(_showcase_all))
	header.add_child(_showcase_all)
	var hero := HBoxContainer.new()
	hero.size_flags_vertical = Control.SIZE_EXPAND_FILL
	hero.add_theme_constant_override("separation", 7)
	box.add_child(hero)
	_carousel_previous = _make_neighbor(-1)
	hero.add_child(_carousel_previous)
	var center := HBoxContainer.new()
	center.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	center.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	center.add_theme_constant_override("separation", 10)
	hero.add_child(center)
	_hero_center = center
	var art_box := VBoxContainer.new()
	art_box.custom_minimum_size.x = 138
	art_box.add_theme_constant_override("separation", 2)
	center.add_child(art_box)
	_showcase_art = TextureRect.new()
	_showcase_art.custom_minimum_size = Vector2(138, 82)
	_showcase_art.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_showcase_art.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_showcase_art.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	art_box.add_child(_showcase_art)
	_showcase_note = Label.new()
	_showcase_note.text = "ПРИМЕР ЛАНДШАФТА"
	_showcase_note.theme_type_variation = &"MenuFootnote"
	_showcase_note.add_theme_font_size_override("font_size", 10)
	art_box.add_child(_showcase_note)
	var info := VBoxContainer.new()
	info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	info.alignment = BoxContainer.ALIGNMENT_CENTER
	info.add_theme_constant_override("separation", 6)
	center.add_child(info)
	_showcase_title = Label.new()
	_showcase_title.theme_type_variation = &"WorldName"
	_showcase_title.add_theme_font_size_override("font_size", 18)
	_showcase_title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	info.add_child(_showcase_title)
	_showcase_description = Label.new()
	_showcase_description.theme_type_variation = &"MenuFootnote"
	_showcase_description.add_theme_font_size_override("font_size", 14)
	_showcase_description.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	info.add_child(_showcase_description)
	_carousel_next = _make_neighbor(1)
	hero.add_child(_carousel_next)
	_type_buttons.assign([_carousel_previous, _carousel_next])
	_showcase_world = Label.new()
	_showcase_world.theme_type_variation = &"WorldName"
	_showcase_world.add_theme_font_size_override("font_size", 15)
	_showcase_world.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	box.add_child(_showcase_world)
	_showcase_status = Label.new()
	_showcase_status.theme_type_variation = &"MenuFootnote"
	_showcase_status.add_theme_font_size_override("font_size", 12)
	box.add_child(_showcase_status)
	_refresh_showcase()


func _make_neighbor(direction: int) -> Button:
	var button := Button.new()
	button.custom_minimum_size = Vector2(55, 70)
	button.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	button.theme_type_variation = &"MenuLink"
	button.clip_contents = true
	button.set_meta(&"ui_sound_custom", true)
	button.pressed.connect(move_type.bind(direction))
	var image := TextureRect.new()
	image.name = "Artwork"
	image.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	image.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	image.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	image.modulate = Color(0.58, 0.62, 0.62, 0.65)
	image.mouse_filter = Control.MOUSE_FILTER_IGNORE
	button.add_child(image)
	var arrow := Label.new()
	arrow.name = "Arrow"
	arrow.text = "‹" if direction < 0 else "›"
	arrow.add_theme_font_size_override("font_size", 34)
	arrow.add_theme_color_override("font_color", Color(1.0, 0.94, 0.78))
	arrow.add_theme_color_override("font_outline_color", Color(0.03, 0.04, 0.05, 0.95))
	arrow.add_theme_constant_override("outline_size", 4)
	arrow.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	arrow.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	arrow.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	arrow.mouse_filter = Control.MOUSE_FILTER_IGNORE
	button.add_child(arrow)
	var badge := Label.new()
	badge.name = "Soon"
	badge.text = "СКОРО"
	badge.theme_type_variation = &"MenuFootnote"
	badge.add_theme_font_size_override("font_size", 9)
	badge.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	badge.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	badge.offset_top = -17
	badge.mouse_filter = Control.MOUSE_FILTER_IGNORE
	button.add_child(badge)
	var focus_ring := Panel.new()
	focus_ring.name = "Highlight"
	focus_ring.theme_type_variation = &"CarouselNeighborFocus"
	focus_ring.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	focus_ring.mouse_filter = Control.MOUSE_FILTER_IGNORE
	focus_ring.visible = false
	button.add_child(focus_ring)
	button.mouse_entered.connect(_update_neighbor_highlight.bind(button, true, false))
	button.mouse_exited.connect(_update_neighbor_highlight.bind(button, false, false))
	button.focus_entered.connect(_update_neighbor_highlight.bind(button, true, true))
	button.focus_exited.connect(_update_neighbor_highlight.bind(button, false, true))
	return button


func _update_neighbor_highlight(button: Button, active: bool, from_focus: bool) -> void:
	button.set_meta(&"_neighbor_focus" if from_focus else &"_neighbor_hover", active)
	var focused := bool(button.get_meta(&"_neighbor_focus", false))
	var hovered := bool(button.get_meta(&"_neighbor_hover", false))
	var highlight := button.get_node("Highlight") as Panel
	highlight.visible = focused or hovered
	highlight.modulate.a = 1.0 if focused else 0.65
	var image := button.get_node("Artwork") as TextureRect
	image.modulate = Color(0.85, 0.87, 0.84, 0.9) if focused or hovered else Color(0.58, 0.62, 0.62, 0.65)


func set_draft(enabled: bool, seed_text := "") -> void:
	_draft_mode = enabled
	_draft_seed = seed_text
	_update_world_summary()


func _type_art(item: Dictionary) -> Texture2D:
	var path := str(item.get("artwork", ""))
	if path.is_empty(): return null
	if _art_cache.has(path):
		_art_order.erase(path)
		_art_order.append(path)
		return _art_cache[path]
	if not ResourceLoader.exists(path): return null
	var texture := load(path) as Texture2D
	if texture == null: return null
	while _art_order.size() >= 4:
		_art_cache.erase(_art_order.pop_front())
	_art_cache[path] = texture
	_art_order.append(path)
	return texture


func displayed_type_available() -> bool:
	return bool(WORLD_TYPES[_displayed_type].get("available", false))


func _refresh_showcase() -> void:
	if _showcase_title == null: return
	var item: Dictionary = WORLD_TYPES[_displayed_type]
	var ready := displayed_type_available()
	_showcase_title.text = str(item.title)
	_showcase_description.text = str(item.get("description", "")) if ready else "Новое путешествие появится позже."
	var artwork := _type_art(item)
	_showcase_art.texture = artwork if artwork != null else Icons.PEAK
	_showcase_art.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED if artwork != null else TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_showcase_art.modulate = Color.WHITE if artwork != null else Color(0.72, 0.77, 0.75, 0.36)
	_showcase_note.text = "ПРИМЕР ЛАНДШАФТА" if ready else "В РАЗРАБОТКЕ"
	_showcase_counter.text = "ПУТЕШЕСТВИЕ   %d / %d" % [_displayed_type + 1, WORLD_TYPES.size()]
	var previous: Dictionary = WORLD_TYPES[posmod(_displayed_type - 1, WORLD_TYPES.size())]
	var next: Dictionary = WORLD_TYPES[(_displayed_type + 1) % WORLD_TYPES.size()]
	(_carousel_previous.get_node("Artwork") as TextureRect).texture = _type_art(previous)
	(_carousel_next.get_node("Artwork") as TextureRect).texture = _type_art(next)
	(_carousel_previous.get_node("Soon") as Label).visible = not bool(previous.get("available", false))
	(_carousel_next.get_node("Soon") as Label).visible = not bool(next.get("available", false))
	_carousel_previous.tooltip_text = "Предыдущее: " + str(previous.title)
	_carousel_next.tooltip_text = "Следующее: " + str(next.title)
	_carousel_previous.disabled = WORLD_TYPES.size() < 2
	_carousel_next.disabled = _carousel_previous.disabled
	_update_world_summary()


func _update_world_summary() -> void:
	if _showcase_world == null: return
	var ready := displayed_type_available()
	var entry: Dictionary = _entries[_index] if _index >= 0 else {}
	var seed := str(entry.get("seed", ""))
	if not ready:
		_showcase_world.text = "ЭТОТ ТИП ПОКА НЕДОСТУПЕН"
		_showcase_world.tooltip_text = ""
		_showcase_status.text = "Выберите другой тип, чтобы начать"
	elif _draft_mode:
		var draft := _draft_seed.strip_edges()
		_showcase_world.text = "НОВЫЙ МИР  ·  " + ("Случайное зерно" if draft.is_empty() else draft)
		_showcase_world.tooltip_text = draft
		_showcase_status.text = "Зерно можно изменить до начала"
	else:
		_showcase_world.text = "ВАШ МИР  ·  " + ("Мир ещё не выбран" if seed.is_empty() else seed)
		_showcase_world.tooltip_text = seed
		_showcase_status.text = "Ошибка сохранения" if entry.get("corrupt", false) else ("Сохранение" if entry.get("saved", false) else ("Ещё не начат" if not seed.is_empty() else "Создайте новое путешествие"))


func _animate_type_step(direction: int, old_texture: Texture2D, old_rect: Rect2) -> void:
	if _carousel_tween != null and _carousel_tween.is_valid(): _carousel_tween.kill()
	if is_instance_valid(_carousel_ghost): _carousel_ghost.queue_free()
	_hero_center.pivot_offset = _hero_center.size * 0.5
	_hero_center.scale = Vector2.ONE
	_hero_center.modulate.a = 1.0
	for tile: Button in _type_buttons:
		tile.scale = Vector2.ONE
		tile.modulate.a = 1.0
	if DisplayServer.get_name() == "headless" and not force_animate_in_headless: return
	var departing := _carousel_previous if direction > 0 else _carousel_next
	var target_rect := departing.get_global_rect()
	departing.pivot_offset = departing.size * 0.5
	departing.scale = Vector2.ONE * 1.15
	departing.modulate.a = 0.6
	_hero_center.scale = Vector2.ONE * 0.94
	_hero_center.modulate.a = 0.55
	_carousel_tween = create_tween().set_parallel(true).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_carousel_tween.tween_property(_hero_center, "scale", Vector2.ONE, 0.20)
	_carousel_tween.tween_property(_hero_center, "modulate:a", 1.0, 0.20)
	_carousel_tween.tween_property(departing, "scale", Vector2.ONE, 0.20)
	_carousel_tween.tween_property(departing, "modulate:a", 1.0, 0.20)
	if old_texture != null and old_rect.size.x > 0:
		_carousel_ghost = TextureRect.new()
		_carousel_ghost.texture = old_texture
		_carousel_ghost.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		_carousel_ghost.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
		_carousel_ghost.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_carousel_ghost.position = old_rect.position - _card.get_global_rect().position
		_carousel_ghost.size = old_rect.size
		_card.add_child(_carousel_ghost)
		_carousel_tween.tween_property(_carousel_ghost, "position", target_rect.position - _card.get_global_rect().position, 0.20)
		_carousel_tween.tween_property(_carousel_ghost, "size", target_rect.size, 0.20)
		_carousel_tween.tween_property(_carousel_ghost, "modulate:a", 0.0, 0.20)
		var ghost := _carousel_ghost
		_carousel_tween.chain().tween_callback(func() -> void:
			if is_instance_valid(ghost): ghost.queue_free())


func _select_type_from_ui(id: String) -> void:
	if id == selected_type_id():
		_displayed_type = _type_index
		_refresh_showcase()
		displayed_type_changed.emit()
		return
	for item: Dictionary in WORLD_TYPES:
		if str(item.id) == id and bool(item.get("available", false)) and WorldTemplate.exists(id):
			select_type(id, false)
			type_changed.emit()
			displayed_type_changed.emit()
			stepped.emit(1)
			return

func set_entries(entries: Array[Dictionary], selected: String) -> void:
	_cancel_slide()
	_entries = entries
	for entry: Dictionary in _entries:
		if entry.get("texture") == null and _generated.has(entry.seed): entry.texture = _generated[entry.seed]
	_index = -1
	show_world(selected)

func show_world(seed_text: String, animate := false, direction := 0) -> void:
	if seed_text.is_empty():
		_show_index(-1)
		return
	for i in _entries.size():
		if _entries[i].seed == seed_text:
			if i == _index and _slide_tween != null: return
			_show_index(i, animate, direction)
			return
	_show_index(0 if not _entries.is_empty() else -1)

func set_preview(seed_text: String, texture: Texture2D) -> void:
	for entry: Dictionary in _entries:
		if entry.seed == seed_text:
			entry.texture = texture if texture != null else _generated.get(seed_text)
			return

## Меняет только состояние звезды, не прерывая подготовку карты или анимацию карусели.
func set_favorite(seed_text: String, favorite: bool) -> void:
	for i in _entries.size():
		if _entries[i].seed == seed_text:
			_entries[i].favorite = favorite
			if i == _index:
				_favorite.icon = Icons.star(favorite)
				_favorite.tooltip_text = "Убрать из избранного" if favorite else "Добавить в избранное"
			return


## Дисковые данные изменились: не позволяем старой задаче вернуть устаревшую карту.
func invalidate_preview(seed_text := "") -> void:
	if _thread != null and (seed_text.is_empty() or _loading_seed == seed_text) and _cancel_flag != null:
		_cancel_flag.cancel()
	if seed_text.is_empty():
		_generated.clear()
		_derived.clear()
		_derived_order.clear()
		_provisional_derived.clear()
		_preview_errors.clear()
	else:
		_generated.erase(seed_text)
		_derived.erase(seed_text)
		_derived_order.erase(seed_text)
		_provisional_derived.erase(seed_text)
		_preview_errors.erase(seed_text)
	for entry: Dictionary in _entries:
		if seed_text.is_empty() or entry.seed == seed_text:
			entry.texture = null

func generated_preview(seed_text: String) -> Texture2D:
	return _generated.get(seed_text)

func promote_cached(seed_text: String) -> void:
	_generated.erase(seed_text)
	if _provisional_derived.has(seed_text):
		_provisional_derived.erase(seed_text)
		_derived.erase(seed_text)
		_derived_order.erase(seed_text)

func _remember_maps(seed_text: String, images: Array) -> void:
	_derived_order.erase(seed_text)
	while not _derived.has(seed_text) and _derived.size() >= MAX_DERIVED_MAPS:
		var oldest: String = _derived_order.pop_front() if not _derived_order.is_empty() else str(_derived.keys()[0])
		_derived.erase(oldest)
		_provisional_derived.erase(oldest)
	_derived[seed_text] = images
	_derived_order.append(seed_text)

func _touch_maps(seed_text: String) -> void:
	if _derived.has(seed_text):
		_derived_order.erase(seed_text)
		_derived_order.append(seed_text)

func selected_texture() -> Texture2D:
	if _index < 0: return null
	var entry: Dictionary = _entries[_index]
	if _mode == 0: return entry.get("texture")
	_touch_maps(entry.seed)
	var images: Array = _derived.get(entry.seed, [])
	return images[_mode - 1] if images.size() == 2 else null

func selected_index() -> int:
	return _index

func type_available() -> bool:
	return bool(WORLD_TYPES[_type_index].available)

func selected_type_id() -> String:
	return str(WORLD_TYPES[_type_index].id)

func select_type(id: String, refresh := true) -> void:
	for i in WORLD_TYPES.size():
		if str(WORLD_TYPES[i].id) == id and bool(WORLD_TYPES[i].available) and WorldTemplate.exists(id):
			_displayed_type = i
			if _type_index != i:
				_type_index = i
				# Данные прежнего типа ещё не сброшены: карту не обновляем до type_changed.
				if refresh: _refresh_showcase()
			return

func move_type(direction: int) -> void:
	if direction == 0 or WORLD_TYPES.size() < 2: return
	var old_texture := _showcase_art.texture
	var old_rect := _showcase_art.get_global_rect()
	_displayed_type = posmod(_displayed_type + signi(direction), WORLD_TYPES.size())
	var item: Dictionary = WORLD_TYPES[_displayed_type]
	var committed := false
	if bool(item.get("available", false)) and WorldTemplate.exists(str(item.id)):
		if str(item.id) != selected_type_id():
			select_type(str(item.id), false)
			type_changed.emit()
			committed = true
	if not committed: _refresh_showcase()
	displayed_type_changed.emit()
	stepped.emit(signi(direction))
	_animate_type_step(signi(direction), old_texture, old_rect)

func move(direction: int) -> void:
	if _entries.size() < 2 or direction == 0: return
	var dir := signi(direction)
	_show_index(posmod(_index + dir, _entries.size()), true, dir)
	stepped.emit(dir)
	world_selected.emit(_entries[_index].seed)

func move_focused(direction: int) -> bool:
	var focus := get_viewport().gui_get_focus_owner()
	if focus == _carousel_previous or focus == _carousel_next:
		move_type(direction)
		return true
	return false

func _show_index(index: int, animate := false, direction := 0) -> void:
	if _index == index:
		_apply_entry()
		return
	_cancel_slide()
	cancel_preview()
	_index = index
	var should_animate := animate and direction != 0 and is_visible_in_tree() and (DisplayServer.get_name() != "headless" or force_animate_in_headless)
	if not should_animate:
		_apply_entry()
		return
	_slide_tween = create_tween()
	_slide_tween.tween_property(_slide, "position:x", -20.0 * direction, 0.07).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN)
	_slide_tween.tween_callback(func() -> void:
		_apply_entry()
		_slide.position.x = 20.0 * direction)
	_slide_tween.tween_property(_slide, "position:x", 0.0, 0.16).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_slide_tween.tween_callback(func() -> void: _slide_tween = null)

func _cancel_slide() -> void:
	if _slide_tween != null and _slide_tween.is_valid(): _slide_tween.kill()
	_slide_tween = null
	_layout_slide()

func _layout_slide() -> void:
	if not is_instance_valid(_slide): return
	var interrupted := _slide_tween != null and _slide_tween.is_valid()
	if interrupted:
		_slide_tween.kill()
		_slide_tween = null
	_slide.offset_left = 0.0
	_slide.offset_right = 0.0
	_slide.offset_top = 0.0
	_slide.offset_bottom = 0.0
	if interrupted: _apply_entry()

func _apply_entry() -> void:
	var entry: Dictionary = _entries[_index] if _index >= 0 else {}
	var available := type_available()
	_name.text = WORLD_TYPES[_type_index].title
	$Card/Slide/Frame/WorldInfo/Caption.text = "ВЫБРАННЫЙ МИР" if available else "СТАТУС"
	$Card/Slide/Frame/WorldInfo/Name.text = str(entry.get("seed", "Пока нет мира")) if available else "В разработке"
	var detail := ("Сохранение" if entry.get("saved", false) else ("Ещё не начат" if _index >= 0 else "Создайте первый мир")) if available else "Этот тип появится позже"
	if available and _index >= 0 and WorldTemplate.show_valley_length(selected_type_id()):
		var sz := WorldTemplate.plan_size(selected_type_id(), WGRandom.hash_string(str(entry.get("seed", ""))))
		var km := roundi(float(sz.y) * GameConfig.TILE / 1000.0)
		detail = ("Сохранение · долина ~%d км" % km) if entry.get("saved", false) else ("Долина ~%d км" % km)
	$Card/Slide/Frame/WorldInfo/Detail.text = detail
	_refresh_showcase()
	_count.text = "%d / %d" % [_type_index + 1, WORLD_TYPES.size()]
	_previous.disabled = WORLD_TYPES.size() < 2
	_next.disabled = _previous.disabled
	_favorite.disabled = _index < 0
	for button in _modes: button.disabled = _index < 0
	var fav: bool = entry.get("favorite", false)
	_favorite.icon = Icons.star(fav)
	_favorite.tooltip_text = "Убрать из избранного" if fav else "Добавить в избранное"
	_refresh_map()

func _set_mode(index: int) -> void:
	var previous := _mode
	_mode = index
	for i in _modes.size(): _modes[i].set_pressed_no_signal(i == index)
	_position_indicator(true)
	_refresh_map(index != previous)
	if index != previous: stepped.emit(signi(index - previous))

func _position_indicator(animate: bool) -> void:
	if not is_node_ready(): return
	var target := _modes[_mode]
	var rect := Rect2(target.position + _mode_buttons.position, target.size)
	if _indicator_tween != null and _indicator_tween.is_valid(): _indicator_tween.kill()
	if animate and _indicator.size.x > 0.0:
		_indicator_tween = create_tween().set_parallel(true)
		_indicator_tween.tween_property(_indicator, "position", rect.position, 0.16).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
		_indicator_tween.tween_property(_indicator, "size", rect.size, 0.16).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	else:
		_indicator.position = rect.position
		_indicator.size = rect.size

func _refresh_map(animate := false) -> void:
	if not is_node_ready(): return
	var entry: Dictionary = _entries[_index] if _index >= 0 else {}
	var seed_text := str(entry.get("seed", ""))
	var tex: Texture2D = entry.get("texture") if _mode == 0 else null
	if _mode > 0 and _derived.has(seed_text):
		_touch_maps(seed_text)
		var images: Array = _derived[seed_text]
		if images.size() == 2: tex = images[_mode - 1]
	if not type_available(): tex = null
	_set_map_texture(tex, animate)
	var empty := _index < 0
	_mode_panel.visible = false
	_pattern.anchor_right = 0.0
	_pattern.offset_right = 130.0
	_placeholder.anchor_right = 0.0
	_placeholder.offset_left = 4.0
	_placeholder.offset_right = 126.0
	var working := _thread != null and _loading_seed == seed_text and _job_kind == "preview" and not _cancel_flag.is_cancelled()
	_pattern.visible = tex == null
	_preview_note.visible = tex != null and (_generated.get(seed_text) == tex or (_mode > 0 and _provisional_derived.has(seed_text)))
	_placeholder.visible = tex == null
	_quick_seed.visible = false
	_create_first.visible = false
	_build_preview.visible = false
	_build_preview.disabled = _thread != null
	_build_preview.tooltip_text = "География без дорог и 3D; построение может занять некоторое время."
	if not type_available():
		_hint.text = "Скоро"
	elif empty:
		_hint.text = "Карта появится после создания мира"
	elif working:
		_hint.text = "Создаём карту…"
	elif _preview_errors.has(seed_text):
		_hint.text = "Не получилось. Попробуйте ещё раз."
	elif entry.get("map_ready", false) and _mode > 0:
		_hint.text = "Подготовка карты…" if not _derived.has(seed_text) else "Данные карты недоступны"
	else:
		_hint.text = "Карта пока недоступна"
	if type_available() and _mode > 0 and tex == null and not seed_text.is_empty() and entry.get("map_ready", false) and not _derived.has(seed_text) and _thread == null:
		_start_job(seed_text, "cached")
	map_changed.emit()

func _set_map_texture(texture: Texture2D, animate: bool) -> void:
	if _map.texture == texture: return
	if _map_tween != null and _map_tween.is_valid(): _map_tween.kill()
	_old_map.texture = _map.texture
	_old_map.visible = animate and _old_map.texture != null
	_old_map.modulate.a = 1.0
	_map.texture = texture
	_map.modulate.a = 0.0 if animate and texture != null else 1.0
	if not animate or (DisplayServer.get_name() == "headless" and not force_animate_in_headless):
		_old_map.visible = false
		_map.modulate.a = 1.0
		return
	_map_tween = create_tween().set_parallel(true).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_map_tween.tween_property(_old_map, "modulate:a", 0.0, 0.16)
	_map_tween.tween_property(_map, "modulate:a", 1.0, 0.16)
	_map_tween.chain().tween_callback(func() -> void:
		_old_map.visible = false
		_old_map.texture = null
		_map_tween = null)

func _create_world() -> void:
	create_requested.emit(_quick_seed.text.strip_edges())

func focus_quick_seed() -> void:
	_quick_seed.grab_focus()

func _request_preview() -> void:
	if _index < 0 or _thread != null: return
	var seed_text := str(_entries[_index].seed)
	_preview_errors.erase(seed_text)
	_start_job(seed_text, "preview")
	_refresh_map()

func _start_job(seed_text: String, kind: String) -> void:
	_loading_seed = seed_text
	_job_kind = kind
	_cancel_flag = PreviewCancel.new()
	_thread = Thread.new()
	var tid := WorldTemplate.normalize_id(selected_type_id())
	var job := MapPreview.generate_geography.bind(seed_text, _cancel_flag.is_cancelled, tid) if kind == "preview" else MapPreview.build.bind(seed_text, tid)
	if _thread.start(job) != OK:
		_thread = null
		_preview_errors[seed_text] = true
	else:
		set_process(true)

func cancel_preview() -> void:
	if _thread != null and _job_kind == "preview" and _cancel_flag != null: _cancel_flag.cancel()

func _process(_delta: float) -> void:
	if _thread != null and not _thread.is_alive():
		var result: Array = _thread.wait_to_finish()
		_thread = null
		set_process(false)
		var cancelled := _cancel_flag.is_cancelled()
		if not cancelled:
			var textures: Array = []
			for img: Image in result: textures.append(ImageTexture.create_from_image(img))
			if _job_kind == "preview" and textures.size() == 3:
				_generated[_loading_seed] = textures[0]
				_provisional_derived[_loading_seed] = true
				set_preview(_loading_seed, textures[0])
				_remember_maps(_loading_seed, [textures[1], textures[2]])
				preview_ready.emit(_loading_seed, textures[0])
			elif _job_kind == "cached":
				_provisional_derived.erase(_loading_seed)
				_remember_maps(_loading_seed, textures)
			elif _job_kind == "preview":
				_preview_errors[_loading_seed] = true
		_refresh_map(true)

func _exit_tree() -> void:
	cancel_preview()
	if _thread != null:
		_thread.wait_to_finish()
		_thread = null

func _set_zoom(value: float) -> void:
	if _zoom != null and _zoom.is_valid(): _zoom.kill()
	_map.pivot_offset = _map.size * 0.5
	_zoom = create_tween()
	_zoom.tween_property(_map, "scale", Vector2.ONE * value, 0.12)

func _hover_link(button: Button, active: bool) -> void:
	var tween: Tween = button.get_meta("menu_hover", null)
	if tween != null and tween.is_valid(): tween.kill()
	tween = create_tween().set_parallel(true)
	button.set_meta("menu_hover", tween)
	for state: String in ["normal", "hover", "pressed", "hover_pressed"]:
		var key := "menu_style_" + state
		if not button.has_meta(key):
			var style := button.get_theme_stylebox(state).duplicate() as StyleBox
			button.add_theme_stylebox_override(state, style)
			button.set_meta(key, style)
			button.set_meta(key + "_margin", style.content_margin_left)
		var style: StyleBox = button.get_meta(key)
		var margin: float = button.get_meta(key + "_margin")
		tween.tween_property(style, "content_margin_left", margin + (4.0 if active else 0.0), 0.075)

func _gui_input(_event: InputEvent) -> void:
	pass

func _scroll(event: InputEvent) -> bool:
	if event is InputEventMouseButton and event.pressed and event.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN]:
		move(-1 if event.button_index == MOUSE_BUTTON_WHEEL_UP else 1)
		return true
	return false

func _card_input(_event: InputEvent) -> void:
	pass
