class_name BikeRide
extends RefCounted
## Упрощённая двухколёсная физика велосипеда ("управляемая достоверность"):
## - Прямое управление рулём и передним колесом (база осей WHEELBASE = 1.06 м),
## - Плавный разгон педалями, предсказуемый тормоз/задний ход и тяга на крутых подъёмах,
## - Банни-хоп на Space (с буфером и coyote time) и аркадный баланс в воздухе на Q/E,
## - Единая конфигурация в BikePhysicsConfig (resources/bike_physics.tres).

const WHEEL_R := 0.34
const BODY_R := 0.30
const AXLE := 0.57
const HUB := GameConfig.BIKE_WHEELBASE * 0.5
const WHEELBASE := GameConfig.BIKE_WHEELBASE
const HZ := 60.0
const SUB_HZ := 60.0
const MOUNT_RISE := 1.5
const STOP_FOOT_FORWARD := 0.06

enum CrashCause { FALL, COLLISION, BRAKING, OBSTACLE }
enum Stance { RIDING, TRACKSTAND, FOOT_DOWN }

var config: BikePhysicsConfig = BikePhysicsConfig.current()

# Положение, движение и наклон рамы
var riding := false
var x := 0.0
var y := 0.0
var z := 0.0
var heading := 0.0
var speed := 0.0
var lateral_speed := 0.0
var vy := 0.0
var airborne := false
var acceleration := 0.0
var feel_acceleration := 0.0
var tick_time := 1.0 / HZ

# Руль, крен и курс
var steer := 0.0
var steer_angle := 0.0
var yaw_rate := 0.0
var slip := 0.0
var lean := 0.0
var rider_lean := 0.0
var tilt := 0.0
var pitch_vel := 0.0

# Привод и тормоза
var effort := 0.0
var effort_ramp := true
var surge := -1.0
var gear := 1.4
var drive_request := 0.0
var drive_force := 0.0
var crank := 0.0
var wheel := 0.0
var brake_pressure := 0.0
var brake_applied := 0.0
var brake_deceleration := 0.0
var brake_force := Vector2()
var brake_skid := 0.0
var brake_risk := 0.0
var nose_lift := 0.0
var braking := 0.0
var reversing := false
var roll_loss := 0.0
var air_loss := 0.0
var rough_loss := 0.0
var slope_force := 0.0
var pump_force := 0.0

# Воздух, прыжок и баланс Q/E
var air_time := 0.0
var air_clearance := 0.0
var clearance_closing_speed := 0.0
var hop_preparing := false
var hop_used := false
var hop_height := 0.0
var body_back := false
var body_forward := false
var body_x := 0.0
var body_v := 0.0
var lift_f := 0.0
var lift_r := 0.0
var unweight := 0.0

# Опора, визуальная подвеска и сцепление (для вида, звука и телеметрии)
var grade_now := 0.0
var bank_slope := 0.0
var vertical_g := 0.0
var ground_f := 0.0
var ground_r := 0.0
var ground_extension := 0.0
var squash := 0.0
var squash_f := 0.0
var squash_r := 0.0
var squash_fv := 0.0
var squash_rv := 0.0
var squash_fv_avg := 0.0
var squash_rv_avg := 0.0
var load_f := 0.5
var load_r := 0.5
var tire_f := 0.5
var tire_r := 0.5
var side_f := 0.5
var side_r := 0.5
var slick_f := 1.0
var slick_r := 1.0
var use_f := 0.0
var use_r := 0.0
var grip_usage := 0.0
var force_f := Vector2()
var force_r := Vector2()
var obstacle_f := -1
var obstacle_r := -1
var instability := 0.0
var front_load: float:
	get: return load_f

# Стоянка с ногой на земле
var stance := Stance.RIDING
var stance_driven := false
var foot_side := -1.0
var foot_support := Vector3.ZERO

# Однотактные события и падение
var wheel_impact := Vector2()
var fork_side_impulse := 0.0
var hit_dv := Vector2()
var impacts := Vector2i()
var bottom_out := 0.0
var land_impact := 0.0
var landing_info := {}
var last_hit := {}
var crashed := false
var crash_cause := CrashCause.FALL
var crash_normal := Vector3.UP
var crash_velocity := Vector3()
var crash_info := {}
var fallen := false
var fallen_transform := Transform3D.IDENTITY

# Поля обратной совместимости телеметрии
var pump_pressed := false
var pump_active := 0.0
var pump_wave := 0.0
var pump_body := 0.0
var pump_accel := 0.0
var pump_motion := 0.0

# Внутреннее состояние шага
var _fresh := true
var _brake_hold := 0.0
var _hop_buf := 0.0
var _coyote := 0.0
var _hop_from := 0.0
var _stop_timer := 0.0
var _sustained_steer := 0.0
var _ground_cross := 0.0
var _support_grade := 0.0
var _support_y := 0.0
var _landing_lift := 0.0
var _prev_gf := 0.0
var _prev_gr := 0.0


func _init(cfg: BikePhysicsConfig = null) -> void:
	if cfg != null:
		config = cfg


func set_config(cfg: BikePhysicsConfig) -> void:
	if cfg != null:
		config = cfg


func contact_f() -> bool:
	return not airborne and lift_f <= 0.005


func contact_r() -> bool:
	return not airborne and lift_r <= 0.005


## Модель показывает направление руля даже при малом угле скоростной дуги.
func steer_visual() -> float:
	var angle := signf(steer) * maxf(absf(steer_angle), absf(steer) * config.steer_visual_floor)
	return clampf(angle / maxf(config.max_steer_angle, 0.001), -1.0, 1.0)


func steer_shown() -> float:
	return steer_visual()


func turn_pose_weight() -> float:
	var transition := config.turn_pose_steer
	return smoothstep(transition.x, transition.y, minf(_sustained_steer, absf(steer)))


func horizontal_velocity() -> Vector2:
	var fwd := Vector2(-sin(heading), -cos(heading))
	var right := Vector2(cos(heading), -sin(heading))
	return fwd * speed + right * (lateral_speed if airborne else lateral_speed - yaw_rate * HUB)


func reset_brakes() -> void:
	brake_pressure = 0.0
	brake_applied = 0.0
	brake_deceleration = 0.0
	brake_force = Vector2()
	brake_skid = 0.0
	brake_risk = 0.0
	nose_lift = 0.0
	braking = 0.0


func clear_tick_events() -> void:
	landing_info = {}
	land_impact = 0.0
	wheel_impact = Vector2()
	fork_side_impulse = 0.0
	bottom_out = 0.0


## Найти место рядом с игроком, начиная справа. null, если рама нигде не помещается.
static func park_near(p: PlayerState, yaw: float, w: WorldData, heights: Heightfield) -> BikeRide:
	var b := BikeRide.new()
	for offset: Vector2 in [Vector2(1.6, 0), Vector2(-1.6, 0), Vector2(0, 1.6), Vector2(0, -1.6),
			Vector2(1.6, 1.6), Vector2(-1.6, 1.6), Vector2(1.6, -1.6), Vector2(-1.6, -1.6), Vector2.ZERO]:
		var b_x := p.x + cos(yaw) * offset.x - sin(yaw) * offset.y
		var b_z := p.z - sin(yaw) * offset.x - cos(yaw) * offset.y
		b.y = heights.surface_at(b_x, b_z, p.feet)
		if not is_finite(b.y) or absf(b.y - p.feet) >= MOUNT_RISE:
			continue
		for hd: float in [yaw, yaw + PI * 0.5]:
			if b.fits(b_x, b_z, hd, w, heights, false):
				b.x = b_x
				b.z = b_z
				b.heading = hd
				return b
	return null


