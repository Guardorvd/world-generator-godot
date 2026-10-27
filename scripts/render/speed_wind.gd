extends Control
## Воздушные следы расходятся к краям, оставляя дорогу и центр прицела чистыми.
var strength := 0.0
var clock := 0.0


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func update_effect(amount: float, dt: float) -> void:
	var was_visible := strength > 0.005
	strength = lerpf(strength, clampf(amount, 0.0, 1.0), 1.0 - exp(-dt * 4.0))
	clock += dt * lerpf(0.35, 1.05, strength)
	if was_visible or strength > 0.005:
		queue_redraw()


func _draw() -> void:
	if strength <= 0.005:
		return
	var center := size * Vector2(0.5, 0.46)
	# Мягкое свечение по краям усиливает ощущение потока без перекрытия обзора.
	for side in 2:
		for band in 6:
			var width := size.x * 0.025
			var x := float(band) * width if side == 0 else size.x - (band + 1) * width
			var alpha := strength * 0.018 * (1.0 - float(band) / 6.0)
			draw_rect(Rect2(x, 0, width + 1.0, size.y), Color(0.63, 0.81, 0.88, alpha))
	for i in 28:
		var phase := fposmod(clock * (0.65 + fposmod(i * 0.37, 0.5)) + i * 0.618, 1.0)
		var side := -1.0 if i % 2 == 0 else 1.0
		var height := 0.08 + fposmod(i * 0.373, 0.84)
		var x := 0.5 + side * (0.31 + phase * 0.23)
		var end := Vector2(x, height + (height - 0.46) * phase * 0.24) * size
		var direction := (end - center).normalized()
		var length := size.x * lerpf(0.018, 0.065, strength) * (0.6 + fposmod(i * 0.43, 0.8))
		var opacity := sin(phase * PI) * strength * (0.12 + fposmod(i * 0.19, 0.14))
		var start := end - direction * length
		draw_line(start, end, Color(0.77, 0.91, 0.96, opacity * 0.22), 4.0, true)
		draw_line(start, end, Color(0.86, 0.95, 1.0, opacity), 1.1, true)
