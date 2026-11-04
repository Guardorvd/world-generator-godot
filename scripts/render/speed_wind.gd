extends Control
## Воздушные штрихи скорости: тонкие конусные линии летят от центра к краям,
## дорога и центр прицела остаются чистыми. Один вызов рисования на штрих.
const STREAKS := 14
const FADE_OUT := Color(0.84, 0.94, 1.0, 0.0)
var strength := 0.0
var clock := 0.0


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func update_effect(amount: float, dt: float) -> void:
	var was_visible := strength > 0.005
	strength = lerpf(strength, clampf(amount, 0.0, 1.0), Util.damp(4.0, dt))
	clock += dt * lerpf(0.3, 0.9, strength)
	if was_visible or strength > 0.005:
		queue_redraw()


func _draw() -> void:
	if strength <= 0.005:
		return
	var center := size * Vector2(0.5, 0.46)
	for i in STREAKS:
		var phase := fposmod(clock * (0.6 + fposmod(i * 0.37, 0.5)) + i * 0.618, 1.0)
		var side := -1.0 if i % 2 == 0 else 1.0
		var height := 0.1 + fposmod(i * 0.373, 0.8)
		var x := 0.5 + side * (0.33 + phase * 0.22)
		var end := Vector2(x, height + (height - 0.46) * phase * 0.24) * size
		var direction := (end - center).normalized()
		var length := size.x * lerpf(0.02, 0.07, strength) * (0.6 + fposmod(i * 0.43, 0.8))
		var opacity := sin(phase * PI) * strength * (0.10 + fposmod(i * 0.19, 0.10))
		# хвост прозрачный, голова светлая: штрих сужается к началу
		var head := Color(0.9, 0.97, 1.0, opacity)
		draw_polyline_colors(PackedVector2Array([end - direction * length, end]),
			PackedColorArray([FADE_OUT, head]), 1.2, true)