func distance_to(p: PlayerState) -> float:
	return Grid.hypot(x - p.x, z - p.z)


func can_mount(p: PlayerState) -> bool:
	return distance_to(p) <= GameConfig.BIKE_MOUNT and absf(y - p.feet) < MOUNT_RISE


func prepare_mount(p: PlayerState, w: WorldData, heights: Heightfield) -> bool:
	if not can_mount(p) or not p.on_ground:
		return false
	for radius: float in ([0.0, 0.5, 1.0, 1.5] if fallen else [0.0]):
		for i in (1 if radius == 0.0 else 8):
			var px := x + cos(i * TAU / 8.0) * radius
			var pz := z + sin(i * TAU / 8.0) * radius
			if Grid.hypot(px - p.x, pz - p.z) > GameConfig.BIKE_MOUNT:
				continue
			var floor_y := heights.surface_at(px, pz, y + 0.4)
			if absf(floor_y - p.feet) > 0.6 or heights.ceiling_at(px, pz, floor_y) < floor_y + BikeRecovery.CLEARANCE:
				continue
			var destination := Vector3(px, floor_y, pz)
			if not BikeRecovery.clear_path(w, heights, Vector3(x, y, z), destination, true):
				continue
			if not BikeRecovery.clear_path(w, heights, Vector3(p.x, p.feet, p.z), destination):
				continue
			for direction: float in [heading, heading + PI * 0.5, heading - PI * 0.5]:
				if BikeRecovery.placement(w, heights, destination, direction).is_empty():
					continue
				x = px
				z = pz
				y = floor_y
				heading = direction
				return true
	return false


func mount(p: PlayerState) -> void:
	reset_motion()
	riding = true
	fallen = false
	speed = 0.0
	p.x = x
	p.z = z
	p.vy = 0.0
	p.vx = 0.0
	p.vz = 0.0
	p.on_ground = true
	p.feet = y


func reset_motion() -> void:
	clear_tick_events()
	reset_brakes()
	last_hit = {}
	crash_info = {}
	tick_time = 0.0
	riding = false
	speed = 0.0
	lateral_speed = 0.0
	vy = 0.0
	airborne = false
	acceleration = 0.0
	feel_acceleration = 0.0
	steer = 0.0
	steer_angle = 0.0
	_sustained_steer = 0.0
	yaw_rate = 0.0
	slip = 0.0
	lean = 0.0
	rider_lean = 0.0
	tilt = 0.0
	pitch_vel = 0.0
	effort = 0.0
	gear = 1.4
	drive_request = 0.0
	drive_force = 0.0
	roll_loss = 0.0
	air_loss = 0.0
	rough_loss = 0.0
	slope_force = 0.0
	reversing = false
	air_time = 0.0
	air_clearance = 0.0
	clearance_closing_speed = 0.0
	hop_preparing = false
	hop_used = false
	body_back = false
	body_forward = false
	body_x = 0.0
	body_v = 0.0
	lift_f = 0.0
	lift_r = 0.0
	grade_now = 0.0
	bank_slope = 0.0
	vertical_g = 0.0
	ground_f = 0.0
	ground_r = 0.0
	ground_extension = 0.0
	squash = 0.0
	squash_f = 0.0
	squash_r = 0.0
	squash_fv = 0.0
	squash_rv = 0.0
	squash_fv_avg = 0.0
	squash_rv_avg = 0.0
	load_f = 0.5
	load_r = 0.5
	tire_f = 0.5
	tire_r = 0.5
	side_f = 0.5
	side_r = 0.5
	slick_f = 1.0
	slick_r = 1.0
	use_f = 0.0
	use_r = 0.0
	grip_usage = 0.0
	force_f = Vector2()
	force_r = Vector2()
	obstacle_f = -1
	obstacle_r = -1
	instability = 0.0
	stance = Stance.RIDING
	stance_driven = false
	foot_side = -1.0
	foot_support = Vector3(x, y, z)
	crashed = false
	crash_cause = CrashCause.FALL
	crash_normal = Vector3.UP
	crash_velocity = Vector3()
	_fresh = true
	_brake_hold = 0.0
	_hop_buf = 0.0
	_coyote = 0.0
	_hop_from = 0.0
	_stop_timer = 0.0
	_ground_cross = 0.0
	_support_grade = 0.0
	_support_y = y
	_landing_lift = 0.0
	_prev_gf = 0.0
	_prev_gr = 0.0


func reset_stats() -> void:
	impacts = Vector2i()
	hop_height = 0.0


func dismount(p: PlayerState, w: WorldData, heights: Heightfield) -> void:
	reset_motion()
	y = heights.surface_at(x, z, y)
	p.vx = 0.0
	p.vy = 0.0
	p.vz = 0.0
	p.on_ground = true
	var spot := _dismount_spot(w, heights)
	p.x = spot.x
	p.z = spot.y
	p.feet = heights.surface_at(p.x, p.z, y)


func _dismount_spot(w: WorldData, heights: Heightfield) -> Vector2:
	var fwd := Vector2(-sin(heading), -cos(heading))
	var dirs: Array[Vector2] = [Vector2(-cos(heading), sin(heading)), Vector2(cos(heading), -sin(heading)), -fwd, fwd]
	for dist: float in [0.9, 1.5]:
		for d: Vector2 in dirs:
			var q := Vector2(x, z) + d * dist
			var floor_y := heights.surface_at(q.x, q.y, y)
			if BikeRecovery.clear_path(w, heights, Vector3(x, y, z), Vector3(q.x, floor_y, q.y)) \
					and BikeRecovery.headroom(heights, q.x, q.y, floor_y):
				return q
	return Vector2(x, z)


func grade(heights: Heightfield) -> float:
	return _slope(heights)


func _slope(heights: Heightfield) -> float:
	var fx := -sin(heading) * HUB
	var fz := -cos(heading) * HUB
	return (_wheel_support_y(x + fx, z + fz, heights) - _wheel_support_y(x - fx, z - fz, heights)) / WHEELBASE


func _wheel_support_raw(px: float, pz: float, raw_y: float, heights: Heightfield) -> float:
	if heights.obstacles != null and not heights.obstacles.data.is_empty():
		return maxf(raw_y, heights.obstacles.wheel_support(px, pz, WHEEL_R, ForestObstacles.CLIMB_MAX))
	return raw_y


func _wheel_support_y(px: float, pz: float, heights: Heightfield) -> float:
	return _wheel_support_raw(px, pz, heights.surface_at(px, pz, y), heights)


func _contact_mid(px: float, pz: float, heights: Heightfield) -> float:
	var fx := -sin(heading) * HUB
	var fz := -cos(heading) * HUB
	return (_wheel_support_y(px + fx, pz + fz, heights) + _wheel_support_y(px - fx, pz - fz, heights)) * 0.5


