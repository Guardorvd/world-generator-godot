class_name GameWorld
extends Node3D
## 3D-режим от первого лица: сцена scenes/game_world.tscn (окружение, солнце, камера и пустые узлы
## для рельефа, воды, построек, мостов и туннелей) и игровой цикл. Копия js/render3d/game3d.js и js/ui/input.js.
## Логика без движка (рельеф, движение игрока, езда на велосипеде) — в scripts/game, интерфейс — в Hud.
## На велосипеде (F) камера переходит за спину седока. Чувствительность мыши, угол обзора и покачивание
## берутся из GameSettings. Звуки путешествия — узел Audio (WorldAudio, с 2.7).
## С 2.8 на открытой карте (M) курсор свободен: там выбирают цель путешествия и место быстрого перемещения
## (travel_to по сигналу Hud.travel_requested).
## С 7.8 сутки сменяются (DayCycle): час идёт тактами игры, скорость и час начала — в GameSettings, T — час вперёд
## (Shift+T — назад).
## Движение и игровое время считаются тактами физики (_physics_process, 60 в секунду при любом FPS),
## а кадр (_process) показывает игрока, велосипед и камеру между двумя последними тактами.

signal pause_requested

const TILE := GameConfig.TILE
const CAM_STEPS := 15   # столько точек на луче от седока до камеры проверяется на стены и склон
## Рельеф, готовый сразу при старте и переносе (м). Дальше в тумане части догружаются по одной за кадр:
## на 900 м туман уже скрывает больше 80 % цвета, а за секунды загрузки игрок проходит считанные метры.
const NEAR := PlanTerrain.RADIUS / 2.0

var world: WorldData
var heights: Heightfield
var hud: Hud
var player: PlayerState
var bike: BikeRide
var bike_view: BikeView
var crash: BikeCrash     # падение с велосипеда (с 7.6): ragdoll и возврат в седло
var water_effects: WaterEffects
var fires: Array = []
var windows: StandardMaterial3D # окна и фонари всех построек, ночью ярче (SettlementsBuilder.set_night)
var fire_light: OmniLight3D     # один свет на весь мир: ночью у ближайшего костра
var _night := -1.0
var outer: OuterTerrain   # рельеф за краем стартовой области
var terrain_stream: PlanTerrain
var load_timings := {}    # WorldLoader.timings и шаги start (мс), для tools/control/check.gd
var _ocean: Node3D        # плоскость моря: ездит за игроком, чтобы море не кончалось
var yaw := 0.0       # смотрим на север, на костёр
var pitch := -0.05
var time := 0.0
var hour := 9.0          # час суток в мире, 0..24
var day: DayCycle
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
var _moving := false    # игрок шёл в последнем такте (для покачивания камеры)
var _prev := Vector3()  # игрок (x, ноги, z) на предпоследнем такте: кадр показывает его между тактами
var _prev_bob := 0.0
var _prev_dip := 0.0    # проседание и время на предпоследнем такте: кадр показывает их между тактами
var _prev_time := 0.0
var _tick_yaw := 0.0    # насколько последний такт повернул камеру сам (вслед за велосипедом);
var _tick_pitch := 0.0  # кадр доворачивает этот поворот плавно, а мышь — сразу

static var _defs: Dictionary
static var _grass_mesh: Mesh

@onready var camera: Camera3D = $Camera
@onready var vegetation: VegetationLayer = $Vegetation
@onready var audio: WorldAudio = $Audio


