extends RefCounted
## One combined brake. Forces are per unit mass (m/s²); no scene dependencies.
## Load transfer: N_front / N = 0.5 + h/L * (a/g_normal - grade) - rider_shift/L.
const WHEELBASE := GameConfig.BIKE_WHEELBASE
const COM_HEIGHT := 1.1
const RIDER_RESPONSE := 0.55
const SURGE_DECAY := 0.7
const TIP_ANGLE := 0.32
const MIN_TIP_SPEED := 14.0
# Arcade balance assistance: ordinary emergency stops stay safe, sustained
# overload on a fast steep descent still allows a readable, avoidable pitch-over.
const BALANCE_MARGIN := 0.22
const OVERLOAD_GRACE := 1.0
const HARD_BRAKE := 0.85
const SHARE_LIMIT := 0.9 # долю другого колеса седок добирает до этой доли его запаса

var pressure := 0.0
var deceleration := 0.0
var front_load := 0.5
var front_force := 0.0
var rear_force := 0.0
var grip_used := 0.0
var skid := 0.0
var risk := 0.0
var lift := 0.0 # rear wheel lift expressed as nose-down pitch, radians
var brace := 0.0
var _surge := 0.0
var _pitch_rate := 0.0
var _overload_time := 0.0
var tipped := false

func reset() -> void:
	pressure = 0.0
	deceleration = 0.0
	front_load = 0.5
	front_force = 0.0
	rear_force = 0.0
	grip_used = 0.0
	skid = 0.0
	risk = 0.0
	lift = 0.0
	brace = 0.0
	_surge = 0.0
	_pitch_rate = 0.0
	_overload_time = 0.0
	tipped = false