func _cross_grade(heights: Heightfield, ref_y: float) -> float:
	var side := Vector2(cos(heading), -sin(heading)) * 0.5
	var center := heights.surface_at(x, z, ref_y)
	var left := center - heights.surface_at(x - side.x, z - side.y, ref_y)
	var right := heights.surface_at(x + side.x, z + side.y, ref_y) - center
	# Для виража нужен уклон под линией езды по обе стороны центра.
	return signf(left) * minf(absf(left), absf(right)) * 2.0 if left * right > 0.0 else 0.0


## Главный шаг физики на такт (обычно 60 Гц).
func step(p: PlayerState, throttle: float, turn: float, boost: bool, hop: bool, dt: float, w: WorldData, heights: Heightfield) -> void:
	if dt <= 0.0 or crashed:
		return
	if dt > 1.0 / HZ + 0.001:
		var n := maxi(2, ceili(dt * HZ - 0.001))
		var sub := dt / float(n)
		for _i in n:
			step(p, throttle, turn, boost, hop and _i == 0, sub, w, heights)
		return
	tick_time = dt
	var cfg := config if config != null else BikePhysicsConfig.current()
	var prev_v := horizontal_velocity()
	var speed0 := speed
	use_f = 0.0
	use_r = 0.0
	grip_usage = 0.0

	if _fresh and not airborne:
		_prev_gf = _wheel_support_y(x - sin(heading) * HUB, z - cos(heading) * HUB, heights)
		_prev_gr = _wheel_support_y(x + sin(heading) * HUB, z + cos(heading) * HUB, heights)
		_support_y = 0.5 * (_prev_gf + _prev_gr)
		y = _support_y
		_support_grade = (_prev_gf - _prev_gr) / WHEELBASE
		grade_now = clampf(_support_grade, -1.5, 1.5)
		vy = _support_grade * speed
		tilt = atan(_support_grade)

	var grip := 0.88
	var contact := {}
	# Покрытие нужно только на земле. Один контакт используется для привода, руля и подвески.
	if not airborne:
		var pc := heights.path_contact(x, z) if heights.road_refinement != null else {}
		var surf := int(pc.get("surface", RoadSurface.NONE))
		var path_weight := smoothstep(0.05, 0.9, float(pc.get("weight", 0.0)))
		if heights.road_refinement == null:
			surf = PlayerState.surface(w.tile_info(x / GameConfig.TILE, z / GameConfig.TILE))
			path_weight = 1.0 if surf != RoadSurface.NONE else 0.0
		if surf != RoadSurface.NONE:
			grip = lerpf(grip, RoadSurface.LIST[surf].grip, path_weight)
		var bump: Vector4 = pc.bump if pc.has("bump") else RoadBump.surface_at(surf, w.template_id)
		contact = {weight = path_weight, across = pc.get("across", 0.0), bump = bump, bump_grade = pc.get("grade", absf(grade_now))}
		_ground_cross = _cross_grade(heights, y)
		bank_slope = lerpf(bank_slope, clampf(_ground_cross, -0.45, 0.45), Util.damp(10.0, dt))
		var terrain := maxf(0.15, PlayerState.terrain_speed(w, x, z, heights, pc))
		var water := lerpf(1.0, 0.4, smoothstep(0.05, 0.8, heights.immersion_at(x, z, y)))
		_step_speed(throttle, boost, _support_grade, terrain * water, dt, grip)
	else:
		_step_effort(0.0, dt)
		_brake_hold = 0.0
		reversing = false
		drive_force = 0.0
		drive_request = 0.0
		slope_force = 0.0
		roll_loss = 0.0
		brake_pressure = move_toward(brake_pressure, 0.0, cfg.brake_response * dt)
		brake_applied = 0.0
		brake_deceleration = 0.0
		brake_force = Vector2()
		brake_skid = 0.0
		braking = 0.0
		var v_air := Vector2(speed, lateral_speed)
		var keep := 1.0 / (1.0 + cfg.air_drag * v_air.length() * dt)
		air_loss = speed * (1.0 - keep) / dt
		speed *= keep
		lateral_speed *= keep

	# Руль и столкновения со стенами, стволами и водой.
	var previous_pose := Vector3(x, heading, z)
	_step_horizontal(turn, grip, dt, w, heights)
	if crashed:
		_sync(p)
		return

	# Опора, препятствия под колёсами и полёт.
	_step_vertical(hop, contact, dt, heights, previous_pose)
	if crashed:
		_sync(p)
		return

	# Крутой склон, по которому рама опускается носом вперёд.
	if not airborne and absf(speed) > 0.25 and _support_grade * signf(speed) < -cfg.cliff_grade:
		var n := Vector3(sin(heading) * _support_grade, 1.0, cos(heading) * _support_grade).normalized()
		_crash(minf(vy, -absf(speed) * absf(_support_grade)), n, CrashCause.FALL)
		_sync(p)
		return

	# Подвеска, поза и вращение колёс и педалей для модели и звука.
	_update_stance(dt, _support_grade, heights)
	wheel = wrapf(wheel + speed * dt / WHEEL_R, -PI, PI)
	if effort > 0.05 and not airborne:
		var spd := maxf(absf(speed), 1.5)
		gear = lerpf(gear, clampf(spd / (WHEEL_R * 7.5), 1.4, 4.5), Util.damp(2.5, dt))
		crank = wrapf(crank + maxf(2.5, absf(speed) / (WHEEL_R * maxf(gear, 1.0))) * dt, -PI, PI)
	acceleration = clampf((speed - speed0) / dt, -14.0, 14.0)
	_step_body_and_suspension(dt)
	var fwd := Vector2(-sin(heading), -cos(heading))
	feel_acceleration = clampf((horizontal_velocity() - prev_v).dot(fwd) / dt, -14.0, 14.0)
	_sync(p)


## Продольный расчёт скорости; вызывается напрямую и модульными тестами.
func _step_speed(throttle: float, boost: bool, slope: float, terrain := 1.0, dt := 1.0 / HZ, grip := 1.0) -> void:
	var cfg := config if config != null else BikePhysicsConfig.current()
	var n := maxi(1, ceili(dt * HZ))
	var sub := dt / float(n)
	for _i in n:
		_step_speed_sub(throttle, boost, slope, terrain, sub, grip, cfg)


