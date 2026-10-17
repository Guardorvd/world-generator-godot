class_name GameWorld
extends Node3D
## 3D-режим от первого лица: сцена scenes/game_world.tscn (окружение, солнце, камера и пустые узлы
## для рельефа, воды, построек, мостов и туннелей) и игровой цикл. Копия js/render3d/game3d.js и js/ui/input.js.
## Логика без движка (рельеф, движение игрока, езда на велосипеде) — в scripts/game, интерфейс — в Hud.
## На велосипеде (F) камера переходит за спину седока. Чувствительность мыши, угол обзора и покачивание
## берутся из GameSettings.

signal pause_requested

const TILE := GameConfig.TILE

var world: WorldData
var heights: Heightfield
var hud: Hud
var player: PlayerState
var bike: BikeRide
var bike_view: BikeView
var fires: Array = []
var labels: Array = []
var yaw := 0.0       # смотрим на север, на костёр
var pitch := -0.05
var time := 0.0
var paused := false
var show_map := false
var info_timer := 0.0
var _dragging := false
var _captured_at := 0
var _looked_at := 0.0   # время последнего движения мыши, чтобы камера на велосипеде не спорила с ней
var _cam_y := 0.0       # высота, за которой следит камера на велосипеде: мягко, чтобы не дёргало на приземлении
var _cam_dist := GameConfig.BIKE_CAM  # расстояние до седока: короче, если сзади склон
var _bob_amp := 0.0     # сила покачивания при ходьбе: нарастает и стихает плавно
var _dip := 0.0         # проседание камеры при приземлении, м (пружина)
var _dip_v := 0.0
var _trauma := 0.0      # тряска камеры 0..1 после жёстких приземлений, затухает сама

static var _defs: Dictionary
static var _grass_mesh: Mesh

@onready var camera: Camera3D = $Camera
@onready var vegetation: VegetationLayer = $Vegetation


## Заполнить сцену загруженным миром (WorldLoader) и начать игру
func start(loaded: WorldLoader, hud_node: Hud) -> void:
	world = loaded.world
	heights = loaded.heights
	hud = hud_node
	if _defs.is_empty():
		_defs = Models.tree_defs()
		_grass_mesh = Models.grass_mesh()
	$Terrain.mesh = loaded.terrain_mesh
	$Terrain.material_override = loaded.terrain_material
	for node in loaded.water:
		$Water.add_child(node)
	vegetation.setup(world, heights, _defs, _grass_mesh)
	var built := SettlementsBuilder.build($Settlements, world, heights)
	fires = built.fires
	labels = built.labels
	StructuresBuilder.build($Structures, heights)

	player = PlayerState.spawn(world, heights)
	if world.settlements.size() > 0:
		# лицом к костру
		var s: Dictionary = world.settlements[0]
		yaw = atan2(player.x - s.x * GameConfig.TILE, player.z - s.y * GameConfig.TILE)
	bike = BikeRide.park_near(player, yaw, world, heights)
	bike_view = preload("res://scenes/bike.tscn").instantiate()
	add_child(bike_view)
	bike_view.show_state(bike)
	hud.set_world(world, loaded.map_image)
	vegetation.update(player.x, player.z, true)
	camera.fov = GameSettings.fov
	_update_camera(false)
	if world.settlements.size() > 0:
		hud.toast("Вы в поселении «%s». Щёлкните по экрану, чтобы осмотреться" % world.settlements[0].name)
	capture_mouse()


func capture_mouse() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	_captured_at = Time.get_ticks_msec()


func set_paused(p: bool) -> void:
	paused = p
	# отпущенная кнопка мыши на паузе не приходит, перетаскивание не должно «залипнуть»
	_dragging = false
	if p:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	else:
		capture_mouse()


func look(dx: float, dy: float) -> void:
	var k := GameConfig.MOUSE * GameSettings.mouse
	yaw -= dx * k
	pitch = clampf(pitch - dy * k * (-1.0 if GameSettings.invert_y else 1.0), -1.5, 1.5)
	_looked_at = time


## F: сесть на велосипед, если он рядом, или слезть с него
func toggle_bike() -> void:
	if bike.riding:
		if bike.airborne:
			hud.toast("Сначала приземлитесь")
			return
		bike.dismount(player, world, heights)
		yaw = bike.heading
		pitch = -0.05
		return
	var d := bike.distance_to(player)
	if d > GameConfig.BIKE_MOUNT:
		hud.toast("Велосипед в %d м отсюда" % roundi(d))
		return
	bike.mount(player)
	_cam_y = player.feet + 1.4
	_cam_dist = GameConfig.BIKE_CAM
	yaw = bike.heading
	pitch = -0.3