## Заполнить сцену загруженным миром (WorldLoader) и начать игру.
## С 9.0 сразу готовится только окружение игрока: ближний рельеф (до NEAR), лес вокруг и край за картой;
## дальний рельеф и растительность догружаются в игре, сначала по ходу движения.
func start(loaded: WorldLoader, hud_node: Hud) -> void:
	var t := Time.get_ticks_usec()
	load_timings = loaded.timings
	world = loaded.world
	heights = loaded.heights
	hud = hud_node
	hud.settlement_panel.closed.connect(_close_settlement)
	hud.settlement_panel.destination_selected.connect(_choose_settlement_route)
	hud.settlement_panel.bike_requested.connect(_recall_bike)
	var scene_started := t
	if _defs.is_empty():
		_defs = Models.tree_defs()
		_grass_mesh = Models.grass_mesh()
	t = _mark("start_models_ms", t)
	$Terrain.material_override = TerrainBuilder.material(loaded.terrain_image, loaded.forest_surface)
	terrain_stream = PlanTerrain.new()
	terrain_stream.name = "PlanTerrain"
	$Terrain.add_child(terrain_stream)
	terrain_stream.setup(loaded.terrain_chunks, $Terrain.material_override)
	# Чанки уже содержат все треугольники. Монолит больше не нужен ни CPU, ни GPU.
	loaded.terrain_arrays = []
	t = _mark("start_material_terrain_setup_ms", t)
	for node: Node in WaterBuilder.build(world, loaded.water_arrays):
		$Water.add_child(node)
		if node.name == "Ocean":
			_ocean = node
	water_effects = WaterEffects.new()
	water_effects.setup($Water)
	$Water.add_child(water_effects)
	t = _mark("start_water_ms", t)
	vegetation.setup(world, heights, _defs, _grass_mesh, loaded.forest_surface)
	t = _mark("start_vegetation_setup_ms", t)
	var built := SettlementsBuilder.build($Settlements, world, heights)
	fires = built.fires
	windows = built.windows
	fire_light = OmniLight3D.new()
	fire_light.light_color = Color8(0xff, 0xa8, 0x55)
	fire_light.omni_range = 14.0
	fire_light.visible = false
	$Settlements.add_child(fire_light)
	t = _mark("start_settlements_ms", t)
	StructuresBuilder.build($Structures, heights)
	t = _mark("start_structures_ms", t)
	load_timings.start_scene_ms = (t - scene_started) / 1000.0

	player = PlayerState.spawn(world, heights)
	terrain_stream.update(player.x, player.z, true, true, NEAR)
	t = _mark("start_terrain_ms", t)
	if world.settlements.size() > 0:
		# лицом к костру
		var s := PlayerState.home(world)
		yaw = atan2(player.x - s.x * GameConfig.TILE, player.z - s.y * GameConfig.TILE)
	outer = OuterTerrain.new()
	outer.name = "OuterTerrain"
	add_child(outer)
	if world.outer != null:
		outer.setup(world, heights)
		outer.preload_around(player.x, player.z, OuterTerrain.RADIUS / 2.0)
	heights.obstacles = ForestObstacles.new(world, heights)
	heights.obstacles.update(player.x, player.z, vegetation.obstacles, vegetation.obstacles_version, true)
	bike = BikeRide.park_near(player, yaw, world, heights)
	bike_view = preload("res://scenes/bike.tscn").instantiate()
	add_child(bike_view)
	crash = BikeCrash.new()
	crash.name = "BikeCrash"
	add_child(crash)
	_snap()
	bike_view.draw(1.0)
	t = _mark("start_outer_ms", t)
	hud.set_world(world, loaded.map_image)
	vegetation.update(player.x, player.z, true)
	t = _mark("start_vegetation_ms", t)
	camera.fov = GameSettings.fov
	_apply_shadows()
	day = DayCycle.new($WorldEnvironment.environment, $Sun)
	day.terrain_mats = [$Terrain.material_override]
	day.camera = camera
	day.world_seed = world.seed_num
	hour = GameSettings.start_hour
	day.apply(hour, time)
	_update_camera(1.0, 0.0)
	if world.settlements.size() > 0:
		hud.toast("Вы в поселении «%s». Щёлкните по экрану, чтобы осмотреться" % PlayerState.home(world).name)
	audio.setup(world, heights)
	hud.travel_requested.connect(travel_to)
	capture_mouse()
	_mark("start_rest_ms", t)


