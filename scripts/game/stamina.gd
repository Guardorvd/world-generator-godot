class_name Stamina
extends RefCounted
## 14.0: выносливость седока — одна полоска 0..1 без физиологии. Тратится, пока игрок давит на педали:
## сильно с Shift, слабо на большой скорости без него; больше в подъём и меньше под уклон. Восстанавливается
## накатом (педали и тормоз отпущены) и пешком. Пуста — Shift не работает, педали крутятся слабее,
## пока полоска не наберёт RECOVERED. Пеший бег пока не тратит её, но и не восстанавливает.
## Новые траты (бег, плавание, груз) — ещё одна ветка в tick_*, числа — константы ниже.

const SHIFT_FLAT := 1.0 / 15.0   # Shift на ровном: пусто за 15 с
const SHIFT_DOWN := 1.0 / 20.0   # Shift под пологий уклон: за 20 с
const SHIFT_UP := 1.0 / 12.0     # Shift в подъём: за 12 с
const PEDAL_FAST := 1.0 / 60.0   # педали без Shift на крейсерской скорости: за минуту
const PEDAL_UP := 1.0 / 30.0     # педали без Shift в подъём: за полминуты
const CLIMB := 0.15              # подъём на метр пути, при котором трата уже как в подъём (≈ 8,5°)
const COAST := 1.0 / 12.0        # накатом или стоя на велосипеде: с нуля до полной за 12 с
const REST := 1.0 / 8.0          # пешком: за 8 с
const REST_DELAY := 0.8          # восстановление начинается после усилия не сразу, с
const RECOVERED := 0.3           # после истощения Shift снова доступен с этого уровня
const TIRED_PEDAL := 0.85        # педали при пустой полоске: доля газа (и крейсерской скорости)

enum State { IDLE, DRAIN, COAST, REST } # 14.2: что происходит с полоской в последнем такте (для интерфейса)

var value := 1.0
var exhausted := false  # полоска опустела и ещё не набрала RECOVERED
var state := State.IDLE
var _rest_wait := 0.0


## Shift действительно добавляет силы: нажат, есть газ и полоска не истощена
func can_boost(boost: bool, throttle: float) -> bool:
	return boost and throttle > 0.0 and not exhausted


## Доля газа, которую ноги ещё дают: при истощении педали слабее
func pedal_scale() -> float:
	return TIRED_PEDAL if exhausted else 1.0


## Такт на велосипеде. throttle — газ (+) и тормоз (-), boost — Shift уже с учётом can_boost,
## speed — м/с вдоль курса, grade — подъём земли на метр пути (BikeRide.grade), airborne — в полёте
func tick_ride(dt: float, throttle: float, boost: bool, speed: float, grade: float, airborne: bool) -> void:
	if airborne:
		state = State.IDLE
		return
	var g := clampf(grade * signf(speed) / CLIMB, -1.0, 1.0)
	var drain := 0.0
	if throttle > 0.0:
		if boost:
			drain = lerpf(SHIFT_FLAT, SHIFT_UP, g) if g > 0.0 else lerpf(SHIFT_FLAT, SHIFT_DOWN, -g)
		elif not exhausted:
			# без Shift тратит быстрая езда и подъём; медленно по ровному и под уклон — почти даром
			var fast := smoothstep(0.55, 1.0, absf(speed) / GameConfig.BIKE_SPEED) * (1.0 - maxf(-g, 0.0))
			drain = maxf(PEDAL_FAST * fast, PEDAL_UP * maxf(g, 0.0))
		drain *= throttle
	if drain > 0.0:
		_spend(drain * dt)
	elif throttle <= 0.0:
		_rest(COAST, dt)
		state = State.COAST if value < 1.0 else State.IDLE
	else:
		state = State.IDLE


## Такт пешком: стоя и шагом полоска восстанавливается, на бегу замирает
func tick_foot(dt: float, running: bool) -> void:
	if running:
		_rest_wait = REST_DELAY
		state = State.IDLE
		return
	_rest(REST, dt)
	state = State.REST if value < 1.0 else State.IDLE


func reset() -> void:
	value = 1.0
	exhausted = false
	_rest_wait = 0.0
	state = State.IDLE


func _spend(amount: float) -> void:
	value = maxf(0.0, value - amount)
	_rest_wait = REST_DELAY
	state = State.DRAIN
	if value <= 0.0:
		exhausted = true


func _rest(rate: float, dt: float) -> void:
	if _rest_wait > 0.0:
		_rest_wait -= dt
		return
	value = minf(1.0, value + rate * dt)
	if exhausted and value >= RECOVERED:
		exhausted = false
