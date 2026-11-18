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