## Время шага запуска в load_timings (мс); возвращает новую отметку
func _mark(key: String, since: int) -> int:
	var now := Time.get_ticks_usec()
	load_timings[key] = (now - since) / 1000.0
	return now


## Тени солнца и затенение (SSAO) по настройке; настройку можно поменять на паузе
func _apply_shadows() -> void:
	var sun: DirectionalLight3D = $Sun
	if sun.shadow_enabled != GameSettings.shadows:
		sun.shadow_enabled = GameSettings.shadows
		$WorldEnvironment.environment.ssao_enabled = GameSettings.shadows


func capture_mouse() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	_captured_at = Time.get_ticks_msec()


func set_paused(p: bool) -> void:
	paused = p
	if p:
		_close_settlement(false)
	else:
		_apply_shadows() # тени меняются в настройках на паузе
	audio.set_paused(p)
	# отпущенная кнопка мыши на паузе не приходит, перетаскивание не должно «залипнуть»
	_dragging = false
	if p or show_map:
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
	if crash.active():
		return
	if bike.riding:
		if bike.airborne:
			hud.toast("Сначала приземлитесь")
			return
		bike.dismount(player, world, heights)
		yaw = bike.heading
		pitch = -0.05
		_snap()
		return
	var d := bike.distance_to(player)
	if d > GameConfig.BIKE_MOUNT:
		hud.toast("Велосипед в %d м отсюда" % roundi(d))
		return
	if not bike.can_mount(player):
		hud.toast("Велосипед выше или ниже вас")
		return
	bike.mount(player)
	_cam_y = player.feet + 1.4
	_cam_dist = GameConfig.BIKE_CAM
	yaw = bike.heading
	pitch = -0.3
	_snap()


func toggle_map() -> void:
	_close_settlement(false)
	show_map = not show_map
	hud.set_map_visible(show_map)
	# на карте курсор нужен, чтобы выбрать место; закрыли — снова осматриваемся мышью
	if show_map:
		_dragging = false
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	else:
		capture_mouse()


## Быстрое перемещение в любое место с карты (Hud.places; с 3.0.2 и туда, где игрок ещё не был): к костру поселения,
## к вершине или на берег озера. Велосипед переезжает вместе с игроком и встаёт рядом, карта закрывается
func travel_to(place: Dictionary) -> void:
	if paused or player == null or not world.accessible(place.x, place.y):
		return
	if bike.riding and bike.airborne:
		return
	_close_settlement(false)
	crash.abort()
	# стволы у места прибытия, чтобы не встать в дерево (валежник появится после раскладки подлеска)
	heights.obstacles.update(place.x * TILE, place.y * TILE, PackedFloat32Array(), -1, true)
	player = PlayerState.arrive(world, heights, place)
	terrain_stream.update(player.x, player.z, true, true, NEAR)
	heights.obstacles.update(player.x, player.z, PackedFloat32Array(), -1, true)
	if place.kind != "peak":
		# лицом к костру или к середине озера
		yaw = atan2(player.x - place.x * TILE, player.z - place.y * TILE)
	pitch = -0.05
	bike = BikeRide.park_near(player, yaw, world, heights)
	_dip = 0.0
	_dip_v = 0.0
	_trauma = 0.0
	_snap()
	bike_view.draw(1.0)
	if world.outer != null:
		outer.preload_around(player.x, player.z, OuterTerrain.RADIUS / 2.0)
	vegetation.update(player.x, player.z, true)
	if show_map:
		toggle_map()
	hud.toast_now("Вы переместились: «%s»" % place.name)


