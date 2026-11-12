class_name Stamina
extends RefCounted
## 14.0: выносливость седока — одна полоска 0..1 без физиологии.
## 15.0: полоска — запас рывков. Нажатие Shift на велосипеде (с педалями) сразу берёт DASH_COST полоски
## и даёт «прилив сил» на SURGE_TIME: крейсерская скорость выше, тяга сильнее, в подъём легче
## (как именно — BikeRide.surge). Больше полоска нигде не тратится: держать Shift бесполезно,
## следующий рывок — новым нажатием. Восстанавливается всегда: на педалях медленнее, накатом и пешком быстрее.
## Меньше DASH_COST — рывка нет (exhausted, дуга красная до засечки RECOVERED).

const DASH_COST := 1.0 / 3.0     # цена рывка: треть полоски
const SURGE_TIME := 3.0          # длительность прилива сил, с
const SURGE_FADE := 1.0          # последнюю секунду прилив мягко спадает к нулю
const PEDAL := 1.0 / 30.0        # восстановление на педалях: с нуля до полной за 30 с (рывок — за 10 с)
const COAST := 1.0 / 12.0        # накатом или стоя на велосипеде: за 12 с (рывок — за 4 с)
const REST := 1.0 / 8.0          # пешком (и на бегу): за 8 с
const REST_DELAY := 0.8          # после рывка восстановление начинается не сразу, с
const RECOVERED := DASH_COST     # засечка на дуге: с неё снова есть рывок

enum State { IDLE, DRAIN, COAST, REST } # 14.2: что происходит с полоской в последнем такте (для интерфейса)

var value := 1.0
var exhausted := false  # меньше цены рывка: Shift сейчас ничего не даёт
var state := State.IDLE
var surge_left := 0.0   # сколько секунд ещё длится прилив сил
var _rest_wait := 0.0
var _held := false      # Shift был зажат в прошлом такте: рывок — только по новому нажатию


## Сила прилива 0..1: полная до последней SURGE_FADE секунды, затем плавно к нулю
func surge() -> float:
	return smoothstep(0.0, SURGE_FADE, surge_left)


## Прилив идёт и есть газ (для позы седока)
func surging(throttle: float) -> bool:
	return throttle > 0.0 and surge_left > 0.0


## Такт на велосипеде. run — Shift зажат, throttle — газ (+) и тормоз (-), airborne — в полёте.
## Рывок — в момент нажатия при газе и хватающей полоске; во время прилива новое нажатие ничего не берёт.
func tick_ride(dt: float, run: bool, throttle: float, airborne: bool) -> void:
	if run and not _held and throttle > 0.0 and surge_left <= 0.0 and value >= DASH_COST - 0.0001:
		value = maxf(0.0, value - DASH_COST)
		surge_left = SURGE_TIME
		_rest_wait = REST_DELAY
	_held = run
	if surge_left > 0.0:
		surge_left = maxf(0.0, surge_left - dt)
		state = State.DRAIN
		_update_exhausted()
		return
	if throttle > 0.0 and not airborne:
		_rest(PEDAL, dt)
		state = State.IDLE
	else:
		_rest(COAST, dt)
		state = State.COAST if value < 1.0 else State.IDLE


## Такт пешком: полоска восстанавливается, бег её не тратит
func tick_foot(dt: float, _running: bool) -> void:
	_held = false
	surge_left = 0.0
	_rest(REST, dt)
	state = State.REST if value < 1.0 else State.IDLE


func reset() -> void:
	value = 1.0
	exhausted = false
	surge_left = 0.0
	_held = false
	_rest_wait = 0.0
	state = State.IDLE


func _rest(rate: float, dt: float) -> void:
	if _rest_wait > 0.0:
		_rest_wait -= dt
	else:
		value = minf(1.0, value + rate * dt)
	_update_exhausted()


func _update_exhausted() -> void:
	exhausted = value < DASH_COST - 0.0001
