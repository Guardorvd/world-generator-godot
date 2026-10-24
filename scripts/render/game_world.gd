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
## С 10.1 одна система наведения: E действует на то, на что смотрит игрок (велосипед, доска маршрутов; _aim),
## на велосипеде E — слезть. F — фара.
## С 11.8 пешком ПКМ — фотоаппарат (PhotoCamera): видоискатель, снимки, названия мест по наведению.
## С 11.9 доска даёт задания (Quests): посещение, доставка сумки (E у доски, сумка за спиной седока), снимок места.
## Движение и игровое время считаются тактами физики (_physics_process, 60 в секунду при любом FPS),
## а кадр (_process) показывает игрока, велосипед и камеру между двумя последними тактами.

signal pause_requested

const TILE := GameConfig.TILE
const CAM_STEPS := 15   # столько точек на луче от седока до камеры проверяется на стены и склон
## Рельеф, готовый сразу при старте и переносе (м). Дальше в тумане части догружаются по одной за кадр:
## на 900 м туман уже скрывает больше 80 % цвета, а за секунды загрузки игрок проходит считанные метры.
const NEAR := PlanTerrain.RADIUS / 2.0
const REACH := 3.5     # предметы дальше этого от глаз игрока (м) не выбираются взглядом
const AIM_R := 0.3     # «толщина» луча взгляда, м: предмет можно задеть краем
const OpeningRoute = preload("res://scripts/game/opening_route.gd")
const OPENING_PASS := 1.6
const OPENING_FOLLOW := 3.0
const SpeedWind = preload("res://scripts/render/speed_wind.gd")
const NavigationLine = preload("res://scripts/render/navigation_line.gd")
const PlaceNames = preload("res://scripts/render/place_names.gd")
const PhotoCamera = preload("res://scripts/render/photo_camera.gd")
const Quests = preload("res://scripts/game/quests.gd")
const CargoBag = preload("res://scripts/render/cargo_bag.gd")
const SettlementPanel = preload("res://scripts/ui/settlement_panel.gd")
var place_names: PlaceNames
var photo: PhotoCamera
var quests: Quests       # 11.9: задания с досок (Quests), счётчик — Hud.tracker
var _bag: Node3D         # сумка доставки у доски, пока её не взяли
var _bag_label: Label3D  # подпись над ней
var _quest_goal := ""    # key места, которое задание поставило целью на компасе
var navigation_line: NavigationLine
var _speed_wind: SpeedWind
var _speed_rush := 0.0
var opening_place := {}
var _opening := false
var _opening_time := 0.0
var _opening_camera := Vector3.ZERO
var _opening_target := Vector3.ZERO
var _opening_caption: Label
var _opening_points: Array[Vector2] = []
var _opening_point := 1