func toggle_map() -> void:
	show_map = not show_map
	hud.set_map_visible(show_map)


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("pause"):
		# Esc сначала закрывает большую карту, потом ставит паузу
		if show_map and not paused:
			toggle_map()
		else:
			pause_requested.emit()
		get_viewport().set_input_as_handled()
		return
	# до start() узлы игрока и велосипеда ещё не созданы
	if paused or player == null:
		return
	if event.is_action_pressed("toggle_map"):
		toggle_map()
	elif event.is_action_pressed("bike"):
		toggle_bike()
	elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed and Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
			capture_mouse()
		_dragging = event.pressed
	elif event is InputEventMouseMotion:
		# без захвата мыши можно смотреть, зажав левую кнопку
		# сразу после захвата курсор переносится в центр окна, этот скачок — не взгляд
		if Time.get_ticks_msec() - _captured_at < 150:
			return
		# screen_relative не зависит от масштаба окна: чувствительность одна при любом размере
		if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED or _dragging:
			look(event.screen_relative.x, event.screen_relative.y)


func _notification(what: int) -> void:
	if what != NOTIFICATION_APPLICATION_FOCUS_OUT or not is_inside_tree():
		return
	# окно потеряло фокус: кнопки мыши и клавиш движения могли отпуститься без нас,
	# иначе игрок продолжит идти или тянуть взгляд после возвращения
	_dragging = false
	for action in ["move_forward", "move_back", "move_left", "move_right", "run", "jump"]:
		Input.action_release(action)
	# пауза, как при выходе из захвата мыши в браузере
	if not paused and player != null:
		pause_requested.emit()


func _process(delta: float) -> void:
	if player == null:
		return
	hud.lock_hint.visible = not paused and Input.mouse_mode != Input.MOUSE_MODE_CAPTURED
	if paused:
		return
	var dt := clampf(delta, 0.0, 0.05)
	time += dt
	var fw := Input.get_action_strength("move_forward") - Input.get_action_strength("move_back")
	var st := Input.get_action_strength("move_right") - Input.get_action_strength("move_left")
	var moving := false
	var jump := Input.is_action_just_pressed("jump")
	if bike.riding:
		var h0 := bike.heading
		bike.step(player, fw, st, Input.is_action_pressed("run"), jump, dt, world, heights)
		# камера поворачивает вместе с велосипедом, а если мышь не трогали — сама уходит за спину
		yaw += bike.heading - h0
		if absf(bike.speed) > 1.0 and time - _looked_at > 1.0:
			yaw = lerp_angle(yaw, bike.heading, 1.0 - exp(-dt * 2.0))
			pitch = lerpf(pitch, -0.3, 1.0 - exp(-dt * 2.0))
		_shake_on_landing(bike.land_impact, 6.0)
		bike.land_impact = 0.0
		if bike.crashed:
			_crash()
	else:
		moving = player.step(fw, st, Input.is_action_pressed("run"), jump, yaw, dt, world, heights)
		if player.land_impact > 0.0:
			# проседание камеры: заметное после высокого прыжка, едва заметное после обычного
			_dip_v -= clampf(player.land_impact - 3.0, 0.0, 14.0) * 0.25
			_shake_on_landing(player.land_impact, 10.0)
			player.land_impact = 0.0
	bike_view.show_state(bike)
	_update_hints()
	_update_camera(moving, dt)

	vegetation.update(player.x, player.z, false)
	for text in player.check_discoveries(world, hud.visited):
		hud.toast(text)
	for l: Label3D in labels:
		var d := Vector2(l.position.x - player.x, l.position.z - player.z).length()
		l.visible = d > 25.0 and d < 900.0
	SettlementsBuilder.animate_fires(fires, time)

	info_timer -= dt
	if info_timer <= 0.0:
		info_timer = 0.15
		hud.update_info(player, yaw, heights.depth_at(player.x, player.z, player.feet))
	hud.set_player(player.x, player.z, bike.heading if bike.riding else yaw)
	hud.set_bike(bike.x, bike.z, not bike.riding)


## Камера на велосипеде упирается в землю, настил моста или стену (перила, стены туннеля) в точке p
func _cam_blocked(p: Vector3) -> bool:
	if p.y < heights.surface_at(p.x, p.z, p.y) + 0.3:
		return true
	# перила и стены: на высоте глаз (чуть выше ног) стена на пути камеры закрывает обзор
	return heights.wall_at(p.x, p.z, p.y - 1.0)


