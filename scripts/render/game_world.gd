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
## Рельеф, готовый сразу при старте и переносе (м). Дальше в тумане части догружаются по одной за кадр:
## на 900 м туман уже скрывает больше 80 % цвета, а за секунды загрузки игрок проходит считанные метры.
const NEAR := PlanTerrain.RADIUS / 2.0
const REACH := 3.5     # предметы дальше этого от глаз игрока (м) не выбираются взглядом
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
const BikePlacement = preload("res://scripts/render/bike_placement.gd")
var bike_placement: BikePlacement
var place_names: PlaceNames
var photo: PhotoCamera
var quests: Quests       # 11.9: задания с досок (Quests), счётчик — Hud.tracker
var _bag: Node3D         # сумка доставки у доски, пока её не взяли
var _bag_label: Label3D  # подпись над ней
var _quest_goal := ""    # key места, которое задание поставило целью на компасе
var navigation_line: NavigationLine
var _navigation_status := ""
var _speed_wind: SpeedWind
var _speed_rush: float:
	get: return camera_controller._speed_rush
	set(value): camera_controller._speed_rush = value
var opening_place := {}
var _opening := false
var _opening_time := 0.0
var _opening_camera := Vector3.ZERO
var _opening_target := Vector3.ZERO
var _opening_caption: Label
var _opening_points: Array[Vector2] = []
var _opening_point := 1

var services: ServiceScope = GameContext.scope
var camera_controller := PlayerCameraController.new()
var bike_controller := BikeController.new()
var stream_coordinator := WorldStreamCoordinator.new()
var interaction_service := InteractionService.new()
var world: WorldData
var heights: Heightfield
var hud: Hud
var player: PlayerState
var bike: BikeRide
var bike_view: BikeView
var crash: BikeCrash     # падение с велосипеда: ragdoll и подъём пешком
var stamina: Stamina:
	get: return bike_controller.stamina # 14.0: выносливость седока — ускорение с Shift тратит, накат и шаг восстанавливают
var water_effects: WaterEffects
var fires: Array = []
var windows: StandardMaterial3D # окна и фонари всех построек, ночью ярче (SettlementsBuilder.set_night)
var fire_light: OmniLight3D     # один свет на весь мир: ночью у ближайшего костра
var _night := -1.0
var outer: OuterTerrain   # рельеф за краем стартовой области
var regions: RegionStream # 13.9: подготовленные соседние области за краем плана
var terrain_stream: PlanTerrain
var _water_streams: Array[PlanTerrain] = []
var chunk_source: RefCounted
var _travel_task := -1
var _water_turn := 0
var _resource_before := {}
var load_timings := {}    # WorldLoader.timings и шаги start (мс), для tools/control/check.gd
var _ocean: Node3D        # плоскость моря: ездит за игроком, чтобы море не кончалось
var yaw: float:
	get: return camera_controller.yaw
	set(value): camera_controller.yaw = value
var pitch: float:
	get: return camera_controller.pitch
	set(value): camera_controller.pitch = value
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
var _looked_at: float:
	get: return camera_controller._looked_at
	set(value): camera_controller._looked_at = value
var _rescue_input_until := 0.0
var _cam_y: float:
	get: return camera_controller._cam_y
	set(value): camera_controller._cam_y = value
var _cam_dist: float:
	get: return camera_controller._cam_dist
	set(value): camera_controller._cam_dist = value
var _bob_amp: float:
	get: return camera_controller._bob_amp
	set(value): camera_controller._bob_amp = value
var _dip: float:
	get: return camera_controller._dip
	set(value): camera_controller._dip = value
var _dip_v: float:
	get: return camera_controller._dip_v
	set(value): camera_controller._dip_v = value
var _trauma: float:
	get: return camera_controller._trauma
	set(value): camera_controller._trauma = value
var _cam_lead: float:
	get: return camera_controller._cam_lead
	set(value): camera_controller._cam_lead = value
var _moving := false    # игрок шёл в последнем такте (для покачивания камеры)
var _prev: Vector3:
	get: return camera_controller._prev
	set(value): camera_controller._prev = value
var _prev_bob: float:
	get: return camera_controller._prev_bob
	set(value): camera_controller._prev_bob = value
var _prev_dip: float:
	get: return camera_controller._prev_dip
	set(value): camera_controller._prev_dip = value
var _prev_time: float:
	get: return camera_controller._prev_time
	set(value): camera_controller._prev_time = value
var _tick_yaw: float:
	get: return camera_controller._tick_yaw
	set(value): camera_controller._tick_yaw = value
var _tick_pitch: float:
	get: return camera_controller._tick_pitch
	set(value): camera_controller._tick_pitch = value