var world: WorldData
var heights: Heightfield
var hud: Hud
var player: PlayerState
var bike: BikeRide
var bike_view: BikeView
var crash: BikeCrash     # падение с велосипеда: ragdoll и подъём пешком
var water_effects: WaterEffects
var fires: Array = []
var windows: StandardMaterial3D # окна и фонари всех построек, ночью ярче (SettlementsBuilder.set_night)
var fire_light: OmniLight3D     # один свет на весь мир: ночью у ближайшего костра
var _night := -1.0
var outer: OuterTerrain   # рельеф за краем стартовой области
var regions: RegionStream # 13.9: подготовленные соседние области за краем плана
var terrain_stream: PlanTerrain
var load_timings := {}    # WorldLoader.timings и шаги start (мс), для tools/control/check.gd
var _ocean: Node3D        # плоскость моря: ездит за игроком, чтобы море не кончалось
var yaw := 0.0       # смотрим на север, на костёр
var pitch := -0.05
var time := 0.0
var hour := 9.0          # час суток в мире, 0..24
var day: DayCycle
var _boards: Array = []  # доски маршрутов: {at (середина щита, повёрнута как щит), place}
var _target := {}        # на что игрок смотрит сейчас (_aim): {kind = "bike" | "board", place}
var paused := false
var show_map := false
var info_timer := 0.0
var _dragging := false
var _captured_at := 0
var _looked_at := 0.0   # время последнего движения мыши, чтобы камера на велосипеде не спорила с ней
var _rescue_ready := 0.0 # игровое время: защита от повторной дорогой операции Y
var _rescue_input_until := 0.0
var _cam_y := 0.0       # высота, за которой следит камера на велосипеде: мягко, чтобы не дёргало на приземлении
var _cam_dist := GameConfig.BIKE_CAM  # расстояние до седока: короче, если сзади склон
var _bob_amp := 0.0     # сила покачивания при ходьбе: нарастает и стихает плавно
var _dip := 0.0         # проседание камеры при приземлении, м (пружина)
var _dip_v := 0.0
var _trauma := 0.0      # тряска камеры 0..1 после жёстких приземлений, затухает сама
var _cam_lead := 0.0    # 12.7: доворот камеры внутрь поворота, рад (только пока мышь не трогали)
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
func start(loaded: WorldLoader, hud_node: Hud, saved: Dictionary = {}) -> void:
	var t := Time.get_ticks_usec()
	load_timings = loaded.timings
	world = loaded.world
	heights = loaded.heights
	hud = hud_node
	hud.settlement_panel.closed.connect(_close_settlement)
	hud.settlement_panel.destination_selected.connect(_choose_settlement_route)
	hud.settlement_panel.bike_requested.connect(_recall_bike)
	hud.settlement_panel.quest_accepted.connect(_accept_quest)
	hud.settlement_panel.quest_abandoned.connect(_abandon_quest)
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
	place_names = PlaceNames.new()
	place_names.setup($Settlements)
	photo = PhotoCamera.new()
	add_child(photo)
	photo.anchors = _photo_anchors()
	photo.occluded = _occluded
	photo.familiar = func(id: String) -> bool: return hud.knows(id)
	photo.capturing.connect(func(on: bool) -> void: hud.visible = not on)
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

	var spawn_started := Time.get_ticks_usec()
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	var opening_spot := OpeningRoute.choose(world, heights, rng) if saved.is_empty() else {}
	load_timings.start_spawn_ms = (Time.get_ticks_usec() - spawn_started) / 1000.0
	player = PlayerState.spawn(world, heights)
	if not saved.is_empty():
		world.expand_territory(world.W)
		player.x = saved.player.x
		player.z = saved.player.z
		player.feet = saved.player.feet
		if not safe_position(player.x, player.z, player.feet):
			player = PlayerState.spawn(world, heights)
		else:
			player.feet = heights.surface_at(player.x, player.z, player.feet)
		yaw = saved.player.yaw
		pitch = clampf(saved.player.pitch, -1.4, 1.4)
	if not opening_spot.is_empty():
		player.x = opening_spot.position.x
		player.z = opening_spot.position.z
		player.feet = opening_spot.position.y
		yaw = opening_spot.heading
		opening_place = opening_spot.place
		_opening_points = opening_spot.points
		# 11.6: вступительный проезд по дороге не упирается в бревно
		vegetation.road.clear.append(Vector2(player.x, player.z))
	terrain_stream.update(player.x, player.z, true, true, NEAR)
	t = _mark("start_terrain_ms", t)
	if saved.is_empty() and opening_spot.is_empty() and world.settlements.size() > 0:
		# лицом к костру
		var s := PlayerState.home(world)
		yaw = atan2(player.x - s.x * GameConfig.TILE, player.z - s.y * GameConfig.TILE)
	outer = OuterTerrain.new()
	outer.name = "OuterTerrain"
	add_child(outer)
	if world.outer != null:
		outer.setup(world, heights)
		outer.preload_around(player.x, player.z, OuterTerrain.RADIUS / 2.0)
		regions = RegionStream.new()
		regions.name = "Regions"
		add_child(regions)
		regions.setup(world, heights, outer, vegetation)
	heights.obstacles = ForestObstacles.new(world, heights)
	heights.obstacles.update(player.x, player.z, vegetation.obstacles, vegetation.obstacles_version, true)
	bike = BikeRide.park_near(player, yaw, world, heights)
	if not saved.is_empty():
		var b: Dictionary = saved.bike
		if safe_position(b.x, b.z, b.y):
			bike.x = b.x
			bike.z = b.z
			bike.y = heights.surface_at(b.x, b.z, b.y)
			bike.heading = b.heading
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
	heights.obstacles.update(player.x, player.z, vegetation.obstacles, vegetation.obstacles_version, true)
	# Посадка из сохранения проходит те же проверки после появления локальных препятствий.
	if not saved.is_empty() and saved.bike.riding and bike.prepare_mount(player, world, heights):
		bike.mount(player)
		_snap()
		bike_view.draw(1.0)
	if not opening_spot.is_empty():
		bike.x = player.x
		bike.z = player.z
		bike.y = player.feet
		bike.heading = yaw
		bike.mount(player)
		pitch = -0.3
		_cam_y = player.feet + 1.4
		_opening = opening_spot.cinematic
		if _opening:
			bike.speed = OpeningRoute.SPEED
			var forward := Vector3(-sin(yaw), 0.0, -cos(yaw))
			var side := Vector3(cos(yaw), 0.0, -sin(yaw))
			_opening_target = opening_spot.position + forward * 2.4 + Vector3.UP * 0.65
			_opening_camera = opening_spot.position + forward * 2.4 + side * 3.2
			_opening_camera.y = heights.surface_at(_opening_camera.x, _opening_camera.z, player.feet) + 0.45
		_snap()
		bike_view.draw(1.0)
	t = _mark("start_vegetation_ms", t)
	if not saved.is_empty():
		bike_view.set_lamp(saved.get("lamp", false))
	camera.fov = GameSettings.fov
	var wind_layer := CanvasLayer.new()
	wind_layer.layer = 0
	add_child(wind_layer)
	_speed_wind = SpeedWind.new()
	wind_layer.add_child(_speed_wind)
	_apply_shadows()
	day = DayCycle.new($WorldEnvironment.environment, $Sun)
	day.terrain_mats = [$Terrain.material_override]
	day.camera = camera
	day.world_seed = world.seed_num
	hour = GameSettings.pick_start_hour() if saved.is_empty() else fposmod(saved.player.hour, 24.0)
	day.apply(hour, time)
	_update_camera(1.0, 0.0)
	if _opening:
		_draw_opening(1.0)
	else:
		_opening_welcome()
	audio.setup(world, heights)
	navigation_line = NavigationLine.new()
	add_child(navigation_line)
	navigation_line.setup(world, heights)
	hud.goal_changed.connect(_navigation_goal)
	hud.travel_requested.connect(travel_to)
	quests = Quests.new()
	quests.changed.connect(_quest_changed)
	hud.quests = quests
	if not saved.is_empty():
		var places := {}
		for p: Dictionary in hud.all_places():
			places[p.key] = p
		hud.visited = saved.visited.duplicate()
		quests.restore_state(saved.quest, places)
		_quest_changed()
		hud.set_goal(places.get(saved.goal, {}))
	photo.photo_taken.connect(_quest_photo)
	photo.wanted_reach = Quests.SHOT_REACH
	for s: Dictionary in world.settlements:
		var foot := SettlementsBuilder.board_foot(s, heights)
		_boards.append({at = Transform3D(Basis(Vector3.UP, -PI / 4.0), foot + Vector3(0, 1.35, 0)), place = s})
	capture_mouse()
	_mark("start_rest_ms", t)


