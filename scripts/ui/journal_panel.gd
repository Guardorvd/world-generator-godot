extends PanelContainer
## «Путешествие»: вкладка «Путь» (счётчики пройденного и открытого) и вкладка «Альбом» (страницы фотоохоты,
## заполняются сами при каждом снимке). Оформление — как у дорожной доски (settlement_panel.gd). Данные собирает
## Hud.journey_data(); панель только показывает их и не хранит ничего своего, кроме кэша маленьких картинок.

signal closed

const HudStyle = preload("res://scripts/ui/hud_style.gd")
const MUTED := HudStyle.MUTED
const CARD := Vector2(172, 150)
const THUMB := Vector2(160, 90)
const COLUMNS := 5

var _box: VBoxContainer
var _path_page: VBoxContainer
var _album_page: ScrollContainer
var _tab_path: Button
var _tab_album: Button
var _cache := {}   # путь снимка -> ImageTexture | null (файл не прочитан)
var _close: Button


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT, Control.PRESET_MODE_KEEP_SIZE)
	offset_left = 48
	offset_right = -48
	offset_top = 24
	offset_bottom = -24
	theme = HudStyle.theme()
	add_theme_stylebox_override("panel", HudStyle.sheet(Vector2.ZERO))
	var margin := MarginContainer.new()
	for edge in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + edge, 22 if edge in ["left", "right"] else 18)
	add_child(margin)
	_box = VBoxContainer.new()
	_box.add_theme_constant_override("separation", 12)
	margin.add_child(_box)
	hide()


func _label(text: String, size: int, parent: Container, color := Color.WHITE) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", size)
	if color != Color.WHITE:
		label.add_theme_color_override("font_color", color)
	parent.add_child(label)
	return label


func clear() -> void:
	for child: Node in _box.get_children():
		_box.remove_child(child)
		child.queue_free()
	_path_page = null
	_album_page = null
	_cache.clear()
	hide()


## data: {foot, bike, time, alt, photos, quests, places: [[название, открыто, всего]], pages: [{title, hint, group, shot: {path, date} или {}}],
## groups: [названия групп страниц]}
func open(data: Dictionary, album_tab := false) -> void:
	clear()
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 12)
	_box.add_child(head)
	var title := _label("Путешествие", 30, head, HudStyle.CREAM)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var group := ButtonGroup.new()
	_tab_path = _tab("Путь", group, head)
	_tab_album = _tab("Альбом", group, head)
	_tab_path.pressed.connect(func() -> void: _select(false))
	_tab_album.pressed.connect(func() -> void: _select(true))
	_close = Button.new()
	_close.text = "Закрыть"
	_close.custom_minimum_size.y = 38
	_close.pressed.connect(func() -> void: closed.emit())
	head.add_child(_close)
	_path_page = VBoxContainer.new()
	_path_page.add_theme_constant_override("separation", 8)
	_path_page.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_box.add_child(_path_page)
	_fill_path(data)
	_album_page = ScrollContainer.new()
	_album_page.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_album_page.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_album_page.follow_focus = true
	_box.add_child(_album_page)
	_fill_album(data)
	show()
	_select(album_tab)
	_close.grab_focus()


func _tab(text: String, group: ButtonGroup, parent: Container) -> Button:
	var button := Button.new()
	button.text = text
	button.toggle_mode = true
	button.button_group = group
	button.custom_minimum_size = Vector2(110, 38)
	parent.add_child(button)
	return button


func _select(album: bool) -> void:
	_tab_path.set_pressed_no_signal(not album)
	_tab_album.set_pressed_no_signal(album)
	_path_page.visible = not album
	_album_page.visible = album


## Две карточки рядом — счётчики пути и открытые места: экран заполнен по ширине, а не узкой колонкой слева
func _fill_path(data: Dictionary) -> void:
	var cards := HBoxContainer.new()
	cards.add_theme_constant_override("separation", 16)
	_path_page.add_child(cards)
	var left := _section(cards, "Пройдено")
	var right := _section(cards, "Открыто мест")
	var rows := GridContainer.new()
	rows.columns = 2
	rows.add_theme_constant_override("h_separation", 48)
	rows.add_theme_constant_override("v_separation", 8)
	left.add_child(rows)
	var seconds := int(data.get("time", 0.0))
	var lines: Array = [
		["Пешком", Util.distance_text(data.get("foot", 0.0))],
		["На велосипеде", Util.distance_text(data.get("bike", 0.0))],
		["Время в пути", "%d:%02d:%02d" % [seconds / 3600, seconds / 60 % 60, seconds % 60]],
		["Высшая точка", "%d м" % roundi(data.get("alt", 0.0))],
		["Выполнено заданий", str(data.get("quests", 0))],
		["Снимков сделано", str(data.get("photos", 0))],
	]
	for line: Array in lines:
		_label(line[0], 18, rows, MUTED)
		_label(line[1], 20, rows, HudStyle.CREAM)
	var places := GridContainer.new()
	places.columns = 2
	places.add_theme_constant_override("h_separation", 48)
	places.add_theme_constant_override("v_separation", 6)
	right.add_child(places)
	for entry: Array in data.get("places", []):
		_label(entry[0], 17, places, MUTED)
		_label("%d из %d" % [entry[1], entry[2]], 18, places, HudStyle.MINT if entry[1] > 0 else MUTED)


