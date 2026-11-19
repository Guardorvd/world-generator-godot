extends Control
## 18.11.2026: единый прибор движения в левом нижнем углу вместо двух отдельных кругов (дуга сил 14.2 и тормоз).
## В середине — скорость на велосипеде (км/ч) или запас сил пешком; слева — дуга сил, растёт снизу вверх;
## справа — дуга нажатия тормоза, появляется только при торможении. Поведение дуг перенесено без изменений:
## засечка Stamina.RECOVERED, белый шлейф траты, пульс ниже LOW, warning для затемнения краёв, ореол наката;
## тормоз: опасность (risk) и потеря сцепления (skid); подпись о них — BrakeAlert под прицелом (19.11.2026).
## Видимость задаёт Hud (сводка, срочность); прибор только считает свои альфы и рисует.

const HudStyle = preload("res://scripts/ui/hud_style.gd")
const UiIcons = preload("res://scripts/ui/ui_icons.gd")
const DIAMETER := 104.0
const R := 42.0
const WIDTH := 4.0
const LOW := 0.2
const GHOST_LAG := 1.5          # 1/с: шлейф догоняет заливку с запаздыванием — рывок Shift тает за доли секунды
const STAMINA_FROM := deg_to_rad(125.0)    # слева: снизу (125°) через 180° вверх (235°)
const STAMINA_SPAN := deg_to_rad(110.0)
const BRAKE_FROM := deg_to_rad(55.0)       # справа: снизу (55°) вверх (−55°)
const BRAKE_SPAN := deg_to_rad(-110.0)
const MIN_SPEED := 1.0          # м/с: ниже тормоз не показывается

# силы
var value := 1.0
var exhausted := false
var state := Stamina.State.IDLE
var warning := 0.0              # 0..1, сила предупреждения (виньетка, пульс)
var _stamina_alpha := 0.0
var _coast := 0.0
var _drain := 0.0
var _kick := 0.0
var _ghost := 1.0
# велосипед и тормоз
var riding := false
var speed := 0.0                # м/с
var pressure := 0.0
var risk := 0.0
var skid := 0.0
var brake_alpha := 0.0
var _ride_alpha := 0.0
var alert: BrakeAlert  # подпись об опасном торможении под прицелом (ставит Hud)
var _t := 0.0
var _drawn := false


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE


## Силы ниже LOW при трате — срочно: видно и без сводки
func stamina_urgent() -> bool:
	return state == Stamina.State.DRAIN and value < LOW


func brake_urgent() -> bool:
	return brake_alpha > 0.01 and (risk > 0.65 or skid > 0.2)


func set_stamina(v: float, tired: bool, st: Stamina.State, allowed: bool) -> void:
	var dt := get_process_delta_time()
	_t += dt
	var active := st == Stamina.State.DRAIN or st == Stamina.State.COAST or st == Stamina.State.REST or v < 0.999
	_stamina_alpha = move_toward(_stamina_alpha, 1.0 if allowed and active else 0.0, dt * (4.0 if allowed and active else 1.5))
	_ghost = v if v >= _ghost else lerpf(_ghost, v, Util.damp(GHOST_LAG, dt))
	var low := 1.0 - smoothstep(0.05, LOW, v) if v < LOW or tired else 0.0
	# предупреждение нарастает мягко при трате и гаснет быстро, как только силы пошли в плюс
	var warn_goal := low if st == Stamina.State.DRAIN and allowed else 0.0
	warning = move_toward(warning, warn_goal, dt * (1.5 if warn_goal > warning else 5.0))
	_coast = move_toward(_coast, 1.0 if st == Stamina.State.COAST and allowed else 0.0, dt * 4.0)
	var draining := st == Stamina.State.DRAIN and allowed
	if draining and state != Stamina.State.DRAIN:
		_kick = 1.0
	_kick = maxf(0.0, _kick - dt * 2.5)
	_drain = move_toward(_drain, 1.0 if draining else 0.0, dt * (6.0 if draining else 3.0))
	value = v
	exhausted = tired
	state = st
	_redraw()


func set_ride(bike: BikeRide, allowed: bool) -> void:
	var dt := get_process_delta_time()
	riding = bike.riding
	speed = bike.speed
	pressure = clampf(bike.brakes.pressure, 0.0, 1.0)
	risk = bike.brakes.risk
	skid = bike.brakes.skid
	var braking := allowed and riding and not bike.airborne and speed > MIN_SPEED and pressure > 0.02
	# смена обстановки (слез, полёт, карта) прячет тормоз сразу; отпущенный тормоз гаснет плавно
	if not allowed or not riding or bike.airborne:
		brake_alpha = 0.0
	else:
		brake_alpha = move_toward(brake_alpha, 1.0 if braking else 0.0, dt * (6.0 if braking else 3.0))
	_ride_alpha = move_toward(_ride_alpha, 1.0 if allowed and riding else 0.0, dt * 5.0)
	_redraw()


func _face_alpha() -> float:
	return maxf(_stamina_alpha, _ride_alpha)


func _redraw() -> void:
	var shown := _face_alpha() > 0.01
	if shown or _drawn:
		queue_redraw()
	_drawn = shown
	if alert != null:
		alert.sync()


func _arc(from: float, span: float, a: float, b: float, width: float, color: Color) -> void:
	if b - a < 0.002:
		return
	draw_arc(Vector2.ONE * DIAMETER * 0.5, R, from + span * a, from + span * b, 32, color, width, true)