func safe_position(x: float, z: float, feet: float) -> bool:
	return absf(x) < world.W * TILE * 4.0 and absf(z) < world.H * TILE * 4.0 \
		and heights.depth_at(x, z, feet) < GameConfig.FORD_DEPTH \
		and PlayerState.is_passable(world, heights, x, z, feet, PlayerState.BODY_R)


static func save_signature(w: WorldData) -> String:
	var rows: Array = []
	for kind: String in WorldData.PLACE_KINDS:
		for p: Dictionary in w.get(kind + "s"):
			rows.append([kind, p.x, p.y, p.get("name", "")])
	return var_to_bytes(rows).hex_encode().sha256_text()


static func can_restore(saved: Dictionary, w: WorldData) -> bool:
	if saved.signature != save_signature(w):
		return false
	var places := {}
	for kind: String in WorldData.PLACE_KINDS:
		for src: Dictionary in w.get(kind + "s"):
			var id := WorldData.place_id(kind, src.x, src.y)
			var p := w.place(id).duplicate()
			p.key = id
			places[id] = p
	for id: String in saved.visited:
		if not places.has(id):
			return false
	return Quests.new().restore_state(saved.quest, places)


func save_state() -> Dictionary:
	return {format = 1, seed = world.seed_text, saved_at = Time.get_unix_time_from_system(),
		signature = save_signature(world), visited = hud.visited.duplicate(), quest = quests.save_state(),
		goal = hud.goal.get("key", ""),
		lamp = bike_view.lamp_on(),
		player = {x = player.x, z = player.z, feet = player.feet, yaw = yaw, pitch = pitch, hour = hour},
		bike = {x = bike.x, z = bike.z, y = bike.y, heading = bike.heading, riding = bike.riding}}


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
	if p:
		_set_photo(false)
	paused = p
	if is_instance_valid(navigation_line) and p:
		navigation_line.visible = false
	if is_instance_valid(_speed_wind):
		_speed_wind.visible = not p
	if is_instance_valid(_opening_caption):
		_opening_caption.visible = not p and _opening
	if p:
		_close_settlement(false)
	else:
		_apply_shadows() # тени меняются в настройках на паузе
		if vegetation.set_draw(GameSettings.draw): # и дальность прорисовки (с 9.8+)
			vegetation.update(player.x, player.z, true)
	audio.set_paused(p)
	# отпущенная кнопка мыши на паузе не приходит, перетаскивание не должно «залипнуть»
	_dragging = false
	if p or show_map:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	else:
		capture_mouse()


func look(dx: float, dy: float) -> void:
	if _opening:
		return
	var k := GameConfig.MOUSE * GameSettings.mouse * (photo.look_scale() if photo.active else 1.0)
	yaw -= dx * k
	pitch = clampf(pitch - dy * k * (-1.0 if GameSettings.invert_y else 1.0), -1.5, 1.5)
	_looked_at = time


## Сесть на велосипед, если он рядом, или слезть с него (E, с 10.1; до этого F)
func toggle_bike() -> void:
	if _opening or crash.active():
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
	if not bike.prepare_mount(player, world, heights):
		hud.toast("Не хватает места для посадки. Подойдите с другой стороны")
		return
	bike.mount(player)
	_cam_y = player.feet + 1.4
	_cam_dist = GameConfig.BIKE_CAM
	yaw = bike.heading
	pitch = -0.3
	_snap()


## ПКМ пешком: достать фотоаппарат или убрать его
func toggle_photo() -> void:
	if photo.active:
		_set_photo(false)
		return
	if _opening or paused or show_map or crash.active() or _settlement_open():
		return
	if bike.riding:
		hud.toast_now("Фотоаппарат — пешком: слезьте с велосипеда (E)")
		return
	if Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
		capture_mouse()
	_set_photo(true)


func _set_photo(on: bool) -> void:
	if photo == null or photo.active == on:
		return
	if on:
		photo.enter()
	else:
		photo.exit()
	hud.set_photo_mode(on)


## Точки наведения фотоаппарата — подписи мест (SettlementsBuilder._label): над костром поселения,
## над вершиной, над серединой озера, над местом. Радиус — примерный размер места, reach — дальше не узнать
func _photo_anchors() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for child in $Settlements.get_children():
		if not (child is Label3D and child.has_meta("place_id")):
			continue
		var p := world.place(child.get_meta("place_id"))
		if p.is_empty():
			continue
		var a := {id = p.id, name = p.name, pos = (child as Label3D).global_position}
		match p.kind:
			"settlement":
				a.merge({kind = "Поселение", radius = 40.0, reach = 1500.0})
			"peak":
				a.merge({kind = "Вершина", radius = 50.0, reach = 2500.0})
			"lake":
				a.merge({kind = "Озеро", radius = sqrt(p.src.cells / PI) * TILE, reach = 1500.0})
			_:
				var title: String = StageSites.TYPES[p.src.type].title
				a.merge({kind = title.left(1).to_upper() + title.substr(1), radius = 12.0, reach = 700.0})
		out.append(a)
	return out


## Склон между глазами и местом: точки луча ниже земли больше чем на метр. Последние 8 % пути не проверяются —
## это склон самой вершины или берег под подписью
func _occluded(from: Vector3, to: Vector3) -> bool:
	var steps := clampi(int(from.distance_to(to) / 25.0), 8, 48)
	for i in range(1, steps):
		var t := float(i) / steps
		if t > 0.92:
			break
		var p := from.lerp(to, t)
		if heights.ground_at(p.x, p.z) > p.y + 1.0:
			return true
	return false