var _defs: Dictionary
var _grass_mesh: Mesh

@onready var camera: Camera3D = $Camera
@onready var vegetation: VegetationLayer = $Vegetation
@onready var audio: WorldAudio = $Audio


## Заполнить сцену загруженным миром (WorldLoader) и начать игру.
## С 9.0 сразу готовится только окружение игрока: ближний рельеф (до NEAR), лес вокруг и край за картой;
## дальний рельеф и растительность догружаются в игре, сначала по ходу движения.
func start(loaded: WorldLoader, hud_node: Hud, saved: Dictionary = {}, service_scope: ServiceScope = null) -> void:
	services = service_scope if service_scope != null else loaded.service_scope
	if services == null:
		services = GameContext.scope
	if services.resource_profile != null:
		_resource_before = services.resource_profile.stamp()
		if DisplayServer.get_name() != "headless": RenderingServer.viewport_set_measure_render_time(get_viewport().get_viewport_rid(), true)
	if loaded.service_scope == null: loaded.service_scope = services
	if loaded.chunk_source == null: loaded.prepare_streaming()
	chunk_source = loaded.chunk_source
	camera_controller.settings = services.settings
	camera_controller.heights = loaded.heights
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
	$Terrain.material_override = services.terrain.material(loaded.terrain_image, loaded.forest_surface)
	terrain_stream = PlanTerrain.new()
	terrain_stream.name = "PlanTerrain"
	$Terrain.add_child(terrain_stream)
	terrain_stream.setup(loaded.terrain_chunks, $Terrain.material_override, services.cache, world, heights, chunk_source)
	stream_coordinator.terrain_update = terrain_stream.update
	stream_coordinator.vegetation_update = vegetation.update
	stream_coordinator.vegetation_budgeted = vegetation.update_frame
	# Чанки уже содержат все треугольники. Монолит больше не нужен ни CPU, ни GPU.
	loaded.terrain_arrays = []
	t = _mark("start_material_terrain_setup_ms", t)
	var streamed_water := loaded.water_chunks.size() == 2
	var prepared_water: Array[Array] = []
	if streamed_water: prepared_water.assign([[], []])
	else: prepared_water = loaded.water_arrays
	for node: Node in WaterBuilder.build(world, prepared_water):
		$Water.add_child(node)
		if node.name == "Ocean":
			_ocean = node
	if streamed_water:
		for layer in 2:
			var water_stream := PlanTerrain.new()
			water_stream.water_layer = layer
			water_stream.cache_size = loaded.cache_size
			water_stream.setup(loaded.water_chunks[layer], WaterBuilder._material(false, layer == 1), services.cache, world, heights, chunk_source)
			$Water.add_child(water_stream)
			_water_streams.append(water_stream)
		stream_coordinator.water_update = _update_water
		loaded.water_arrays.clear()
	water_effects = WaterEffects.new()
	water_effects.setup($Water)
	$Water.add_child(water_effects)
	t = _mark("start_water_ms", t)
	vegetation.settings = services.settings
	vegetation.setup(world, heights, _defs, _grass_mesh, loaded.forest_surface)
	t = _mark("start_vegetation_setup_ms", t)
	var built := SettlementsBuilder.build($Settlements, world, heights)
	place_names = PlaceNames.new()
	place_names.setup($Settlements, heights)
	photo = PhotoCamera.new()
	photo.controls = services.controls
	add_child(photo)
	photo.anchors = _photo_anchors()
	photo.occluded = _occluded
	photo.familiar = func(id: String) -> bool: return hud.knows(id)
	photo.capturing.connect(_photo_capturing)
	fires = built.fires
	windows = built.windows
	fire_light = OmniLight3D.new()
	fire_light.light_color = Color8(0xff, 0xa8, 0x55)
	fire_light.omni_range = 14.0
	fire_light.visible = false
	$Settlements.add_child(fire_light)
	t = _mark("start_settlements_ms", t)
	StructuresBuilder.build($Structures, heights)
	TrailLabProps.populate($Structures, heights.trail_technical.get("props", []))
	t = _mark("start_structures_ms", t)
	load_timings.start_scene_ms = (t - scene_started) / 1000.0

	var spawn_started := Time.get_ticks_usec()
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	var opening_spot := (loaded.opening_spot if loaded.opening_prepared else OpeningRoute.choose(world, heights, rng)) if saved.is_empty() else {}
	load_timings.start_spawn_ms = (Time.get_ticks_usec() - spawn_started) / 1000.0
	# 14.4+: соседние области — только с бесконечной генерацией (галочка в меню); без неё граница
	# стартовой области закрыта: незакреплённая земля за краем недоступна (WorldData.accessible)
	if world.outer != null and services.settings.infinite_world:
		# 13.9+: закреплённые области мира — до игрока: сохранённое место может лежать в них.
		regions = RegionStream.new()
		regions.cpu_budget = services.cpu_budget
		regions.terrain_builder = services.terrain
		regions.name = "Regions"
		add_child(regions)
		regions.setup(world, heights, null, vegetation)
		regions.storage_failed.connect(hud.toast_now)
		stream_coordinator.region_restore = regions.restore
		if saved.is_empty():
			stream_coordinator.restore_regions(Vector3(world.W * TILE * 0.5, 0.0, world.H * TILE * 0.5))
		else:
			stream_coordinator.restore_regions(Vector3(saved.player.x, 0.0, saved.player.z))
	player = PlayerState.spawn(world, heights)
	if not saved.is_empty():
		world.expand_territory(world.W)
		player.x = saved.player.x
		player.z = saved.player.z
		player.feet = saved.player.feet
		# Стволы и валуны вокруг сохранённого места — до проверки: иначе можно появиться внутри дерева
		heights.obstacles = ForestObstacles.new(world, heights)
		heights.obstacles.update(player.x, player.z, PackedFloat32Array(), -1, true)
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
	stream_coordinator.force_terrain(Vector3(player.x, player.feet, player.z), NEAR)
	if chunk_source != null: chunk_source.finish_startup()
	t = _mark("start_terrain_ms", t)
	if saved.is_empty() and opening_spot.is_empty() and world.settlements.size() > 0:
		# лицом к костру
		var s: Variant = PlayerState.home(world)
		yaw = atan2(player.x - s.x * GameConfig.TILE, player.z - s.y * GameConfig.TILE)
	outer = OuterTerrain.new()
	outer.cpu_budget = services.cpu_budget
	outer.terrain_builder = services.terrain
	outer.name = "OuterTerrain"
	add_child(outer)
	if world.outer != null:
		outer.setup(world, heights)
		outer.preload_around(player.x, player.z, OuterTerrain.RADIUS / 2.0)
		if regions != null:
			regions.terrain = outer
	if heights.obstacles == null:
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
	stream_coordinator.force_vegetation(Vector3(player.x, player.feet, player.z))
	heights.obstacles.update(player.x, player.z, vegetation.obstacles, vegetation.obstacles_version, true)
	# Валежник и камни появились только сейчас: велосипед, поставленный раньше, может стоять в бревне
	if not bike.fits(bike.x, bike.z, bike.heading, world, heights):
		var moved := BikeRide.park_near(player, yaw, world, heights)
		if moved.fits(moved.x, moved.z, moved.heading, world, heights):
			bike.x = moved.x
			bike.z = moved.z
			bike.y = moved.y
			bike.heading = moved.heading
			_snap()
			bike_view.draw(1.0)
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
	camera.fov = services.settings.fov
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
	hour = services.settings.pick_start_hour() if saved.is_empty() else fposmod(saved.player.hour, 24.0)
	day.apply(hour, time)
	_update_camera(1.0, 0.0)
	if _opening:
		_draw_opening(1.0)
	else:
		_opening_welcome()
	audio.setup(world, heights)
	navigation_line = NavigationLine.new()
	navigation_line.background_search = true
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
	for s: SettlementData in world.settlements:
		var foot := SettlementsBuilder.board_foot(s, heights)
		_boards.append({at = Transform3D(Basis(Vector3.UP, -PI / 4.0), foot + Vector3(0, 1.35, 0)), place = s})
	if world.outer != null and outer != null:
		stream_coordinator.outer_update = outer.update
	if regions != null:
		stream_coordinator.region_update = regions.update
		stream_coordinator.region_priority = regions.publication_pending
	stream_coordinator.region_committed.connect(func() -> void:
		for m: StandardMaterial3D in regions.windows:
			SettlementsBuilder.set_night(m, _night))
	interaction_service.quests = quests
	interaction_service.world = world
	interaction_service.all_places = hud.all_places
	interaction_service.visited = hud.visited
	interaction_service.message.connect(hud.toast_now)
	interaction_service.banner.connect(hud.banner)
	interaction_service.completed.connect(hud.quest_done)
	interaction_service.close_requested.connect(_close_settlement)
	bike_controller.message.connect(hud.toast)
	bike_controller.mount_changed.connect(_bike_mount_changed)
	bike_controller.recovered.connect(func() -> void:
		hud.toast("Вы встали. Подойдите к велосипеду и нажмите %s" % services.controls.label("interact")))
	bike_controller.recovery_started.connect(func() -> void:
		pitch = -0.05
		_dip = 0.0
		_dip_v = 0.0
		_trauma = 0.0)
	capture_mouse()
	_mark("start_rest_ms", t)
	if services.resource_profile != null:
		services.resource_profile.phase("scene_start", _resource_before, services, load_timings.duplicate(true))
		services.resource_profile.save()


