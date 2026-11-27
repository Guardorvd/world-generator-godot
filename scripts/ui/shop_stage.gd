extends Control
## Спокойная графическая подложка под портрет игровой модели.

func _ready() -> void:
	mouse_filter = MOUSE_FILTER_IGNORE
	resized.connect(queue_redraw)

func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), Color("#354653"))
	var center := Vector2(size.x * 0.55, size.y * 0.48)
	var radius := size.y * 0.48
	draw_circle(center, radius, Color("#4a5f6a"), true, -1, true)
	draw_arc(center, radius * 1.07, 0, TAU, 96, Color(0.88, 0.9, 0.9, 0.19), 1.0, true)
	draw_line(Vector2(0, size.y * 0.87), Vector2(size.x, size.y * 0.87), Color(0.1, 0.14, 0.18, 0.3), 1.0)