func _section(parent: Container, title: String) -> VBoxContainer:
	var card := PanelContainer.new()
	card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	card.add_theme_stylebox_override("panel", HudStyle.panel(HudStyle.RECESS, HudStyle.BORDER, 10, Vector2(20, 16), false))
	parent.add_child(card)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 10)
	card.add_child(box)
	_label(title, 22, box, HudStyle.MINT)
	return box


func _fill_album(data: Dictionary) -> void:
	var content := VBoxContainer.new()
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content.add_theme_constant_override("separation", 10)
	_album_page.add_child(content)
	var pages: Array = data.get("pages", [])
	var groups: Array = data.get("groups", [])
	for g in groups.size():
		var mine: Array = pages.filter(func(p: Dictionary) -> bool: return p.group == g)
		if mine.is_empty():
			continue
		var done := mine.filter(func(p: Dictionary) -> bool: return not p.shot.is_empty()).size()
		_label("%s · %d из %d" % [groups[g], done, mine.size()], 20, content, HudStyle.MINT)
		var grid := GridContainer.new()
		grid.columns = COLUMNS
		grid.add_theme_constant_override("h_separation", 10)
		grid.add_theme_constant_override("v_separation", 10)
		content.add_child(grid)
		for page: Dictionary in mine:
			grid.add_child(_card(page))


func _card(page: Dictionary) -> Control:
	var done: bool = not page.shot.is_empty()
	var card := PanelContainer.new()
	card.custom_minimum_size = CARD
	card.add_theme_stylebox_override("panel", HudStyle.panel(HudStyle.RECESS if done else HudStyle.SURFACE.lerp(HudStyle.RECESS, 0.4), HudStyle.MINT if done else HudStyle.BORDER, 8, Vector2(6, 6), false))
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 2)
	card.add_child(column)
	var texture := _thumbnail(page.shot.get("path", "")) if done else null
	if texture != null:
		var view := TextureRect.new()
		view.texture = texture
		view.custom_minimum_size = THUMB
		view.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		view.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
		column.add_child(view)
	else:
		# пустая страница — серый силуэт; снимок есть, а файла уже нет — тёплая заглушка
		var plate := ColorRect.new()
		plate.custom_minimum_size = THUMB
		plate.color = HudStyle.RECESS if not done else HudStyle.RECESS.lerp(HudStyle.AMBER, 0.18)
		column.add_child(plate)
		var mark := Label.new()
		mark.text = "?" if not done else "снимок удалён"
		mark.add_theme_font_size_override("font_size", 34 if not done else 13)
		mark.add_theme_color_override("font_color", Color(HudStyle.MUTED, 0.3 if not done else 0.75))
		mark.set_anchors_preset(Control.PRESET_FULL_RECT)
		mark.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		mark.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		plate.add_child(mark)
	_label(page.title, 14, column, HudStyle.CREAM if done else MUTED).clip_text = true
	if done and page.get("text", "") != "":
		# страница обелиска: текст таблички, снятой вблизи (полностью — во всплывающей подсказке)
		card.tooltip_text = page.text
		var text := _label(page.text, 10, column, MUTED)
		text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		text.custom_minimum_size.x = CARD.x - 20
		text.max_lines_visible = 4
		text.clip_text = true
	var note := _label(page.shot.get("date", "") if done else page.hint, 11, column, HudStyle.MINT if done else Color(HudStyle.MUTED, 0.6))
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	note.custom_minimum_size.x = CARD.x - 20
	return card


## Снимок целиком в игровом размере тяжёл: в карточке — уменьшенная копия, одна на путь
func _thumbnail(path: String) -> Texture2D:
	if path.is_empty():
		return null
	if _cache.has(path):
		return _cache[path]
	var texture: ImageTexture = null
	if FileAccess.file_exists(path):
		var image := Image.load_from_file(path)
		if image != null and not image.is_empty():
			var width := 320
			image.resize(width, maxi(1, roundi(float(width) * image.get_height() / image.get_width())), Image.INTERPOLATE_BILINEAR)
			texture = ImageTexture.create_from_image(image)
	_cache[path] = texture
	return texture