func _update_water(x: float, z: float, force := false, allow_apply := true, near := PlanTerrain.RADIUS) -> bool:
	var uploaded := false
	for offset in _water_streams.size():
		var stream := _water_streams[(_water_turn + offset) % _water_streams.size()]
		uploaded = stream.update(x, z, force, allow_apply and not uploaded, near) or uploaded
	_water_turn += 1
	return uploaded


func _photo_capturing(on: bool) -> void:
	if is_inside_tree() and not is_queued_for_deletion() and is_instance_valid(hud) and hud.world == world:
		hud.visible = not on and not paused and not _opening


func _exit_tree() -> void:
	if _travel_task != -1:
		WorkerThreadPool.wait_for_task_completion(_travel_task)
		_travel_task = -1
	if chunk_source != null: chunk_source.close()
	# Hud переживает игру; удалить только обработчики этой сцены, включая панель поселения.
	if is_instance_valid(hud):
		var connections: Array = [[hud.goal_changed, _navigation_goal], [hud.travel_requested, travel_to]]
		if is_instance_valid(hud.settlement_panel):
			var panel: SettlementPanel = hud.settlement_panel
			connections.append_array([[panel.closed, _close_settlement],
				[panel.destination_selected, _choose_settlement_route], [panel.bike_requested, _recall_bike],
				[panel.quest_accepted, _accept_quest], [panel.quest_abandoned, _abandon_quest]])
		for connection: Array in connections:
			var source: Signal = connection[0]
			var handler: Callable = connection[1]
			if source.is_connected(handler):
				source.disconnect(handler)


