extends PanelContainer
## Табличка обелиска (ObeliskLore): название и описание. Открывается у таблички (E «Прочитать»), закрывается E, Esc или кнопкой.
## Оформление — как у дорожной доски и «Путешествия»; хранит только показанный текст.

signal closed

const HudStyle = preload("res://scripts/ui/hud_style.gd")
const WIDTH := 560.0

var _box: VBoxContainer
var _close: Button


func _ready() -> void:
	set_anchors_preset(Control.PRESET_CENTER)
	grow_horizontal = Control.GROW_DIRECTION_BOTH
	grow_vertical = Control.GROW_DIRECTION_BOTH
	custom_minimum_size = Vector2(WIDTH, 0)
	var frame := StyleBoxFlat.new()
	frame.bg_color = Color("#2a2a24")
	frame.border_color = Color("#a08a5c")
	frame.set_border_width_all(2)
	frame.set_corner_radius_all(6)
	frame.set_content_margin_all(22)
	add_theme_stylebox_override("panel", frame)
	_box = VBoxContainer.new()
	_box.add_theme_constant_override("separation", 12)
	add_child(_box)
	hide()


## title — название обелиска, text — описание, hint — подпись под текстом (например, что делать дальше)
func open(title: String, text: String, hint := "") -> void:
	clear()
	_label(title, 26, Color("#f5ead2"), 0.0)
	var line := ColorRect.new()
	line.custom_minimum_size = Vector2(0, 2)
	line.color = Color("#a08a5c")
	_box.add_child(line)
	_label(text, 17, Color("#e8dfc8"), WIDTH - 44.0)
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
