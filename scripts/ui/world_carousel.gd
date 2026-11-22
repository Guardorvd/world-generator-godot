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

func setup(start_button: Button, actions: Array[Button], trail_lab: Button) -> void:
	set_process(false)
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
	var chain: Array[Control] = [_previous, _next, start_button]
	chain.append_array(actions)
	chain.append(trail_lab)
	for i in chain.size():
		chain[i].focus_neighbor_top = chain[i].get_path_to(chain[posmod(i - 1, chain.size())])
		chain[i].focus_neighbor_bottom = chain[i].get_path_to(chain[(i + 1) % chain.size()])
	for button in actions:
		button.mouse_entered.connect(_hover_link.bind(button, true))
		button.mouse_exited.connect(_hover_link.bind(button, false))
	_set_mode(0)

func set_entries(entries: Array[Dictionary], selected: String) -> void:
	_cancel_slide()
	_entries = entries
	for entry: Dictionary in _entries:
		if entry.get("texture") == null and _generated.has(entry.seed): entry.texture = _generated[entry.seed]
	_index = -1
	show_world(selected)

func show_world(seed_text: String, animate := false, direction := 0) -> void:
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

func select_type(id: String) -> void:
	for i in WORLD_TYPES.size():
		if str(WORLD_TYPES[i].id) == id:
			if _type_index != i:
				_type_index = i
				invalidate_preview()
				_apply_entry()
			return

func move_type(direction: int) -> void:
	if direction == 0: return
	_type_index = posmod(_type_index + signi(direction), WORLD_TYPES.size())
	invalidate_preview()
	_apply_entry()
	stepped.emit(signi(direction))
	type_changed.emit()

func move(direction: int) -> void:
	if _entries.size() < 2 or direction == 0: return
	var dir := signi(direction)
	_show_index(posmod(_index + dir, _entries.size()), true, dir)
	stepped.emit(dir)
	world_selected.emit(_entries[_index].seed)

func move_focused(direction: int) -> bool:
	var focus := get_viewport().gui_get_focus_owner()
	if focus == _previous or focus == _next:
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
	if available and _index >= 0 and WorldTemplate.is_expedition(selected_type_id()):
		var sz := WorldTemplate.plan_size(selected_type_id(), WGRandom.hash_string(str(entry.get("seed", ""))))
		var km := roundi(float(sz.y) * GameConfig.TILE / 1000.0)
		detail = ("Сохранение · долина ~%d км" % km) if entry.get("saved", false) else ("Долина ~%d км" % km)
	$Card/Slide/Frame/WorldInfo/Detail.text = detail
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