func safe_position(x: float, z: float, feet: float) -> bool:
	# 13.9+: дальние точки допустимы в закреплённых областях — их пропускает is_passable (accessible).
	return is_finite(x) and is_finite(z) and (absf(x) < world.W * TILE * 4.0 and absf(z) < world.H * TILE * 4.0
		or world.outer != null and world.outer.committed(floori(x / TILE), floori(z / TILE))) \
		and heights.depth_at(x, z, feet) < GameConfig.FORD_DEPTH \
		and PlayerState.is_passable(world, heights, x, z, feet, PlayerState.BODY_R)


static func save_signature(w: WorldData) -> String:
	var rows: Array = []
	for kind: String in WorldData.PLACE_KINDS:
		for p: Variant in w.get(kind + "s"):
			rows.append([kind, p.x, p.y, EntityCodec.value(p, "name", "")])
	return var_to_bytes(rows).hex_encode().sha256_text()


static func can_restore(saved: Dictionary, w: WorldData, settings: GameSettings = null) -> bool:
	if settings == null:
		settings = GameContext.scope.settings
	if saved.signature != save_signature(w):
		return false
	# 13.9+final: места и задания соседних областей — из их журнала на диске
	if w.outer != null and w.outer.get_ledger().is_empty() and settings.infinite_world:
		w.outer.set_ledger(RegionStream.read_ledger(w))
	var places := {}
	for kind: String in WorldData.PLACE_KINDS:
		for src: Variant in w.get(kind + "s"):
			var id := WorldData.place_id(kind, src.x, src.y)
			var p := w.place(id).duplicate()
			p.key = id
			places[id] = p
	for src: Dictionary in w.region_places().list:
		var p: Dictionary = src.duplicate()
		p.key = p.id
		places[p.id] = p
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
	if sun.shadow_enabled != services.settings.shadows:
		sun.shadow_enabled = services.settings.shadows
		$WorldEnvironment.environment.ssao_enabled = services.settings.shadows


func capture_mouse() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	_captured_at = Time.get_ticks_msec()


func set_paused(p: bool) -> void:
	if p:
		_cancel_bike_placement()
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
		if vegetation.set_draw(services.settings.draw): # и дальность прорисовки (с 9.8+)
			stream_coordinator.force_vegetation(Vector3(player.x, player.feet, player.z))
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
	var k := GameConfig.MOUSE * services.settings.mouse * (photo.look_scale() if photo.active else 1.0)
	yaw -= dx * k
	pitch = clampf(pitch - dy * k * (-1.0 if services.settings.invert_y else 1.0), -1.5, 1.5)
	_looked_at = time


## Сесть на велосипед, если он рядом, или слезть с него (E, с 10.1; до этого F)
func toggle_bike() -> void:
	if _opening or crash.active():
		return
	bike_controller.toggle_mount(player, bike, world, heights)