## loads — нагрузки шин переднего и заднего колеса (BikeRide, модель двух контактов), доли веса; тогда запас каждого
## колеса — от его нагрузки, а не от front_load. Отрицательные — прежняя модель.
func step(dt: float, command: float, speed: float, grade: float, grip: float, corner: float, grounded := true, loads := Vector2(-1.0, -1.0)) -> void:
	if dt <= 0.0 or not is_finite(dt): return
	command = clampf(command, 0.0, 1.0) if grounded else 0.0
	var previous := pressure
	var response := GameConfig.BIKE_BRAKE_RISE if command > pressure else GameConfig.BIKE_BRAKE_RELEASE
	pressure = lerpf(pressure, command, 1.0 - exp(-dt / response))
	brace = lerpf(brace, pressure, 1.0 - exp(-dt / RIDER_RESPONSE))
	_surge *= exp(-dt / SURGE_DECAY)
	_surge = maxf(_surge, maxf(0.0, pressure - previous) / dt * 0.12 * smoothstep(8.0, 18.0, speed))
	# Перенос нагрузки зависит от самого торможения: начинаем с прошлого подшага и сходимся за три итерации
	# с усреднением (без него итерация по силе и нагрузке колеблется, а с одним задним колесом — заметно).
	var guess := deceleration if grounded and command > 0.0 else 0.0
	front_force = 0.0
	rear_force = 0.0
	deceleration = 0.0
	grip_used = 0.0
	skid = 0.0
	var normal_g := GameConfig.GRAVITY / sqrt(1.0 + grade * grade)
	var capacity := GameConfig.BIKE_GRIP * maxf(grip, 0.0) / sqrt(1.0 + grade * grade)
	var reserve := capacity * GameConfig.BIKE_CORNER_RESERVE * clampf(corner, 0.0, 1.0)
	var available := sqrt(maxf(0.0, capacity * capacity - reserve * reserve))
	# запас на долю веса: нагрузки шин уже включают косинус уклона
	var per_load := available * sqrt(1.0 + grade * grade)
	var shift := brace * GameConfig.BIKE_BRAKE_SHIFT - _surge * 0.18
	var demand := GameConfig.BIKE_BRAKE * pressure
	for i in 3:
		front_load = 0.5 + COM_HEIGHT / WHEELBASE * (guess / normal_g - grade) - shift / WHEELBASE
		var front_share := clampf(front_load, 0.65, 1.0)
		var cap_f := per_load * loads.x if loads.x >= 0.0 else available * clampf(front_load, 0.0, 1.0)
		# Тормозной перенос разгружает заднее колесо сразу, даже если переднее ещё в воздухе: момент торможения
		# опускает нос, а не держится поднятым. Иначе заднее тормозило бы под полным весом, и при возврате
		# переднего тормоз проваливался, пока его шина набирает силу.
		var cap_r := per_load * minf(loads.y, clampf(1.0 - front_load, 0.0, 1.0) / sqrt(1.0 + grade * grade)) if loads.y >= 0.0 else available * clampf(1.0 - front_load, 0.0, 1.0)
		# Седок распределяет один тормоз: что не держит одно колесо (разгружено, скользит), берёт другое,
		# но не до самого предела — остаётся резерв для курса.
		var want_f := demand * front_share
		var want_r := demand - want_f
		front_force = minf(want_f, cap_f)
		rear_force = minf(want_r, cap_r)
		var spare_r := maxf(0.0, cap_r * SHARE_LIMIT - rear_force)
		var spare_f := maxf(0.0, cap_f * SHARE_LIMIT - front_force)
		var moved_r := minf(want_f - front_force, spare_r)
		front_force += minf(want_r - rear_force, spare_f)
		rear_force += moved_r
		deceleration = minf(front_force + rear_force, maxf(speed, 0.0) / dt) if grounded and speed > 0.05 else 0.0
		guess = (guess + deceleration) * 0.5
	_match_forces()
	front_load = 0.5 + COM_HEIGHT / WHEELBASE * (deceleration / normal_g - grade) - shift / WHEELBASE
	var total := per_load * (loads.x + loads.y) if loads.x >= 0.0 else available
	grip_used = clampf(deceleration / maxf(total, 0.001), 0.0, 1.0)
	skid = clampf((demand - deceleration) / maxf(demand, 0.001), 0.0, 1.0) if grounded and speed > 1.0 else 0.0
	# Пороги скорости и силы нажатия — плавные: у их границы перегрузка нарастает постепенно, а не включается сразу.
	var near := smoothstep(MIN_TIP_SPEED - 2.0, MIN_TIP_SPEED + 2.0, speed) * smoothstep(HARD_BRAKE - 0.1, HARD_BRAKE + 0.05, minf(command, pressure))
	var overload := (front_load - 1.0 - BALANCE_MARGIN) * near
	var danger := grounded and overload > 0.0
	if danger:
		_overload_time += dt * near
		if _overload_time <= OVERLOAD_GRACE:
			# Small visual warning first; no hidden angular momentum during the grace period.
			lift = move_toward(lift, 0.04 * _overload_time / OVERLOAD_GRACE, dt * 0.08)
			_pitch_rate = 0.0
		else:
			var torque := overload * normal_g * WHEELBASE
			_pitch_rate += torque / (COM_HEIGHT * COM_HEIGHT * 0.5) * dt
			_pitch_rate *= exp(-dt * 6.0)
			lift = maxf(0.0, lift + _pitch_rate * dt)
	else:
		_overload_time = maxf(0.0, _overload_time - dt * 3.0)
		lift = move_toward(lift, 0.0, dt * 0.8)
		_pitch_rate = 0.0
	risk = clampf(maxf(_overload_time / OVERLOAD_GRACE * 0.8, lift / TIP_ANGLE), 0.0, 1.0) if danger else 0.0
	tipped = danger and lift >= TIP_ANGLE


## Итоговый тормоз ограничен (остановка, сопротивление уже гасит ход): силы колёс уменьшаются в той же доле,
## чтобы они описывали фактически приложенный импульс.
func limit(total: float) -> void:
	deceleration = maxf(0.0, total)
	_match_forces()


func _match_forces() -> void:
	var sum := front_force + rear_force
	if sum > deceleration + 0.000001:
		var k := deceleration / sum
		front_force *= k
		rear_force *= k