func toggle_map() -> void:
	if _opening:
		return
	_set_photo(false)
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
	if _opening or paused or player == null or not world.accessible(place.x, place.y):
		return
	if bike.riding and bike.airborne:
		return
	if quests != null and quests.cargo:
		hud.toast_now("С сумкой за спиной быстро не переместиться — довезите её сами")
		return
	_set_photo(false)
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


## Y доступна и в воздухе/рэгдолле. Сначала ищем и проверяем место, лишь затем меняем состояние.
func restore_at_place() -> bool:
	if _opening:
		return false
	if paused or player == null or bike == null or not is_instance_valid(bike_view) or world == null or heights == null or _settlement_open() or time < _rescue_ready:
		return false
	_rescue_ready = time + 1.0
	var origin := Vector3(player.x, player.feet, player.z)
	var spot := {}
	var refreshed := false
	# После прогрева растительности проверяем свежий валежник; отказ не переносит игрока.
	for attempt in 3:
		var details := vegetation.obstacles if vegetation != null else (heights.obstacles.data if heights.obstacles != null else PackedFloat32Array())
		spot = BikeRecovery.find(world, heights, origin, yaw, details)
		if spot.is_empty():
			break
		_refresh_recovery_area(spot.position)
		refreshed = true
		if not BikeRecovery.placement(world, heights, spot.position, spot.heading, null, true).is_empty():
			break
		spot = {}
	if spot.is_empty():
		if refreshed:
			_refresh_recovery_area(origin)
		if hud != null:
			hud.toast_now("Безопасное место не найдено. Положение сохранено")
		return false
	if crash != null:
		crash.abort()
	_set_photo(false)
	player = PlayerState.new()
	player.x = spot.position.x
	player.z = spot.position.z
	player.feet = spot.position.y
	# Сохраняем сам велосипед и фару, очищаем только движение и состояние падения.
	bike.x = player.x
	bike.z = player.z
	bike.y = player.feet
	bike.heading = spot.heading
	bike.tilt = 0.0
	bike.mount(player)
	yaw = bike.heading
	pitch = -0.3
	_cam_y = player.feet + 1.4
	_cam_dist = GameConfig.BIKE_CAM
	_dip = 0.0
	_dip_v = 0.0
	_trauma = 0.0
	_bob_amp = 0.0
	_moving = false
	_dragging = false
	_target = {}
	_rescue_input_until = time + 0.35
	if terrain_stream != null:
		terrain_stream.update(player.x, player.z, true, true, NEAR)
	if world.outer != null and outer != null:
		outer.preload_around(player.x, player.z, OuterTerrain.RADIUS / 2.0)
	_snap()
	bike_view.draw(1.0)
	if show_map:
		toggle_map()
	if camera != null:
		_update_camera(1.0, 0.0)
	if hud != null:
		hud.toast_now("Вы с велосипедом у места «%s»" % spot.name)
	return true


func _refresh_recovery_area(at: Vector3) -> void:
	if vegetation != null:
		vegetation.update(at.x, at.z, true)
	if heights.obstacles != null:
		var details := vegetation.obstacles if vegetation != null else heights.obstacles.data.duplicate()
		heights.obstacles.update(at.x, at.z, details, vegetation.obstacles_version if vegetation != null else 0, true)