func _step_speed_sub(throttle: float, boost: bool, slope: float, terrain: float, dt: float, grip: float, cfg: BikePhysicsConfig) -> void:
	var slope_a := -cfg.gravity * slope / sqrt(1.0 + slope * slope)
	slope_force = slope_a
	var roll_mag := cfg.roll_resistance / maxf(terrain, 0.35)
	var drag_mag := cfg.air_drag * speed * speed
	roll_loss = roll_mag
	air_loss = drag_mag
	rough_loss = 0.0

	# Смена направления с активного заднего хода на вперёд проходит через торможение до остановки
	if (reversing or speed < -0.15) and throttle > 0.0:
		brake_applied = cfg.brake_decel * throttle
		brake_deceleration = brake_applied
		var stop_decel := maxf(brake_applied + roll_mag + slope_a, 3.5)
		speed = move_toward(speed, 0.0, stop_decel * dt)
		drive_force = 0.0
		drive_request = 0.0
		_step_effort(0.0, dt)
		if speed >= -0.02:
			speed = 0.0
			reversing = false
		return

	# Торможение и задний ход
	if throttle < 0.0:
		_step_effort(0.0, dt)
		drive_force = 0.0
		drive_request = 0.0
		brake_pressure = move_toward(brake_pressure, -throttle, cfg.brake_response * dt)
		var eff_grip := clampf(grip * lerpf(0.75, 1.05, clampf(terrain, 0.30, 1.15)), 0.68, 1.08)
		var max_brake := cfg.brake_decel * eff_grip
		var brk := max_brake * brake_pressure

		if speed > 0.01:
			_brake_hold = 0.0
			reversing = false
			var prev_s := speed
			var net_stop := brk + roll_mag + drag_mag - slope_a
			if net_stop > 0.0:
				speed = maxf(0.0, speed - net_stop * dt)
			else:
				speed += (-net_stop) * dt
			brake_deceleration = brk
			brake_applied = maxf(0.0, (prev_s - speed) / dt - roll_mag - drag_mag)
			braking = clampf(brake_applied / maxf(cfg.brake_decel, 1.0), 0.0, 1.0) * smoothstep(0.3, 2.5, prev_s)
			brake_force = Vector2(brk * 0.65, brk * 0.35)
			use_f = clampf(brake_force.x / maxf(max_brake * 0.7, 1.0), 0.0, 1.0)
			use_r = clampf(brake_force.y / maxf(max_brake * 0.5, 1.0), 0.0, 1.0)
			brake_skid = smoothstep(0.75, 1.0, maxf(use_f, use_r)) * smoothstep(1.5, 6.0, prev_s)
			return

		# Пауза нужна при включении заднего хода с места, но не прерывает уже начатый ход.
		var can_reverse := absf(slope) <= cfg.reverse_max_grade
		reversing = can_reverse and (reversing or speed < -0.02 or _brake_hold + dt >= cfg.reverse_wait)
		brake_applied = 0.0
		brake_deceleration = 0.0
		brake_force = Vector2()
		brake_skid = 0.0
		braking = 0.0
		_brake_hold += dt
		if reversing:
			speed = move_toward(speed, -cfg.reverse_speed * absf(throttle), cfg.pedal_accel * dt)
		else:
			speed = move_toward(minf(speed, 0.0), 0.0, (brk + roll_mag) * dt)
		return

	# Газ или накат
	_brake_hold = 0.0
	reversing = false
	brake_pressure = move_toward(brake_pressure, 0.0, cfg.brake_response * 1.4 * dt)
	brake_applied = 0.0
	brake_deceleration = 0.0
	brake_force = Vector2()
	brake_skid = 0.0
	braking = 0.0
	_step_effort(throttle, dt)

	var power := surge if surge >= 0.0 else (1.0 if boost else 0.0)
	var active_boost := power > 0.0 and throttle > 0.05
	var top := cfg.cruise_speed * (lerpf(1.0, cfg.boost_mult, power) if active_boost else 1.0) * maxf(terrain, 0.55)
	var eq_resist := cfg.roll_resistance / maxf(terrain, 0.35) + cfg.air_drag * top * top
	var u := clampf(maxf(speed, 0.0) / maxf(top, 0.1), 0.0, 1.0)
	var base_push := lerpf(cfg.pedal_accel * cfg.start_push_mult, eq_resist, pow(u, cfg.pedal_taper))
	if speed > top:
		base_push = eq_resist * maxf(0.0, 1.0 - (speed - top) / 2.5)
	var climb_bonus := 0.0
	if slope > 0.0 and effort > 0.01:
		climb_bonus = cfg.climb_assist * cfg.gravity * (slope / sqrt(1.0 + slope * slope)) * (1.0 - smoothstep(0.30, 0.92, u))
	var surge_bonus := cfg.surge_push * power * (1.0 - 0.35 * u) if active_boost else 0.0
	drive_request = effort * (base_push + climb_bonus) + surge_bonus * effort
	drive_force = drive_request

	# Покой на месте без газования: на заметном спуске начинает разгон, на пологом и в подъём не катится само
	if absf(speed) < 0.02 and throttle <= 0.05 and effort <= 0.01:
		var downhill_roll := slope < 0.0 and slope_a > roll_mag + 0.35
		if not downhill_roll and absf(slope) <= cfg.stop_hold_grade:
			speed = 0.0
			return

	var prev := speed
	if throttle > 0.05:
		var resist := (roll_mag + drag_mag) * (-1.0 if speed < 0.0 else 1.0)
		speed += (drive_force + slope_a - resist) * dt
		if speed < 0.0 and slope <= 0.58:
			speed = 0.0
	elif speed >= 0.0:
		var accel := drive_force + slope_a - roll_mag - drag_mag
		speed += accel * dt
		if speed < 0.0 and absf(slope) <= cfg.stop_hold_grade:
			speed = 0.0
		if absf(prev) > 0.01 and absf(speed) < 0.02 and effort <= 0.01 and absf(slope) <= cfg.stop_hold_grade:
			speed = 0.0
	else:
		# Откат назад без тормоза (на крутом >40% склоне или после заднего хода)
		if absf(slope) <= cfg.stop_hold_grade:
			speed = move_toward(speed, 0.0, maxf(roll_mag + drag_mag - slope_a, 0.8) * dt)
		else:
			speed += (slope_a + roll_mag + drag_mag) * dt
		if speed > 0.0 and effort <= 0.01:
			speed = 0.0


func _step_effort(want: float, dt: float) -> void:
	if not effort_ramp:
		effort = want
		return
	var cfg := config if config != null else BikePhysicsConfig.current()
	var rate := cfg.effort_rise if want > effort else cfg.effort_fall
	effort = move_toward(effort, want, rate * dt) if absf(want - effort) < 0.05 else lerpf(effort, want, 1.0 - exp(-rate * dt))


