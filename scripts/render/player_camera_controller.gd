class_name PlayerCameraController
extends RefCounted
## Camera state belongs to one player; no references to GameWorld or UI nodes.
const CAM_STEPS := 15
var settings: GameSettings
var heights: Heightfield
var yaw := 0.0       # смотрим на север, на костёр
var pitch := -0.05
var _looked_at := 0.0   # время последнего движения мыши, чтобы камера на велосипеде не спорила с ней
var _cam_y := 0.0       # высота, за которой следит камера на велосипеде: мягко, чтобы не дёргало на приземлении
var _cam_dist := GameConfig.BIKE_CAM  # расстояние до седока: короче, если сзади склон
var _bob_amp := 0.0     # сила покачивания при ходьбе: нарастает и стихает плавно
var _dip := 0.0         # проседание камеры при приземлении, м (пружина)
var _dip_v := 0.0
var _trauma := 0.0      # тряска камеры 0..1 после жёстких приземлений, затухает сама
var _cam_lead := 0.0    # 12.7: доворот камеры внутрь поворота, рад (только пока мышь не трогали)
var _speed_rush := 0.0
var _prev := Vector3()  # игрок (x, ноги, z) на предпоследнем такте: кадр показывает его между тактами
var _prev_bob := 0.0
var _prev_dip := 0.0    # проседание и время на предпоследнем такте: кадр показывает их между тактами
var _prev_time := 0.0
var _tick_yaw := 0.0    # насколько последний такт повернул камеру сам (вслед за велосипедом);
var _tick_pitch := 0.0  # кадр доворачивает этот поворот плавно, а мышь — сразу

func _cam_blocked(p: Vector3, feet: float) -> bool:
	if p.y < heights.surface_at(p.x, p.z, p.y) + 0.3:
		return true
	if p.y > heights.ceiling_at(p.x, p.z, feet) - 0.3:
		return true # свод туннеля, в котором едет седок
	# перила и стены: на высоте глаз (чуть выше ног) стена на пути камеры закрывает обзор;
	# камера держится в 0,25 м от них, чтобы ближняя плоскость отсечения не заглядывала за стену
	return heights.wall_at(p.x, p.z, p.y - 1.0, 0.25)


