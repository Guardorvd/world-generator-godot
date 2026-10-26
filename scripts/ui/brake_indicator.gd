extends Control
## Read-only presentation of the same state used by physics and animation.
var pressure := 0.0
var deceleration := 0.0
var risk := 0.0
var skid := 0.0
var _style := StyleBoxFlat.new()

func _ready() -> void:
	_style.bg_color = Color(0.045, 0.065, 0.07, 0.8)
	_style.set_corner_radius_all(6)

func update_state(bike: BikeRide, allowed: bool) -> void:
	pressure = bike.brakes.pressure
	deceleration = bike.brakes.deceleration
	risk = bike.brakes.risk
	skid = bike.brakes.skid
	visible = allowed and bike.riding and not bike.airborne and pressure > 0.02
	if visible: queue_redraw()

func _draw() -> void:
	var font := ThemeDB.fallback_font
	var color := Color("ffbe66") if risk > 0.65 else Color("b9d7d4")
	draw_style_box(_style, Rect2(Vector2.ZERO, size))
	var status := "Отпусти тормоз — риск перелёта" if risk > 0.65 else ("Торможение · предел сцепления" if skid > 0.2 else "Торможение")
	draw_string(font, Vector2(10, 20), status, HORIZONTAL_ALIGNMENT_LEFT, size.x - 20, 14, color)
	draw_string(font, Vector2(10, 39), "%d%% · %.1f м/с²" % [roundi(pressure * 100), deceleration], HORIZONTAL_ALIGNMENT_LEFT, size.x - 20, 13, Color.WHITE)
	draw_rect(Rect2(10, 48, size.x - 20, 4), Color(1, 1, 1, 0.12))
	draw_rect(Rect2(10, 48, (size.x - 20) * pressure, 4), color)