func _unhandled_input(event: InputEvent) -> void:
	if event.is_echo():
		return
	if _settlement_open():
		if event.is_action_pressed("pause") or event.is_action_pressed("interact"):
			_close_settlement()
			get_viewport().set_input_as_handled()
		return
	if event.is_action_pressed("pause"):
		# Esc сначала закрывает большую карту и убирает фотоаппарат, потом ставит паузу
		if show_map and not paused:
			toggle_map()
		elif photo != null and photo.active and not paused:
			_set_photo(false)
		else:
			pause_requested.emit()
		get_viewport().set_input_as_handled()
		return
	# до start() узлы игрока и велосипеда ещё не созданы
	if paused or player == null:
		return
	if _opening:
		if event.is_action_pressed("jump"):
			_finish_opening()
		get_viewport().set_input_as_handled()
		return
	if event.is_action_pressed("recover_bike"):
		restore_at_place()
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("toggle_map"):
		toggle_map()
	elif event.is_action_pressed("flashlight"):
		toggle_flashlight()
	elif event.is_action_pressed("time_skip"):
		hour = fposmod(hour + (-1.0 if Input.is_key_pressed(KEY_SHIFT) else 1.0), 24.0)
		hud.toast_now("Время %s" % DayCycle.clock(hour))
	elif event.is_action_pressed("interact") and not show_map:
		interact()
	elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_RIGHT:
		if event.pressed and not show_map:
			toggle_photo()
	elif event is InputEventMouseButton and photo.active and event.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN]:
		if event.pressed:
			photo.zoom_by(1 if event.button_index == MOUSE_BUTTON_WHEEL_UP else -1)
	elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if show_map:
			return
		if event.pressed and Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
			capture_mouse()
		elif event.pressed and photo.active:
			photo.shoot()
		_dragging = event.pressed
	elif event is InputEventMouseMotion:
		if show_map:
			return
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
	if _opening:
		_opening_time += dt
		fw = 1.0 if bike.speed < OpeningRoute.SPEED else (-1.0 if bike.speed > OpeningRoute.SPEED + 0.2 else 0.0)
		var at := Vector2(bike.x, bike.z)
		while _opening_point < _opening_points.size() - 1 and at.distance_to(_opening_points[_opening_point]) < 2.5:
			_opening_point += 1
		var forward := _opening_points[_opening_point] - at
		var wanted := atan2(-forward.x, -forward.y)
		st = clampf(-wrapf(wanted - bike.heading, -PI, PI) * 2.0, -1.0, 1.0)
		jump = false
	if time < _rescue_input_until:
		fw = 0.0
		st = 0.0
		jump = false
	_moving = false
	var crashed := false
	heights.obstacles.update(player.x, player.z, vegetation.obstacles, vegetation.obstacles_version)
	heights.obstacles.set_bumps(vegetation.bumps, vegetation.obstacles_version)
	if crash.active():
		# Камера следит за телом; завершение возвращает пешее управление на месте падения.
		var was_ragdoll := crash.phase == BikeCrash.Phase.RAGDOLL
		var back := crash.tick(dt, bike, world, heights)
		var at := crash.focus(bike)
		player.x = at.x
		player.z = at.z
		player.feet = at.y
		if was_ragdoll and crash.phase == BikeCrash.Phase.RECOVER:
			player.vx = 0.0
			player.vy = 0.0
			player.vz = 0.0
			pitch = -0.05
			_dip = 0.0
			_dip_v = 0.0
			_trauma = 0.0
			crashed = true
		if back:
			player.vx = 0.0
			player.vy = 0.0
			player.vz = 0.0
			player.on_ground = true
			player.land_impact = 0.0
			hud.toast("Вы встали. Подойдите к велосипеду и нажмите E")
			crashed = true
	elif bike.riding:
		var h0 := bike.heading
		bike.step(player, fw, st, not _opening and Input.is_action_pressed("run"), jump, dt, world, heights)
		if _opening and (bike.airborne or bike.crashed or bike.speed < 0.3):
			_finish_opening()
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
		elif bike.bottom_out > 0.0:
			audio.bottom_out(bike.bottom_out)
		crashed = bike.crashed
		if crashed:
			_crash()
	else:
		# с фотоаппаратом у глаз — медленный шаг, без бега и прыжков
		var aiming := photo.active
		_moving = player.step(fw, st, Input.is_action_pressed("run") and not aiming, jump and not aiming, yaw, dt, world, heights, 0.5 if aiming else 1.0)
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
		bike_view.tick(bike, dt, fw, not _opening and Input.is_action_pressed("run"))
	bike.land_impact = 0.0
	bike.bottom_out = 0.0
	audio.tick(player, bike.riding)
	if crashed:
		_snap()
	for text: String in player.check_discoveries(world, hud.visited):
		hud.toast(text)
	# шаг задания раньше цели компаса: он сам переставит цель на следующее место
	_quest_progress(quests.tick(func(place: Dictionary) -> bool: return hud.at_place(place, player.x, player.z)))
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
		if regions != null:
			for m: StandardMaterial3D in regions.windows:
				SettlementsBuilder.set_night(m, night)
	var near := {}
	var best := 80.0 * 80.0
	if night > 0.05:
		for list: Array in [fires, regions.fires if regions != null else []]:
			for f: Dictionary in list:
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
	_update_camera(alpha, delta)
	if _speed_wind != null:
		_speed_wind.update_effect(_speed_rush, delta)
	if _opening:
		_draw_opening(alpha)
	if navigation_line != null:
		navigation_line.update_line(pos, delta, not _opening and not show_map and not crash.active() and not photo.active)
	if place_names != null:
		place_names.update(camera, delta, hud.visited, photo.active, quests.known)
	if _bag != null and _bag.visible:
		# подпись над сумкой покачивается, чтобы её было видно издалека
		_bag_label.position.y = 0.75 + sin(time * 2.5) * 0.06
		_bag_label.visible = camera.global_position.distance_to(_bag.position) < 60.0 and not photo.active
	photo.update(camera, delta)
	_target = _aim()
	_update_hints()
	day.apply(hour, time)

	var uploaded := vegetation.update(pos.x, pos.z, false)
	uploaded = terrain_stream.update(pos.x, pos.z, false, not uploaded) or uploaded
	if world.outer != null:
		outer.update(pos.x, pos.z, not uploaded)
		# Новая область собирается в главном потоке: не в кадре с другой передачей на GPU.
		if not uploaded and regions.update(pos.x, pos.z):
			for m: StandardMaterial3D in regions.windows:
				SettlementsBuilder.set_night(m, _night)
	if _ocean != null:
		_ocean.position = Vector3(pos.x, 0.0, pos.z)
	var fire_time := lerpf(_prev_time, time, alpha)
	SettlementsBuilder.animate_fires(fires, fire_time, pos)
	if regions != null:
		SettlementsBuilder.animate_fires(regions.fires, fire_time, pos)
	_light_night(pos, fire_time)
	audio.update(pos, bike.speed if bike.riding else 0.0, bike.riding and not bike.airborne, delta, bike.lean if bike.riding else 0.0, bike.crank if bike.riding else 0.0, bike.braking if bike.riding else 0.0)

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


func opening_active() -> bool:
	return _opening


func _opening_welcome() -> void:
	if not opening_place.is_empty():
		hud.toast_now("Начало пути: «%s»" % opening_place.name)
	hud.toast("Tab — мини-карта, компас и задание")


func _finish_opening() -> void:
	_opening = false
	_opening_time = 0.0
	if is_instance_valid(_opening_caption):
		_opening_caption.queue_free()
	# Тот же велосипед, скорость и камера: никаких переносов при передаче управления.
	_rescue_input_until = time + 0.2
	hud.visible = not paused
	_update_camera(1.0, 0.0)
	_opening_welcome()