func _unhandled_input(event: InputEvent) -> void:
	if event.is_echo():
		return
	if _settlement_open():
		if event.is_action_pressed("pause") or event.is_action_pressed("interact"):
			_close_settlement()
			get_viewport().set_input_as_handled()
		return
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
	elif event.is_action_pressed("time_skip"):
		hour = fposmod(hour + (-1.0 if Input.is_key_pressed(KEY_SHIFT) else 1.0), 24.0)
		hud.toast_now("Время %s" % DayCycle.clock(hour))
	elif event.is_action_pressed("interact") and not show_map:
		_open_settlement()
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
	for action: String in ["move_forward", "move_back", "move_left", "move_right", "run", "jump"]:
		Input.action_release(action)
	# пауза, как при выходе из захвата мыши в браузере
	if not paused and player != null:
		pause_requested.emit()


## Такт симуляции: движение игрока и велосипеда, игровое время, пружины камеры. Длина такта всегда
## одна (1/60 с), поэтому разгон, прыжки и полёт одинаковы при любом FPS, и за такт не проскочить стену.
## При FPS ниже 60 за кадр проходит несколько тактов, ниже 7,5 (8 тактов за кадр) игра замедляется,
## чтобы не захлебнуться
func _physics_process(dt: float) -> void:
	if player == null or paused or _settlement_open():
		return
	world.open_around(player.x / TILE, player.z / TILE)
	_store_prev()
	var yaw0 := yaw
	var pitch0 := pitch
	time += dt
	if GameSettings.day_minutes > 0.0:
		hour = fposmod(hour + dt * 24.0 / (GameSettings.day_minutes * 60.0), 24.0)
	var fw := Input.get_action_strength("move_forward") - Input.get_action_strength("move_back")
	var st := Input.get_action_strength("move_right") - Input.get_action_strength("move_left")
	# «только что нажат» в такте физики срабатывает ровно в одном такте, даже если за кадр их несколько
	var jump := Input.is_action_just_pressed("jump")
	_moving = false
	var crashed := false
	heights.obstacles.update(player.x, player.z, vegetation.obstacles, vegetation.obstacles_version)
	if crash.active():
		# седок падает: управление ждёт, пока он снова в седле; камера следит за телом
		var back := crash.tick(dt, bike, world, heights)
		var at := crash.focus(bike)
		player.x = at.x
		player.z = at.z
		player.feet = at.y
		if back:
			bike.dismount(player, world, heights)
			bike.mount(player)
			yaw = bike.heading
			crashed = true
	elif bike.riding:
		var h0 := bike.heading
		bike.step(player, fw, st, Input.is_action_pressed("run"), jump, dt, world, heights)
		# камера поворачивает вместе с велосипедом, а если мышь не трогали — сама уходит за спину
		yaw += bike.heading - h0
		if absf(bike.speed) > 1.0 and time - _looked_at > 1.0:
			yaw = lerp_angle(yaw, bike.heading, 1.0 - exp(-dt * 2.0))
			# Следуем склону только при автоматическом взгляде; мышь сохраняет приоритет.
			var slope_pitch := 0.0 if bike.airborne else clampf(bike.tilt * 0.3, -0.12, 0.12)
			pitch = lerpf(pitch, -0.3 + slope_pitch, 1.0 - exp(-dt * 2.0))
		_shake_on_landing(bike.land_impact, 6.0)
		if bike.land_impact > 0.0:
			if GameSettings.head_bob:
				_dip_v -= clampf(bike.land_impact - 2.5, 0.0, 8.0) * 0.12
			audio.land(bike.x, bike.z, bike.y, bike.land_impact)
		crashed = bike.crashed
		if crashed:
			_crash()
	else:
		_moving = player.step(fw, st, Input.is_action_pressed("run"), jump, yaw, dt, world, heights)
		if player.land_impact > 0.0:
			# проседание камеры: заметное после высокого прыжка, едва заметное после обычного
			_dip_v -= clampf(player.land_impact - 3.0, 0.0, 14.0) * 0.25
			_shake_on_landing(player.land_impact, 10.0)
			audio.land(player.x, player.z, player.feet, player.land_impact)
			player.land_impact = 0.0
	_tick_yaw = yaw - yaw0
	water_effects.tick(dt, player, bike, _prev, heights)
	_tick_pitch = pitch - pitch0
	# пружина проседания и затухающая тряска камеры
	_dip_v += (-120.0 * _dip - 18.0 * _dip_v) * dt
	_dip = clampf(_dip + _dip_v * dt, -0.6, 0.2)
	_trauma = maxf(0.0, _trauma - dt * 1.6)
	if not crash.active():
		bike_view.tick(bike, dt, fw, Input.is_action_pressed("run"))
	bike.land_impact = 0.0
	audio.tick(player, bike.riding)
	if crashed:
		_snap()
	for text: String in player.check_discoveries(world, hud.visited):
		hud.toast(text)
	var reached := hud.check_goal(player.x, player.z)
	if reached != "":
		hud.toast(reached)