func update(alpha: float, dt: float, player: PlayerState, bike: BikeRide,
		camera: Camera3D, time: float, _opening: bool, _moving: bool,
		crash_active: bool, photo_active: bool, photo_fov: float, view_squash: float) -> void:
	var riding := bike != null and bike.riding
	var pos := _prev.lerp(Vector3(player.x, player.feet, player.z), alpha)
	# поворот, который сделал сам такт, доворачивается плавно; мышь уже учтена в yaw и pitch
	var view_yaw := yaw - _tick_yaw * (1.0 - alpha)
	var view_pitch := pitch - _tick_pitch * (1.0 - alpha)
	# 12.7: на скорости камера заглядывает внутрь поворота, куда повёрнут руль; мышь её не трогает
	var lead_goal := 0.0
	if riding and not crash_active and not _opening:
		lead_goal = -bike.steer * deg_to_rad(8.5) * smoothstep(3.0, 12.0, bike.speed) * auto_follow(time)
	_cam_lead = lerpf(_cam_lead, lead_goal, _smooth(4.0, dt))
	if riding:
		view_yaw += _cam_lead
	var rush_goal := 0.0
	if riding and not crash_active and not _opening:
		rush_goal = smoothstep(12.0, 26.0, absf(bike.speed))
		rush_goal += smoothstep(1.0, 5.0, bike.acceleration) * smoothstep(8.0, 18.0, absf(bike.speed)) * 0.2
	_speed_rush = lerpf(_speed_rush, minf(rush_goal, 1.0), _smooth(2.5, dt))
	# на скорости обзор чуть шире: на бегу немного, на велосипеде сильнее
	var fov_goal := settings.fov
	if riding:
		fov_goal += GameConfig.BIKE_FOV * clampf((absf(bike.speed) - 2.0) / (GameConfig.BIKE_SPEED - 2.0), 0.0, 1.3)
	else:
		fov_goal += GameConfig.RUN_FOV * clampf((player.ground_speed() - GameConfig.WALK * 1.1) / (GameConfig.WALK * 0.6), 0.0, 1.0)
	if photo_active:
		fov_goal = photo_fov
	camera.fov = lerpf(camera.fov, fov_goal, _smooth(9.0 if photo_active else 4.0, dt))
	var shake := _trauma * _trauma if settings.head_bob else 0.0
	var t := lerpf(_prev_time, time, alpha)
	var jolt := Vector3(sin(t * 41.0), sin(t * 37.0 + 1.7), sin(t * 29.0 + 3.1)) * shake
	var dip := lerpf(_prev_dip, _dip, alpha) if settings.head_bob else 0.0
	if riding:
		# от третьего лица: камера сзади на луче взгляда; если между ней и седоком склон — подходит ближе
		var suspension := -view_squash * 0.25 if settings.head_bob else 0.0
		_cam_y = lerpf(_cam_y, pos.y + 1.4 + suspension, _smooth(10.0, dt))
		if absf(_cam_y - pos.y - 1.4) > 2.0:
			_cam_y = pos.y + 1.4 + clampf(_cam_y - pos.y - 1.4, -2.0, 2.0)
		var target := Vector3(pos.x, _cam_y + dip, pos.z)
		var dir := Vector3(-sin(view_yaw) * cos(view_pitch), sin(view_pitch), -cos(view_yaw) * cos(view_pitch))
		var desired_dist := GameConfig.BIKE_CAM + _speed_rush * 0.7
		var dist := desired_dist
		var steps := maxi(CAM_STEPS, ceili(desired_dist / 0.3))
		# шаг проверки 0,3 м: тоньше перил и стен с запасом камеры, их не перешагнуть
		for k in range(1, steps + 1):
			var p := target - dir * (desired_dist * k / steps)
			if _cam_blocked(p, pos.y):
				dist = maxf(1.2, desired_dist * (k - 1) / steps)
				break
		# ближе — сразу, дальше — плавно, чтобы камера не прыгала за каждым бугром
		_cam_dist = dist if dist < _cam_dist else lerpf(_cam_dist, dist, _smooth(3.0, dt))
		var cam := target - dir * _cam_dist + jolt * 0.12
		# не ниже земли и настила моста, под которым камера окажется в стене или в воздухе
		cam.y = maxf(cam.y, heights.surface_at(cam.x, cam.z, cam.y) + 0.4)
		# в туннеле — не выше свода
		cam.y = minf(cam.y, heights.ceiling_at(cam.x, cam.z, pos.y) - 0.3)
		camera.look_at_from_position(cam, target, Vector3.UP)
		return
	_bob_amp = lerpf(_bob_amp, 1.0 if _moving and player.on_ground and settings.head_bob else 0.0, _smooth(8.0, dt))
	var stride := clampf(player.ground_speed() / GameConfig.WALK, 0.0, 1.6)
	var bob := sin(lerpf(_prev_bob, player.bob, alpha)) * 0.05 * stride * _bob_amp * (0.3 if photo_active else 1.0)
	camera.position = Vector3(pos.x, pos.y + GameConfig.EYE + bob + dip, pos.z)
	camera.rotation = Vector3(view_pitch + jolt.x * 0.03, view_yaw + jolt.y * 0.02, jolt.z * 0.03)



func auto_follow(time: float) -> float:
	return smoothstep(0.6, 1.6, time - _looked_at)

func shake_on_landing(impact: float, soft: float) -> void:
	if impact > soft:
		_trauma = minf(1.0, _trauma + (impact - soft) * 0.08)

func follow_bike(bike: BikeRide, heading_delta: float, time: float, dt: float) -> void:
	yaw += heading_delta
	var follow := auto_follow(time)
	if absf(bike.speed) > 1.0 and follow > 0.0:
		yaw = lerp_angle(yaw, bike.heading, 1.0 - exp(-dt * 2.0 * follow))
		var slope_pitch := 0.0 if bike.airborne else clampf(bike.tilt * 0.3, -0.12, 0.12)
		pitch = lerpf(pitch, -0.3 + slope_pitch, 1.0 - exp(-dt * 2.0 * follow))

static func _smooth(rate: float, dt: float) -> float:
	return 1.0 - exp(-rate * dt)

func store_previous(player: PlayerState, time: float) -> void:
	_prev = Vector3(player.x, player.feet, player.z)
	_prev_bob = player.bob
	_prev_dip = _dip
	_prev_time = time

func tick_effects(dt: float) -> void:
	_dip_v += (-120.0 * _dip - 18.0 * _dip_v) * dt
	_dip = clampf(_dip + _dip_v * dt, -0.6, 0.2)
	_trauma = maxf(0.0, _trauma - dt * 1.6)
