class_name GameWorld
extends Node3D
## 3D-режим от первого лица: сцена scenes/game_world.tscn (окружение, солнце, камера и пустые узлы
## для рельефа, воды и построек) и игровой цикл. Копия js/render3d/game3d.js и js/ui/input.js.
## Логика без движка (рельеф, движение игрока) — в scripts/game, интерфейс — в Hud.

signal pause_requested

const TILE := GameConfig.TILE

var world: WorldData
var heights: Heightfield
var hud: Hud
var player: PlayerState
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

	player = PlayerState.spawn(world, heights)
	if world.settlements.size() > 0:
		# лицом к костру
		var s: Dictionary = world.settlements[0]
		yaw = atan2(player.x - s.x * GameConfig.TILE, player.z - s.y * GameConfig.TILE)
	hud.set_world(world, loaded.map_image)
	vegetation.update(player.x, player.z, true)
	_update_camera(false)
	if world.settlements.size() > 0:
		hud.toast("Вы в поселении «%s». Щёлкните по экрану, чтобы осмотреться" % world.settlements[0].name)
	capture_mouse()


func capture_mouse() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	_captured_at = Time.get_ticks_msec()


func set_paused(p: bool) -> void:
	paused = p
	if p:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	else:
		capture_mouse()


func look(dx: float, dy: float) -> void:
	yaw -= dx * GameConfig.MOUSE
	pitch = clampf(pitch - dy * GameConfig.MOUSE, -1.5, 1.5)


func toggle_map() -> void:
	show_map = not show_map
	hud.set_map_visible(show_map)


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("pause"):
		pause_requested.emit()
		get_viewport().set_input_as_handled()
		return
	if paused:
		return
	if event.is_action_pressed("toggle_map"):
		toggle_map()
	elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed and Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
			capture_mouse()
		_dragging = event.pressed
	elif event is InputEventMouseMotion:
		# без захвата мыши можно смотреть, зажав левую кнопку
		# сразу после захвата курсор переносится в центр окна, этот скачок — не взгляд
		if Time.get_ticks_msec() - _captured_at < 150:
			return
		if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED or _dragging:
			look(event.relative.x, event.relative.y)


func _notification(what: int) -> void:
	# окно потеряло фокус — пауза, как при выходе из захвата мыши в браузере
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT and not paused and is_inside_tree():
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
	var moving := player.step(fw, st, Input.is_action_pressed("run"), Input.is_action_pressed("jump"), yaw, dt, world, heights)
	_update_camera(moving)

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
		hud.update_info(player, yaw, heights.depth_at(player.x, player.z))
	hud.set_player(player.x, player.z, yaw)


func _update_camera(moving: bool) -> void:
	var bob := sin(player.bob) * 0.06 if moving and player.on_ground else 0.0
	camera.position = Vector3(player.x, player.feet + GameConfig.EYE + bob, player.z)
	camera.rotation = Vector3(pitch, yaw, 0.0)