## Запомнить положение игрока как предпоследний такт (для интерполяции кадра)
func _store_prev() -> void:
	_prev = Vector3(player.x, player.feet, player.z)
	_prev_bob = player.bob
	_prev_dip = _dip
	_prev_time = time


## Последний такт становится и предпоследним: после переноса игрока (сел, слез, упал) кадр не тянет
## его плавно со старого места
func _snap() -> void:
	_store_prev()
	if water_effects != null:
		water_effects.clear()
	_tick_yaw = 0.0
	_tick_pitch = 0.0
	bike_view.snap(bike)


## Вечером окна разгораются, а ближайший костёр (до 80 м) освещает дома вокруг. Один источник света
## на весь мир: на слабой видеокарте свет на каждый костёр дорог
func _light_night(pos: Vector3, t: float) -> void:
	var night := 1.0 - day.sunlight
	if absf(night - _night) > 0.02:
		_night = night
		SettlementsBuilder.set_night(windows, night)
	var near := {}
	var best := 80.0 * 80.0
	if night > 0.05:
		for f: Dictionary in fires:
			var d := pos.distance_squared_to(f.pos)
			if d < best:
				best = d
				near = f
	fire_light.visible = not near.is_empty()
	if near.is_empty():
		return
	fire_light.position = near.pos + Vector3(0, 1.2, 0)
	var s: float = t * 9.0 + near.phase
	fire_light.light_energy = night * (1.5 + sin(s) * 0.15 + sin(s * 1.7) * 0.1)


func _process(delta: float) -> void:
	if player == null:
		return
	hud.lock_hint.visible = not paused and not _settlement_open() and Input.mouse_mode != Input.MOUSE_MODE_CAPTURED
	if paused:
		return
	# доля пути от предпоследнего такта физики к последнему, в которой сейчас кадр
	var alpha := Engine.get_physics_interpolation_fraction()
	var pos := _prev.lerp(Vector3(player.x, player.feet, player.z), alpha)
	if crash.active():
		crash.draw()
	else:
		bike_view.draw(alpha)
	_update_hints()
	_update_camera(alpha, delta)
	day.apply(hour, time)

	var uploaded := vegetation.update(pos.x, pos.z, false)
	uploaded = terrain_stream.update(pos.x, pos.z, false, not uploaded) or uploaded
	if world.outer != null:
		outer.update(pos.x, pos.z, not uploaded)
	if _ocean != null:
		_ocean.position = Vector3(pos.x, 0.0, pos.z)
	var fire_time := lerpf(_prev_time, time, alpha)
	SettlementsBuilder.animate_fires(fires, fire_time, pos)
	_light_night(pos, fire_time)
	audio.update(pos, bike.speed if bike.riding else 0.0, bike.riding and not bike.airborne, delta, bike.lean if bike.riding else 0.0)

	info_timer -= delta
	if info_timer <= 0.0:
		info_timer = 0.15
		hud.update_info(player, yaw, heights.depth_at(player.x, player.z, player.feet))
	hud.set_player(pos.x, pos.z, bike.heading if bike.riding else yaw)
	hud.set_bike(bike.x, bike.z, not bike.riding)


