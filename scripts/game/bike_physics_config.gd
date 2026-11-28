class_name BikePhysicsConfig
extends Resource
## Единая упрощённая конфигурация физики велосипеда и отзывчивого управления.
## Загружается через BikePhysicsConfig.current() из resources/bike_physics.tres.

const VERSION := "1.5"
const PATH := "res://resources/bike_physics.tres"

@export_group("Тяжесть и привод")
## Единое ускорение свободного падения (м/с²): уклоны, гребни, полёт и ragdoll.
@export var gravity := 12.0
## Крейсерская скорость по ровной дороге без Shift (м/с).
@export var cruise_speed := 11.5
## Множитель максимальной скорости при рывке на Shift.
@export var boost_mult := 1.30
## Базовая тяга педалей на ровном (м/с²).
@export var pedal_accel := 4.2
## Множитель стартового импульса педалей с места.
@export var start_push_mult := 1.55
## Степень ослабления тяги педалей к крейсерской скорости.
@export var pedal_taper := 0.85
## Скорость включения усилия педалей (1/с).
@export var effort_rise := 12.0
## Скорость спада усилия при отпускании газа (1/с).
@export var effort_fall := 10.0
## Компенсация тяги в крутой подъём (доля проекции тяжести): даёт стабильный заезд без откатов.
@export var climb_assist := 0.50
## Дополнительный импульс ускорения при рывке Shift (м/с²).
@export var surge_push := 2.4
## Сопротивление качению на плотной дороге (м/с²).
@export var roll_resistance := 0.24
## Квадратичное сопротивление воздуха (1/м).
@export var air_drag := 0.0068
## Максимальная скорость заднего хода (м/с).
@export var reverse_speed := 1.6
## Задержка на тормозе у остановки перед включением заднего хода (с).
@export var reverse_wait := 0.35
## Максимальный продольный уклон для включения заднего хода (м/м).
@export var reverse_max_grade := 0.15

@export_group("Тормоза и стоянка")
## Максимальное замедление тормозов на твёрдом покрытии (м/с²).
@export var brake_decel := 9.8
## Скорость набора и отпускания тормозного давления (1/с).
@export var brake_response := 16.0
## Предельный продольный уклон, на котором велосипед спокойно стоит без скатывания (м/м).
@export var stop_hold_grade := 0.40
## Время удержания остановки перед постановкой ноги на землю (с).
@export var stop_settle_time := 0.28
## Боковой отступ опорной стопы при стоянке (м).
@export var stop_foot_offset := 0.27
## Крутизна обрыва, при выезде на который начинается падение (м/м).
@export var cliff_grade := 1.20

@export_group("Руль и поворот")
## Максимальный угол поворота руля/переднего колеса (рад).
@export var max_steer_angle := 0.60
## Минимальный читаемый угол руля в модели при полной команде (рад).
@export var steer_visual_floor := 0.075
## Предельное боковое ускорение в повороте на плотном грунте (м/с²).
@export var max_lat_accel := 10.5
## Начальная доля угла руля при коротком нажатии клавиши.
@export var steer_tap := 0.30
## Начальная доля руля на скорости; переход между значениями указан в м/с.
@export_range(0.0, 1.0) var steer_fast_tap := 0.60
@export var steer_fast_speed := Vector2(6.0, 16.0)
## Время удержания клавиши до полного выворота руля (с).
@export var steer_ramp_time := 0.18
## Скорость поворота руля при нажатии (1/с).
@export var steer_response := 22.0
## Скорость возврата руля в ноль при отпускании (1/с).
@export var steer_release := 24.0
## Отзывчивость при смене направления нажатия (1/с).
@export var steer_reverse_response := 38.0
## Доля предельного бокового ускорения, доступная даже на крутом обратном вираже.
@export_range(0.0, 1.0) var bank_grip_floor := 0.55
## Скорость стабилизации бокового скольжения (1/с).
@export var drift_recover := 12.0
## Скорость, с которой удерживаемый руль вовлекает корпус (1/с).
@export var turn_pose_response := 6.0
## Начало и полное включение позы по накопленной команде руля (0..1).
@export var turn_pose_steer := Vector2(0.59, 0.92)
## Доля равновесного крена рамы в полном повороте.
@export var lean_share := 0.48
## Максимальный угол визуального/физического крена в повороте (рад).
@export var lean_max := 0.32
## Скорость переноса веса седока и следования рамы за ним (1/с).
@export var lean_response := 14.0