func _bike_mount_changed(riding: bool) -> void:
	if riding:
		_cam_y = player.feet + 1.4
		_cam_dist = GameConfig.BIKE_CAM
	yaw = bike.heading
	pitch = -0.3 if riding else -0.05
	_snap()


## ПКМ пешком: достать фотоаппарат или убрать его
func toggle_photo() -> void:
	if photo.active:
		_set_photo(false)
		return
	if _opening or paused or show_map or crash.active() or _settlement_open():
		return
	if bike.riding:
		hud.toast_now("Фотоаппарат — пешком: слезьте с велосипеда (%s)" % services.controls.label("interact"))
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
	var labels: Array = $Settlements.get_children()
	if regions != null:
		for node: Node in regions.get_children():
			labels.append_array(node.get_children())
	for child in labels:
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
	_cancel_bike_placement()
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
	_cancel_bike_placement()
	if quests != null and quests.cargo:
		hud.toast_now("С сумкой за спиной быстро не переместиться — довезите её сами")
		return
	_set_photo(false)
	_close_settlement(false)
	crash.abort()
	# стволы у места прибытия, чтобы не встать в дерево (валежник появится после раскладки подлеска)
	heights.obstacles.update(place.x * TILE, place.y * TILE, PackedFloat32Array(), -1, true)
	var arriving := PlayerState.arrive(world, heights, place)
	if chunk_source != null:
		set_paused(true)
		var source := chunk_source
		var at := Vector2(arriving.x, arriving.z)
		_travel_task = WorkerThreadPool.add_task(func() -> void:
			source.finish()
			source.prewarm([at], NEAR), true, "Место прибытия")
		while not WorkerThreadPool.is_task_completed(_travel_task): await get_tree().process_frame
		WorkerThreadPool.wait_for_task_completion(_travel_task)
		_travel_task = -1
		set_paused(false)
	player = arriving
	stream_coordinator.force_terrain(Vector3(player.x, player.feet, player.z), NEAR)
	if chunk_source != null: chunk_source.finish_startup()
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
	stream_coordinator.force_vegetation(Vector3(player.x, player.feet, player.z))
	if show_map:
		toggle_map()
	hud.toast_now("Вы переместились: «%s»" % place.name)


func _placing_bike() -> bool:
	return is_instance_valid(bike_placement) and bike_placement.active

func _cancel_bike_placement() -> void:
	if is_instance_valid(bike_placement):
		bike_placement.cancel()

func toggle_bike_placement() -> bool:
	if _placing_bike():
		_cancel_bike_placement()
		return false
	if _opening or paused or show_map or player == null or bike == null or _settlement_open():
		return false
	if (crash != null and crash.active()) or bike.airborne or not player.on_ground:
		if hud != null: hud.toast_now("Для размещения дождитесь остановки на земле")
		return false
	_set_photo(false)
	if not is_instance_valid(bike_placement):
		bike_placement = BikePlacement.new()
		add_child(bike_placement)
	bike_placement.begin(world, heights, Vector3(player.x, player.feet, player.z), yaw)
	if is_inside_tree(): capture_mouse()
	player.vx = 0.0
	player.vz = 0.0
	_dragging = false
	_update_bike_placement(0.0)
	return true

func _update_bike_placement(dt: float) -> void:
	if not _placing_bike() or camera == null:
		return
	var turn := Input.get_action_strength("move_right") - Input.get_action_strength("move_left")
	bike_placement.rotate_by(-turn * BikePlacement.ROTATE_SPEED * dt)
	var reach := Input.get_action_strength("move_forward") - Input.get_action_strength("move_back")
	if absf(reach) > 0.05:
		bike_placement.adjust_distance(reach * dt * 2)
	bike_placement.update_preview(camera.global_position, -camera.global_basis.z, yaw)

func confirm_bike_placement() -> bool:
	if not _placing_bike() or paused or show_map:
		return false
	_update_bike_placement(0.0)
	if not bike_placement.confirm(bike):
		if hud != null: _update_hints()
		return false
	# Игрок остаётся на месте пешком; освобождаем только застрявшую/упавшую раму.
	player.vx = 0
	player.vz = 0
	player.vy = 0
	player.on_ground = true
	_rescue_input_until = time + 0.2
	_target = {}
	_snap()
	bike_view.draw(1.0)
	if hud != null: hud.toast_now("Велосипед поставлен. Подойдите и нажмите %s" % services.controls.label("interact"))
	return true

## 14.0: подсказки показывают кнопки того, чем играют сейчас (Controls)
func _input(event: InputEvent) -> void:
	services.controls.note(event)