## Прямой двухколесный поворот: переднее колесо ведёт курс, задняя ось следует на базе WHEELBASE; скольжение без залипания.
func _step_horizontal(turn: float, grip: float, dt: float, w: WorldData, heights: Heightfield) -> void:
	var cfg := config if config != null else BikePhysicsConfig.current()
	var turn_clamped := clampf(turn, -1.0, 1.0)
	var rate := cfg.steer_response
	if turn_clamped == 0.0:
		rate = cfg.steer_release
	elif steer * turn_clamped < 0.0:
		rate = cfg.steer_reverse_response
	steer = lerpf(steer, turn_clamped, Util.damp(rate, dt))
	# Короткое подруливание сразу меняет курс и положение вилки. Вес переносится в удерживаемом повороте.
	var pose_steer := absf(steer) if not airborne and turn_clamped != 0.0 else 0.0
	_sustained_steer = lerpf(_sustained_steer, pose_steer, Util.damp(cfg.turn_pose_response, dt))

	var fwd := Vector2(-sin(heading), -cos(heading))
	var right := Vector2(cos(heading), -sin(heading))
	var prev_heading := heading
	# Команда задаёт долю доступного угла. Тот же угол задаёт кривизну и положение колеса.
	var base_cap := cfg.max_lat_accel * clampf(grip, 0.55, 1.15)
	var bank_accel := bank_slope * cfg.gravity / sqrt(1.0 + bank_slope * bank_slope)
	var lat_cap := maxf(base_cap * cfg.bank_grip_floor, base_cap - signf(speed * steer) * bank_accel)
	var angle_limit := minf(cfg.max_steer_angle, atan(WHEELBASE * lat_cap / maxf(speed * speed, 0.5)))
	steer_angle = steer * angle_limit

	if airborne:
		yaw_rate = 0.0
		var vel_air := fwd * speed + right * lateral_speed
		var center := Vector2(x, z)
		var air_axle := fwd * (HUB * cos(tilt))
		var front := center + air_axle
		var rear := center - air_axle
		var front_next := _slide_point(front, vel_air * dt, vel_air, dt, w, heights)
		if crashed:
			return
		var rear_next := _slide_point(rear, front_next - front, vel_air, dt, w, heights)
		if crashed:
			return
		var next_pos := _slide_point(center, rear_next - rear, vel_air, dt, w, heights)
		if crashed:
			return
		x = next_pos.x
		z = next_pos.y
		_update_lean(0.0, cfg.lean_response * 0.5 * dt)
		slip = move_toward(slip, 0.0, 4.0 * dt)
		return

	# На земле только гасятся остатки боковой скорости после полёта или сдвига.
	lateral_speed = move_toward(lateral_speed, 0.0, cfg.drift_recover * dt)
	var wanted_yaw := -speed * tan(steer_angle) / WHEELBASE

	if absf(speed) > 0.002 or absf(lateral_speed) > 0.002:
		var center := Vector2(x, z)
		var old_p_f := center + fwd * HUB
		var old_p_r := center - fwd * HUB
		var step_v := fwd * speed + right * lateral_speed
		var half_turn := wanted_yaw * dt * 0.5
		var mid_heading := heading + half_turn
		var mid_fwd := Vector2(-sin(mid_heading), -cos(mid_heading))
		var mid_right := Vector2(cos(mid_heading), -sin(mid_heading))
		var next_heading := heading + 2.0 * half_turn
		var next_axle := Vector2(-sin(next_heading), -cos(next_heading)) * HUB
		var chord := sin(half_turn) / half_turn if absf(half_turn) > 0.001 else 1.0
		var want_r := old_p_r + (mid_fwd * (speed * chord) + mid_right * lateral_speed) * dt
		var want_f := want_r + next_axle * 2.0
		var front_step := want_f - old_p_f
		var rear_step := want_r - old_p_r
		var new_p_f := _slide_point(old_p_f, front_step, front_step / dt, dt, w, heights)
		if crashed:
			return
		var new_p_r := _slide_point(old_p_r, rear_step, rear_step / dt, dt, w, heights)
		if crashed:
			return
		var center_next := 0.5 * (new_p_f + new_p_r)
		var center_ok := _can_roll_to(center, center_next, w, heights)
		if new_p_f.distance_squared_to(want_f) > 0.000001 or new_p_r.distance_squared_to(want_r) > 0.000001:
			# После скольжения восстанавливаем жёсткую базу и проверяем получившиеся точки.
			var span := new_p_f - new_p_r
			if span.length_squared() > HUB * HUB:
				next_axle = span.normalized() * HUB
				next_heading = atan2(-span.x, -span.y)
				center_ok = center_ok and _can_roll_to(old_p_f, center_next + next_axle, w, heights) \
					and _can_roll_to(old_p_r, center_next - next_axle, w, heights)
			else:
				center_ok = false
		if not center_ok:
			center_next = _slide_point(center, step_v * dt, step_v, dt, w, heights)
			if crashed:
				return
			if not (_can_roll_to(old_p_f, center_next + fwd * HUB, w, heights) \
					and _can_roll_to(old_p_r, center_next - fwd * HUB, w, heights)):
				center_next = center
			next_heading = heading

		# Потолок туннелей и низы мостов
		if BikeRecovery.roof(heights, center_next.x, center_next.y, y) < y + BikeRecovery.CLEARANCE:
			if absf(speed) > cfg.wall_crash_speed:
				_crash(vy, Vector3(0, -1, 0), CrashCause.COLLISION)
				return
			speed *= 0.25
		else:
			x = center_next.x
			z = center_next.y
			heading = wrapf(next_heading, -PI, PI)

	yaw_rate = wrapf(heading - prev_heading, -PI, PI) / dt
	var lat_a := speed * yaw_rate
	use_f = clampf(maxf(use_f, absf(lat_a) / maxf(lat_cap, 1.0)), 0.0, 1.0)
	use_r = clampf(maxf(use_r, absf(lat_a) / maxf(lat_cap, 1.0)), 0.0, 1.0)
	grip_usage = maxf(use_f, use_r)
	slip = atan2(lateral_speed, maxf(absf(speed), 1.5))
	# Задевание края не превращает поправку рулём в глубокий крен.
	var turn_side := -signf(steer)
	var turn_accel := clampf(lat_a * turn_side, 0.0, absf(speed * wanted_yaw))
	var lean_share := cfg.lean_share * smoothstep(3.2, 8.5, absf(speed)) * turn_pose_weight()
	var lean_goal := turn_side * minf(atan(turn_accel / cfg.gravity) * lean_share, cfg.lean_max)
	_update_lean(lean_goal, cfg.lean_response * dt)


## Два последовательных перехода с одной скоростью: седок к целевому крену, рама за седоком.
func _update_lean(goal: float, response_step: float) -> void:
	var keep := exp(-response_step)
	lean = goal + (lean - goal + (rider_lean - goal) * response_step) * keep
	rider_lean = lerpf(goal, rider_lean, keep)


func _can_roll_to(from: Vector2, to: Vector2, w: WorldData, heights: Heightfield) -> bool:
	var climb := ForestObstacles.CLIMB_MAX
	if PlayerState.is_passable(w, heights, to.x, to.y, y, BODY_R, false, climb, airborne):
		return true
	return not PlayerState.is_passable(w, heights, from.x, from.y, y, BODY_R, false, climb, airborne) \
		and PlayerState.is_passable(w, heights, to.x, to.y, y, 0.0, false, climb, airborne)