@export_group("Опора, подвеска и препятствия")
## Локальный ход над ступеньками и стыками сетки (м).
@export var micro_step_absorb := 0.09
## Вертикальный зазор до последнего колеса, который подвеска ещё закрывает (м).
@export var ground_reach := 0.20
## Скорость согласования тангажа рамы с опорой на земле и после касания (1/с).
@export var landing_settle_response := 8.0
## Доля скорости удара, переданная визуальной подвеске.
@export var landing_compression := 0.42
## Жёсткость визуальной пружины подвески (1/с²).
@export var spring_k := 135.0
## Демпфирование подвески (1/с).
@export var spring_damp := 24.0
## Максимальное сжатие подвески (м).
@export var sag_max := 0.16
## Максимальное растяжение подвески (м).
@export var stretch_max := 0.07
## Порог скорости сжатия вилки для события пробоя (м/с).
@export var bottom_out_speed := 1.4
## Коэффициент потери кинетической энергии при переезде через неперепрыгнутое бревно.
@export var step_energy_k := 14.0
## Скорость прямого наезда на высокое бревно (>=0.28 м) без хопа, ведущая к падению через руль (м/с).
@export var endo_obstacle_speed := 10.5
## Скорость лобового удара в стену/валун/ствол до падения (м/с).
@export var wall_crash_speed := 8.5

@export_group("Прыжок и баланс в воздухе (Q / E)")
## Вертикальный импульс банни-хопа на Space (м/с).
@export var hop_pop := 3.7
## Буфер нажатия Space до приземления/отрыва (с).
@export var hop_buffer := 0.20
## Запас coyote time для прыжка сразу после схода с кромки (с).
@export var hop_coyote := 0.10
## Угловая скорость тангажа в воздухе при удержании Q (нос вверх) и E (нос вниз) (рад/с).
@export var air_pitch_rate := 2.6
## Отзывчивость раскрутки и остановки тангажа от Q/E (рад/с²).
@export var air_pitch_accel := 14.0
## Предельный угол тангажа велосипеда в воздухе от Q/E (рад).
@export var air_pitch_limit := 0.85
## Допустимое расхождение угла велосипеда со склоном при чистом приземлении без потери скорости (рад).
@export var landing_clean_angle := 0.30
## Критическая ошибка угла приземления на скорости после реального полёта (рад -> авария).
@export var landing_crash_angle := 0.72
## Порог силы приземления, с которого начинается мягкое гашение скорости (м/с).
@export var soft_impact := 7.2
## Порог вертикального удара, при котором наступает жёсткое падение (м/с).
@export var crash_impact := 13.5

static var _current: BikePhysicsConfig
static var _lock := Mutex.new()


static func current() -> BikePhysicsConfig:
	_lock.lock()
	var cached := _current
	_lock.unlock()
	if cached != null:
		return cached
	var loaded := load(PATH) as BikePhysicsConfig
	if loaded == null:
		loaded = BikePhysicsConfig.new()
	_lock.lock()
	if _current == null:
		_current = loaded
	var out := _current
	_lock.unlock()
	return out


static func set_current(cfg: BikePhysicsConfig) -> void:
	_lock.lock()
	_current = cfg
	_lock.unlock()


func to_dict() -> Dictionary:
	var out := {}
	for prop: Dictionary in get_property_list():
		var usage := int(prop.get("usage", 0))
		if (usage & PROPERTY_USAGE_SCRIPT_VARIABLE) == 0:
			continue
		var prop_name := String(prop.name)
		var val: Variant = get(prop_name)
		if val is float or val is int or val is bool or val is String:
			out[prop_name] = val
		elif val is Vector2:
			out[prop_name] = {x = val.x, y = val.y}
	return out
