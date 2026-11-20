extends Control
## Декоративные изолинии, не изображающие географию выбранного зерна.
func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), Color("#182c2d"))
	for line in range(-5, 18):
		var points := PackedVector2Array()
		for x in range(0, ceili(size.x) + 1, 8):
			var y := line * 25.0 + 14.0 * sin(float(x) * 0.018 + line * 0.38) + 8.0 * sin(float(x) * 0.041 - line * 0.24)
			if y >= 0.0 and y <= size.y:
				points.append(Vector2(x, y))
			elif points.size() > 1:
				draw_polyline(points, Color(0.65, 0.75, 0.65, 0.09), 1.0, true)
				points.clear()
		if points.size() > 1:
			draw_polyline(points, Color(0.65, 0.75, 0.65, 0.09), 1.0, true)
