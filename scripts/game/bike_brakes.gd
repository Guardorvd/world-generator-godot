extends RefCounted
## One combined brake. Forces are per unit mass (m/s²); no scene dependencies.
## Load transfer: N_front / N = 0.5 + h/L * (a/g_normal - grade) - rider_shift/L; uphill grade counts at climb_transfer.
const WHEELBASE := GameConfig.BIKE_WHEELBASE

var config: BikePhysicsConfig = BikePhysicsConfig.current()
var pressure := 0.0
var deceleration := 0.0
var front_load := 0.5
var front_force := 0.0
var rear_force := 0.0
var skid := 0.0
var risk := 0.0
var lift := 0.0 # rear wheel lift expressed as nose-down pitch, radians
var brace := 0.0
var _surge := 0.0
var _pitch_rate := 0.0
var _overload_time := 0.0
var tipped := false


func _init(cfg: BikePhysicsConfig = null) -> void:
	if cfg != null:
		config = cfg


func reset() -> void:
	pressure = 0.0
	deceleration = 0.0
	front_load = 0.5
	front_force = 0.0
	rear_force = 0.0
	skid = 0.0
	risk = 0.0
	lift = 0.0
	brace = 0.0
	_surge = 0.0
	_pitch_rate = 0.0
	_overload_time = 0.0
	tipped = false


## loads — нагрузки шин переднего и заднего колеса (BikeRide), доли веса.
## rider_back — положение корпуса от −1 (вперёд) до 1 (назад), влияет только на перелёт через руль.
func step(dt: float, command: float, speed: float, grade: float, grip: float, corner: float, grounded := true, loads := Vector2(0.5, 0.5), rider_back := 0.0, cross := 0.0) -> void:
	if dt <= 0.0 or not is_finite(dt): return
	var cfg := config if config != null else BikePhysicsConfig.current()
	command = clampf(command, 0.0, 1.0) if grounded else 0.0
	var previous := pressure
	var response := cfg.brake_rise if command > pressure else cfg.brake_release
	pressure = lerpf(pressure, command, 1.0 - exp(-dt / response))
	brace = lerpf(brace, pressure, 1.0 - exp(-dt / cfg.brake_rider_response))
	_surge *= exp(-dt / cfg.brake_surge_decay)
	_surge = maxf(_surge, maxf(0.0, pressure - previous) / dt * cfg.brake_surge_gain * smoothstep(8.0, 18.0, speed))
	# Перенос нагрузки зависит от самого торможения: начинаем с прошлого подшага и сходимся за три итерации
	# с усреднением (без него итерация по силе и нагрузке колеблется, а с одним задним колесом — заметно).
	var guess := deceleration if grounded and command > 0.0 else 0.0
	front_force = 0.0
	rear_force = 0.0
	deceleration = 0.0
	skid = 0.0
	var inv_cos := sqrt(1.0 + grade * grade + cross * cross)
	var normal_g := cfg.ground_gravity / inv_cos
	var capacity := cfg.base_grip() * maxf(grip, 0.0) / inv_cos
	var reserve := capacity * cfg.brake_corner_reserve * clampf(corner, 0.0, 1.0)
	var available := sqrt(maxf(0.0, capacity * capacity - reserve * reserve))
	# запас на долю веса: нагрузки шин уже включают косинус уклона
	var per_load := available * inv_cos
	var shift := brace * cfg.brake_shift - _surge * cfg.brake_surge_shift
	var lean_grade := grade * cfg.brake_climb_transfer if grade > 0.0 else grade
	var demand := cfg.brake_decel * pressure
	var com_h := cfg.brake_com_height
	for i in 3:
		front_load = 0.5 + com_h / WHEELBASE * (guess / normal_g - lean_grade) - shift / WHEELBASE
		var front_share := clampf(front_load, cfg.brake_front_share_min, 1.0)
		front_share = lerpf(front_share, maxf(0.45, front_share - 0.15), smoothstep(0.2, 0.8, corner))
		var cap_f := per_load * loads.x
		# Тормозной перенос разгружает заднее колесо сразу, даже если переднее ещё в воздухе: момент торможения
		# опускает нос, а не держится поднятым. Иначе заднее тормозило бы под полным весом, и при возврате
		# переднего тормоз проваливался, пока его шина набирает силу.
		var cap_r := per_load * minf(loads.y, clampf(1.0 - front_load, 0.0, 1.0) / inv_cos)
		# Седок распределяет один тормоз: что не держит одно колесо (разгружено, скользит), берёт другое,
		# но не до самого предела — остаётся резерв для курса.
		var want_f := demand * front_share
		var want_r := demand - want_f
		front_force = minf(want_f, cap_f)
		rear_force = minf(want_r, cap_r)
		var spare_r := maxf(0.0, cap_r * cfg.brake_share_limit - rear_force)
		var spare_f := maxf(0.0, cap_f * cfg.brake_share_limit - front_force)
		var moved_r := minf(want_f - front_force, spare_r)
		front_force += minf(want_r - rear_force, spare_f)
		rear_force += moved_r
		deceleration = minf(front_force + rear_force, absf(speed) / dt) if grounded and absf(speed) > 0.05 else 0.0
		guess = (guess + deceleration) * 0.5
	_match_forces()
	front_load = 0.5 + com_h / WHEELBASE * (deceleration / normal_g - lean_grade) - shift / WHEELBASE
	skid = clampf((demand - deceleration) / maxf(demand, 0.001), 0.0, 1.0) if grounded and absf(speed) > 1.0 else 0.0
	# Пороги скорости и силы нажатия — плавные: у их границы перегрузка нарастает постепенно, а не включается сразу.
	var near := smoothstep(cfg.brake_min_tip_speed - 2.0, cfg.brake_min_tip_speed + 2.0, speed) \
		* smoothstep(cfg.brake_hard - 0.1, cfg.brake_hard + 0.05, minf(command, pressure))
	var balance := front_load - clampf(rider_back, -1.0, 1.0) * cfg.brake_rider_back_shift / WHEELBASE
	var overload := (balance - 1.0 - cfg.brake_balance_margin) * near
	var danger := grounded and overload > 0.0
	if danger:
		_overload_time += dt * near
		if _overload_time <= cfg.brake_overload_grace:
			# Small visual warning first; no hidden angular momentum during the grace period.
			lift = move_toward(lift, cfg.brake_warn_lift * _overload_time / cfg.brake_overload_grace, dt * cfg.brake_warn_lift * 2.0)
			_pitch_rate = 0.0
		else:
			var torque := overload * normal_g * WHEELBASE
			_pitch_rate += torque / (com_h * com_h * 0.5) * dt
			_pitch_rate *= exp(-dt * 6.0)
			lift = maxf(0.0, lift + _pitch_rate * dt)
	else:
		_overload_time = maxf(0.0, _overload_time - dt * 3.0)
		lift = move_toward(lift, 0.0, dt * 0.8)
		_pitch_rate = 0.0
	risk = clampf(maxf(_overload_time / cfg.brake_overload_grace * 0.8, lift / cfg.brake_tip_angle), 0.0, 1.0) if danger else 0.0
	tipped = danger and lift >= cfg.brake_tip_angle


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
