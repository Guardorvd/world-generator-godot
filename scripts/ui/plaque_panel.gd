extends PanelContainer
## Табличка обелиска (ObeliskLore): вид памятника, статус в альбоме, текст и компактная кнопка закрытия.
## Открывается у таблички (E «Прочитать»), закрывается E, Esc или кнопкой. Оформление — HudStyle.

signal closed
signal photo_requested # 20.11: «Сфотографировать» — закрыть табличку и сразу достать фотоаппарат

const HudStyle = preload("res://scripts/ui/hud_style.gd")
const UiIcons = preload("res://scripts/ui/ui_icons.gd")
const WIDTH := 580.0
const FORM_NAMES := [
	"Каменный обелиск",
	"Расколотый обелиск",
	"Старая статуя",
	"Обломки колонны",
	"Памятная стела",
]

var _box: VBoxContainer
var _close: Button
var can_photo := false # 20.11: в подвале есть «Сфотографировать» (табличка ещё не в альбоме)


func _ready() -> void:
	# keep_offsets: без него смещения пересчитывались под прежнее место, и табличка висела в левом верхнем углу
	set_anchors_preset(Control.PRESET_CENTER, true)
	grow_horizontal = Control.GROW_DIRECTION_BOTH
	grow_vertical = Control.GROW_DIRECTION_BOTH
	custom_minimum_size = Vector2(WIDTH, 0)
	theme = HudStyle.theme()
	add_theme_stylebox_override("panel", HudStyle.sheet(Vector2(22, 20)))
	_box = VBoxContainer.new()
	_box.add_theme_constant_override("separation", 14)
	add_child(_box)
	hide()


## title — название обелиска, text — описание, hint — подпись под текстом,
## meta — необязательные сведения: {form, in_album, series: Vector2i, key_hint, photo_key}; photo_key — подпись клавиши
## фотоаппарата: если табличка ещё не в альбоме, в подвале есть кнопка «Сфотографировать»
func open(title: String, text: String, hint := "", meta := {}) -> void:
	var was_open := visible
	clear()
	var form := clampi(int(meta.get("form", 0)), 0, FORM_NAMES.size() - 1)
	var series: Vector2i = meta.get("series", Vector2i.ZERO)
	var in_album := bool(meta.get("in_album", false))

	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 12)
	_box.add_child(head)

	var icon_badge := PanelContainer.new()
	icon_badge.custom_minimum_size = Vector2(44, 44)
	icon_badge.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	icon_badge.add_theme_stylebox_override("panel", HudStyle.panel(HudStyle.RECESS, HudStyle.BORDER, 8, Vector2(10, 10), false))
	icon_badge.add_child(UiIcons.rect(UiIcons.obelisk(form), 24, HudStyle.MINT))
	head.add_child(icon_badge)

	var titles := VBoxContainer.new()
	titles.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	titles.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	titles.add_theme_constant_override("separation", 2)
	head.add_child(titles)
	var sub_text: String = FORM_NAMES[form]
	if series.y > 0:
		sub_text += " · %d из %d в летописи" % [series.x, series.y]
	_label(sub_text, 12, HudStyle.MUTED, 0.0, titles)
	var title_lbl := _label(title, 23, HudStyle.CREAM, 0.0, titles)
	title_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART

	var status_color := HudStyle.MINT if in_album else HudStyle.AMBER
	var status_box := PanelContainer.new()
	status_box.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	status_box.add_theme_stylebox_override("panel", HudStyle.panel(HudStyle.RECESS, Color(status_color, 0.6), 8, Vector2(9, 5), false))
	head.add_child(status_box)
	var status_row := HBoxContainer.new()
	status_row.add_theme_constant_override("separation", 6)
	status_box.add_child(status_row)
	status_row.add_child(UiIcons.rect(UiIcons.QUESTS.photo, 14, status_color))
	_label("В альбоме" if in_album else "Снимите вблизи", 12, status_color, 0.0, status_row)

	var body_card := PanelContainer.new()
	body_card.add_theme_stylebox_override("panel", HudStyle.panel(HudStyle.RECESS, HudStyle.BORDER, 8, Vector2(16, 14), false))
	_box.add_child(body_card)
	_label(text, 17, HudStyle.CREAM, WIDTH - 76.0, body_card)

	can_photo = not in_album and meta.has("photo_key")
	# с кнопкой «Сфотографировать» подвал тесен: подпись встаёт отдельной строкой над кнопками
	if can_photo and hint != "":
		var above := _label(hint, 13, HudStyle.MINT, WIDTH - 44.0)
		above.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		hint = ""
	var footer := HBoxContainer.new()
	footer.add_theme_constant_override("separation", 10)
	_box.add_child(footer)
	if hint != "":
		var hlbl := _label(hint, 13, HudStyle.MINT, 0.0, footer)
		hlbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		hlbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		hlbl.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	else:
		var spacer := Control.new()
		spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		footer.add_child(spacer)

	var key_hint := str(meta.get("key_hint", "E / Esc"))
	if not key_hint.is_empty():
		footer.add_child(HudStyle.chip(key_hint))
	if can_photo:
		var shoot := Button.new()
		shoot.text = "Сфотографировать · %s" % str(meta.photo_key)
		shoot.icon = UiIcons.QUESTS.photo
		shoot.tooltip_text = str(meta.photo_key)
		shoot.custom_minimum_size = Vector2(0, 44)
		shoot.pressed.connect(func() -> void: photo_requested.emit())
		footer.add_child(shoot)
	_close = Button.new()
	_close.text = "Закрыть"
	_close.custom_minimum_size = Vector2(140, 44)
	_close.size_flags_horizontal = Control.SIZE_SHRINK_END
	_close.pressed.connect(func() -> void: closed.emit())
	footer.add_child(_close)

	show()
	if not was_open:
		HudStyle.pop_in(self)
	_close.grab_focus()


func clear() -> void:
	for child: Node in _box.get_children():
		_box.remove_child(child)
		child.queue_free()
	hide()


func _label(text: String, size: int, color: Color, wrap: float, parent: Container = null) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", size)
	label.add_theme_color_override("font_color", color)
	if wrap > 0.0:
		label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		label.custom_minimum_size.x = wrap
	(parent if parent != null else _box).add_child(label)
	return label
