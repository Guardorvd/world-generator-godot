extends RefCounted
## Cartographic styles over the same north-up geometry, in world metres.

const Data = preload("res://scripts/ui/local_map_data.gd")
const INK := Color("#344d56")
const BLUE := Color("#2173e6")
const PARK_INK := Color("#433b2a")
const PARK_PAPER := Color("#f2e7cd")
const TRACE := Color("#765be1")


static func tiles(canvas: CanvasItem, data: Data, park: bool) -> void:
	var span := Vector2.ONE * Data.SPAN
	var tint := Color("#f3e5c5") if park else Color.WHITE
	for key: Vector2i in data.tiles:
		canvas.draw_texture_rect(data.tiles[key].texture, Rect2(Vector2(key) * span, span), false, tint)


const PAPER_STROKES := [
	[Color("#799999"), Color("#91afac"), 3.5, 2.3],
	[Color("#938259"), Color("#f3dfae"), 2.7, 1.5],
	[Color("#9d7850"), Color("#fff1ca"), 5.6, 3.8],
	[Color("#f6edd0"), Color("#536c48"), 3.5, 1.8],
]
const LOCAL_STROKES := [
	[Color("#85bfdc"), Data.WATER, 3.5, 2.3],
	[Color("#b5a582"), Color("#fbf4e6"), 2.7, 1.5],
	[Color("#bcaa8f"), Color("#fffdf7"), 5.6, 3.8],
	[Color("#f2fbf3"), Color("#458775"), 3.5, 1.8],
]


static func stroke_scale(screen_scale: float) -> float:
	return clampf(sqrt(screen_scale / 0.58), 0.34, 1.0) / screen_scale


static func lines(canvas: CanvasItem, data: Data, screen_scale: float, park: bool) -> void:
	var styles := PAPER_STROKES if park else LOCAL_STROKES
	var width := stroke_scale(screen_scale)
	for kind in styles.size():
		var style: Array = styles[kind]
		_stroke(canvas, data.strokes[kind], style[0], style[1], style[2] * width, style[3] * width)


static func _stroke(canvas: CanvasItem, lines: PackedVector2Array, edge: Color, fill: Color, outer: float, inner: float) -> void:
	if not lines.is_empty():
		canvas.draw_multiline(lines, edge, outer, true)
		canvas.draw_multiline(lines, fill, inner, true)


static func player(canvas: CanvasItem, at: Vector2, heading: float) -> void:
	canvas.draw_circle(at, 18.0, Color(0.13, 0.45, 0.9, 0.14), true, -1.0, true)
	canvas.draw_set_transform(at, -heading)
	var tip := PackedVector2Array([Vector2(0, -12), Vector2(8, 8), Vector2(0, 4), Vector2(-8, 8)])
	canvas.draw_colored_polygon(tip, BLUE)
	tip.append(tip[0])
	canvas.draw_polyline(tip, Color.WHITE, 2.0, true)
	canvas.draw_set_transform(Vector2.ZERO)


static func text(canvas: CanvasItem, at: Vector2, caption: String, color: Color, font_size: int, font: Font = null) -> void:
	if font == null:
		font = ThemeDB.fallback_font
	at.x -= font.get_string_size(caption, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x * 0.5
	canvas.draw_string_outline(font, at, caption, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, 4, Color("#fff9e9"))
	canvas.draw_string(font, at, caption, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, color)
