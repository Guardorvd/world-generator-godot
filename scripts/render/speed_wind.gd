extends Control
## Лёгкие штрихи воздушного потока только в боковых полях; без шума, размытия и частиц.
var strength := 0.0
var clock := 0.0


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func update_effect(amount: float, dt: float) -> void:
	var was_visible := strength > 0.01
	strength = clampf(amount, 0.0, 1.0)
	clock += dt * lerpf(0.65, 1.15, strength)
	if was_visible or strength > 0.01:
		queue_redraw()


func _draw() -> void:
	if strength <= 0.01:
		return
	for i in 18:
		var phase := fposmod(clock + i * 0.618, 1.0)
		var side := -1.0 if i % 2 == 0 else 1.0
		var height := 0.18 + fposmod(i * 0.373, 0.68)
		var x := 0.5 + side * (0.31 + phase * 0.18)
		var end := Vector2(x, height + (height - 0.5) * phase * 0.15) * size
		var direction := (end - size * Vector2(0.5, 0.45)).normalized()
		var length := size.x * lerpf(0.02, 0.055, strength)
		var opacity := sin(phase * PI) * strength * 0.42
		draw_line(end - direction * length, end, Color(0.86, 0.94, 1.0, opacity), 1.8, true)
