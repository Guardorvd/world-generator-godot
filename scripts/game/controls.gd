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


## 30.10: руль велосипеда с клавиатуры — частичная команда. Клавиша даёт сразу долю хода (TAP), а полный — только
## если её держат RAMP секунд: короткое нажатие — подправить линию, удержание — дуга до предела сцепления.
## Шагом и медленно (до 4 м/с) мягко, на скорости (от 12 м/с) быстро: там полный руль — уже предел шин, а не
## резкий поворот. Стик геймпада и автопилот (не ±1/0) идут как есть. Возврат к середине — в BikeRide (STEER_CENTER).
const KEY_STEER_TAP := Vector2(0.3, 0.5)    # медленно, быстро
const KEY_STEER_RAMP := Vector2(0.55, 0.2)  # с от первого касания до полного хода
var _key_steer := 0.0

func bike_steer(raw: float, dt: float, pace := 0.0) -> float:
	var digital := is_zero_approx(raw) or is_equal_approx(absf(raw), 1.0)
	if joypad or not digital:
		_key_steer = raw
		return raw
	var fast := smoothstep(4.0, 12.0, absf(pace))
	if is_zero_approx(raw):
		_key_steer = 0.0
	elif signf(raw) != signf(_key_steer) or is_zero_approx(_key_steer):
		_key_steer = raw * lerpf(KEY_STEER_TAP.x, KEY_STEER_TAP.y, fast)
	else:
		_key_steer = move_toward(_key_steer, raw, dt / lerpf(KEY_STEER_RAMP.x, KEY_STEER_RAMP.y, fast))
	return _key_steer


## Один ввод тела в игре и лаборатории; заблокированное управление всегда снимает прошлое удержание.
func read_bike_body(bike: BikeRide, enabled := true) -> void:
	bike.body_back = enabled and bike.riding and Input.is_action_pressed("bike_back")
	bike.body_forward = enabled and bike.riding and Input.is_action_pressed("bike_forward")