func _unhandled_input(event: InputEvent) -> void:
	if event.is_echo():
		return
	if _placing_bike():
		if event.is_action_pressed("recover_bike") or event.is_action_pressed("pause") or event.is_action_pressed("back") or (event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_RIGHT):
			_cancel_bike_placement()
		elif event.is_action_pressed("interact") or event.is_action_pressed("jump") or (event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT):
			confirm_bike_placement()
		elif event.is_action_pressed("toggle_map"):
			toggle_map()
		elif event is InputEventMouseButton and event.pressed and event.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN]:
			bike_placement.rotate_by(PI / 12 * (1 if event.button_index == MOUSE_BUTTON_WHEEL_UP else -1))
		elif event is InputEventMouseMotion:
			if Time.get_ticks_msec() - _captured_at >= 150:
				look(event.screen_relative.x, event.screen_relative.y)
		get_viewport().set_input_as_handled()
		return
	if _settlement_open():
		if event.is_action_pressed("pause") or event.is_action_pressed("interact") or event.is_action_pressed("back"):
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
	if event.is_action_pressed("back"):
		# B на геймпаде закрывает карту и убирает фотоаппарат, как Esc, но паузу не ставит
		if show_map:
			toggle_map()
		elif photo.active:
			_set_photo(false)
		get_viewport().set_input_as_handled()
	elif photo.active and event.is_action_pressed("photo_shoot"):
		photo.shoot()
	elif photo.active and (event.is_action_pressed("photo_zoom_in") or event.is_action_pressed("photo_zoom_out")):
		photo.zoom_by(1 if event.is_action_pressed("photo_zoom_in") else -1)
	elif event.is_action_pressed("photo"):
		if not show_map:
			toggle_photo()
	elif event.is_action_pressed("recover_bike"):
		toggle_bike_placement()
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
	if _placing_bike():
		_store_prev()
		return
	world.open_around(player.x / TILE, player.z / TILE)
	_store_prev()
	var yaw0 := yaw
	var pitch0 := pitch
	time += dt
	if services.settings.day_minutes > 0.0:
		hour = fposmod(hour + dt * 24.0 / (services.settings.day_minutes * 60.0), 24.0)
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
		crashed = bike_controller.recover(dt, player, bike, crash, world, heights)
	elif bike.riding:
		var h0 := bike.heading
		fw = bike_controller.ride(dt, player, bike, world, heights, fw, st, Input.is_action_pressed("run"), jump, _opening)
		if _opening and (bike.airborne or bike.crashed or bike.speed < 0.3):
			_finish_opening()
		camera_controller.follow_bike(bike, bike.heading - h0, time, dt)
		_shake_on_landing(bike.land_impact, 6.0)
		if bike.land_impact > 0.0:
			if services.settings.head_bob:
				_dip_v -= clampf(bike.land_impact - 2.5, 0.0, 8.0) * 0.12
			audio.land(bike.x, bike.z, bike.y, bike.land_impact)
			services.controls.rumble(clampf(bike.land_impact / 10.0, 0.0, 0.6), clampf((bike.land_impact - 4.0) / 8.0, 0.0, 1.0), 0.15)
		elif bike.bottom_out > 0.0:
			audio.bottom_out(bike.bottom_out)
			# 14.1: пробой вилки — удар рамы: камера проседает и вздрагивает, геймпад отдаёт тяжёлым мотором
			var hit := clampf(bike.bottom_out - BikeRide.BOTTOM_OUT, 0.0, 3.0)
			if services.settings.head_bob:
				_dip_v -= 0.4 + hit * 0.35
			_trauma = minf(1.0, _trauma + 0.12 + hit * 0.08)
			services.controls.rumble(0.3, 0.45 + hit * 0.15, 0.1)
		crashed = bike.crashed
		if crashed:
			_crash()
	else:
		# с фотоаппаратом у глаз — медленный шаг, без бега и прыжков
		var aiming := photo.active
		var running := Input.is_action_pressed("run") and not aiming
		_moving = player.step(fw, st, running, jump and not aiming, yaw, dt, world, heights, 0.5 if aiming else 1.0)
		stamina.tick_foot(dt, running and _moving)
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
	camera_controller.tick_effects(dt)
	if not crash.active():
		bike_view.tick(bike, dt, fw, bike.riding and not _opening and stamina.can_boost(Input.is_action_pressed("run"), fw))
	bike.land_impact = 0.0
	bike.bottom_out = 0.0
	audio.tick(player, bike.riding)
	if crashed:
		_snap()
	for text: String in player.check_discoveries(world, hud.visited):
		hud.toast(text)
	# шаг задания раньше цели компаса: он сам переставит цель на следующее место
	_quest_progress(quests.tick(func(place: Dictionary) -> bool: return hud.at_place(place, player.x, player.z)))
	var reached := hud.check_goal(player.x, player.z) if navigation_line == null or navigation_line.can_arrive(Vector3(player.x, player.feet, player.z)) else ""
	if reached != "":
		hud.toast(reached)


