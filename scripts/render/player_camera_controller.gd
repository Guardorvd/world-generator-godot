class_name PlayerCameraController
extends RefCounted
## Camera state belongs to one player; no references to GameWorld or UI nodes.
const CAM_STEPS := 15
## Настройки камеры (скорости сглаживания — 1/с, через Util.damp; расстояния — м).
const RIDE_HEIGHT := 1.4        # камера на велосипеде смотрит на точку выше колёс на столько
const RIDE_HEIGHT_RESPONSE := 10.0 # и следит за её высотой так быстро
const RIDE_HEIGHT_LAG := 2.0    # дальше этого по высоте не отстаёт
const RIDE_SQUASH := 0.25       # доля хода подвески, которую повторяет камера
const RUSH_DIST := 0.7          # на полной скорости камера отходит дальше на столько
const RUSH_RESPONSE := 2.5      # как быстро нарастает ощущение скорости
const CAM_MIN_DIST := 1.2       # ближе к седоку камера не подходит, даже у стены
const CAM_STEP := 0.3           # шаг проверки препятствий между седоком и камерой
const CAM_PROBE_GAP := 0.3
const CAM_WALL_RADIUS := 0.25
const CAM_CLOSE := 22.0        # как быстро камера подходит ближе при небольшом препятствии
const CAM_SNAP := 0.45          # а если надо подойти ближе, чем на столько, — сразу (стена)
const CAM_RETURN := 3.0         # как быстро камера отходит обратно после стены
const CAM_GROUND_GAP := 0.4     # камера не ниже земли плюс это
const CAM_CEILING_GAP := 0.3    # и не выше потолка (туннель) минус это
const BRAKE_RESPONSE := 6.0     # 30.10: торможение видно: камера подходит, опускается и сужает обзор
const BRAKE_DIST := 1.1         # м ближе при полном торможении
const BRAKE_DIP := 0.3          # м ниже
const BRAKE_FOV := 6.0          # градусов уже
const FOV_RESPONSE := 4.0       # смена угла обзора
const FOV_RESPONSE_PHOTO := 9.0 # и в видоискателе
const BOB_RESPONSE := 8.0       # нарастание и затихание покачивания шага
const BOB_AMP := 0.05           # покачивание шага, м
const BOB_PHOTO := 0.3          # доля покачивания в видоискателе
const DIP_SPRING := 120.0       # пружина проседания при приземлении, 1/с²
const DIP_DAMP := 24.0          # её затухание, 1/с
const DIP_MIN := -0.6           # пределы проседания, м
const DIP_MAX := 0.2
const SEAT_DROP := 0.55        # сидя на лавке глаза ниже, чем стоя, м
const SEAT_RATE := 1.4          # и опускаются и встают за доли секунды, м/с
const TRAUMA_GAIN := 0.08       # тряска на 1 м/с удара сверх мягкого
const TRAUMA_DECAY := 1.6       # затухание тряски, доля в секунду
const FOV_KICK_DECAY := 10.0    # 20.11: 1/с, толчок обзора при падении гаснет за ~0,3 с
var settings: GameSettings
var heights: Heightfield
var yaw := 0.0       # смотрим на север, на костёр
var pitch := -0.05
var _cam_y := 0.0       # высота, за которой следит камера на велосипеде: мягко, чтобы не дёргало на приземлении
var _cam_dist := GameConfig.BIKE_CAM  # расстояние до седока: короче, если сзади склон
var _bob_amp := 0.0     # сила покачивания при ходьбе: нарастает и стихает плавно
var _dip := 0.0         # проседание камеры при приземлении, м (пружина)
var _dip_v := 0.0
var seated := false     # игрок сидит на лавке (GameWorld): камера опускается на SEAT_DROP
var _seat_drop := 0.0
var _fov_kick := 0.0    # 20.11: толчок обзора при падении, градусы; гаснет сам по кадрам (update)
var _fov_kick_shown := 0.0 # какая доля толчка сейчас в camera.fov: плавное следование идёт без неё
var _trauma := 0.0      # тряска камеры 0..1 после жёстких приземлений, затухает сама
var _speed_rush := 0.0
var _brake_feel := 0.0  # 30.10: торможение 0..1 по фактическому замедлению тормозом (не подъёму): камера ближе, ниже и уже (нос «клюёт»)
var _prev := Vector3()  # игрок (x, ноги, z) на предпоследнем такте: кадр показывает его между тактами
var _prev_bob := 0.0
var _prev_dip := 0.0    # проседание и время на предпоследнем такте: кадр показывает их между тактами
var _prev_time := 0.0
var _tick_yaw := 0.0    # насколько последний такт повернул камеру сам (вслед за велосипедом);
var _tick_pitch := 0.0  # кадр доворачивает этот поворот плавно, а мышь — сразу

