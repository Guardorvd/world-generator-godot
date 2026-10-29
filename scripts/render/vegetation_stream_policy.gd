extends RefCounted
## Только политика планирования: не владеет миром, потоками или узлами GPU.
const FADE_SECONDS := 0.5
const REFILL_STEP := 8.0
const MAX_LEAD := 256.0
const MAX_SPEED := 90.0
var clock := 1.0
var velocity := Vector2.ZERO
var previous := Vector2.INF
var latency := 0.25

func sample(position: Vector2, dt: float, reset := false) -> void:
	clock += maxf(0.0, dt)
	if reset or previous == Vector2.INF or dt <= 0.0 or position.distance_to(previous) > maxf(128.0, dt * MAX_SPEED * 4.0):
		velocity = Vector2.ZERO
	else:
		var target := ((position - previous) / dt).limit_length(MAX_SPEED)
		velocity = velocity.lerp(target, Util.damp(8.0, dt))
		if target.length_squared() > velocity.length_squared():
			velocity = target
	previous = position

func record_latency(seconds: float) -> void:
	# Рост задержки учитывается сразу, снижение — постепенно, чтобы не терять запас после одного быстрого кадра.
	latency = maxf(clampf(seconds, 0.05, 3.0), latency * 0.85)

func lead() -> Vector2:
	return (velocity * (latency + FADE_SECONDS + 0.25)).limit_length(MAX_LEAD)

static func distance_to_coverage(point: Vector2, origin: Vector2, offset: Vector2) -> float:
	var t := clampf((point - origin).dot(offset) / maxf(offset.length_squared(), 0.000001), 0.0, 1.0)
	return point.distance_to(origin + offset * t)

static func reserve_factor(radius: float, offset: Vector2) -> float:
	# Площадь капсулы = площадь круга + ширина * длина упреждения.
	return 1.0 + 2.0 * offset.length() / (PI * maxf(radius, 1.0))