func _slide_point(at: Vector2, disp: Vector2, vel: Vector2, dt: float, w: WorldData, heights: Heightfield) -> Vector2:
	var cfg := config if config != null else BikePhysicsConfig.current()
	var climb := ForestObstacles.CLIMB_MAX
	var dest := at + disp
	if PlayerState.is_passable(w, heights, dest.x, dest.y, y, BODY_R, false, climb, airborne):
		return dest
	var r := BODY_R if PlayerState.is_passable(w, heights, at.x, at.y, y, BODY_R, false, climb, airborne) else 0.0
	if r == 0.0 and PlayerState.is_passable(w, heights, dest.x, dest.y, y, 0.0, false, climb, airborne):
		return dest
	var hit_n := Vector2.ZERO
	if heights.obstacles != null:
		hit_n = heights.obstacles.normal(dest.x, dest.y, y, r, climb)
	var free_cb := func(px: float, pz: float) -> bool:
		return PlayerState.is_passable(w, heights, px, pz, y, r, false, climb, airborne)
	var around_cb := Callable()
	if heights.obstacles != null:
		around_cb = func(px: float, pz: float) -> Vector2:
			return heights.obstacles.normal(px, pz, y, r, climb)
	var res: PackedFloat64Array = PlayerState.slide(free_cb, at.x, at.y, disp.x, disp.y, around_cb)
	var slid := Vector2(res[0], res[1])
	if hit_n == Vector2.ZERO and disp.length_squared() > 0.000001:
		var blocked := dest - slid
		if blocked.length_squared() > 0.000001:
			hit_n = -blocked.normalized()
	if hit_n != Vector2.ZERO:
		var into := -vel.dot(hit_n)
		var cos_hit := into / maxf(vel.length(), 0.001)
		if into > cfg.wall_crash_speed and cos_hit > 0.55:
			_crash(vy, Vector3(hit_n.x, 0.0, hit_n.y), CrashCause.COLLISION)
			return at
		if into > 0.35:
			speed = move_toward(speed, 0.0, into * cos_hit * 2.4 * dt)
	return slid


## Вертикальная опора, переезд брёвен, прыжок на Space и аркадный баланс на Q/E в воздухе.
func _step_vertical(hop: bool, contact: Dictionary, dt: float, heights: Heightfield, previous_pose: Vector3) -> void:
	var cfg := config if config != null else BikePhysicsConfig.current()
	var fwd := Vector2(-sin(heading), -cos(heading))
	var half_span := HUB * cos(tilt) if airborne else HUB
	var axle := fwd * half_span
	var prev_grade := _support_grade
	var pitch_offset := sin(tilt) * HUB if airborne else prev_grade * HUB
	var raw_gf := heights.surface_at(x + axle.x, z + axle.y, y + pitch_offset)
	var raw_gr := heights.surface_at(x - axle.x, z - axle.y, y - pitch_offset)
	var sup_f := _wheel_support_raw(x + axle.x, z + axle.y, raw_gf, heights)
	var sup_r := _wheel_support_raw(x - axle.x, z - axle.y, raw_gr, heights)
	_hop_buf = cfg.hop_buffer if hop else maxf(0.0, _hop_buf - dt)
	_coyote = maxf(0.0, _coyote - dt) if airborne else cfg.hop_coyote
	var launch := false
	hop_preparing = _hop_buf > 0.0 and not airborne
	if (hop or _hop_buf > 0.0) and (not airborne or _coyote > 0.0) and not hop_used:
		var kick := vy + cfg.hop_pop if not airborne else maxf(vy, 0.0) + cfg.hop_pop
		var roof := _roof_over(x, z, heading, y, heights) - BikeRecovery.CLEARANCE
		_hop_buf = 0.0
		if roof > y + 0.02:
			_begin_flight(kick)
			hop_used = true
			hop_height = 0.0
			_hop_from = y
			_coyote = 0.0
			launch = true

	# Брёвна и перекатываемые кромки дают один удар на колесо при въезде.
	var has_obs := not airborne and heights.obstacles != null and not heights.obstacles.data.is_empty()
	var was_f := obstacle_f
	var was_r := obstacle_r
	var hit_f := heights.obstacles.wheel_contact(x + axle.x, z + axle.y, WHEEL_R, ForestObstacles.CLIMB_MAX, raw_gf) if has_obs and sup_f > raw_gf + 0.0001 else {}
	var hit_r := heights.obstacles.wheel_contact(x - axle.x, z - axle.y, WHEEL_R, ForestObstacles.CLIMB_MAX, raw_gr) if has_obs and sup_r > raw_gr + 0.0001 else {}
	obstacle_f = int(hit_f.get("id", -1)) if y + pitch_offset <= sup_f + 0.08 else -1
	obstacle_r = int(hit_r.get("id", -1)) if y - pitch_offset <= sup_r + 0.08 else -1

	if not airborne and obstacle_f >= 0 and obstacle_f != was_f:
		var rise := float(hit_f.get("rise", maxf(0.0, sup_f - raw_gf)))
		if rise > 0.04:
			wheel_impact.x = maxf(wheel_impact.x, clampf(rise * absf(speed) * 0.85, 0.4, 4.0))
			var normal: Vector2 = hit_f.get("normal", Vector2.ZERO)
			fork_side_impulse = normal.dot(Vector2(-fwd.y, fwd.x)) * wheel_impact.x
			impacts.x += 1
			if rise >= 0.28 and speed >= cfg.endo_obstacle_speed:
				_crash(vy, Vector3(0.0, 0.6, 0.0) - Vector3(fwd.x, 0.0, fwd.y) * 0.8, CrashCause.OBSTACLE)
				return
			elif rise > 0.14:
				var v2 := speed * speed - 2.0 * cfg.step_energy_k * rise
				if v2 <= 0.0:
					x = previous_pose.x
					heading = previous_pose.y
					z = previous_pose.z
					yaw_rate = 0.0
					speed = 0.0
					vy = 0.0
					obstacle_f = was_f
					obstacle_r = was_r
					return
				else:
					speed = signf(speed) * sqrt(v2)
					squash_fv = clampf(squash_fv + rise * 12.0, -4.0, 6.0)
	if not airborne and obstacle_r >= 0 and obstacle_r != was_r:
		var rise_r := float(hit_r.get("rise", maxf(0.0, sup_r - raw_gr)))
		if rise_r > 0.04:
			wheel_impact.y = maxf(wheel_impact.y, clampf(rise_r * absf(speed) * 0.85, 0.4, 4.0))
			impacts.y += 1
			squash_rv = clampf(squash_rv + rise_r * 10.0, -4.0, 6.0)

	var sup_y := 0.5 * (sup_f + sup_r)
	var support_grade := clampf((sup_f - sup_r) / (half_span * 2.0), -4.0, 4.0)
	if not airborne:
		var ballistic_y := y - _landing_lift + (vy - 0.5 * cfg.gravity * dt) * dt
		var one_wheel_y := maxf(sup_f - pitch_offset, sup_r + pitch_offset)
		var overhang := one_wheel_y - sup_y > cfg.micro_step_absorb and ballistic_y > sup_y + cfg.micro_step_absorb
		if not _fresh and _landing_lift <= 0.005 and ballistic_y > one_wheel_y + cfg.ground_reach:
			_begin_flight(vy)
			launch = true
		else:
			var support := one_wheel_y if overhang else sup_y
			_support_grade = prev_grade if overhang else support_grade
			var tangent_vy := _support_grade * speed + _ground_cross * (lateral_speed - yaw_rate * HUB)
			var supported := _fresh or _landing_lift > 0.005 or ballistic_y <= support
			if supported:
				var travel_vy := (support - _support_y) / dt
				var target_vy := clampf(tangent_vy, minf(0.0, travel_vy), maxf(0.0, travel_vy))
				vy = move_toward(vy, target_vy, cfg.gravity * 3.0 * dt)
			else:
				# Пока ход подвески достаёт до опоры, колёса продолжают держать дорогу.
				vy -= cfg.gravity * dt
			_support_y = support
			grade_now = clampf(_support_grade, -1.5, 1.5)
			var settle := Util.damp(cfg.landing_settle_response, dt)
			tilt = lerpf(tilt, atan(_support_grade), settle)
			pitch_vel = 0.0
			_landing_lift *= 1.0 - settle
			var old_extension := ground_extension
			var clearance := 0.0 if supported else maxf(0.0, ballistic_y - support)
			ground_extension = clearance * smoothstep(cfg.micro_step_absorb * 0.5, cfg.ground_reach, clearance)
			var settled_y := support + _landing_lift
			y = settled_y + clearance
			var pose_f := pitch_offset if overhang else (sup_f - sup_y + _landing_lift * signf(tilt - atan(support_grade)))
			lift_f = maxf(0.0, settled_y + pose_f - sup_f)
			lift_r = maxf(0.0, settled_y - pose_f - sup_r)
			var gf_vis := sup_f + _sample_bump(x + axle.x, z + axle.y, contact, heights)
			var gr_vis := sup_r + _sample_bump(x - axle.x, z - axle.y, contact, heights)
			_ground_suspension(gf_vis, gr_vis, tangent_vy * dt + old_extension - ground_extension)
			ground_f = gf_vis - y + lift_f
			ground_r = gr_vis - y + lift_r
			return

	_step_flight(dt, sup_f, sup_r, support_grade, heights, launch)


