extends RefCounted
## 19.11.2026: задание на доске поселения — листок объявления, приколотый кнопкой: бумага, штамп вида задания
## цветом вида (Quests.KINDS), заголовок тушью, строка «вид · далеко ли · шагов», короткий текст. Чуть наклонён
## (устойчиво по id задания), как вешают на доску. Один вид в панели доски (с кнопкой «Взять») и на щите в мире
## (BoardDisplay рисует щит в текстуру один раз).
##
## Листок — Control-держатель постоянного размера (контейнер раскладывает его как обычный элемент), внутри — сам лист,
## повёрнутый вокруг середины: контейнеры сбрасывают поворот своих детей, держатель — нет.

const Quests = preload("res://scripts/game/quests.gd")
const UiIcons = preload("res://scripts/ui/ui_icons.gd")
const HudStyle = preload("res://scripts/ui/hud_style.gd")

const INK := Color("#2c2a23")
const INK_SOFT := Color("#5d584a")
const PIN := Color("#b8402f")
const MAX_TILT := 1.8  # градусы

static var _sheet_styles := {}  # толщина края -> StyleBoxFlat бумаги (общие для всех листков)


## q — задание; size — размер листка, px; scale — множитель шрифтов и отступов (щит в мире — крупнее);
## take — нажатие «Взять» (пусто — без кнопки); stamp — надпись поверх (например «ВЗЯТО»), пусто — без неё;
## distance — до цели, м (меньше 0 — не писать)
static func build(q: QuestData, size: Vector2, scale := 1.0, take := Callable(), stamp := "", distance := -1.0) -> Control:
	var kind: Dictionary = Quests.KINDS.get(q.kind, Quests.KINDS.visit)
	var holder := Control.new()
	holder.custom_minimum_size = size
	holder.mouse_filter = Control.MOUSE_FILTER_PASS
	var sheet := PanelContainer.new()
	sheet.add_theme_stylebox_override("panel", _sheet(scale))
	sheet.position = Vector2.ZERO
	sheet.size = size
	sheet.pivot_offset = size * 0.5
	sheet.rotation_degrees = tilt(q.id)
	sheet.mouse_filter = Control.MOUSE_FILTER_PASS
	holder.add_child(sheet)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", roundi(4 * scale))
	sheet.add_child(box)

	# шапка: штамп вида (кружок цвета вида с пиктограммой тушью) и название вида
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", roundi(8 * scale))
	box.add_child(head)
	var seal := PanelContainer.new()
	var seal_style := StyleBoxFlat.new()
	seal_style.bg_color = kind.color
	seal_style.set_corner_radius_all(roundi(15 * scale))
	seal_style.set_content_margin_all(roundi(5 * scale))
	seal.add_theme_stylebox_override("panel", seal_style)
	seal.mouse_filter = Control.MOUSE_FILTER_IGNORE
	seal.add_child(UiIcons.rect(UiIcons.quest(q.kind), 18 * scale, INK))
	head.add_child(seal)
	var kind_label := _label(String(kind.title).to_upper(), 12 * scale, kind.color.darkened(0.55), head)
	kind_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	kind_label.size_flags_vertical = Control.SIZE_SHRINK_CENTER

	var title := _label(q.title, 17 * scale, INK, box)
	title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	title.max_lines_visible = 2
	title.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	var meta := PackedStringArray()
	if distance >= 0.0:
		meta.append(Util.distance_text(distance))
	meta.append("шагов: %d" % q.steps.size())
	_label(" · ".join(meta), 12 * scale, INK_SOFT, box)
	var rule := ColorRect.new()
	rule.color = Color(INK, 0.25)
	rule.custom_minimum_size.y = maxf(1.0, scale)
	rule.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(rule)
	var text := _label(q.text, 12.5 * scale, INK, box)
	text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	text.size_flags_vertical = Control.SIZE_EXPAND_FILL
	text.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	text.clip_text = true
	if take.is_valid():
		var button := Button.new()
		button.text = "Взять"
		button.custom_minimum_size = Vector2(0, 40)
		button.tooltip_text = "Взять задание: %s" % String(kind.title).to_lower()
		button.pressed.connect(take)
		box.add_child(button)

	# кнопка-булавка сверху посередине и, если нужно, штамп поверх
	var pin := Panel.new()
	var pin_style := StyleBoxFlat.new()
	pin_style.bg_color = PIN
	pin_style.set_corner_radius_all(roundi(7 * scale))
	pin_style.shadow_color = Color(0, 0, 0, 0.35)
	pin_style.shadow_size = roundi(2 * scale)
	pin_style.shadow_offset = Vector2(1, 2) * scale
	pin.add_theme_stylebox_override("panel", pin_style)
	pin.size = Vector2(14, 14) * scale
	pin.position = Vector2(size.x * 0.5 - 7 * scale, -4 * scale)
	pin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	holder.add_child(pin)
	pin.pivot_offset = size * 0.5 - pin.position
	pin.rotation = sheet.rotation
	if not stamp.is_empty():
		var mark := _label(stamp, 20 * scale, Color(PIN, 0.85), holder)
		mark.add_theme_constant_override("outline_size", 0)
		mark.position = Vector2(size.x * 0.28, size.y * 0.38)
		mark.rotation_degrees = -14.0
	return holder


## Наклон листка по id задания: устойчив между открытиями доски и одинаков в панели и на щите
static func tilt(id: String) -> float:
	return (float(hash(id) % 1000) / 999.0 * 2.0 - 1.0) * MAX_TILT


static func _sheet(scale: float) -> StyleBoxFlat:
	var key := snappedf(scale, 0.01)
	if _sheet_styles.has(key):
		return _sheet_styles[key]
	var style := StyleBoxFlat.new()
	style.bg_color = HudStyle.PAPER
	style.border_color = HudStyle.PAPER.darkened(0.18)
	style.set_border_width_all(1)
	style.set_corner_radius_all(roundi(2 * scale))
	style.content_margin_left = 12 * scale
	style.content_margin_right = 12 * scale
	style.content_margin_top = 14 * scale
	style.content_margin_bottom = 10 * scale
	style.shadow_color = Color(0, 0, 0, 0.28)
	style.shadow_size = roundi(4 * scale)
	style.shadow_offset = Vector2(2, 3) * scale
	_sheet_styles[key] = style
	return style


static func _label(text: String, font_size: float, color: Color, parent: Control) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", roundi(font_size))
	label.add_theme_color_override("font_color", color)
	label.add_theme_constant_override("outline_size", 0)
	label.add_theme_color_override("font_shadow_color", Color.TRANSPARENT)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(label)
	return label