## Запомнить положение игрока как предпоследний такт (для интерполяции кадра)
func _store_prev() -> void:
	camera_controller.store_previous(player, time)


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
	if services.resource_profile != null: services.resource_profile.frame(get_viewport(), delta * 1000.0, self)
	hud.lock_hint.visible = not paused and not _settlement_open() and not services.controls.joypad and Input.mouse_mode != Input.MOUSE_MODE_CAPTURED
	if paused:
		return
	if not show_map and not _settlement_open():
		var stick := services.controls.look_delta(delta)
		if stick != Vector2.ZERO:
			look(stick.x, stick.y)
	hud.set_stamina(stamina.value, stamina.exhausted, stamina.state)
	hud.set_brakes(bike)
	# доля пути от предпоследнего такта физики к последнему, в которой сейчас кадр
	var alpha := 1.0 if _placing_bike() else Engine.get_physics_interpolation_fraction()
	var pos := _prev.lerp(Vector3(player.x, player.feet, player.z), alpha)
	if crash.active():
		crash.draw()
	else:
		bike_view.draw(alpha)
	_update_camera(alpha, delta)
	_update_bike_placement(delta)
	if _speed_wind != null:
		_speed_wind.update_effect(_speed_rush, delta)
	if _opening:
		_draw_opening(alpha)
	if navigation_line != null:
		navigation_line.update_line(pos, delta, not _opening and not show_map and not crash.active() and not photo.active and not _placing_bike())
		if navigation_line.visible and navigation_line.status != _navigation_status:
			_navigation_status = navigation_line.status
			if _navigation_status != "": hud.toast_now(_navigation_status)
	if place_names != null:
		place_names.update(camera, delta, hud.visited, photo.active, quests.known)
	if _bag != null and _bag.visible:
		# подпись над сумкой покачивается, чтобы её было видно издалека
		_bag_label.position.y = 0.75 + sin(time * 2.5) * 0.06
		_bag_label.visible = camera.global_position.distance_to(_bag.position) < 60.0 and not photo.active
	photo.bike_at = Vector3.INF if bike.riding or crash.active() else Vector3(bike.x, bike.y + 0.6, bike.z)
	photo.update(camera, delta)
	_target = _aim()
	_update_hints()
	day.apply(hour, time)

	stream_coordinator.update(pos)
	if _ocean != null:
		_ocean.position = Vector3(pos.x, 0.0, pos.z)
	var fire_time := lerpf(_prev_time, time, alpha)
	SettlementsBuilder.animate_fires(fires, fire_time, pos)
	if regions != null:
		SettlementsBuilder.animate_fires(regions.fires, fire_time, pos)
	_light_night(pos, fire_time)
	audio.update(pos, bike.speed if bike.riding else 0.0, bike.riding and not bike.airborne, delta, bike.lean if bike.riding else 0.0, bike.crank if bike.riding else 0.0, maxf(bike.braking, smoothstep(0.04, 0.18, absf(bike.slip)) * 0.65) if bike.riding else 0.0)

	info_timer -= delta
	if info_timer <= 0.0:
		info_timer = 0.15
		hud.update_info(player, yaw, heights.depth_at(player.x, player.z, player.feet))
	hud.set_player(pos.x, pos.z, bike.heading if bike.riding else yaw)
	hud.set_bike(bike.x, bike.z, not bike.riding)


## Камера на велосипеде упирается в землю, настил моста или стену (перила, стены туннеля) в точке p
func _cam_blocked(p: Vector3, feet: float) -> bool:
	return camera_controller._cam_blocked(p, feet)

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
		_opening_caption.text = "«%s»\n%s — пропустить · %s — пауза" % [opening_place.name, services.controls.label("jump"), services.controls.label("pause")]
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
	camera_controller.shake_on_landing(impact, soft)

## Седок упал (жёсткое приземление, удар в стену): велосипед и тело разлетаются (BikeCrash),
## после остановки игрок встаёт пешком; Y позволяет выбрать новое место для рамы
func _crash() -> void:
	bike_controller.begin_crash(bike_view, bike, crash, heights)
	# 12.3: хрупкий груз бьётся при падении
	var broken := quests.crashed() if quests != null else ""
	if not broken.is_empty():
		hud.banner("Груз разбит", broken, Quests.KINDS.fragile.color)
	if bike.land_impact <= 0.0:
		audio.land(bike.x, bike.z, bike.y, 12.0) # удар в стену: глухой стук, как от жёсткой посадки
	pitch = -0.35
	_dip_v -= 3.0
	_trauma = 1.0


