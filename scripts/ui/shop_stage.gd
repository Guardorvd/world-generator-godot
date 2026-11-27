extends Control
## Спокойная графическая подложка под портрет игровой модели.

func _ready() -> void:
	mouse_filter = MOUSE_FILTER_IGNORE
	resized.connect(queue_redraw)

func _draw() -> void:
	# Мягкий свет витрины не закрывает прозрачную сцену сплошным прямоугольником.
	var center := Vector2(size.x * 0.55, size.y * 0.48)
	var radius := minf(size.x * 0.48, size.y * 0.72)
	for i in range(12, 0, -1):
		var k := float(i) / 12.0
		draw_circle(center, radius * k, Color(0.55, 0.68, 0.69, 0.012), true, -1, true)
	draw_arc(center, radius * 0.90, -2.7, 0.35, 96, Color(0.87, 0.85, 0.75, 0.15), 1.0, true)
	draw_arc(center, radius * 1.02, 0.45, 2.7, 96, Color(0.87, 0.85, 0.75, 0.08), 1.0, true)
	draw_line(Vector2(size.x * 0.08, size.y * 0.87), Vector2(size.x * 0.92, size.y * 0.87), Color(0.81, 0.81, 0.72, 0.12), 1.0)