func _cam_blocked(p: Vector3, feet: float) -> bool:
	if p.y < heights.surface_at(p.x, p.z, p.y) + CAM_PROBE_GAP:
		return true
	if p.y > heights.ceiling_at(p.x, p.z, feet) - CAM_PROBE_GAP:
		return true # свод туннеля, в котором едет седок
	# перила и стены: на высоте глаз (чуть выше ног) стена на пути камеры закрывает обзор;
	# камера держится в 0,25 м от них, чтобы ближняя плоскость отсечения не заглядывала за стену
	return heights.wall_at(p.x, p.z, p.y - 1.0, CAM_WALL_RADIUS)


func _obstruction_distance(target: Vector3, dir: Vector3, desired: float, feet: float) -> float:
	var steps := maxi(CAM_STEPS, ceili(desired / CAM_STEP))
	var hit := heights.native_camera_ray_hit(target, dir, desired, steps, feet, CAM_PROBE_GAP, CAM_WALL_RADIUS)
	if hit == -1:
		for k in range(1, steps + 1):
			if _cam_blocked(target - dir * (desired * k / steps), feet):
				hit = k
				break
	return maxf(CAM_MIN_DIST, desired * (hit - 1) / steps) if hit >= 1 and hit <= steps else desired


func update(alpha: float, dt: float, player: PlayerState, bike: BikeRide,
		camera: Camera3D, time: float, _opening: bool, _moving: bool,
		crash_active: bool, photo_active: bool, photo_fov: float, view_squash: float,
		bike_frame_y := NAN) -> void:
	var riding := bike != null and bike.riding
	var pos := _prev.lerp(Vector3(player.x, player.feet, player.z), alpha)
	# поворот, который сделал сам такт, доворачивается плавно; мышь уже учтена в yaw и pitch
	var view_yaw := yaw - _tick_yaw * (1.0 - alpha)
	var view_pitch := pitch - _tick_pitch * (1.0 - alpha)
	var rush_goal := 0.0
	if riding and not crash_active and not _opening:
		rush_goal = smoothstep(7.0, 20.0, absf(bike.speed))
		rush_goal += smoothstep(1.0, 5.0, bike.feel_acceleration) * smoothstep(8.0, 18.0, absf(bike.speed)) * 0.2
	_speed_rush = lerpf(_speed_rush, minf(rush_goal, 1.0), _smooth(RUSH_RESPONSE, dt))
	var brake_goal := clampf(bike.brake_applied / 7.0, 0.0, 1.0) * smoothstep(1.0, 4.0, absf(bike.speed)) if riding and not crash_active and not _opening else 0.0
	_brake_feel = lerpf(_brake_feel, brake_goal, _smooth(BRAKE_RESPONSE, dt))
	# на скорости обзор чуть шире: на бегу немного, на велосипеде сильнее
	var fov_goal := settings.fov
	if riding:
		var cruise := BikePhysicsConfig.current().cruise_speed
		fov_goal += GameConfig.BIKE_FOV * clampf((absf(bike.speed) - 2.0) / (cruise - 2.0), 0.0, 1.3) - BRAKE_FOV * _brake_feel
	else:
		fov_goal += GameConfig.RUN_FOV * clampf((player.ground_speed() - GameConfig.WALK * 1.1) / (GameConfig.WALK * 0.6), 0.0, 1.0)
	if photo_active:
		fov_goal = photo_fov
	if _fov_kick != 0.0:
		_fov_kick = _fov_kick * exp(-FOV_KICK_DECAY * dt) if _fov_kick > 0.02 else 0.0
	var kick := _fov_kick if settings.head_bob and not photo_active else 0.0
	camera.fov = lerpf(camera.fov - _fov_kick_shown, fov_goal, _smooth(FOV_RESPONSE_PHOTO if photo_active else FOV_RESPONSE, dt)) + kick
	_fov_kick_shown = kick
	var shake := _trauma * _trauma if settings.head_bob else 0.0
	var t := lerpf(_prev_time, time, alpha)
	var jolt := Vector3(sin(t * 41.0), sin(t * 37.0 + 1.7), sin(t * 29.0 + 3.1)) * shake
	var dip := lerpf(_prev_dip, _dip, alpha) if settings.head_bob else 0.0
	if riding:
		# от третьего лица: камера сзади на луче взгляда; если между ней и седоком склон — подходит ближе
		var base_y := bike_frame_y if is_finite(bike_frame_y) else pos.y
		var suspension := (view_squash * (1.0 - RIDE_SQUASH) if settings.head_bob else view_squash) if is_finite(bike_frame_y) else (-view_squash * RIDE_SQUASH if settings.head_bob else 0.0)
		_cam_y = lerpf(_cam_y, base_y + RIDE_HEIGHT + suspension, _smooth(RIDE_HEIGHT_RESPONSE, dt))
		if absf(_cam_y - base_y - RIDE_HEIGHT) > RIDE_HEIGHT_LAG:
			_cam_y = base_y + RIDE_HEIGHT + clampf(_cam_y - base_y - RIDE_HEIGHT, -RIDE_HEIGHT_LAG, RIDE_HEIGHT_LAG)
		var target := Vector3(pos.x, _cam_y + dip - BRAKE_DIP * _brake_feel, pos.z)
		var dir := Vector3(-sin(view_yaw) * cos(view_pitch), sin(view_pitch), -cos(view_yaw) * cos(view_pitch))
		var desired_dist := GameConfig.BIKE_CAM + _speed_rush * RUSH_DIST - BRAKE_DIST * _brake_feel
		var dist := _obstruction_distance(target, dir, desired_dist, pos.y)
		# ближе — сразу, дальше — плавно, чтобы камера не прыгала за каждым бугром
		# малое сближение (бугор, куст у луча) — быстро, но плавно: камера не дёргается; у стены — сразу
		if dist >= _cam_dist:
			_cam_dist = lerpf(_cam_dist, dist, _smooth(CAM_RETURN, dt))
		elif _cam_dist - dist > CAM_SNAP:
			_cam_dist = dist
		else:
			_cam_dist = lerpf(_cam_dist, dist, _smooth(CAM_CLOSE, dt))
		var cam := target - dir * _cam_dist + jolt * 0.12
		# не ниже земли и настила моста, под которым камера окажется в стене или в воздухе
		cam.y = maxf(cam.y, heights.surface_at(cam.x, cam.z, cam.y) + CAM_GROUND_GAP)
		# в туннеле — не выше свода
		cam.y = minf(cam.y, heights.ceiling_at(cam.x, cam.z, pos.y) - CAM_CEILING_GAP)
		camera.look_at_from_position(cam, target, Vector3.UP)
		return
	_bob_amp = lerpf(_bob_amp, 1.0 if _moving and player.on_ground and settings.head_bob else 0.0, _smooth(BOB_RESPONSE, dt))
	var stride := clampf(player.ground_speed() / GameConfig.WALK, 0.0, 1.6)
	var bob := sin(lerpf(_prev_bob, player.bob, alpha)) * BOB_AMP * stride * _bob_amp * (BOB_PHOTO if photo_active else 1.0)
	camera.position = Vector3(pos.x, pos.y + GameConfig.EYE + bob + dip - _seat_drop, pos.z)
	camera.rotation = Vector3(view_pitch + jolt.x * 0.03, view_yaw + jolt.y * 0.02, jolt.z * 0.03)



## 20.11: резкий короткий толчок обзора (падение): мгновенно шире на degrees, возвращается за ~0,3 с
func kick_fov(degrees: float) -> void:
	_fov_kick = degrees

func shake_on_landing(impact: float, soft: float) -> void:
	if impact > soft:
		_trauma = minf(1.0, _trauma + (impact - soft) * TRAUMA_GAIN)

static func _smooth(rate: float, dt: float) -> float:
	return Util.damp(rate, dt)

func store_previous(player: PlayerState, time: float) -> void:
	_prev = Vector3(player.x, player.feet, player.z)
	_prev_bob = player.bob
	_prev_dip = _dip
	_prev_time = time

func tick_effects(dt: float) -> void:
	_dip_v += (-DIP_SPRING * _dip - DIP_DAMP * _dip_v) * dt
	_dip = clampf(_dip + _dip_v * dt, DIP_MIN, DIP_MAX)
	_trauma = maxf(0.0, _trauma - dt * TRAUMA_DECAY)
	_seat_drop = move_toward(_seat_drop, SEAT_DROP if seated else 0.0, SEAT_RATE * dt)