## Только геометрия рельефа и мостов/туннелей, как у обычной камеры. Растения могут закрывать кадр.
func _opening_safe_camera(target: Vector3, desired: Vector3, feet: float) -> Vector3:
	var count := maxi(1, ceili(target.distance_to(desired) / 0.2))
	var safe := target
	for i in range(1, count + 1):
		var point := target.lerp(desired, float(i) / count)
		if _cam_blocked(point, feet):
			break
		safe = point
	return safe


func _draw_opening(alpha: float) -> void:
	if not is_instance_valid(_opening_caption):
		var layer := CanvasLayer.new()
		add_child(layer)
		_opening_caption = Label.new()
		layer.add_child(_opening_caption)
		_opening_caption.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
		_opening_caption.offset_top = -65
		_opening_caption.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_opening_caption.add_theme_color_override("font_shadow_color", Color.BLACK)
		_opening_caption.add_theme_constant_override("shadow_offset_x", 2)
		_opening_caption.add_theme_constant_override("shadow_offset_y", 2)
		_opening_caption.text = "«%s»\nПробел — пропустить · Esc — пауза" % opening_place.name
	var elapsed := maxf(0.0, _opening_time - (1.0 - alpha) / Engine.physics_ticks_per_second)
	var pos := _prev.lerp(Vector3(player.x, player.feet, player.z), alpha)
	var target := pos + Vector3.UP * 1.4
	var standard := camera.transform
	if elapsed < OPENING_PASS:
		var safe := _opening_safe_camera(_opening_target, _opening_camera, pos.y)
		if safe.distance_to(_opening_camera) < 0.1:
			camera.look_at_from_position(safe, _opening_target)
		# Если низкий кадр закрыла местность, используем безопасный штатный ракурс.
		return
	var fraction := clampf((elapsed - OPENING_PASS) / OPENING_FOLLOW, 0.0, 1.0)
	var forward := Vector3(-sin(bike.heading), 0.0, -cos(bike.heading))
	var desired := target - forward * 9.0 + Vector3.UP * 3.0
	var far := _opening_safe_camera(target, desired, pos.y)
	if far.distance_to(target) > 0.1:
		camera.look_at_from_position(far, target)
		var blended := camera.transform.interpolate_with(standard, smoothstep(0.0, 1.0, fraction))
		var safe := _opening_safe_camera(target, blended.origin, pos.y)
		blended.origin = safe
		camera.transform = blended
	if fraction >= 1.0:
		_finish_opening()


## Тряска камеры после приземления сильнее soft (м/с)
func _shake_on_landing(impact: float, soft: float) -> void:
	if impact > soft:
		_trauma = minf(1.0, _trauma + (impact - soft) * 0.08)


## Седок упал (жёсткое приземление, удар в стену): велосипед и тело разлетаются (BikeCrash),
## после остановки игрок встаёт пешком; Y позволяет явно восстановиться вместе с рамой
func _crash() -> void:
	bike.crashed = false
	crash.start(bike_view, bike, bike.crash_velocity, heights)
	# 12.3: хрупкий груз бьётся при падении
	var broken := quests.crashed() if quests != null else ""
	if not broken.is_empty():
		hud.banner("Груз разбит", broken, Quests.KINDS.fragile.color)
	if bike.land_impact <= 0.0:
		audio.land(bike.x, bike.z, bike.y, 12.0) # удар в стену: глухой стук, как от жёсткой посадки
	bike.speed = 0.0
	pitch = -0.35
	_dip_v -= 3.0
	_trauma = 1.0


## Подсказки внизу экрана и у прицела — по тому, что игрок делает сейчас
func _update_hints() -> void:
	if _opening:
		hud.set_hints("Пробел — пропустить · Esc — пауза", "")
		return
	if _settlement_open() or photo.active:
		hud.set_hints("", "")
		return
	var prompt := ""
	if crash.active():
		hud.set_hints("Падение · Y — восстановиться у ближайшего места · Esc — пауза", "", true)
		return
	match _target.get("kind", ""):
		"board": prompt = "E — доска поселения «%s»: задания и маршруты" % _target.place.name
		"bike": prompt = "E — сесть на велосипед"
		"cargo": prompt = "E — надеть сумку"
	if bike.riding:
		hud.set_hints("W — педали · S — тормоз · A, D — руль · Shift — сильнее · Пробел — прыжок · E — слезть · Y — к месту · F — фара · Tab — карта и задание · Esc — пауза", prompt)
		return
	hud.set_hints("WASD — идти · Shift — бег · Пробел — прыжок · E — действие · ПКМ — фотоаппарат · Y — к ближайшему месту · F — фара · M — карта · Tab — карта и задание · Esc — пауза", prompt)


func _settlement_open() -> bool:
	return hud != null and hud.settlement_panel != null and hud.settlement_panel.visible


