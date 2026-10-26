extends RefCounted
## One combined brake. Forces are per unit mass (m/s²); no scene dependencies.
## Load transfer: N_front / N = 0.5 + h/L * (a/g_normal - grade) - rider_shift/L.
const WHEELBASE := GameConfig.BIKE_WHEELBASE
const COM_HEIGHT := 1.1
const RIDER_RESPONSE := 0.55
const SURGE_DECAY := 0.7
const TIP_ANGLE := 0.16
const MIN_TIP_SPEED := 6.0

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
	tipped = false

func step(dt: float, command: float, speed: float, grade: float, grip: float, corner: float, grounded := true) -> void:
	if dt <= 0.0 or not is_finite(dt): return
	command = clampf(command, 0.0, 1.0) if grounded else 0.0
	var previous := pressure
	var response := GameConfig.BIKE_BRAKE_RISE if command > pressure else GameConfig.BIKE_BRAKE_RELEASE
	pressure = lerpf(pressure, command, 1.0 - exp(-dt / response))
	brace = lerpf(brace, pressure, 1.0 - exp(-dt / RIDER_RESPONSE))
	_surge *= exp(-dt / SURGE_DECAY)
	_surge = maxf(_surge, maxf(0.0, pressure - previous) / dt * 0.12 * smoothstep(8.0, 18.0, speed))
	front_force = 0.0
	rear_force = 0.0
	deceleration = 0.0
	grip_used = 0.0
	skid = 0.0
	var normal_g := GameConfig.GRAVITY / sqrt(1.0 + grade * grade)
	var capacity := GameConfig.BIKE_GRIP * maxf(grip, 0.0) / sqrt(1.0 + grade * grade)
	var reserve := capacity * GameConfig.BIKE_CORNER_RESERVE * clampf(corner, 0.0, 1.0)
	var available := sqrt(maxf(0.0, capacity * capacity - reserve * reserve))
	var shift := brace * GameConfig.BIKE_BRAKE_SHIFT - _surge * 0.18
	var demand := GameConfig.BIKE_BRAKE * pressure
	# Two bounded iterations resolve force/load coupling without an allocation or solver.
	for i in 2:
		front_load = 0.5 + COM_HEIGHT / WHEELBASE * (deceleration / normal_g - grade) - shift / WHEELBASE
		var front_share := clampf(front_load, 0.65, 1.0)
		front_force = minf(demand * front_share, available * clampf(front_load, 0.0, 1.0))
		rear_force = minf(demand * (1.0 - front_share), available * clampf(1.0 - front_load, 0.0, 1.0))
		deceleration = minf(front_force + rear_force, maxf(speed, 0.0) / dt) if grounded and speed > 0.05 else 0.0
	front_load = 0.5 + COM_HEIGHT / WHEELBASE * (deceleration / normal_g - grade) - shift / WHEELBASE
	grip_used = clampf(deceleration / maxf(available, 0.001), 0.0, 1.0)
	skid = clampf((demand - deceleration) / maxf(demand, 0.001), 0.0, 1.0) if grounded and speed > 1.0 else 0.0
	if grounded and speed > MIN_TIP_SPEED and pressure > 0.05:
		var torque := (front_load - 1.0) * normal_g * WHEELBASE
		_pitch_rate += torque / (COM_HEIGHT * COM_HEIGHT * 0.5) * dt
		_pitch_rate *= exp(-dt * 2.0)
		lift = maxf(0.0, lift + _pitch_rate * dt)
		if lift <= 0.0: _pitch_rate = maxf(0.0, _pitch_rate)
	else:
		lift = move_toward(lift, 0.0, dt * 0.8)
		_pitch_rate = 0.0
	risk = clampf(maxf((front_load - 0.8) / 0.2, lift / TIP_ANGLE), 0.0, 1.0) if grounded and speed > MIN_TIP_SPEED and pressure > 0.05 else 0.0
	tipped = lift >= TIP_ANGLE
