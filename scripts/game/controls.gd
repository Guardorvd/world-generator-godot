class_name Controls
extends RefCounted
## 14.0: чем игрок управляет сейчас — клавиатурой с мышью или геймпадом — и как назвать кнопку в подсказке.
## Кнопки геймпада в InputMap (project.godot) позиционные, как в SDL: JOY_BUTTON_A — нижняя кнопка ромба,
## у Xbox и 8BitDo в режиме X-input это «A», у Nintendo и 8BitDo в режиме Switch — «B», у PlayStation — крестик.
## Поэтому раскладка одна, а подписи берутся по имени устройства (Input.get_joy_name).

enum Family { XBOX, NINTENDO, PLAYSTATION }

## Подписи кнопок геймпада по семействам: индекс — JoyButton
const BUTTONS := {
	Family.XBOX: ["A", "B", "X", "Y", "View", "Xbox", "Menu", "L3", "R3", "LB", "RB", "↑", "↓", "←", "→"],
	Family.NINTENDO: ["B", "A", "Y", "X", "−", "Home", "+", "L3", "R3", "L", "R", "↑", "↓", "←", "→"],
	Family.PLAYSTATION: ["Крестик", "Кружок", "Квадрат", "Треугольник", "Share", "PS", "Options", "L3", "R3", "L1", "R1", "↑", "↓", "←", "→"],
}
const TRIGGERS := {
	Family.XBOX: ["LT", "RT"],
	Family.NINTENDO: ["ZL", "ZR"],
	Family.PLAYSTATION: ["L2", "R2"],
}
const STICK_LOOK := 2.6 # радиан в секунду при стике обзора до упора (умножается на чувствительность)

var joypad := false  # последний ввод был с геймпада
var device := 0      # с какого геймпада


## Запомнить, откуда пришёл ввод (GameWorld._input). Дрожание стика у нуля не переключает подсказки.
func note(event: InputEvent) -> void:
	if event is InputEventJoypadButton:
		joypad = true
		device = event.device
	elif event is InputEventJoypadMotion:
		if absf(event.axis_value) > 0.5:
			joypad = true
			device = event.device
	elif event is InputEventKey or event is InputEventMouseButton:
		joypad = false
	elif event is InputEventMouseMotion and event.relative.length() > 2.0:
		joypad = false


func family() -> Family:
	var name := Input.get_joy_name(device).to_lower()
	for word in ["nintendo", "switch", "pro controller", "joy-con"]:
		if word in name:
			return Family.NINTENDO
	for word in ["playstation", "dualshock", "dualsense", "sony", "ps3", "ps4", "ps5"]:
		if word in name:
			return Family.PLAYSTATION
	return Family.XBOX


func button(index: JoyButton) -> String:
	var names: Array = BUTTONS[family()]
	return names[index] if index < names.size() else str(index)


func trigger(right: bool) -> String:
	return TRIGGERS[family()][1 if right else 0]


## Подпись первой кнопки действия: клавиши — если играют с клавиатуры, кнопки — если с геймпада
func label(action: StringName) -> String:
	for event in InputMap.action_get_events(action):
		if joypad and event is InputEventJoypadButton:
			return button(event.button_index)
		if not joypad and event is InputEventMouseButton:
			return {MOUSE_BUTTON_LEFT: "ЛКМ", MOUSE_BUTTON_RIGHT: "ПКМ"}.get(event.button_index, "Мышь")
		if not joypad and event is InputEventKey:
			var code: Key = event.physical_keycode if event.physical_keycode != KEY_NONE else event.keycode
			return {KEY_SPACE: "Пробел", KEY_ESCAPE: "Esc"}.get(code, OS.get_keycode_string(code))
	return ""


## 14.1: отдача в руки — только на геймпаде, с которого играют. weak — лёгкий мотор, strong — тяжёлый, 0..1
func rumble(weak: float, strong: float, seconds: float) -> void:
	if joypad:
		Input.start_joy_vibration(device, clampf(weak, 0.0, 1.0), clampf(strong, 0.0, 1.0), seconds)


## Стик обзора: сдвиг взгляда за кадр в «пикселях мыши», чтобы чувствительность из настроек была общей.
## Квадратичный отклик: стик чуть отклонён — точное наведение, до упора — быстрый разворот
func look_delta(dt: float) -> Vector2:
	var v := Input.get_vector("look_left", "look_right", "look_up", "look_down")
	return v * v.length() * STICK_LOOK * dt / GameConfig.MOUSE


func reset() -> void:
	joypad = false
	device = 0
	reset_motion()


## Снять накопленный руль/тормоз при смене режима, сохранив устройство и его подсказки.
func reset_motion() -> void:
	_key_steer = 0.0
	_key_direction = 0.0
	_key_hold = 0.0
	_brake_hold = 0.0


## Окно или меню забрали управление: отпускание могло не дойти до игры.
func release_motion() -> void:
	for action: StringName in [&"move_forward", &"move_back", &"move_left", &"move_right", &"run", &"jump",
			&"bike_pump", &"bike_back", &"bike_forward", &"look_left", &"look_right", &"look_up", &"look_down"]:
		Input.action_release(action)
	reset_motion()