## Наведение: каждый предмет — коробка по его форме (велосипед — узкая и длинная по ходу, доска — щит).
## Луч из камеры по центру экрана:
## 1) если он попадает в коробки, выбирается та, что ближе к глазам, — то, на что игрок смотрит прямо
##    (велосипед у самой доски выбирается, когда взгляд на нём, а не на щите за ним);
## 2) если не попал никуда, луч «толще» на AIM_R: из задетых краем — ближайший к центру взгляда по углу.
## Берутся только предметы рядом: велосипед, на который можно сесть, доски не дальше REACH от глаз.
## Подсказку E показывают только для выбранного
func _aim() -> Dictionary:
	if player == null or paused or show_map or crash.active() or _settlement_open() or photo.active:
		return {}
	var from := camera.global_position
	var dir := -camera.global_basis.z
	var eye := Vector3(player.x, player.feet + GameConfig.EYE, player.z)
	var items: Array = []
	if not bike.riding and bike.can_mount(player):
		var at := bike.fallen_transform if bike.fallen else Transform3D(Basis(Vector3.UP, bike.heading), Vector3(bike.x, bike.y, bike.z))
		at.origin += at.basis.y * 0.55
		items.append({kind = "bike", at = at, half = Vector3(0.3, 0.55, 0.9)})
	for b: Dictionary in _boards:
		if eye.distance_squared_to(b.at.origin) < REACH * REACH:
			items.append({kind = "board", at = b.at, half = Vector3(0.9, 0.48, 0.08), place = b.place})
	if _bag != null and _bag.visible and not bike.riding and eye.distance_squared_to(_bag.position) < REACH * REACH:
		var at := _bag.transform
		at.origin += at.basis * Vector3(0.0, 0.0, CargoBag.SIZE.z * 0.5)
		items.append({kind = "cargo", at = at, half = CargoBag.SIZE * 0.5 + Vector3(0.05, 0.08, 0.05)})
	var best := {}
	var best_hit := INF
	var best_angle := INF
	for it: Dictionary in items:
		var inv: Transform3D = it.at.affine_inverse()
		var o := inv * from
		var d := inv.basis * dir
		var hit := _ray_box(o, d, it.half)
		if hit < best_hit:
			best = it
			best_hit = hit
		elif best_hit == INF and _ray_box(o, d, it.half + Vector3.ONE * AIM_R) < INF:
			var to: Vector3 = it.at.origin - from
			var angle := to.angle_to(dir)
			if angle < best_angle:
				best = it
				best_angle = angle
	return best


## Расстояние вдоль луча (o, d) до коробки с половинами сторон half вокруг нуля; INF — мимо
static func _ray_box(o: Vector3, d: Vector3, half: Vector3) -> float:
	var near := 0.0
	var far := INF
	for k in 3:
		if absf(d[k]) < 1e-6:
			if absf(o[k]) > half[k]:
				return INF
			continue
		var a := (-half[k] - o[k]) / d[k]
		var b := (half[k] - o[k]) / d[k]
		near = maxf(near, minf(a, b))
		far = minf(far, maxf(a, b))
	return near if near <= far else INF


## E: действие с тем, на что смотрит игрок; на велосипеде, если смотреть не на что, — слезть
func interact() -> void:
	_set_photo(false) # E с фотоаппаратом у глаз — сначала убрать его
	_target = _aim()
	match _target.get("kind", ""):
		"board": _open_settlement(_target.place)
		"bike": toggle_bike()
		"cargo": _quest_progress(quests.pick_up())
		_:
			if bike.riding:
				toggle_bike()


## Доска маршрутов поселения village; без него — та, на которую смотрит игрок
func _open_settlement(village := {}) -> void:
	if paused or show_map or _settlement_open() or crash.active():
		return
	if village.is_empty():
		village = _aim().get("place", {})
	if village.is_empty():
		return
	_set_photo(false)
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
	hud.settlement_panel.open(village, world, hud.places(), bike.distance_to(player) < 4.0, quests, _offers(village))


## Задания доски поселения village (Quests.offers): соседи по дорогам и дальнее поселение — из индекса мира
func _offers(village: Dictionary) -> Array:
	var here := SettlementPanel._target(world.place(WorldData.place_id("settlement", village.x, village.y)))
	var neighbors: Array = []
	for r: Dictionary in world.routes(here.id):
		neighbors.append(SettlementPanel._target(world.place(r.to if r.from == here.id else r.from)))
	var far := world.far_destination(here.id)
	return quests.offers(here, hud.all_places(), neighbors, {} if far.is_empty() else SettlementPanel._target(far), hud.visited, world.seed_num)


func _accept_quest(q: Dictionary) -> void:
	quests.accept(q)
	_close_settlement()
	hud.banner("Новое задание", q.title, Quests.KINDS[q.kind].color)
	hud.toast_now(quests.step_text())


func _abandon_quest() -> void:
	quests.abandon()
	_close_settlement()
	hud.toast_now("Вы отказались от задания")


## Сообщение о шаге задания: следующий шаг или «Задание выполнено» (крупно посередине и в счётчике)
func _quest_progress(text: String) -> void:
	if text.is_empty():
		return
	if quests.active.is_empty():
		hud.quest_done(quests.last)
		hud.banner("Задание выполнено", "%s · всего выполнено: %d" % [quests.last, quests.done], Hud.GOLD)
	else:
		hud.toast_now("Дальше: " + text)


## Снимок: засчитать для задания или подсказать, почему не засчитан
func _quest_photo(shot: Dictionary) -> void:
	var s := quests.step()
	if s.get("do") != "shoot":
		return
	if shot.place.is_empty():
		hud.toast_now("Наведите фотоаппарат на «%s»: снимок засчитается, когда в видоискателе появится название" % s.place.name)
	elif not quests.wants_photo(shot.place):
		hud.toast_now("Это «%s». Для задания нужен снимок «%s»" % [shot.name, s.place.name])
	elif shot.dist > Quests.SHOT_REACH:
		hud.toast_now("Слишком далеко для задания: подойдите к «%s» ближе %s (сейчас %s)" % [s.place.name, Hud._fmt_dist(Quests.SHOT_REACH), Hud._fmt_dist(shot.dist)])
	else:
		_quest_progress(quests.photographed(shot.place, shot.dist))


