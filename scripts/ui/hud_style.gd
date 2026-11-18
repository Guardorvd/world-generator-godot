extends RefCounted
## Цвета и примитивы игрового HUD. Плашки держат контраст на светлом рельефе.

const SURFACE := Color("#192c29")
const RECESS := Color("#263d37")
const BORDER := Color("#58766c")
const CREAM := Color("#f5f1e5")
const MUTED := Color("#bed0c8")
const MINT := Color("#ace5cd")
const AMBER := Color("#ffd18c")
const RED := Color("#ff9784")
## 18.11.2026: бумага карт (мини-карта, доска) — единственный светлый тон HUD; рамки и экраны — те же SURFACE/BORDER
const PAPER := Color("#e9e2cf")

static var _theme: Theme


## Тема экранов поверх игры («Путешествие», доска поселения, табличка): кнопки, вкладки, прокрутка и подписи
## в палитре HUD вместо сланцевых кнопок меню (resources/ui_theme.tres). Одна на всех, создаётся при первом вызове
static func theme() -> Theme:
	if _theme != null:
		return _theme
	_theme = Theme.new()
	var pad := Vector2(16, 8)
	var normal := panel(RECESS, BORDER, 8, pad, false)
	var hover := panel(RECESS.lerp(MINT, 0.1), Color(MINT, 0.7), 8, pad, false)
	var pressed := panel(SURFACE.lerp(MINT, 0.24), MINT, 8, pad, false)
	var disabled := panel(Color(RECESS, 0.45), Color(BORDER, 0.4), 8, pad, false)
	var focus := panel(Color.TRANSPARENT, AMBER, 10, pad, false)
	focus.draw_center = false
	focus.set_border_width_all(2)
	focus.set_expand_margin_all(2)
	_button_type(&"Button", normal, hover, pressed, disabled, focus, CREAM, MINT)
	var danger_bg := SURFACE.lerp(RED, 0.32)
	_button_type(&"DangerButton", panel(danger_bg, RED, 8, pad, false), panel(danger_bg.lerp(RED, 0.18), RED, 8, pad, false),
		panel(danger_bg.lerp(RED, 0.3), CREAM, 8, pad, false), panel(Color(danger_bg, 0.45), Color(RED, 0.4), 8, pad, false), focus, CREAM, CREAM)
	_theme.set_type_variation(&"DangerButton", &"Button")
	var seg_pad := Vector2(14, 6)
	var seg_normal := panel(Color.TRANSPARENT, Color.TRANSPARENT, 7, seg_pad, false)
	var seg_hover := panel(Color(MINT, 0.1), Color(MINT, 0.35), 7, seg_pad, false)
	var seg_pressed := panel(SURFACE.lerp(MINT, 0.28), MINT, 7, seg_pad, false)
	var seg_disabled := panel(Color.TRANSPARENT, Color.TRANSPARENT, 7, seg_pad, false)
	_button_type(&"SegmentButton", seg_normal, seg_hover, seg_pressed, seg_disabled, focus, MUTED, MINT)
	_theme.set_type_variation(&"SegmentButton", &"Button")
	var pill_pad := Vector2(12, 5)
	_button_type(&"PillButton", panel(RECESS, BORDER, 16, pill_pad, false), panel(RECESS.lerp(MINT, 0.12), Color(MINT, 0.65), 16, pill_pad, false),
		panel(SURFACE.lerp(MINT, 0.25), MINT, 16, pill_pad, false), panel(Color(RECESS, 0.45), Color(BORDER, 0.4), 16, pill_pad, false), focus, CREAM, MINT)
	_theme.set_type_variation(&"PillButton", &"Button")
	var card_pad := Vector2(6, 6)
	_button_type(&"CardButton", panel(RECESS, MINT, 8, card_pad, false), panel(RECESS.lerp(MINT, 0.12), MINT.lerp(CREAM, 0.25), 8, card_pad, false),
		panel(SURFACE.lerp(MINT, 0.22), CREAM, 8, card_pad, false), disabled, focus, CREAM, CREAM)
	_theme.set_type_variation(&"CardButton", &"Button")
	_theme.set_constant("icon_max_width", &"Button", 18)
	_theme.set_constant("h_separation", &"Button", 7)
	_theme.set_constant("icon_max_width", &"SegmentButton", 16)
	_theme.set_constant("h_separation", &"SegmentButton", 6)
	_theme.set_constant("icon_max_width", &"PillButton", 14)
	_theme.set_constant("h_separation", &"PillButton", 5)
	_theme.set_color("font_color", "Label", CREAM)
	for bar: StringName in [&"VScrollBar", &"HScrollBar"]:
		_theme.set_stylebox("scroll", bar, panel(Color(RECESS, 0.6), Color(RECESS, 0.6), 4, Vector2(3, 3), false))
		_theme.set_stylebox("grabber", bar, panel(BORDER, BORDER, 4, Vector2(3, 3), false))
		_theme.set_stylebox("grabber_highlight", bar, panel(MUTED, MUTED, 4, Vector2(3, 3), false))
		_theme.set_stylebox("grabber_pressed", bar, panel(MINT, MINT, 4, Vector2(3, 3), false))
	_theme.set_stylebox("panel", "TooltipPanel", panel(SURFACE, BORDER, 6, Vector2(10, 6), false))
	_theme.set_color("font_color", "TooltipLabel", CREAM)
	return _theme