## Подсказки внизу экрана и у прицела — по тому, что игрок делает сейчас.
## 14.2: только действия к месту, чипами [клавиша] действие; постоянные клавиши (WASD, Esc, Tab, M) — в паузе
func _update_hints() -> void:
	var k := services.controls.label
	if _placing_bike():
		var confirm_key: String = k.call("jump") if services.controls.joypad else "ЛКМ / E"
		var cancel_key: String = k.call("back") if services.controls.joypad else "ПКМ / Y / Esc"
		var help := [[cancel_key, "Отмена"], ["Левый стик", "Поворот и расстояние"]] if services.controls.joypad else [[cancel_key, "Отмена"], ["A/D / колесо", "Поворот"], ["W/S", "Расстояние"]]
		hud.set_hints(help, [[confirm_key, bike_placement.reason]], true)
		return
	if _opening or _settlement_open() or photo.active:
		hud.set_hints([], [])
		return
	if crash.active():
		hud.set_hints([], [], true)
		return
	var near: Array = []
	match _target.get("kind", ""):
		"board": near = [[k.call("interact"), "Доска «%s»" % _target.place.name]]
		"bike": near = [[k.call("interact"), "Сесть"]]
		"cargo": near = [[k.call("interact"), "Надеть сумку"]]
	# внизу (видно с зажатым Tab) — главное для того, чем игрок занят
	if bike.riding:
		hud.set_hints([[k.call("run"), "Сильнее"], [k.call("jump"), "Прыжок"], [k.call("interact"), "Слезть"], [k.call("recover_bike"), "Поставить велосипед"]], near)
		return
	var photo_key: String = k.call("photo") if services.controls.joypad else "ПКМ"
	hud.set_hints([[k.call("run"), "Бег"], [k.call("jump"), "Прыжок"], [photo_key, "Фотоаппарат"], [k.call("recover_bike"), "Поставить велосипед"]], near)


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
	if player == null or paused or show_map or crash.active() or _settlement_open() or photo.active or _placing_bike():
		return {}
	var from := camera.global_position
	var dir := -camera.global_basis.z
	var eye := Vector3(player.x, player.feet + GameConfig.EYE, player.z)
	var items: Array = []
	if not bike.riding and bike.can_mount(player):
		var at := bike.fallen_transform if bike.fallen else Transform3D(Basis(Vector3.UP, bike.heading), Vector3(bike.x, bike.y, bike.z))
		at.origin += at.basis.y * 0.55
		items.append({kind = "bike", at = at, half = Vector3(0.3, 0.55, 0.9)})
	for b: Dictionary in _boards + (regions.boards if regions != null else []):
		if eye.distance_squared_to(b.at.origin) < REACH * REACH:
			items.append({kind = "board", at = b.at, half = Vector3(0.9, 0.48, 0.08), place = b.place})
	if _bag != null and _bag.visible and not bike.riding and eye.distance_squared_to(_bag.position) < REACH * REACH:
		var at := _bag.transform
		at.origin += at.basis * Vector3(0.0, 0.0, CargoBag.SIZE.z * 0.5)
		items.append({kind = "cargo", at = at, half = CargoBag.SIZE * 0.5 + Vector3(0.05, 0.08, 0.05)})
	return interaction_service.select(items, from, dir)


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
func _open_settlement(village: Variant = {}) -> void:
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
func _offers(village: Variant) -> Array:
	return interaction_service.offers(village)


func _accept_quest(q: QuestData) -> void:
	interaction_service.accept(q)

func _abandon_quest() -> void:
	interaction_service.abandon()

func _quest_progress(text: String) -> void:
	interaction_service.progress(text)

func _quest_photo(shot: Dictionary) -> void:
	interaction_service.photographed(shot)


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
	navigation_line.set_goal(place, Vector2(player.x, player.z), player.feet)
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
## Пешком переключается только рядом с велосипедом, в пределах доступности посадки.
func toggle_flashlight() -> void:
	if not bike.riding and not bike.can_mount(player):
		hud.toast_now("Подойдите к велосипеду, чтобы переключить фару")
		return
	bike_view.set_lamp(not bike_view.lamp_on())
	hud.toast_now("Фара включена" if bike_view.lamp_on() else "Фара выключена")


## Камера в доле alpha пути между двумя последними тактами; dt — длина кадра, для сглаживания
func _update_camera(alpha: float, dt: float) -> void:
	camera_controller.update(alpha, dt, player, bike, camera, time, _opening, _moving,
		crash.active(), photo != null and photo.active,
		photo.fov(services.settings.fov) if photo != null else services.settings.fov, bike_view.view_squash())