## Камера на велосипеде упирается в землю, настил моста или стену (перила, стены туннеля) в точке p
func _cam_blocked(p: Vector3, feet: float) -> bool:
	if p.y < heights.surface_at(p.x, p.z, p.y) + 0.3:
		return true
	if p.y > heights.ceiling_at(p.x, p.z, feet) - 0.3:
		return true # свод туннеля, в котором едет седок
	# перила и стены: на высоте глаз (чуть выше ног) стена на пути камеры закрывает обзор;
	# камера держится в 0,25 м от них, чтобы ближняя плоскость отсечения не заглядывала за стену
	return heights.wall_at(p.x, p.z, p.y - 1.0, 0.25)


## Тряска камеры после приземления сильнее soft (м/с)
func _shake_on_landing(impact: float, soft: float) -> void:
	if impact > soft:
		_trauma = minf(1.0, _trauma + (impact - soft) * 0.08)


## Седок упал (жёсткое приземление, удар в стену): велосипед и тело разлетаются (BikeCrash),
## через пару секунд седок снова в седле
func _crash() -> void:
	bike.crashed = false
	crash.start(bike_view, bike, bike.crash_velocity, heights)
	if bike.land_impact <= 0.0:
		audio.land(bike.x, bike.z, bike.y, 12.0) # удар в стену: глухой стук, как от жёсткой посадки
	bike.speed = 0.0
	pitch = -0.35
	_dip_v -= 3.0
	_trauma = 1.0


## Подсказки внизу экрана и у прицела — по тому, что игрок делает сейчас
func _update_hints() -> void:
	if _settlement_open():
		hud.set_hints("", "")
		return
	var village := _near_settlement()
	var visit := "E — маршруты поселения «%s»" % village.name if not village.is_empty() else ""
	if bike.riding:
		hud.set_hints("W — педали · S — тормоз · A, D — руль · Shift — сильнее · Пробел — прыжок · F — слезть · Esc — пауза", visit)
		return
	var near := bike.can_mount(player)
	hud.set_hints("WASD — идти · Shift — бег · Пробел — прыжок · F — велосипед · M — карта · Esc — пауза",
		visit if not visit.is_empty() else ("F — сесть на велосипед" if near else ""))


func _settlement_open() -> bool:
	return hud != null and hud.settlement_panel != null and hud.settlement_panel.visible


func _near_settlement() -> Dictionary:
	if world == null or player == null or not player.on_ground:
		return {}
	var nearest := {}
	var distance := 7.0
	for s: Dictionary in world.settlements:
		var d := Grid.hypot(s.x * TILE - player.x, s.y * TILE - player.z)
		if d < distance and absf(player.feet - heights.ground_at(s.x * TILE, s.y * TILE)) < 3.0:
			nearest = s
			distance = d
	return nearest


func _open_settlement() -> void:
	if paused or show_map or _settlement_open() or crash.active():
		return
	var village := _near_settlement()
	if village.is_empty():
		return
	if bike.riding:
		if absf(bike.speed) > 0.5 or bike.airborne:
			hud.toast("Остановитесь у костра, чтобы прочитать указатель")
			return
		toggle_bike()
	for action: String in ["move_forward", "move_back", "move_left", "move_right", "run", "jump"]:
		Input.action_release(action)
	player.vx = 0.0
	player.vz = 0.0
	_snap()
	_dragging = false
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	hud.settlement_panel.open(village, world, hud.places(), bike.distance_to(player) < 4.0)


func _close_settlement(capture := true) -> void:
	if not _settlement_open():
		return
	hud.settlement_panel.hide()
	if capture and not paused and not show_map:
		capture_mouse()


func _choose_settlement_route(place: Dictionary) -> void:
	hud.set_goal(place)
	_close_settlement()
	hud.toast_now("На указателе: путь к «%s». Цель отмечена на компасе и карте" % place.name)