## Плавная команда с клавиатуры: короткое нажатие правит линию, удержание усиливает дугу.
## Смена направления проходит через нейтраль; отпускание быстрее набора, чтобы не мешать выходу.
## 31.10: дугу можно вести и частыми нажатиями: набранное удержание забывается за KEY_HOLD_FORGET, а не сразу,
## и повторное нажатие в ту же сторону продолжает дугу (раньше каждое начиналось заново с KEY_STEER_TAP и
## нажатия по 0,25 с держали руль не выше 0,44). Крупная дуга отпускается чуть мягче мелкой правки.
## 31.10: короткое нажатие сильнее и быстрее (было 0,22 и 18/с): на 13 м/с нажатие 0,1 с доворачивало на 2°.
## 12.11: форма команды перевёрнута. Нажатие — резкий доворот полным рулём (KEY_STEER_KICK): им объезжают
## препятствие и правят линию на любой скорости. Удержание после KEY_KICK_TIME мягко отпускает руль до
## KEY_STEER_HOLD — широкая устойчивая дуга (на малой скорости руль остаётся полным: серпантин, подъём).
## Если клавишу держат дольше KEY_PRESS_FROM, дуга плавно дожимается до полной к KEY_PRESS_FULL — долгий поворот
## срабатывает всегда. Раньше было наоборот: нажатие давало 0,45 руля, полный набирался за 0,55 с, и на 18 м/с
## короткое нажатие доворачивало на 3,7°.
const KEY_STEER_KICK := 1.0
const KEY_STEER_KICK_FAST := 0.8 # на большой скорости доворот чуть мягче: полный руль с полным тормозом ронял на 18 м/с
const KEY_KICK_PACE := Vector2(13.0, 20.0)
const KEY_KICK_TIME := 0.14   # с: столько держится резкий доворот
const KEY_KICK_FADE := 0.3    # с: за столько он переходит в дугу удержания
## 13.11: было 0,8 — на 18 м/с дуга через 0,6 с удержания проседала до 38 °/с при 46 в начале и в конце
## (резко, туго, снова резко в одном повороте); теперь провал вдвое меньше, дожим до полной остался.
const KEY_STEER_HOLD := 0.9   # руль широкой дуги на скорости
const KEY_HOLD_PACE := Vector2(4.0, 12.0) # м/с: ниже — удержание полным рулём, выше — KEY_STEER_HOLD
const KEY_STEER_CROSS := 0.3  # цель руля, пока он ещё на прежней стороне (перекладка)
const KEY_PRESS_FROM := 0.5   # с удержания: отсюда дуга дожимается
const KEY_PRESS_FULL := 1.2   # и здесь она полная
const KEY_STEER_RESPONSE := 26.0
const KEY_STEER_RELEASE := 14.0
const KEY_STEER_ARC_RELEASE := 6.0 # отпускание заложенной дуги (руль больше половины)
const KEY_HOLD_FORGET := 1.0 # секунд удержания забывается за секунду без нажатия
var _key_steer := 0.0
var _key_direction := 0.0
var _key_hold := 0.0
## 31.10: тормоз с клавиатуры ступенями — нажатие подтормаживает (BRAKE_TAP), удержание за BRAKE_RAMP доводит до
## полного. Раньше любое нажатие S было полным тормозом: 0,15 с снимали 3 м/с, подтормозить перед поворотом было нечем.
const BRAKE_TAP := 0.35
const BRAKE_RAMP := 0.45
var _brake_hold := 0.0

## Газ/тормоз велосипеда: газ проходит как есть, тормоз с клавиатуры набирается удержанием; аналоговый — как есть.
func bike_brake(raw: float, dt: float) -> float:
	if raw >= 0.0 or joypad or not is_equal_approx(raw, -1.0):
		_brake_hold = 0.0
		return raw
	_brake_hold += dt
	return -lerpf(BRAKE_TAP, 1.0, smoothstep(0.0, BRAKE_RAMP, _brake_hold))

func bike_steer(raw: float, dt: float, pace := 0.0) -> float:
	var digital := is_zero_approx(raw) or is_equal_approx(absf(raw), 1.0)
	if joypad or not digital:
		_key_steer = raw
		_key_direction = 0.0
		_key_hold = 0.0
		return raw
	if is_zero_approx(raw):
		_key_hold = maxf(0.0, _key_hold - dt * KEY_HOLD_FORGET)
	elif raw != _key_direction:
		_key_hold = 0.0
		_key_direction = raw
	else:
		_key_hold += dt
	var hold := lerpf(1.0, KEY_STEER_HOLD, smoothstep(KEY_HOLD_PACE.x, KEY_HOLD_PACE.y, absf(pace)))
	hold = lerpf(hold, 1.0, smoothstep(KEY_PRESS_FROM, KEY_PRESS_FULL, _key_hold))
	var kick := lerpf(KEY_STEER_KICK, KEY_STEER_KICK_FAST, smoothstep(KEY_KICK_PACE.x, KEY_KICK_PACE.y, absf(pace)))
	var strength := lerpf(maxf(kick, hold), hold, smoothstep(KEY_KICK_TIME, KEY_KICK_TIME + KEY_KICK_FADE, _key_hold))
	var target := raw * strength
	var reversing := raw * _key_steer < 0.0
	var rate := KEY_STEER_RESPONSE
	if reversing:
		rate = KEY_STEER_RELEASE
		target = raw * KEY_STEER_CROSS # через нейтраль без рывка; резкий доворот начинается уже на новой стороне
	elif is_zero_approx(raw):
		rate = lerpf(KEY_STEER_RELEASE, KEY_STEER_ARC_RELEASE, smoothstep(0.3, 0.8, absf(_key_steer)))
	_key_steer = lerpf(_key_steer, target, Util.damp(rate, dt))
	return _key_steer


## Один ввод тела в игре и лаборатории; заблокированное управление всегда снимает прошлое удержание.
func read_bike_body(bike: BikeRide, enabled := true) -> void:
	bike.pump_pressed = enabled and bike.riding and Input.is_action_pressed("bike_pump")
	bike.body_back = enabled and bike.riding and Input.is_action_pressed("bike_back")
	bike.body_forward = enabled and bike.riding and Input.is_action_pressed("bike_forward")