func _step_flight(dt: float, front_y: float, rear_y: float, support_grade: float, heights: Heightfield, launch: bool) -> void:
	var cfg := config
	var sup_y := 0.5 * (front_y + rear_y)
	var prev_clearance := air_clearance
	var next_y := y + vy * dt - 0.5 * cfg.gravity * dt * dt
	if next_y > y:
		var roof := _roof_over(x, z, heading, y, heights) - BikeRecovery.CLEARANCE
		if next_y > roof:
			next_y = maxf(y, roof)
			vy = 0.0
	y = next_y
	vy -= cfg.gravity * dt
	air_time += dt
	if hop_used:
		hop_height = maxf(hop_height, y - _hop_from)

	# Q (body_back) поднимает нос вверх (+tilt), E (body_forward) опускает нос вниз (-tilt)
	var pitch_in := float(int(body_back) - int(body_forward))
	var pitch_accel := cfg.air_pitch_accel * (3.0 if pitch_in == 0.0 else 1.0)
	pitch_vel = move_toward(pitch_vel, pitch_in * cfg.air_pitch_rate, pitch_accel * dt)
	var prev_tilt := tilt
	tilt = clampf(tilt + pitch_vel * dt, -cfg.air_pitch_limit, cfg.air_pitch_limit)
	pitch_vel = (tilt - prev_tilt) / dt

	_support_grade = support_grade
	grade_now = clampf(support_grade, -1.5, 1.5)
	ground_f = sin(tilt) * HUB
	ground_r = -ground_f
	var touch_y := maxf(front_y - ground_f, rear_y - ground_r)
	lift_f = maxf(0.0, y + ground_f - front_y)
	lift_r = maxf(0.0, y + ground_r - rear_y)
	air_clearance = maxf(0.0, y - touch_y)
	clearance_closing_speed = maxf(0.0, (prev_clearance - air_clearance) / dt) if air_time > dt else 0.0
	if not launch and y <= touch_y:
		var cross := _cross_grade(heights, sup_y)
		if vy <= support_grade * speed + cross * lateral_speed + absf(pitch_vel) * HUB + 0.25:
			_land(sup_y, support_grade, dt, heights, cfg, touch_y, cross)


func _begin_flight(vertical_speed: float) -> void:
	if not airborne:
		lateral_speed -= yaw_rate * HUB
	airborne = true
	vy = vertical_speed
	air_time = 0.0
	_landing_lift = 0.0
	ground_extension = 0.0
	pitch_vel = 0.0


func _ground_suspension(front: float, rear: float, travel_y: float) -> void:
	if not _fresh:
		# Колесо сразу поднимается на кромку, рама догоняет его через подвеску.
		var travel := config.micro_step_absorb
		squash_f = clampf(squash_f + clampf(front - _prev_gf - travel_y, -travel, travel), -config.stretch_max, maxf(squash_f, travel))
		squash_r = clampf(squash_r + clampf(rear - _prev_gr - travel_y, -travel, travel), -config.stretch_max, maxf(squash_r, travel))
	_fresh = false
	_prev_gf = front
	_prev_gr = rear


func _land(sup_y: float, support_grade: float, _dt: float, heights: Heightfield, cfg: BikePhysicsConfig, touch_y := -INF, cross_grade := NAN) -> void:
	var slope_angle := atan(support_grade)
	var pitch_err := absf(tilt - slope_angle)
	var fwd := Vector2(-sin(heading), -cos(heading))
	var right := Vector2(cos(heading), -sin(heading))
	var cross := cross_grade if is_finite(cross_grade) else _cross_grade(heights, sup_y)
	var normal := Vector3(-(fwd.x * support_grade + right.x * cross), 1.0, -(fwd.y * support_grade + right.y * cross)).normalized()
	var vel := horizontal_velocity()
	var vel3 := Vector3(vel.x, vy, vel.y)
	var impact := maxf(0.0, -vel3.dot(normal))

	landing_info = {air = air_time, impact = impact, speed = speed, vy = vy, pitch_error = tilt - slope_angle, hop = hop_used, hop_height = hop_height if hop_used else 0.0}
	if air_time >= 0.06 or impact > 1.5:
		land_impact = impact
	_landing_lift = maxf(0.0, touch_y - sup_y)
	ground_extension = 0.0
	y = sup_y + _landing_lift
	airborne = false
	_fresh = false
	_support_y = sup_y
	_support_grade = support_grade

	# Оценка угла и силы удара приземления
	if impact > cfg.crash_impact or (air_time > 0.28 and absf(speed) > 4.5 and pitch_err > cfg.landing_crash_angle):
		var cause := CrashCause.OBSTACLE if (tilt < slope_angle - cfg.landing_crash_angle and impact <= cfg.crash_impact) else CrashCause.FALL
		_crash(vy, normal, cause)
		speed = 0.0
		lateral_speed = 0.0
	elif pitch_err > cfg.landing_clean_angle:
		var bad_t := smoothstep(cfg.landing_clean_angle, cfg.landing_crash_angle, pitch_err)
		speed *= lerpf(1.0, 0.62, bad_t)
		lateral_speed *= lerpf(1.0, 0.7, bad_t)
	if not crashed:
		speed = move_toward(speed, 0.0, maxf(0.0, impact - cfg.soft_impact) * 0.45)
		var bias := clampf((tilt - slope_angle) / maxf(cfg.landing_clean_angle, 0.001), -1.0, 1.0) * 0.6
		var stroke := impact * cfg.landing_compression
		squash_fv = clampf(stroke * (1.0 - bias), 0.0, 6.0)
		squash_rv = clampf(stroke * (1.0 + bias), 0.0, 6.0)

	vy = support_grade * speed
	if is_finite(touch_y):
		var terrain_offset := sin(slope_angle) * HUB
		lift_f = maxf(0.0, y + ground_f - (sup_y + terrain_offset))
		lift_r = maxf(0.0, y + ground_r - (sup_y - terrain_offset))
	_prev_gf = sup_y + support_grade * HUB
	_prev_gr = sup_y - support_grade * HUB
	yaw_rate = 0.0
	pitch_vel = 0.0
	air_time = 0.0
	air_clearance = 0.0
	clearance_closing_speed = 0.0
	_coyote = cfg.hop_coyote
	hop_used = false