static func _button_type(type: StringName, normal: StyleBox, hover: StyleBox, pressed: StyleBox, disabled: StyleBox,
		focus: StyleBox, text: Color, on: Color) -> void:
	_theme.set_stylebox("normal", type, normal)
	_theme.set_stylebox("hover", type, hover)
	_theme.set_stylebox("pressed", type, pressed)
	_theme.set_stylebox("hover_pressed", type, pressed)
	_theme.set_stylebox("disabled", type, disabled)
	_theme.set_stylebox("focus", type, focus)
	for state: String in ["font_color", "font_focus_color", "font_hover_color", "icon_normal_color", "icon_focus_color", "icon_hover_color"]:
		_theme.set_color(state, type, text)
	for state: String in ["font_pressed_color", "font_hover_pressed_color", "icon_pressed_color", "icon_hover_pressed_color"]:
		_theme.set_color(state, type, on)
	_theme.set_color("font_disabled_color", type, Color(text, 0.38))
	_theme.set_color("icon_disabled_color", type, Color(text, 0.38))


## Рамка экрана поверх игры: тот же хвойный фон, что у плашек HUD; сплошной — сквозь полупрозрачный проступали плашки
static func sheet(padding := Vector2(22, 18)) -> StyleBoxFlat:
	return panel(SURFACE, BORDER, 12, padding)


static func panel(background := SURFACE, border := BORDER, radius := 12, padding := Vector2(12, 8), shadow := true) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = background
	style.border_color = border
	style.set_corner_radius_all(radius)
	style.set_border_width_all(1)
	style.content_margin_left = padding.x
	style.content_margin_right = padding.x
	style.content_margin_top = padding.y
	style.content_margin_bottom = padding.y
	if shadow:
		style.shadow_color = Color(0.03, 0.07, 0.06, 0.24)
		style.shadow_size = 4
		style.shadow_offset = Vector2(0, 2)
	return style


static func label(target: Label, font_size: int, color := CREAM) -> void:
	target.add_theme_font_size_override("font_size", font_size)
	target.add_theme_color_override("font_color", color)
	target.mouse_filter = Control.MOUSE_FILTER_IGNORE


static func bar(value: float, height := 6.0, fill_color := MINT, bg_color := Color(SURFACE, 0.85)) -> ProgressBar:
	var progress := ProgressBar.new()
	progress.show_percentage = false
	progress.mouse_filter = Control.MOUSE_FILTER_IGNORE
	progress.min_value = 0.0
	progress.max_value = 1.0
	progress.value = clampf(value, 0.0, 1.0)
	progress.custom_minimum_size.y = height
	progress.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var radius := int(ceili(height * 0.5))
	var bg := StyleBoxFlat.new()
	bg.bg_color = bg_color
	bg.set_corner_radius_all(radius)
	var fill := StyleBoxFlat.new()
	fill.bg_color = fill_color
	fill.set_corner_radius_all(radius)
	progress.add_theme_stylebox_override("background", bg)
	progress.add_theme_stylebox_override("fill", fill)
	return progress


static func chip(text: String, text_color := MUTED, bg := RECESS, border := BORDER) -> PanelContainer:
	var box := PanelContainer.new()
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	box.add_theme_stylebox_override("panel", panel(bg, border, 6, Vector2(8, 3), false))
	var lbl := Label.new()
	lbl.text = text
	label(lbl, 12, text_color)
	box.add_child(lbl)
	return box


static func centered(canvas: CanvasItem, at: Vector2, text: String, font_size: int, color: Color) -> void:
	var font := ThemeDB.fallback_font
	var width := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
	canvas.draw_string(font, at - Vector2(width * 0.5, 0), text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, color)


static func dial_face(canvas: CanvasItem, center: Vector2, radius: float, alpha: float) -> void:
	canvas.draw_circle(center + Vector2(0, 2), radius + 1.0, Color(0.04, 0.08, 0.07, 0.27 * alpha), true, -1, true)
	canvas.draw_circle(center, radius, Color(SURFACE, alpha), true, -1, true)
	canvas.draw_circle(center, radius, Color(BORDER, alpha), false, 1.0, true)


static func dial_text(canvas: CanvasItem, center: Vector2, value: float, caption: String, color: Color, alpha: float) -> void:
	centered(canvas, center + Vector2(0, 3), "%d%%" % roundi(value * 100.0), 17, Color(color, alpha))
	centered(canvas, center + Vector2(0, 18), caption, 9, Color(MUTED, alpha))