func _draw() -> void:
	var a := _face_alpha()
	if a <= 0.01:
		return
	var c := Vector2.ONE * DIAMETER * 0.5
	HudStyle.dial_face(self, c, DIAMETER * 0.5 - 2.0, a)
	_draw_stamina(c, a)
	if brake_alpha > 0.01:
		_draw_brake(c, a * brake_alpha)
	if riding and _ride_alpha > 0.01:
		draw_texture_rect(UiIcons.SPEED, Rect2(c + Vector2(-7.0, -33.0), Vector2(14.0, 14.0)), false, Color(HudStyle.MUTED, 0.72 * a))
		HudStyle.centered(self, c + Vector2(0, 8), str(roundi(absf(speed) * 3.6)), 28, Color(HudStyle.CREAM, a))
		HudStyle.centered(self, c + Vector2(0, 24), "км/ч", 10, Color(HudStyle.MUTED, a))
	else:
		HudStyle.dial_text(self, c, value, "СИЛЫ", _stamina_color(a), a)


func _stamina_color(a: float) -> Color:
	var fill := HudStyle.MINT
	if exhausted:
		fill = HudStyle.RED
	elif value < LOW:
		fill = HudStyle.AMBER
	fill = fill.lerp(Color(0.6, 0.9, 1.0), _coast * 0.6)
	# расход — тёплый оттенок и мягкий пульс, в начале расхода — вспышка шире и ярче
	if not exhausted and value >= LOW:
		fill = fill.lerp(HudStyle.AMBER, _drain * 0.55)
	fill = fill.lerp(Color.WHITE, _kick * 0.5)
	var pulse := 0.5 + 0.5 * sin(_t * 7.0)
	var spend := 0.5 + 0.5 * sin(_t * 4.5)
	fill.a = a * lerpf(lerpf(0.95, 0.75 + 0.25 * spend, _drain), 0.55 + 0.4 * pulse, warning)
	return fill


func _draw_stamina(c: Vector2, a: float) -> void:
	_arc(STAMINA_FROM, STAMINA_SPAN, 0.0, 1.0, WIDTH, Color(HudStyle.BORDER, 0.65 * a))
	if _coast > 0.0:
		_arc(STAMINA_FROM, STAMINA_SPAN, 0.0, value, WIDTH + 5.0, Color(0.45, 0.85, 1.0, 0.20 * _coast * a))
	_arc(STAMINA_FROM, STAMINA_SPAN, value, _ghost, WIDTH, Color(HudStyle.CREAM, 0.55 * a))
	var pulse := 0.5 + 0.5 * sin(_t * 7.0)
	var spend := 0.5 + 0.5 * sin(_t * 4.5)
	_arc(STAMINA_FROM, STAMINA_SPAN, 0.0, value, WIDTH + warning * pulse * 1.5 + _drain * spend + _kick * 3.0, _stamina_color(a))
	# засечка цены рывка: поперёк дуги, светлая с тёмной обводкой
	var dir := Vector2.from_angle(STAMINA_FROM + STAMINA_SPAN * Stamina.RECOVERED)
	var mark := Color(HudStyle.CREAM, a if exhausted or value < Stamina.RECOVERED + 0.1 else 0.6 * a)
	draw_line(c + dir * (R - 4.0), c + dir * (R + 4.0), Color(HudStyle.SURFACE, a), 3.0)
	draw_line(c + dir * (R - 3.0), c + dir * (R + 3.0), mark, 1.5, true)


func _draw_brake(c: Vector2, a: float) -> void:
	var danger := risk > 0.65
	var slipping := skid > 0.2
	var color := HudStyle.RED if danger else (HudStyle.AMBER if slipping else HudStyle.MINT)
	color.a = a * (0.75 + 0.25 * sin(_t * 8.0) if danger else 1.0)
	_arc(BRAKE_FROM, BRAKE_SPAN, 0.0, 1.0, WIDTH, Color(HudStyle.BORDER, 0.65 * a))
	# дуга справа идёт против часовой: от 0 к 1 — снизу вверх
	draw_arc(c, R, BRAKE_FROM, BRAKE_FROM + BRAKE_SPAN * pressure, 32, color, WIDTH, true)
	# 19.11.2026: подпись «Отпустите тормоз» / «Потеря сцепления» — не здесь, а под прицелом (BrakeAlert):
	# на спуске взгляд в центре кадра, а не в левом нижнем углу


## 19.11.2026: предупреждение о торможении у центра экрана — короткая плашка под прицелом.
## Состояние берёт из прибора: перерисовывается только когда видна или только что погасла.
class BrakeAlert extends Control:
	const SIZE := Vector2(184.0, 26.0)
	var dial  # прибор движения (ride_dial.gd)
	var _box := HudStyle.panel(Color(HudStyle.SURFACE, 0.86), HudStyle.AMBER, 8, Vector2.ZERO)
	var _shown := false

	func _init() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func sync() -> void:
		var on: bool = dial.brake_urgent()
		if on or _shown:
			queue_redraw()
		_shown = on
		visible = on

	func _draw() -> void:
		if not dial.brake_urgent():
			return
		var danger: bool = dial.risk > 0.65
		var color := HudStyle.RED if danger else HudStyle.AMBER
		var a: float = dial.brake_alpha * (0.75 + 0.25 * sin(dial._t * 8.0) if danger else 1.0)
		var box := Rect2((size - SIZE) * 0.5, SIZE)
		_box.border_color = Color(color, 0.9)
		draw_style_box(_box, box)
		draw_texture_rect(UiIcons.ALERT, Rect2(Vector2(box.position.x + 9.0, box.get_center().y - 7.0), Vector2(14.0, 14.0)), false, Color(color, a))
		HudStyle.centered(self, box.get_center() + Vector2(9, 5), "Отпустите тормоз" if danger else "Потеря сцепления", 13, Color(color, a))
