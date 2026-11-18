extends Control
## Compact brake-pressure gauge; physics remains the source of truth.
const HudStyle = preload("res://scripts/ui/hud_style.gd")
const DIAMETER := 76.0
const R := 28.0
const FROM := deg_to_rad(135.0)
const SPAN := deg_to_rad(270.0)
const MIN_SPEED := 1.0
var pressure := 0.0
var risk := 0.0
var skid := 0.0
var _alpha := 0.0
var _t := 0.0
var _warning := HudStyle.panel(HudStyle.SURFACE, HudStyle.AMBER, 8, Vector2.ZERO)

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
		draw_arc(size * 0.5, R, FROM + SPAN * from, FROM + SPAN * to, 48, color, width, true)

func _draw() -> void:
	var a := _alpha
	var danger := risk > 0.65
	var slipping := skid > 0.2
	var color := HudStyle.AMBER if slipping else HudStyle.MINT
	if danger:
		color = HudStyle.RED
		color.a = a * (0.75 + 0.25 * sin(_t * 8.0))
	else:
		color.a = a
	var center := size * 0.5
	HudStyle.dial_face(self, center, DIAMETER * 0.5 - 2, a)
	_arc(0.0, 1.0, 4.0, Color(HudStyle.BORDER, 0.65 * a))
	_arc(0.0, pressure, 4.0, color)
	HudStyle.dial_text(self, center, pressure, "ТОРМОЗ", color, a)
	if danger or slipping:
		var caption := "Отпустите тормоз" if danger else "Потеря сцепления"
		draw_style_box(_warning, Rect2(center.x - 77.0, -32.0, 154.0, 24.0))
		HudStyle.centered(self, Vector2(center.x, -16.0), caption, 13, Color(color, a))
