extends Control
## Compact brake-pressure gauge; physics remains the source of truth.
const R := 26.0
const FROM := deg_to_rad(135.0)
const SPAN := deg_to_rad(270.0)
const MIN_SPEED := 1.0
var pressure := 0.0
var risk := 0.0
var skid := 0.0
var _alpha := 0.0
var _t := 0.0

func update_state(bike: BikeRide, allowed: bool) -> void:
	pressure = clampf(bike.brakes.pressure, 0.0, 1.0)
	risk = bike.brakes.risk
	skid = bike.brakes.skid
	var active := allowed and bike.riding and not bike.airborne and bike.speed > MIN_SPEED and pressure > 0.02
	var dt := get_process_delta_time()
	_t += dt
	# Context changes must hide immediately; releasing the brake fades naturally.
	if not allowed or not bike.riding or bike.airborne:
		_alpha = 0.0
	else:
		_alpha = move_toward(_alpha, 1.0 if active else 0.0, dt * (6.0 if active else 3.0))
	visible = _alpha > 0.01
	if visible: queue_redraw()

func _arc(from: float, to: float, width: float, color: Color) -> void:
	if to - from > 0.002:
		draw_arc(Vector2(38, 38), R, FROM + SPAN * from, FROM + SPAN * to, 48, color, width, true)

func _draw() -> void:
	var a := _alpha
	var danger := risk > 0.65
	var slipping := skid > 0.2
	var color := Color(1.0, 0.72, 0.3) if slipping else Color(0.92, 0.95, 0.9)
	if danger:
		color = Color(1.0, 0.35, 0.25)
		color.a = a * (0.75 + 0.25 * sin(_t * 8.0))
	else:
		color.a = a
	_arc(0.0, 1.0, 8.0, Color(0, 0, 0, 0.45 * a))
	_arc(0.0, 1.0, 5.0, Color(1, 1, 1, 0.15 * a))
	_arc(0.0, pressure, 5.0, color)
	# A small brake-disc symbol keeps the gauge distinct from stamina.
	var center := Vector2(38, 38)
	draw_arc(center, 9.0, 0.0, TAU, 32, Color(0, 0, 0, 0.55 * a), 4.0, true)
	draw_arc(center, 9.0, 0.0, TAU, 32, Color(color.r, color.g, color.b, 0.9 * a), 2.0, true)
	draw_line(center + Vector2(-5, 0), center + Vector2(5, 0), Color(color.r, color.g, color.b, a), 2.0, true)
	if danger or slipping:
		var label := "Отпусти тормоз" if danger else "Потеря сцепления"
		var font := ThemeDB.fallback_font
		var pos := Vector2(80, 43)
		draw_string_outline(font, pos, label, HORIZONTAL_ALIGNMENT_LEFT, -1, 15, 3, Color(0, 0, 0, 0.8 * a))
		draw_string(font, pos, label, HORIZONTAL_ALIGNMENT_LEFT, -1, 15, color)
