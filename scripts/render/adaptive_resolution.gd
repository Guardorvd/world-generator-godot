extends RefCounted
## 20.11.2026: адаптивное разрешение 3D. Когда видеокарта не укладывается в кадр экрана (вид с высоты, луга,
## болото — запись сессий: 22–24 мс против 16,7), доля разрешения 3D опускается на ступень (FSR 1 повышает
## резкость), когда запас вернулся — поднимается. Интерфейс всегда в полном разрешении. Растительность, дальность
## и подгрузка не меняются: дорожают пиксели (затенение, SSAO, сглаживание, стиль), а не число деревьев.
## Только логика: время GPU на входе, ступень на выходе. Применяет GameWorld через DisplayConfig.adaptive_scale.
## Смена ступени пересоздаёт буферы кадра, поэтому ступени редкие: опускание — после DROP_HOLD_S перегрузки,
## подъём — после RAISE_HOLD_S запаса с оценкой на ступень выше, после смены SETTLE_S кадры не считаются.

const STEPS: Array[float] = [1.0, 0.9, 0.8] # доля стороны кадра от выбранной игроком
const TARGET_FPS := 60.0    # цель — ровные 60 к/с; экран с меньшей частотой — его частота
const DROP_AT := 0.94       # GPU дольше этой доли кадра — перегрузка
const RAISE_AT := 0.78      # оценка GPU на ступень выше ниже этой доли кадра — запас
const DROP_HOLD_S := 0.75
const RAISE_HOLD_S := 4.0
const SETTLE_S := 1.0
const SMOOTH := 0.12        # сглаживание времени GPU по кадрам
const SAMPLE_CAP := 2.0     # одиночный долгий кадр (подгрузка, сборка буферов) весит не больше двух кадров экрана

var level := 0
var gpu_ms := 0.0           # сглаженное время GPU, мс
var _over_s := 0.0
var _under_s := 0.0
var _settle_s := 0.0


func scale() -> float:
	return STEPS[level]


## Длительность кадра экрана, мс: 60 к/с или частота экрана, если она ниже
static func budget_ms(refresh_hz: float) -> float:
	return 1000.0 / (minf(TARGET_FPS, refresh_hz) if refresh_hz >= 24.0 else TARGET_FPS)


## Один кадр. sample_ms — время кадра на GPU (0 — замера нет). true — ступень сменилась, её надо применить.
func update(sample_ms: float, dt: float, budget: float) -> bool:
	if _settle_s > 0.0:
		_settle_s -= dt
		return false
	if sample_ms <= 0.0:
		return false
	var capped := minf(sample_ms, budget * SAMPLE_CAP)
	gpu_ms = capped if gpu_ms == 0.0 else lerpf(gpu_ms, capped, SMOOTH)
	_over_s = _over_s + dt if gpu_ms > budget * DROP_AT and level < STEPS.size() - 1 else 0.0
	# вся цена кадра считается пиксельной (∝ площади): оценка сверху, подъём осторожнее опускания
	var ratio := STEPS[level - 1] / STEPS[level] if level > 0 else 1.0
	_under_s = _under_s + dt if level > 0 and gpu_ms * ratio * ratio < budget * RAISE_AT else 0.0
	if _over_s >= DROP_HOLD_S:
		return _set_level(level + 1)
	if _under_s >= RAISE_HOLD_S:
		return _set_level(level - 1)
	return false


## Вернуть полное разрешение (выключили в настройках, вышли из мира). true — было снижено.
func reset() -> bool:
	return _set_level(0)


func _set_level(next: int) -> bool:
	_over_s = 0.0
	_under_s = 0.0
	if next == level:
		return false
	level = next
	_settle_s = SETTLE_S
	gpu_ms = 0.0 # старое время снято при другом разрешении
	return true