## Задание изменилось: цель на компасе, сумка у доски и за спиной, нужный снимок в видоискателе, счётчик
func _quest_changed() -> void:
	var goal := quests.goal()
	if not goal.is_empty():
		_quest_goal = goal.key
		hud.set_goal(goal)
	elif not _quest_goal.is_empty():
		if hud.goal.get("key") == _quest_goal:
			hud.set_goal({})
		_quest_goal = ""
	var s := quests.step()
	photo.wanted = s.place.key if s.get("do") == "shoot" else ""
	if s.get("do") == "pickup":
		if _bag == null:
			_bag = CargoBag.build()
			add_child(_bag)
			# подпись над сумкой: видна издалека и сквозь кусты, как метка предмета в играх
			_bag_label = Label3D.new()
			_bag_label.text = "▼ Сумка · E"
			_bag_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
			_bag_label.no_depth_test = true
			_bag_label.fixed_size = true
			_bag_label.pixel_size = 0.0015
			_bag_label.font_size = 28
			_bag_label.outline_size = 8
			_bag_label.modulate = Quests.KINDS.delivery.color
			_bag.add_child(_bag_label)
		# у правого края доски, лицом туда же, куда щит; стоит на земле
		var board := SettlementsBuilder.board_foot(s.place.src, heights)
		var basis := Basis(Vector3.UP, -PI / 4.0)
		var at := board + basis * Vector3(1.35, 0.0, 0.35)
		at.y = heights.ground_at(at.x, at.z) + CargoBag.SIZE.y * 0.5 + 0.03
		_bag.transform = Transform3D(basis.rotated(Vector3.UP, 0.4), at)
		_bag.visible = true
	elif _bag != null:
		_bag.visible = false
	bike_view.set_pack(quests.cargo)
	hud.quest_changed()


func _close_settlement(capture := true) -> void:
	if not _settlement_open():
		return
	hud.settlement_panel.hide()
	if capture and not paused and not show_map:
		capture_mouse()


func _navigation_goal(place: Dictionary) -> void:
	navigation_line.set_goal(place, Vector2(player.x, player.z))
	place_names.set_goal(place)


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


## Фонарик (F): с 10.4 это фара на руле велосипеда (BikeView.lamp), светит туда, куда повёрнут руль.
## Пешком она остаётся на велосипеде и освещает место, где он стоит
func toggle_flashlight() -> void:
	bike_view.set_lamp(not bike_view.lamp_on())
	hud.toast_now("Фара включена" if bike_view.lamp_on() else "Фара выключена")


## Камера в доле alpha пути между двумя последними тактами; dt — длина кадра, для сглаживания
func _update_camera(alpha: float, dt: float) -> void:
	var riding := bike != null and bike.riding
	var pos := _prev.lerp(Vector3(player.x, player.feet, player.z), alpha)
	# поворот, который сделал сам такт, доворачивается плавно; мышь уже учтена в yaw и pitch
	var view_yaw := yaw - _tick_yaw * (1.0 - alpha)
	var view_pitch := pitch - _tick_pitch * (1.0 - alpha)
	# 12.7: на скорости камера заглядывает внутрь поворота, куда повёрнут руль; мышь её не трогает
	var lead_goal := 0.0
	if riding and not crash.active() and not _opening and time - _looked_at > 1.0:
		lead_goal = -bike.steer * deg_to_rad(8.5) * smoothstep(3.0, 12.0, bike.speed)
	_cam_lead = lerpf(_cam_lead, lead_goal, _smooth(4.0, dt))
	if riding:
		view_yaw += _cam_lead
	var rush_goal := 0.0
	if riding and not crash.active() and not _opening:
		rush_goal = smoothstep(12.0, 26.0, absf(bike.speed))
		rush_goal += smoothstep(1.0, 5.0, bike.acceleration) * smoothstep(8.0, 18.0, absf(bike.speed)) * 0.2
	_speed_rush = lerpf(_speed_rush, minf(rush_goal, 1.0), _smooth(2.5, dt))
	# на скорости обзор чуть шире: на бегу немного, на велосипеде сильнее
	var fov_goal := GameSettings.fov
	if riding:
		fov_goal += GameConfig.BIKE_FOV * clampf((absf(bike.speed) - 2.0) / (GameConfig.BIKE_SPEED - 2.0), 0.0, 1.3)
	else:
		fov_goal += GameConfig.RUN_FOV * clampf((player.ground_speed() - GameConfig.WALK * 1.1) / (GameConfig.WALK * 0.6), 0.0, 1.0)
	if photo != null and photo.active:
		fov_goal = photo.fov(GameSettings.fov)
	camera.fov = lerpf(camera.fov, fov_goal, _smooth(9.0 if photo != null and photo.active else 4.0, dt))
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
	_bob_amp = lerpf(_bob_amp, 1.0 if _moving and player.on_ground and GameSettings.head_bob else 0.0, _smooth(8.0, dt))
	var stride := clampf(player.ground_speed() / GameConfig.WALK, 0.0, 1.6)
	var bob := sin(lerpf(_prev_bob, player.bob, alpha)) * 0.05 * stride * _bob_amp * (0.3 if photo != null and photo.active else 1.0)
	camera.position = Vector3(pos.x, pos.y + GameConfig.EYE + bob + dip, pos.z)
	camera.rotation = Vector3(view_pitch + jolt.x * 0.03, view_yaw + jolt.y * 0.02, jolt.z * 0.03)


## Доля, на которую за кадр dt догоняют цель при скорости rate (1/с): одинаково при любом FPS
static func _smooth(rate: float, dt: float) -> float:
	return 1.0 - exp(-rate * dt)