func _sample_bump(px: float, pz: float, contact: Dictionary, heights: Heightfield) -> float:
	var template_id := heights.world.template_id
	var origin := Vector2(heights.world.world_origin) * GameConfig.TILE
	var world_x := px + origin.x
	var world_z := pz + origin.y
	var road_h := RoadBump.height_params(world_x, world_z, contact.bump, contact.bump_grade, contact.across, RoadBump.rut_params(template_id))
	var off_h := sin(world_x * 0.83 + world_z * 1.13) * 0.015
	var obstacle_h := heights.obstacles.bump_at(px, pz) if heights.obstacles != null and not heights.obstacles.bumps.is_empty() else 0.0
	return lerpf(off_h, road_h, contact.weight) + obstacle_h


func _step_body_and_suspension(dt: float) -> void:
	var cfg := config if config != null else BikePhysicsConfig.current()
	var body_goal := float(int(body_back) - int(body_forward)) * 0.85
	var prev_body := body_x
	body_x = move_toward(body_x, body_goal, 14.0 * dt) if absf(body_goal - body_x) < 0.05 else lerpf(body_x, body_goal, Util.damp(14.0, dt))
	body_v = (body_x - prev_body) / dt

	if airborne:
		squash_f = lerpf(squash_f, 0.0, Util.damp(10.0, dt))
		squash_r = lerpf(squash_r, 0.0, Util.damp(10.0, dt))
		squash_fv = move_toward(squash_fv, 0.0, 20.0 * dt)
		squash_rv = move_toward(squash_rv, 0.0, 20.0 * dt)
		squash_fv_avg = absf(squash_fv)
		squash_rv_avg = absf(squash_rv)
		squash = 0.0
		load_f = 0.5
		load_r = 0.5
		tire_f = 0.5
		tire_r = 0.5
		side_f = 0.5
		side_r = 0.5
		return

	# Простые затухающие пружины вилки и задней подвески для ощущения дороги
	var contact_accel := acceleration - slope_force
	var rest := clampf(contact_accel * -0.004, -0.04, 0.04)
	var af := -cfg.spring_k * (squash_f - rest) - cfg.spring_damp * squash_fv
	var ar := -cfg.spring_k * (squash_r + rest * 0.45) - cfg.spring_damp * squash_rv
	squash_fv += af * dt
	squash_rv += ar * dt
	squash_f = clampf(squash_f + squash_fv * dt, -cfg.stretch_max, cfg.sag_max)
	squash_r = clampf(squash_r + squash_rv * dt, -cfg.stretch_max, cfg.sag_max)
	if squash_f >= cfg.sag_max and squash_fv > cfg.bottom_out_speed:
		bottom_out = maxf(bottom_out, squash_fv)
	if squash_f >= cfg.sag_max or squash_f <= -cfg.stretch_max:
		squash_fv = 0.0
	if squash_r >= cfg.sag_max or squash_r <= -cfg.stretch_max:
		squash_rv = 0.0
	squash_fv_avg = absf(squash_fv)
	squash_rv_avg = absf(squash_rv)
	squash = 0.5 * (squash_f + squash_r)

	var shift := clampf(-contact_accel * 0.025 - body_x * 0.12 + (lift_r - lift_f), -0.25, 0.25)
	load_f = clampf(0.5 + shift, 0.15, 0.85)
	load_r = 1.0 - load_f
	tire_f = load_f
	tire_r = load_r
	side_f = load_f
	side_r = load_r
	instability = lerpf(instability, clampf(absf(slip) * 1.4, 0.0, 0.8), Util.damp(8.0, dt))


func _update_stance(dt: float, slope: float, heights: Heightfield) -> void:
	stance_driven = true
	if airborne or not riding or crashed:
		stance = Stance.RIDING
		_stop_timer = 0.0
		return
	var cfg := config if config != null else BikePhysicsConfig.current()
	if absf(speed) < 0.25 and effort < 0.05 and not reversing and absf(lean) < 0.15 and absf(slope) <= cfg.stop_hold_grade:
		_stop_timer += dt
		if stance != Stance.FOOT_DOWN:
			foot_side = (1.0 if _ground_cross > 0.0 else -1.0) if absf(_ground_cross) > 0.03 else (1.0 if lean < -0.01 else -1.0)
		var support := foot_probe(foot_side)
		support.y = clampf(heights.surface_at(support.x, support.z, y), y - 0.35, y + 0.22)
		foot_support = support
		stance = Stance.FOOT_DOWN if _stop_timer >= cfg.stop_settle_time else Stance.TRACKSTAND
	else:
		_stop_timer = 0.0
		stance = Stance.RIDING


func foot_probe(side: float) -> Vector3:
	var lateral := side * config.stop_foot_offset
	var sin_h := sin(heading)
	var cos_h := cos(heading)
	return Vector3(x + cos_h * lateral - sin_h * STOP_FOOT_FORWARD, y, z - sin_h * lateral - cos_h * STOP_FOOT_FORWARD)


func fits(px: float, pz: float, hd: float, w: WorldData, heights: Heightfield, allow_climb := true) -> bool:
	var climb := ForestObstacles.CLIMB_MAX if allow_climb else 0.0
	var fx := -sin(hd) * AXLE
	var fz := -cos(hd) * AXLE
	return (PlayerState.is_passable(w, heights, px, pz, y, BODY_R, false, climb, airborne)
		and PlayerState.is_passable(w, heights, px + fx, pz + fz, y, BODY_R, false, climb, airborne)
		and PlayerState.is_passable(w, heights, px - fx, pz - fz, y, BODY_R, false, climb, airborne)
		and _roof_over(px, pz, hd, y, heights) >= y + BikeRecovery.CLEARANCE)


func _roof_over(px: float, pz: float, hd: float, feet: float, heights: Heightfield) -> float:
	var fx := -sin(hd) * AXLE
	var fz := -cos(hd) * AXLE
	return minf(BikeRecovery.roof(heights, px, pz, feet),
		minf(BikeRecovery.roof(heights, px + fx, pz + fz, feet), BikeRecovery.roof(heights, px - fx, pz - fz, feet)))


func _crash(v_up: float, normal := Vector3.UP, cause := CrashCause.FALL) -> void:
	if crashed:
		return
	crash_info = {speed = speed, lateral_speed = lateral_speed, vy = v_up, load_f = load_f, load_r = load_r, pitch_error = tilt - atan(grade_now)}
	crashed = true
	crash_cause = cause
	crash_normal = normal.normalized() if normal.length_squared() > 0.000001 else Vector3.UP
	var v := horizontal_velocity()
	crash_velocity = Vector3(v.x, v_up, v.y)


func _sync(p: PlayerState) -> void:
	p.x = x
	p.z = z
	p.feet = y
	var v := horizontal_velocity()
	p.vx = v.x
	p.vz = v.y
	p.vy = vy
	p.on_ground = not airborne