## Тряска камеры после приземления сильнее soft (м/с)
func _shake_on_landing(impact: float, soft: float) -> void:
	if impact > soft:
		_trauma = minf(1.0, _trauma + (impact - soft) * 0.08)


## Жёсткое приземление на велосипеде: седок падает рядом, велосипед остаётся на месте
func _crash() -> void:
	bike.crashed = false
	bike.dismount(player, world, heights)
	yaw = bike.heading
	pitch = -0.25
	_dip_v -= 3.0
	_trauma = 1.0
	hud.toast("Слишком жёсткое приземление: вы упали с велосипеда")


## Подсказки внизу экрана и у прицела — по тому, что игрок делает сейчас
func _update_hints() -> void:
	if bike.riding:
		hud.set_hints("W — педали · S — тормоз · A, D — руль · Shift — сильнее · Пробел — прыжок · F — слезть · Esc — пауза", "")
		return
	var near := bike.distance_to(player) <= GameConfig.BIKE_MOUNT
	hud.set_hints("WASD — идти · Shift — бег · Пробел — прыжок · F — велосипед · M — карта · Esc — пауза",
		"F — сесть на велосипед" if near else "")


func _update_camera(moving: bool, dt: float = 0.0) -> void:
	var riding := bike != null and bike.riding
	# на скорости обзор чуть шире: на бегу немного, на велосипеде сильнее
	var fov_goal := GameSettings.fov
	if riding:
		fov_goal += GameConfig.BIKE_FOV * clampf((absf(bike.speed) - 2.0) / (GameConfig.BIKE_SPEED - 2.0), 0.0, 1.3)
	else:
		fov_goal += GameConfig.RUN_FOV * clampf((player.ground_speed() - GameConfig.WALK * 1.1) / (GameConfig.WALK * 0.6), 0.0, 1.0)
	camera.fov = lerpf(camera.fov, fov_goal, minf(1.0, dt * 4.0))
	# пружина проседания и затухающая тряска
	_dip_v += (-120.0 * _dip - 18.0 * _dip_v) * dt
	_dip = clampf(_dip + _dip_v * dt, -0.6, 0.2)
	_trauma = maxf(0.0, _trauma - dt * 1.6)
	var shake := _trauma * _trauma
	var jolt := Vector3(sin(time * 41.0), sin(time * 37.0 + 1.7), sin(time * 29.0 + 3.1)) * shake
	if riding:
		# от третьего лица: камера сзади на луче взгляда; если между ней и седоком склон — подходит ближе
		_cam_y = lerpf(_cam_y, player.feet + 1.4, minf(1.0, dt * 10.0))
		if absf(_cam_y - player.feet - 1.4) > 2.0:
			_cam_y = player.feet + 1.4 + clampf(_cam_y - player.feet - 1.4, -2.0, 2.0)
		var target := Vector3(player.x, _cam_y, player.z)
		var dir := Vector3(-sin(yaw) * cos(pitch), sin(pitch), -cos(yaw) * cos(pitch))
		var dist := GameConfig.BIKE_CAM
		for k in range(1, 7):
			var p := target - dir * (GameConfig.BIKE_CAM * k / 6.0)
			if _cam_blocked(p):
				dist = maxf(1.2, GameConfig.BIKE_CAM * (k - 1) / 6.0)
				break
		# ближе — сразу, дальше — плавно, чтобы камера не прыгала за каждым бугром
		_cam_dist = dist if dist < _cam_dist else lerpf(_cam_dist, dist, minf(1.0, dt * 3.0))
		var pos := target - dir * _cam_dist + jolt * 0.12
		# не ниже земли и настила моста, под которым камера окажется в стене или в воздухе
		pos.y = maxf(pos.y, heights.surface_at(pos.x, pos.z, pos.y) + 0.4)
		camera.look_at_from_position(pos, target, Vector3.UP)
		return
	_bob_amp = lerpf(_bob_amp, 1.0 if moving and player.on_ground and GameSettings.head_bob else 0.0, minf(1.0, dt * 8.0))
	var stride := clampf(player.ground_speed() / GameConfig.WALK, 0.0, 1.6)
	var bob := sin(player.bob) * 0.05 * stride * _bob_amp
	camera.position = Vector3(player.x, player.feet + GameConfig.EYE + bob + _dip, player.z)
	camera.rotation = Vector3(pitch + jolt.x * 0.03, yaw + jolt.y * 0.02, jolt.z * 0.03)