func _recall_bike() -> void:
	if not _settlement_open() or paused or not player.on_ground:
		return
	bike = BikeRide.park_near(player, yaw, world, heights)
	bike_view.snap(bike)
	bike_view.draw(1.0)
	_close_settlement()
	hud.toast_now("Велосипед ждёт рядом с костром")


## Камера в доле alpha пути между двумя последними тактами; dt — длина кадра, для сглаживания
func _update_camera(alpha: float, dt: float) -> void:
	var riding := bike != null and bike.riding
	var pos := _prev.lerp(Vector3(player.x, player.feet, player.z), alpha)
	# поворот, который сделал сам такт, доворачивается плавно; мышь уже учтена в yaw и pitch
	var view_yaw := yaw - _tick_yaw * (1.0 - alpha)
	var view_pitch := pitch - _tick_pitch * (1.0 - alpha)
	# на скорости обзор чуть шире: на бегу немного, на велосипеде сильнее
	var fov_goal := GameSettings.fov
	if riding:
		fov_goal += GameConfig.BIKE_FOV * clampf((absf(bike.speed) - 2.0) / (GameConfig.BIKE_SPEED - 2.0), 0.0, 1.3)
	else:
		fov_goal += GameConfig.RUN_FOV * clampf((player.ground_speed() - GameConfig.WALK * 1.1) / (GameConfig.WALK * 0.6), 0.0, 1.0)
	camera.fov = lerpf(camera.fov, fov_goal, _smooth(4.0, dt))
	var shake := _trauma * _trauma if GameSettings.head_bob else 0.0
	var t := lerpf(_prev_time, time, alpha)
	var jolt := Vector3(sin(t * 41.0), sin(t * 37.0 + 1.7), sin(t * 29.0 + 3.1)) * shake
	var dip := lerpf(_prev_dip, _dip, alpha) if GameSettings.head_bob else 0.0
	if riding:
		# от третьего лица: камера сзади на луче взгляда; если между ней и седоком склон — подходит ближе
		var suspension := -bike_view.view_squash() * 0.25 if GameSettings.head_bob else 0.0
		_cam_y = lerpf(_cam_y, pos.y + 1.4 + suspension, _smooth(10.0, dt))
		if absf(_cam_y - pos.y - 1.4) > 2.0:
			_cam_y = pos.y + 1.4 + clampf(_cam_y - pos.y - 1.4, -2.0, 2.0)
		var target := Vector3(pos.x, _cam_y + dip, pos.z)
		var dir := Vector3(-sin(view_yaw) * cos(view_pitch), sin(view_pitch), -cos(view_yaw) * cos(view_pitch))
		var dist := GameConfig.BIKE_CAM
		# шаг проверки 0,3 м: тоньше перил и стен с запасом камеры, их не перешагнуть
		for k in range(1, CAM_STEPS + 1):
			var p := target - dir * (GameConfig.BIKE_CAM * k / CAM_STEPS)
			if _cam_blocked(p, pos.y):
				dist = maxf(1.2, GameConfig.BIKE_CAM * (k - 1) / CAM_STEPS)
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
	_bob_amp = lerpf(_bob_amp, 1.0 if _moving and player.on_ground and GameSettings.head_bob else 0.0, _smooth(8.0, dt))
	var stride := clampf(player.ground_speed() / GameConfig.WALK, 0.0, 1.6)
	var bob := sin(lerpf(_prev_bob, player.bob, alpha)) * 0.05 * stride * _bob_amp
	camera.position = Vector3(pos.x, pos.y + GameConfig.EYE + bob + dip, pos.z)
	camera.rotation = Vector3(view_pitch + jolt.x * 0.03, view_yaw + jolt.y * 0.02, jolt.z * 0.03)


## Доля, на которую за кадр dt догоняют цель при скорости rate (1/с): одинаково при любом FPS
static func _smooth(rate: float, dt: float) -> float:
	return 1.0 - exp(-rate * dt)
