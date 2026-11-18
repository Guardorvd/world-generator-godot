extends PanelContainer
## Табличка обелиска (ObeliskLore): название и описание. Открывается у таблички (E «Прочитать»), закрывается E, Esc или кнопкой.
## Оформление — как у дорожной доски и «Путешествия»; хранит только показанный текст.

signal closed

const HudStyle = preload("res://scripts/ui/hud_style.gd")
const WIDTH := 560.0

var _box: VBoxContainer
var _close: Button


func _ready() -> void:
	# keep_offsets: без него смещения пересчитывались под прежнее место, и табличка висела в левом верхнем углу
	set_anchors_preset(Control.PRESET_CENTER, true)
	grow_horizontal = Control.GROW_DIRECTION_BOTH
	grow_vertical = Control.GROW_DIRECTION_BOTH
	custom_minimum_size = Vector2(WIDTH, 0)
	theme = HudStyle.theme()
	add_theme_stylebox_override("panel", HudStyle.sheet(Vector2(22, 22)))
	_box = VBoxContainer.new()
	_box.add_theme_constant_override("separation", 12)
	add_child(_box)
	hide()


## title — название обелиска, text — описание, hint — подпись под текстом (например, что делать дальше)
func open(title: String, text: String, hint := "") -> void:
	clear()
	_label(title, 26, HudStyle.CREAM, 0.0)
	var line := ColorRect.new()
	line.custom_minimum_size = Vector2(0, 2)
	line.color = HudStyle.BORDER
	_box.add_child(line)
	_label(text, 17, HudStyle.CREAM, WIDTH - 44.0)
	if hint != "":
		_label(hint, 13, HudStyle.MINT, WIDTH - 44.0)
	_close = Button.new()
	_close.text = "Закрыть"
	_close.custom_minimum_size.y = 38
	_close.pressed.connect(func() -> void: closed.emit())
	_box.add_child(_close)
	show()
	_close.grab_focus()


func clear() -> void:
	for child: Node in _box.get_children():
		_box.remove_child(child)
		child.queue_free()
	hide()


func _label(text: String, size: int, color: Color, wrap: float) -> void:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", size)
	label.add_theme_color_override("font_color", color)
	if wrap > 0.0:
		label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		label.custom_minimum_size.x = wrap
	_box.add_child(label)
