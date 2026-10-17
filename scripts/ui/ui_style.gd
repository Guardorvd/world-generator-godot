class_name UiStyle
extends RefCounted
## Общее оформление интерфейса: тёмные полупрозрачные панели и кнопки, как в style.css JS-версии.

const ACCENT := Color(0.85, 0.72, 0.42)


static func panel(bg: Color, radius: int = 12, pad: int = 24) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = bg
	s.set_corner_radius_all(radius)
	s.set_content_margin_all(pad)
	return s


static func make_theme() -> Theme:
	var t := Theme.new()
	t.default_font_size = 18
	t.set_stylebox("panel", "PanelContainer", panel(Color(0.05, 0.08, 0.13, 0.86), 14, 28))
	var normal := panel(Color(0.16, 0.2, 0.28, 0.95), 8, 10)
	var hover := panel(Color(0.24, 0.29, 0.38, 0.95), 8, 10)
	var pressed := panel(Color(0.12, 0.15, 0.21, 0.95), 8, 10)
	for st in ["normal", "hover", "pressed", "focus", "disabled"]:
		var box: StyleBoxFlat = {"normal": normal, "hover": hover, "pressed": pressed, "focus": hover, "disabled": pressed}[st]
		t.set_stylebox(st, "Button", box)
		t.set_stylebox(st, "OptionButton", box)
	t.set_stylebox("normal", "LineEdit", panel(Color(0.1, 0.13, 0.19, 1.0), 8, 10))
	t.set_stylebox("focus", "LineEdit", panel(Color(0.12, 0.16, 0.23, 1.0), 8, 10))
	t.set_color("font_color", "Label", Color(0.93, 0.93, 0.9))
	return t


## Главная кнопка экрана (золотистая)
static func primary(b: Button) -> void:
	var n := panel(Color(0.78, 0.62, 0.32, 1.0), 8, 12)
	var h := panel(Color(0.86, 0.7, 0.38, 1.0), 8, 12)
	b.add_theme_stylebox_override("normal", n)
	b.add_theme_stylebox_override("hover", h)
	b.add_theme_stylebox_override("focus", h)
	b.add_theme_stylebox_override("pressed", n)
	b.add_theme_color_override("font_color", Color(0.1, 0.08, 0.05))
	b.add_theme_color_override("font_hover_color", Color(0.1, 0.08, 0.05))
	b.add_theme_color_override("font_focus_color", Color(0.1, 0.08, 0.05))
	b.add_theme_color_override("font_pressed_color", Color(0.1, 0.08, 0.05))
