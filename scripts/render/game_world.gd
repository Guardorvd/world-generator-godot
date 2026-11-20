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
const ShopProgress := preload("res://scripts/game/shop_progress.gd")
const CargoBag = preload("res://scripts/render/cargo_bag.gd")
const BeaconLayer = preload("res://scripts/render/beacon_layer.gd")
const PaintLayer = preload("res://scripts/render/paint_layer.gd")
const SettlementPanel = preload("res://scripts/ui/settlement_panel.gd")
const BikePlacement = preload("res://scripts/render/bike_placement.gd")
const HudStyle := preload("res://scripts/ui/hud_style.gd")
const BoardDisplay = preload("res://scripts/render/board_display.gd")
var board_display: BoardDisplay  # щит ближней доски с картой и заданиями
var bike_placement: BikePlacement
var place_names: PlaceNames
var photo: PhotoCamera
var quests: Quests       # 11.9: задания с досок (Quests), счётчик — Hud.tracker
var shop_progress: ShopProgress
var _bag: Node3D         # сумка доставки у доски, пока её не взяли
var _bag_label: Label3D  # подпись над ней
var _beacon_layer: BeaconLayer
var _paint_layer: PaintLayer
var _quest_goal := ""    # key места, которое задание поставило целью на компасе
var navigation_line: NavigationLine
var _navigation_status := ""
var _speed_wind: SpeedWind
var _speed_rush: float:
	get: return camera_controller._speed_rush
	set(value): camera_controller._speed_rush = value
var opening_place := {}
var _route_revision := -1
var _opening := false
var startup_input_locked := false
var _opening_time := 0.0
var _opening_camera := Vector3.ZERO
var _opening_target := Vector3.ZERO
var _opening_caption: PanelContainer
var _opening_points: Array[Vector2] = []
var _opening_point := 1

var services: ServiceScope = GameContext.scope
var camera_controller := PlayerCameraController.new()
var bike_controller := BikeController.new()
var stream_coordinator := WorldStreamCoordinator.new()
var interaction_service := InteractionService.new()
var world: WorldData
var heights: Heightfield
var local_mist: Node3D
var hud: Hud
var player: PlayerState
var bike: BikeRide
var bike_view: BikeView
var crash: BikeCrash     # падение с велосипеда: ragdoll и подъём пешком
var stamina: Stamina:
	get: return bike_controller.stamina # 14.0: выносливость седока; 15.0: запас рывков (Shift — треть полоски), восстанавливается всегда
var water_effects: WaterEffects
var brake_effects: BrakeEffects
var ambient: AmbientParticles # 11.11: частицы окружения (пылинки, листья, светлячки, снег)
var garlands: TreeGarlandsLayer # парковые гирлянды вдоль отдельных дорог и полян
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
var _travel_waiting := false # во время подготовки и передачи чанков физика и обычный стриминг остановлены
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
var _clock_hour := 9.0   # полные часы для смены ночей, включая переход через полночь
var _prev_clock_hour := 9.0
var _sky_time_offset := 0.0
var _clock_frame_tick := -1.0
var _clock_frame_alpha := 0.0
var hour: float:        # час суток для инструментов и сохранений
	get: return fposmod(_clock_hour, 24.0)
	set(value):
		_clock_hour = floorf(_clock_hour / 24.0) * 24.0 + fposmod(value, 24.0)
		_prev_clock_hour = _clock_hour
var _hour_skip := 0.0    # остаток ручной перемотки, в игровых часах со знаком
var day: DayCycle
var _boards: Array = []  # доски маршрутов: {at (середина щита, повёрнута как щит), place}
var _target := {}        # на что игрок смотрит сейчас (_aim): {kind = "bike" | "board" | "bench" | "repair", place, id}
var repairs: Repairables       # что в мире починено (лавки, туры на вершинах, причалы); сохранение — поле "repairs"
var repair_layer: RepairLayer  # модели починяемого: сломанное и причалы; отдаёт коробки наведения
var _plaques: Array = []         # таблички обелисков: {id, name, form, size, at} (SettlementsBuilder); чтение, зона съёмки
var _seat_id := ""             # лавка, на которой сидит игрок (камера ниже, ходьба заперта)
const REPAIR_TICK_SECONDS := 0.45
const REPAIR_TIME_EPSILON := 0.000001
var _fix_target := ""
var _fix_elapsed := 0.0
var paused := false
var show_map := false
var _hints_key := []  # от чего зависели последние подсказки (_update_hints)
var _map_disabled_3d := false
var _map_stream_origin := Vector2.INF
var info_timer := 0.0
const DISCOVERY_TICKS := 6   # такты физики между проверками открытий мест (10 раз в секунду)
var _discovery_tick := 0
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
var _dip: float:
	get: return camera_controller._dip
	set(value): camera_controller._dip = value
var _dip_v: float:
	get: return camera_controller._dip_v
	set(value): camera_controller._dip_v = value
var _trauma: float:
	get: return camera_controller._trauma
	set(value): camera_controller._trauma = value
var _moving := false    # игрок шёл в последнем такте (для покачивания камеры)
var _prev: Vector3:
	get: return camera_controller._prev
	set(value): camera_controller._prev = value
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
var _live_veg_dirty := false
var _live_veg_due_ms := -1
var _live_veg_pumping := false
var _live_veg_fade_left := 0.0

@onready var camera: Camera3D = $Camera
@onready var vegetation: VegetationLayer = $Vegetation
@onready var audio: WorldAudio = $Audio


## Заполнить сцену загруженным миром (WorldLoader) и начать игру.
## С 9.0 сразу готовится только окружение игрока: ближний рельеф (до NEAR), лес вокруг и край за картой;
## дальний рельеф и растительность догружаются в игре, сначала по ходу движения.
func start(loaded: WorldLoader, hud_node: Hud, saved: Dictionary = {}, service_scope: ServiceScope = null) -> void:
	_hints_key = [] # подсказки HUD собрать заново
	services = service_scope if service_scope != null else loaded.service_scope
	if services == null:
		services = GameContext.scope
	if services.resource_profile != null:
		_resource_before = services.resource_profile.stamp()
		if DisplayServer.get_name() != "headless": RenderingServer.viewport_set_measure_render_time(get_viewport().get_viewport_rid(), true)
	if loaded.service_scope == null: loaded.service_scope = services
	if loaded.chunk_source == null: loaded.prepare_streaming()
	if not loaded.error.is_empty(): return
	chunk_source = loaded.chunk_source
	camera_controller.settings = services.settings
	camera_controller.heights = loaded.heights
	var t := Time.get_ticks_usec()
	load_timings = loaded.timings
	world = loaded.world
	heights = loaded.heights
	# 15.11: опора и вода для физики на C# (RideGround): только главный поток, вне плана — прежний GDScript
	heights.native_ride = true
	hud = hud_node
	hud.settlement_panel.closed.connect(_close_settlement)
	hud.settlement_panel.travel_requested.connect(_board_travel)
	hud.settlement_panel.bike_requested.connect(_recall_bike)
	hud.settlement_panel.quest_accepted.connect(_accept_quest)
	hud.settlement_panel.quest_abandoned.connect(_abandon_quest)
	var scene_started := t
	if _defs.is_empty():
		_defs = Models.tree_defs()
		_grass_mesh = Models.grass_mesh()
	t = _mark("start_models_ms", t)
	$Terrain.material_override = services.terrain.material(loaded.terrain_image, loaded.forest_surface)
	TerrainBuilder.set_cavity($Terrain.material_override, heights)
	terrain_stream = PlanTerrain.new()
	terrain_stream.name = "PlanTerrain"
	$Terrain.add_child(terrain_stream)
	terrain_stream.setup(loaded.terrain_chunks, $Terrain.material_override, services.cache, world, heights, chunk_source)
	terrain_stream.far_material = services.terrain.far_material($Terrain.material_override)
	stream_coordinator.terrain_update = terrain_stream.update
	terrain_stream.frame_budget = stream_coordinator.frame_budget
	vegetation.frame_budget = stream_coordinator.frame_budget
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
			water_stream.frame_budget = stream_coordinator.frame_budget
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
	repairs = Repairables.new(world.seed_num)
	if not saved.is_empty():
		repairs.restore(saved.get("repairs", {}))
	repair_layer = RepairLayer.new()
	repair_layer.name = "Repairs"
	$Settlements.add_child(repair_layer)
	repair_layer.setup(built.repairables, built.windows, repairs)
	heights.add_site_decks(world.sites) # 18.11.2026: на вышки (TowerLayout) и причалы (FishingLayout) можно подняться и выйти
	place_names = PlaceNames.new()
	place_names.setup($Settlements, heights)
	photo = PhotoCamera.new()
	photo.controls = services.controls
	photo.feedback = hud.interaction_audio
	add_child(photo)
	photo.anchors = _photo_anchors()
	_plaques = built.plaques
	photo.plaques = _plaques
	photo.plaque_near = Quests.PLAQUE_REACH_M
	photo.occluded = _occluded
	photo.familiar = func(id: String) -> bool: return hud.knows(id)
	photo.capturing.connect(_photo_capturing)
	fires = built.fires
	_boards = built.boards
	audio.fires = fires
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
	var rng := OpeningRoute.make_rng()
	var opening_spot := (loaded.opening_spot if loaded.opening_prepared else OpeningRoute.choose(world, heights, rng)) if saved.is_empty() else {}
	load_timings.start_spawn_ms = (Time.get_ticks_usec() - spawn_started) / 1000.0
	# Restore pinned regions even when generation of new regions is disabled.
	if world.outer != null and (services.settings.infinite_world or not world.outer.get_ledger().is_empty()):
		# 13.9+: закреплённые области мира — до игрока: сохранённое место может лежать в них.
		regions = RegionStream.new()
		regions.generation_enabled = services.settings.infinite_world
		regions.cpu_budget = services.cpu_budget
		regions.terrain_builder = services.terrain
		regions.name = "Regions"
		add_child(regions)
		regions.setup(world, heights, null, vegetation)
		regions.storage_failed.connect(hud.toast_now.bind(&"warning"))
		regions.settlements_changed.connect(_sync_region_settlements)
		stream_coordinator.region_restore = regions.restore
		if saved.is_empty():
			stream_coordinator.restore_regions(Vector3(world.W * TILE * 0.5, 0.0, world.H * TILE * 0.5))
		else:
			stream_coordinator.restore_regions(Vector3(saved.player.x, 0.0, saved.player.z))
	player = PlayerState.spawn(world, heights)
	if player == null:
		loaded.error = "В подготовленном мире не найдено безопасное место появления."
		return
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
			if player == null:
				loaded.error = "Не найдено безопасное место для восстановления игрока."
				return
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
		var s: Variant = PlayerState.home(world)
		var look_at := Vector2(s.x, s.y) * TILE
		for fire: Dictionary in fires:
			if fire.place == s:
				look_at = Vector2(fire.pos.x, fire.pos.z)
				break
		yaw = atan2(player.x - look_at.x, player.z - look_at.y)
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
	t = _mark("start_outer_ms", t)
	hud.controls = services.controls
	hud.set_world(world, loaded.map_image)
	stream_coordinator.force_vegetation(Vector3(player.x, player.feet, player.z))
	heights.obstacles.update(player.x, player.z, vegetation.obstacles, vegetation.obstacles_version, true)
	heights.obstacles.async_rebuild = true # дальше препятствия леса пересобираются в фоне, а не в такте физики
	bike = BikeRide.park_near(player, yaw, world, heights)
	if not saved.is_empty():
		var b: Dictionary = saved.bike
		if safe_position(b.x, b.z, b.y):
			var restored := BikeRide.new()
			restored.y = heights.surface_at(b.x, b.z, b.y)
			if restored.fits(b.x, b.z, b.heading, world, heights, false):
				restored.x = b.x
				restored.z = b.z
				restored.heading = b.heading
				bike = restored
	if bike == null:
		loaded.error = "Рядом с местом появления не найдено безопасной точки для велосипеда."
		return
	bike_view = preload("res://scenes/bike.tscn").instantiate()
	add_child(bike_view)
	if shop_progress != null:
		shop_progress.equipment_changed.connect(bike_view.set_scheme)
		bike_view.set_scheme(shop_progress.equipped)
	brake_effects = BrakeEffects.new()
	brake_effects.name = "BrakeEffects"
	add_child(brake_effects)
	bike_view.heat_source = brake_effects
	ambient = AmbientParticles.new()
	ambient.name = "AmbientParticles"
	add_child(ambient)
	ambient.setup(world, heights)
	ambient.density = GameSettings.PARTICLE_LEVELS[services.settings.particles].density
	crash = BikeCrash.new()
	crash.name = "BikeCrash"
	add_child(crash)
	_snap()
	bike_view.draw(1.0)
	# Посадка из сохранения проходит те же проверки после появления локальных препятствий.
	if not saved.is_empty() and saved.bike.riding and bike.prepare_mount(player, world, heights):
		bike.mount(player)
		_snap()
		bike_view.draw(1.0)
	var opening_bike: BikeRide = null
	if not opening_spot.is_empty():
		opening_bike = BikeRide.new()
		opening_bike.y = player.feet
	if opening_bike != null and opening_bike.fits(player.x, player.z, yaw, world, heights, false):
		bike = opening_bike
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
	day = DayCycle.new($WorldEnvironment.environment, $Sun)
	add_child(day.make_cloud_dome()) # 16.11: облака неба считаются в куполе по полосам, не по пикселям экрана
	camera.add_child(StyleGrain.new()) # 13.11: зерно визуального стиля, рисуется только в 3D-мире
	local_mist = preload("res://scripts/render/local_mist.gd").new()
	add_child(local_mist)
	local_mist.setup(world, heights)
	_apply_lighting_and_fog()
	day.terrain_mats = [$Terrain.material_override]
	if terrain_stream.far_material != null:
		day.terrain_mats.append(terrain_stream.far_material)
	if outer != null and outer._mat != null:
		day.terrain_mats.append(outer._mat)
	day.camera = camera
	day.world_seed = world.seed_num
	_restore_clock(saved)
	_apply_render_clock(1.0)
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
	hud.map_close_requested.connect(close_tablet)
	quests = Quests.new()
	if shop_progress != null:
		quests.reward_for = func(id: String) -> int: return shop_progress.reward(world.seed_text, id)
		quests.completion_note = _quest_reward_note
	_beacon_layer = BeaconLayer.new()
	add_child(_beacon_layer)
	_paint_layer = PaintLayer.new()
	_paint_layer.vegetation = vegetation
	add_child(_paint_layer)
	quests.changed.connect(_quest_changed)
	hud.quests = quests
	if not saved.is_empty():
		var places := {}
		for p: Dictionary in hud.all_places():
			places[p.key] = p
		hud.visited = saved.visited.duplicate()
		hud.map_journal.restore(saved.get("atlas", {}))
		hud.ride_log.restore(saved.get("rides", {}))
		hud.explore.restore(saved.get("explore", {}))
		if not quests.restore_state(saved.quest, places, Rect2i(0, 0, world.W, world.H), world):
			push_warning("Задание из сохранения не восстановлено: данные неверны или его места не найдены в мире.")
		elif shop_progress != null:
			var note := _quest_reward_note(saved.quest.completed.keys())
			if not note.is_empty():
				hud.toast("Награды за задания" + note, &"quest")
		_quest_changed()
		# Точка установки уже восстановлена из шага задания, её нет в каталоге мест.
		if hud.goal.get("kind") not in Quests.FIELD_PLACES or hud.goal.key != saved.goal:
			hud.restore_goal(saved.goal, saved.get("goal_marker", Vector2.INF))
	else:
		# 18.11.2026: новая игра начинается с основного задания — доехать до ближайшего поселения (там доска заданий);
		# цель сразу на компасе, путь рисуется
		var home := _nearest_village(Vector2(player.x, player.z) / TILE)
		if not home.is_empty():
			quests.accept(Quests.start(home))
	hud.ride_log.begin(hud.map_journal, hud.explore, quests.done)  # 20.11.2026: заезд — от входа в мир до выхода
	photo.photo_taken.connect(_quest_photo)
	photo.photo_taken.connect(_album_photo)
	photo.wanted_reach = Quests.SHOT_REACH_M
	if world.outer != null and outer != null:
		outer.frame_budget = stream_coordinator.frame_budget
		stream_coordinator.outer_update = outer.update
	if regions != null:
		stream_coordinator.region_update = regions.update
		stream_coordinator.region_priority = regions.publication_pending
	stream_coordinator.region_committed.connect(func() -> void:
		for m: StandardMaterial3D in regions.windows:
			SettlementsBuilder.set_night(m, _night)
		if hud.big_map.visible:
			hud.big_map.prepare_player_view()
			hud.sync_map_places()
		if garlands != null and regions != null:
			garlands.sync_regions(regions.ledger.get("regions", {}), _garland_huts()))
	garlands = TreeGarlandsLayer.new()
	garlands.name = "TreeGarlands"
	add_child(garlands)
	garlands.setup(world, heights, _garland_clear_spots(), _garland_huts())
	if regions != null:
		garlands.sync_regions(regions.ledger.get("regions", {}), _garland_huts())
	garlands.set_enabled(services.settings.tree_garlands)
	interaction_service.quests = quests
	interaction_service.is_broken = repairs.is_broken
	interaction_service.world = world
	interaction_service.heights = heights
	interaction_service.warm()
	interaction_service.all_places = hud.all_places
	interaction_service.visited = hud.visited
	interaction_service.travel = func() -> Dictionary:
		return {explored = hud.map_journal.explored_cells(Quests.EXPLORED_CELL), from = hud.map_journal.came_from(Vector2(player.x, player.z))}
	interaction_service.message.connect(hud.toast_now)
	interaction_service.close_requested.connect(_close_settlement)
	# 19.11.2026: на щите ближней доски — карта и листки заданий (рисуются в текстуру один раз)
	board_display = BoardDisplay.new()
	board_display.name = "BoardDisplay"
	add_child(board_display)
	board_display.setup(world, quests, hud.map_data,
		func() -> Array: return _boards + (regions.boards if regions != null else []),
		func(place: Variant) -> Array: return _offers(place),
		func(place: Variant) -> Array: return hud.board_places(place))
	bike_controller.message.connect(hud.toast.bind(&"warning"))
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


## Вызывается на закрытом экране до первого игрового такта.
func prepare_render_pipelines() -> Node3D:
	brake_effects.prepare_track_pipeline()
	var probes := Node3D.new()
	probes.name = "RenderWarmup"
	probes.position = to_local(camera.global_position - camera.global_basis.z * 2.0)
	probes.add_child(navigation_line.make_pipeline_probe())
	var mist: Node3D = local_mist.make_pipeline_probe()
	if mist != null:
		probes.add_child(mist)
	add_child(probes)
	return probes


func _update_water(x: float, z: float, force := false, allow_apply := true, near := INF) -> bool:
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
	_resume_map_rendering()
	if day != null:
		RenderingServer.global_shader_parameter_set("vegetation_night", 0.0)
		VisualStyle.release() # окружение мира закрыто; глобальные параметры стиля нейтральны для других сцен
	if heights != null and heights.obstacles != null:
		heights.obstacles.finish()
	if garlands != null:
		garlands.finish()
	if _travel_task != -1:
		WorkerThreadPool.wait_for_task_completion(_travel_task)
		_travel_task = -1
	if chunk_source != null: chunk_source.close()
	# Hud переживает игру; удалить только обработчики этой сцены, включая панель поселения.
	if is_instance_valid(hud):
		var connections: Array = [[hud.goal_changed, _navigation_goal], [hud.travel_requested, travel_to], [hud.map_close_requested, close_tablet]]
		if is_instance_valid(hud.settlement_panel):
			var panel: SettlementPanel = hud.settlement_panel
			connections.append_array([[panel.closed, _close_settlement],
				[panel.travel_requested, _board_travel], [panel.bike_requested, _recall_bike],
				[panel.quest_accepted, _accept_quest], [panel.quest_abandoned, _abandon_quest]])
		if is_instance_valid(hud.plaque_panel):
			connections.append([hud.plaque_panel.closed, close_plaque])
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


static func can_restore(saved: Dictionary, w: WorldData, _settings: GameSettings = null) -> bool:
	if saved.signature != save_signature(w):
		return false
	# 13.9+final: места и задания соседних областей — из их журнала на диске
	if w.outer != null and w.outer.get_ledger().is_empty():
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
	return Quests.new().restore_state(saved.quest, places, Rect2i(0, 0, w.W, w.H), w)


func save_state() -> Dictionary:
	var state := {format = 1, seed = world.seed_text, saved_at = Time.get_unix_time_from_system(),
		signature = save_signature(world), visited = hud.visited.duplicate(), quest = quests.save_state(),
		atlas = hud.map_journal.save_state(),
		rides = hud.ride_log.save_state(hud.map_journal, hud.explore, quests.done),
		explore = hud.explore.save_state(),
		repairs = repairs.save_state(),
		goal = hud.goal.get("key", ""),
		lamp = bike_view.lamp_on(),
		player = {x = player.x, z = player.z, feet = player.feet, yaw = yaw, pitch = pitch, hour = hour,
			clock_day = floori(_clock_hour / 24.0), sky_seconds = _sky_time_offset + time},
		bike = {x = bike.x, z = bike.z, y = bike.y, heading = bike.heading, riding = bike.riding}}
	# ID свободной метки общий: её положение отсутствует в каталоге мест мира.
	if hud.goal.get("kind") == "marker":
		state.goal_marker = Vector2(hud.goal.x, hud.goal.y)
	return state


## Время шага запуска в load_timings (мс); возвращает новую отметку
func _mark(key: String, since: int) -> int:
	var now := Time.get_ticks_usec()
	load_timings[key] = (now - since) / 1000.0
	return now


## Качество освещения, тени и туман применяются при запуске и выходе из паузы.
func _apply_lighting_and_fog() -> void:
	var settings := services.settings
	preload("res://scripts/render/lighting_quality.gd").apply(
		$WorldEnvironment.environment, $Sun, settings.lighting, settings.shadows, settings.fog_quality)
	if local_mist != null:
		local_mist.set_quality(settings.fog_quality, $WorldEnvironment.environment)
	preload("res://scripts/render/lighting_quality.gd").apply_clouds($WorldEnvironment.environment, settings.cloud_quality)
	# визуальный стиль (13.11): окружение мира и настройки игрока; на паузе меню меняет их сразу, здесь — на старте и после паузы
	VisualStyle.bind($WorldEnvironment.environment)
	VisualStyle.configure(settings.style_on, settings.style_amount)
	if garlands != null:
		garlands.set_enabled(settings.tree_garlands)


func _garland_clear_spots() -> Array[Vector2]:
	var out: Array[Vector2] = []
	if player != null:
		out.append(Vector2(player.x, player.z))
	var home: Variant = PlayerState.home(world)
	if home != null:
		var hx: float = home.x * GameConfig.TILE
		var hz: float = home.y * GameConfig.TILE
		out.append(Vector2(hx, hz))
	return out


func _garland_huts() -> Array[Vector3]:
	var out: Array[Vector3] = []
	if world != null:
		for s: SettlementData in world.settlements:
			out.append(Vector3(float(s.x) * GameConfig.TILE, float(s.y) * GameConfig.TILE, 30.0))
	if regions != null:
		for entry: Dictionary in regions.ledger.get("regions", {}).values():
			for s: Variant in entry.get("decor", {}).get("settlements", []):
				var sx: float = s.x * GameConfig.TILE
				var sz: float = s.y * GameConfig.TILE
				out.append(Vector3(sx, sz, 30.0))
	return out


func capture_mouse() -> void:
	if startup_input_locked:
		return
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	_captured_at = Time.get_ticks_msec()


func has_cursor_overlay() -> bool:
	return show_map or _settlement_open() or _journal_open() or _plaque_open()


func sync_mouse_mode() -> void:
	if paused or has_cursor_overlay():
		_dragging = false
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	else:
		capture_mouse()


func set_paused(p: bool) -> void:
	if p:
		_cancel_repair()
		if hud != null: hud.note_interaction_target("")
		services.controls.release_motion()
		if bike != null: services.controls.read_bike_body(bike, false)
		_cancel_bike_placement()
		_set_photo(false)
	paused = p
	if p:
		_resume_map_rendering()
	elif show_map:
		_suspend_map_rendering()
	if is_instance_valid(navigation_line) and p:
		navigation_line.visible = false
	if p and place_names != null:
		place_names.update(camera, 0.0, hud.visited, true)
	if p and is_instance_valid(_bag_label):
		_bag_label.hide()
	if p and is_instance_valid(bike_view) and not crash.active():
		bike_view.watch_requested = false
		bike_view.draw(1.0, false)
	if is_instance_valid(_speed_wind):
		_speed_wind.visible = not p
	if is_instance_valid(_opening_caption):
		_opening_caption.visible = not p and _opening
	if p:
		_close_settlement(false)
	else:
		_live_veg_pumping = false
		_live_veg_fade_left = 0.0
		_apply_lighting_and_fog()
		_apply_live_fov()
		# 19.11.2026: растительность уже применена на паузе (_tick_paused_preview). Раньше здесь каждый
		# выход из паузы звал _apply_vegetation_settings: set_carpet ждал фоновую задачу ковра и выбрасывал её
		# результат даже без изменений — рывок в момент возврата управления. Теперь только недоделанное
		# изменение, и то в игре без ожидания задач (_tick_live_vegetation)
		if _live_veg_dirty:
			_live_veg_due_ms = mini(_live_veg_due_ms, Time.get_ticks_msec())
			if DisplayServer.get_name() == "headless":
				_live_veg_dirty = false
				_live_veg_due_ms = -1
				if _apply_vegetation_settings() and stream_coordinator.vegetation_update.is_valid():
					stream_coordinator.force_vegetation(Vector3(player.x, player.feet, player.z))
		if ambient != null:
			ambient.density = GameSettings.PARTICLE_LEVELS[services.settings.particles].density
	if travel_active():
		audio.set_paused(true)
	else:
		audio.set_paused(false)
		audio.set_ducked(p, 0.18)
	# отпущенная кнопка мыши на паузе не приходит, перетаскивание не должно «залипнуть»
	sync_mouse_mode()


func apply_live_settings(category: StringName = &"all") -> void:
	if player == null:
		return
	if category in [&"all", &"fov"]:
		_apply_live_fov()
	if category in [&"all", &"graphics", &"lighting", &"style"]:
		_apply_lighting_and_fog()
		if day != null:
			_apply_render_clock(_clock_frame_alpha)
			var dome := get_node_or_null("SkyCloudDome")
			if dome != null:
				dome._full = true
		if local_mist != null and camera != null:
			local_mist.update(camera.global_position, 0.0)
		if ambient != null:
			ambient.density = GameSettings.PARTICLE_LEVELS[services.settings.particles].density
		var road: Dictionary = GameSettings.ROAD_QUALITY[services.settings.road_quality]
		RenderingServer.global_shader_parameter_set("road_quality", Vector2(road.quality, GameSettings.ROAD_RANGE[services.settings.road_range].scale))
	if category in [&"all", &"vegetation"]:
		var road: Dictionary = GameSettings.ROAD_QUALITY[services.settings.road_quality]
		RenderingServer.global_shader_parameter_set("road_quality", Vector2(road.quality, GameSettings.ROAD_RANGE[services.settings.road_range].scale))
		_live_veg_dirty = true
		_live_veg_due_ms = Time.get_ticks_msec() + 200


func _apply_live_fov() -> void:
	if camera == null or player == null:
		return
	if photo != null and photo.active:
		camera.fov = photo.fov(services.settings.fov)
		return
	var fov_goal := services.settings.fov
	if bike != null and bike.riding:
		fov_goal += GameConfig.BIKE_FOV * clampf((absf(bike.speed) - 2.0) / (GameConfig.BIKE_SPEED - 2.0), 0.0, 1.3)
	else:
		fov_goal += GameConfig.RUN_FOV * clampf((player.ground_speed() - GameConfig.WALK * 1.1) / (GameConfig.WALK * 0.6), 0.0, 1.0)
	camera.fov = fov_goal


func _apply_vegetation_settings() -> bool:
	if vegetation == null or vegetation.world == null:
		return false
	var draw_changed := vegetation.set_draw(services.settings.draw)
	if draw_changed:
		vegetation.last_trees = Vector2.INF
	var redraw := draw_changed
	redraw = vegetation.set_flora(services.settings.flora) or redraw
	redraw = vegetation.set_mid_grass(services.settings.mid_grass) or redraw
	var carpet_changed := vegetation.set_carpet()
	return redraw or carpet_changed


## Изменение растительности, не успевшее примениться на паузе: в игре — когда фоновые задачи свободны
## (без ожидания их в кадре); если заняты дольше 1,5 с — всё же сейчас, иначе настройка не применится никогда
func _tick_live_vegetation() -> void:
	var now := Time.get_ticks_msec()
	if vegetation == null or now < _live_veg_due_ms:
		return
	if vegetation.busy() and now < _live_veg_due_ms + 1500:
		return
	_live_veg_dirty = false
	_live_veg_due_ms = -1
	_apply_vegetation_settings() # обычная подгрузка дорисует новое сама (last_fill сброшен)


func _tick_paused_preview(delta: float) -> void:
	if player == null or vegetation == null:
		return
	if _live_veg_dirty and Time.get_ticks_msec() >= _live_veg_due_ms:
		if vegetation.busy():
			var busy_budget := stream_coordinator.frame_budget
			busy_budget.deadline_usec = Time.get_ticks_usec() + stream_coordinator.publication_budget_us
			vegetation.update(player.x, player.z, false, delta, true)
			busy_budget.deadline_usec = 0
		else:
			_live_veg_dirty = false
			_live_veg_due_ms = -1
			if _apply_vegetation_settings():
				_live_veg_pumping = true
				_live_veg_fade_left = 0.45
	if _live_veg_pumping:
		var budget := stream_coordinator.frame_budget
		budget.deadline_usec = Time.get_ticks_usec() + stream_coordinator.publication_budget_us
		vegetation.update(player.x, player.z, false, delta, true)
		budget.deadline_usec = 0
		var carpet_busy := vegetation.carpet != null and vegetation.carpet.busy()
		if vegetation.placement_ready() and not carpet_busy:
			_live_veg_fade_left -= delta
			if _live_veg_fade_left <= 0.0:
				_live_veg_pumping = false


func look(dx: float, dy: float) -> void:
	if startup_input_locked or _opening:
		return
	var k := GameConfig.MOUSE * services.settings.mouse * (photo.look_scale() if photo.active else 1.0)
	yaw -= dx * k
	pitch = clampf(pitch - dy * k * (-1.0 if services.settings.invert_y else 1.0), -1.5, 1.5)
	_looked_at = time


## Сесть на велосипед, если он рядом, или слезть с него (действие interact, по умолчанию F).
func toggle_bike() -> void:
	if _opening or crash.active():
		return
	bike_controller.toggle_mount(player, bike, world, heights)


func _bike_mount_changed(riding: bool) -> void:
	services.controls.reset_motion()
	services.controls.read_bike_body(bike, false)
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
		hud.toast_now("Фотоаппарат — пешком: слезьте с велосипеда (%s)" % services.controls.label("interact"), &"warning")
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
	if show_map and hud.journal_panel.active_tab == Hud.Tablet.Tab.MAP:
		close_tablet()
	else:
		_open_tablet(Hud.Tablet.Tab.MAP)


func _open_tablet(tab: Hud.Tablet.Tab) -> void:
	if _opening or paused or player == null or travel_active() or crash.active():
		return
	if not show_map:
		_cancel_bike_placement()
		_set_photo(false)
		_close_settlement(false)
		close_plaque(false)
		services.controls.release_motion()
		services.controls.read_bike_body(bike, false)
		_dragging = false
		show_map = true
		_suspend_map_rendering()
		sync_mouse_mode()
	hud.show_tablet(tab)


func close_tablet(capture := true) -> void:
	if not show_map or travel_active():
		return
	show_map = false
	hud.set_map_visible(false)
	_resume_map_rendering()
	if capture:
		sync_mouse_mode()


func _suspend_map_rendering() -> void:
	if not get_viewport().disable_3d:
		get_viewport().disable_3d = true
		_map_disabled_3d = true
		_map_stream_origin = Vector2(player.x, player.z)


func _resume_map_rendering() -> void:
	if _map_disabled_3d:
		get_viewport().disable_3d = false
		_map_disabled_3d = false


func travel_active() -> bool:
	return _travel_task != -1 or _travel_waiting


## Костры, ночные окна, свет ближайшего костра и гирлянды. Зовёт и tools/stress на паузе (там нет _process).
func update_lights(pos: Vector3, eye: Vector3, fire_time: float, delta: float, stream_deadline := 0) -> void:
	SettlementsBuilder.animate_fires(fires, fire_time, pos)
	if regions != null:
		SettlementsBuilder.animate_fires(regions.fires, fire_time, pos)
	_light_night(pos, fire_time)
	if garlands != null:
		var garland_night := smoothstep(0.22, 0.96, 1.0 - day.sunlight) if day != null else 0.0
		var fire_on := fire_light != null and fire_light.visible
		var fire_pos := fire_light.global_position if fire_on else Vector3.ZERO
		garlands.update(pos, eye, fire_pos, fire_on, garland_night,
			services.settings.draw, services.settings.lighting, delta, stream_deadline, camera)


func travel_to(place: Dictionary) -> void:
	if _opening or paused or travel_active() or player == null or not world.accessible(place.x, place.y):
		return
	if bike.riding and bike.airborne:
		return
	_cancel_bike_placement()
	if quests != null and quests.cargo:
		hud.toast_now("С сумкой за спиной быстро не переместиться — довезите её сами", &"warning")
		return
	var from_board := _settlement_open()
	_set_photo(false)
	_close_settlement(false)
	_travel_waiting = true
	while heights.obstacles.busy():
		await get_tree().process_frame
		if not is_inside_tree() or is_queued_for_deletion(): return
	# стволы у места прибытия, чтобы не встать в дерево (валежник появится после раскладки подлеска)
	heights.obstacles.update(place.x * TILE, place.y * TILE, PackedFloat32Array(), -1, true)
	var arriving := PlayerState.arrive(world, heights, place)
	if arriving == null:
		heights.obstacles.update(player.x, player.z, vegetation.obstacles, vegetation.obstacles_version, true)
		_travel_waiting = false
		_finish_travel("Рядом с местом прибытия не найдено безопасной точки", from_board, &"warning")
		return
	if chunk_source != null:
		services.controls.release_motion()
		services.controls.read_bike_body(bike, false)
		_dragging = false
		audio.set_paused(true)
	var arrival_yaw := PlayerState.arrival_heading(place, Vector2(arriving.x, arriving.z), yaw)
	if not await _travel_load(Vector3(arriving.x, arriving.feet, arriving.z), arrival_yaw): return
	heights.obstacles.update(arriving.x, arriving.z, vegetation.obstacles, vegetation.obstacles_version, true)
	var parked := BikeRide.park_near(arriving, arrival_yaw, world, heights)
	if parked == null or not safe_position(arriving.x, arriving.z, arriving.feet):
		var origin := Vector3(player.x, player.feet, player.z)
		if not await _travel_load(origin, yaw): return
		heights.obstacles.update(player.x, player.z, vegetation.obstacles, vegetation.obstacles_version, true)
		_finish_travel("Рядом с местом прибытия нет свободного места для игрока и велосипеда", from_board, &"warning")
		return
	crash.abort()
	hud.map_journal.end_trip()
	player = arriving
	yaw = arrival_yaw
	pitch = -0.05
	bike = parked
	_dip = 0.0
	_dip_v = 0.0
	_trauma = 0.0
	_snap()
	bike_view.draw(1.0)
	_travel_waiting = false # карта закрывается только после завершения перехода
	if show_map:
		close_tablet()
	_finish_travel("Вы переместились: «%s»" % place.name, from_board, &"discovery")


func _finish_travel(message: String, from_board: bool, kind: StringName = &"info") -> void:
	_travel_waiting = false
	if from_board and not paused and not show_map:
		capture_mouse()
	audio.set_paused(paused)
	hud.toast_now(message, kind)


## Рельеф, вода и растительность готовятся в фоне и передаются порциями. false — мир закрыт во время ожидания.
func _travel_load(destination: Vector3, heading: float) -> bool:
	if chunk_source == null:
		var began := Time.get_ticks_usec()
		stream_coordinator.force_terrain(destination, NEAR)
		stream_coordinator.force_vegetation(destination)
		_tick_mark("frame_travel_apply", began)
		return true
	var at := Vector2(destination.x, destination.z)
	while vegetation.busy():
		await get_tree().process_frame
		if not is_inside_tree() or is_queued_for_deletion():
			_travel_waiting = false
			return false
	var prepare_vegetation := vegetation.travel_begin(at, Vector2(-sin(heading), -cos(heading)))
	# PlanTerrain reads and uploads destination geometry while the vegetation job is running.
	# Going through ChunkSource's normal read queue also bounds the memory held before upload.
	_travel_task = WorkerThreadPool.add_task(prepare_vegetation, true, "Растительность у места прибытия")

	var layers: Array[PlanTerrain] = [terrain_stream]
	layers.append_array(_water_streams)
	for layer_stream: PlanTerrain in layers:
		layer_stream.checked_at = Vector2.INF
	var outdoor_keys: Array[Vector2i] = []
	if outer != null:
		outdoor_keys = outer.arrival_chunks(at)
		outer.recheck()
	var budget := stream_coordinator.frame_budget
	while true:
		await get_tree().process_frame
		if not is_inside_tree() or is_queued_for_deletion(): return false
		var began := Time.get_ticks_usec()
		if _travel_task != -1 and WorkerThreadPool.is_task_completed(_travel_task):
			WorkerThreadPool.wait_for_task_completion(_travel_task)
			_travel_task = -1
			vegetation.travel_prepare_present()
		budget.deadline_usec = Time.get_ticks_usec() + stream_coordinator.publication_budget_us
		var uploaded := false
		var ready := true
		for layer_stream: PlanTerrain in layers:
			if not layer_stream.arrival_ready(at, NEAR):
				uploaded = layer_stream.update(at.x, at.y, false, not uploaded, NEAR) or uploaded
				ready = ready and layer_stream.arrival_ready(at, NEAR)
		if outer != null and not outer.arrival_ready(outdoor_keys):
			uploaded = outer.update(at.x, at.y, not uploaded, true) or uploaded
			ready = ready and outer.arrival_ready(outdoor_keys)
		var finished := _travel_task == -1 and ready and not uploaded and vegetation.travel_present(at, budget.deadline_usec)
		budget.deadline_usec = 0
		_tick_mark("frame_travel_apply", began)
		if finished: break

	vegetation.travel_end(at)
	for layer_stream: PlanTerrain in layers:
		layer_stream.checked_at = Vector2.INF # штатная очередь выгрузит узлы старого места
	if outer != null:
		outer.recheck()
	return true


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
		if hud != null: hud.toast_now("Для размещения дождитесь остановки на земле", &"warning")
		return false
	_set_photo(false)
	if not is_instance_valid(bike_placement):
		bike_placement = BikePlacement.new()
		add_child(bike_placement)
	bike_placement.begin(world, heights, Vector3(player.x, player.feet, player.z), yaw)
	_cancel_repair()
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
		if hud != null:
			_update_hints()
			hud.deny_placement()
		return false
	# Игрок остаётся на месте пешком; освобождаем только застрявшую/упавшую раму.
	player.vx = 0
	player.vz = 0
	player.vy = 0
	player.on_ground = true
	_rescue_input_until = time + 0.2
	_target = {}
	_snap()
	bike_view.play_placement_appearance()
	bike_view.draw(1.0)
	audio.bike_placed()
	if hud != null: hud.toast_now("Велосипед поставлен. Подойдите и нажмите %s" % services.controls.label("interact"))
	return true

## 14.0: подсказки показывают кнопки того, чем играют сейчас (Controls)
func _input(event: InputEvent) -> void:
	if not startup_input_locked:
		services.controls.note(event)
		if not _fix_target.is_empty() and event.is_action_released("interact"):
			_cancel_repair()
		if _tablet_shortcut(event):
			get_viewport().set_input_as_handled()


func _tablet_shortcut(event: InputEvent) -> bool:
	if not show_map or event.is_echo() or paused or hud._travel_dialog != null:
		return false
	if travel_active():
		return true
	if event.is_action_pressed("toggle_map"):
		toggle_map()
	elif event.is_action_pressed("journal"):
		if hud.journal_panel.active_tab == Hud.Tablet.Tab.PATH:
			close_tablet()
		else:
			open_journal()
	elif event.is_action_pressed("pause") or event.is_action_pressed("back"):
		if not hud.journal_panel.dismiss_subpanel():
			close_tablet()
	elif event is InputEventJoypadButton and event.pressed \
			and event.button_index in [JOY_BUTTON_LEFT_SHOULDER, JOY_BUTTON_RIGHT_SHOULDER]:
		var direction := 1 if event.button_index == JOY_BUTTON_RIGHT_SHOULDER else -1
		hud.journal_panel.cycle_tab(direction)
	else:
		return false
	return true


func _unhandled_input(event: InputEvent) -> void:
	if startup_input_locked or event.is_echo() or paused:
		return
	if show_map:
		if _tablet_shortcut(event) or (hud._travel_dialog == null and not travel_active() and hud.big_map.map_action(event)):
			get_viewport().set_input_as_handled()
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
	if _plaque_open():
		if event.is_action_pressed("pause") or event.is_action_pressed("back") or event.is_action_pressed("interact"):
			close_plaque()
			get_viewport().set_input_as_handled()
		return
	if _settlement_open():
		if event.is_action_pressed("pause") or event.is_action_pressed("interact") or event.is_action_pressed("back"):
			_close_settlement()
			get_viewport().set_input_as_handled()
		return
	if event.is_action_pressed("pause"):
		# Esc сначала закрывает большую карту и убирает фотоаппарат, потом ставит паузу
		if photo != null and photo.active and not paused:
			_set_photo(false)
		else:
			pause_requested.emit()
		get_viewport().set_input_as_handled()
		return
	# до start() узлы игрока и велосипеда ещё не созданы
	if paused or travel_active() or player == null:
		return
	if _opening:
		if event.is_action_pressed("jump"):
			_finish_opening()
		get_viewport().set_input_as_handled()
		return
	if event.is_action_pressed("back"):
		# B на геймпаде закрывает карту и убирает фотоаппарат, как Esc, но паузу не ставит
		if photo.active:
			_set_photo(false)
		get_viewport().set_input_as_handled()
	elif photo.active and event.is_action_pressed("photo_shoot"):
		photo.shoot()
	elif photo.active and (event.is_action_pressed("photo_zoom_in") or event.is_action_pressed("photo_zoom_out")):
		photo.zoom_by(1 if event.is_action_pressed("photo_zoom_in") else -1)
	elif event.is_action_pressed("photo"):
		toggle_photo()
	elif event.is_action_pressed("recover_bike"):
		toggle_bike_placement()
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("toggle_map"):
		toggle_map()
	elif event.is_action_pressed("journal"):
		open_journal()
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("flashlight"):
		toggle_flashlight()
	elif event.is_action_pressed("time_skip"):
		var step := -1.0 if event is InputEventKey and event.shift_pressed else 1.0
		_hour_skip += step
		hud.toast_now("Перемотка на %s1 ч" % ("−" if step < 0.0 else "+"))
	elif event.is_action_pressed("interact"):
		interact()
	elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_RIGHT:
		# 20.11: на велосипеде ПКМ — памп (действие bike_pump), фотоаппарат там всё равно недоступен
		if event.pressed and not bike.riding:
			toggle_photo()
	elif event is InputEventMouseButton and photo.active and event.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN]:
		if event.pressed:
			photo.zoom_by(1 if event.button_index == MOUSE_BUTTON_WHEEL_UP else -1)
	elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed and Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
			capture_mouse()
		elif event.pressed and photo.active:
			photo.shoot()
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
	services.controls.release_motion()
	if bike != null: services.controls.read_bike_body(bike, false)
	# пауза, как при выходе из захвата мыши в браузере
	if not paused and player != null:
		pause_requested.emit()


## Такт симуляции: движение игрока и велосипеда, игровое время, пружины камеры. Длина такта всегда
## одна (1/60 с), поэтому разгон, прыжки и полёт одинаковы при любом FPS, и за такт не проскочить стену.
## При FPS ниже 60 за кадр проходит несколько тактов, ниже 7,5 (8 тактов за кадр) игра замедляется,
## чтобы не захлебнуться
## Накопленное время частей физики и кадра, мкс. Читают отчёт игровой сессии и tools/stress.
var tick_us := {}


func _tick_mark(part: String, t0: int) -> int:
	var now := Time.get_ticks_usec()
	tick_us[part] = tick_us.get(part, 0) + now - t0
	return now


func performance_mode() -> String:
	if travel_active(): return "travel"
	if paused: return "pause"
	if show_map: return "map"
	if _journal_open(): return "journal"
	if _plaque_open(): return "plaque"
	if _settlement_open(): return "settlement"
	if photo.active: return "photo"
	return "opening" if _opening else "gameplay"


func performance_camera() -> Dictionary:
	var at := camera.global_position
	var forward := -camera.global_basis.z
	return {xyz_m = [at.x, at.y, at.z], forward = [forward.x, forward.y, forward.z],
		fov = camera.fov, far_m = camera.far}


func performance_settings() -> Dictionary:
	var settings := services.settings.display_state()
	var resolution: Vector2i = settings.resolution
	var window_size := get_window().size
	settings.resolution = [resolution.x, resolution.y]
	settings.window_px = [window_size.x, window_size.y]
	settings.max_fps = Engine.max_fps
	return settings


func performance_context() -> Dictionary:
	var at := Vector2(player.x, player.z) / TILE
	var region := world.region_at(Vector2i(floori(at.x), floori(at.y)))
	var biome: int = world.tile_info(at.x, at.y).get("biome", -1)
	var solar := DayCycle.solar_hour(hour)
	var light := "night"
	if solar >= 5.0 and solar < 7.0:
		light = "dawn"
	elif solar >= 17.0 and solar < 19.0:
		light = "dusk"
	elif solar >= 7.0 and solar < 17.0:
		light = "day"
	var nearest := _performance_settlement(at)
	var cam_at := camera.global_position
	var forward := -camera.global_basis.z
	var heading := Vector2(forward.x, forward.z).normalized()
	var drop: Variant = null
	var view := "other"
	var far_at := Vector2(cam_at.x, cam_at.z) + heading * 240.0
	if not world.tile_info(far_at.x / TILE, far_at.y / TILE).is_empty():
		drop = cam_at.y - heights.base_ground_at(far_at.x, far_at.y)
		if drop >= 24.0 and forward.y > -0.45 and forward.y < 0.45:
			var near_at := Vector2(cam_at.x, cam_at.z) + heading * 60.0
			if heights.base_ground_at(near_at.x, near_at.y) < cam_at.y + 6.0:
				view = "vista"
	return {
		player_xyz_m = [player.x, player.feet, player.z], camera = performance_camera(),
		biome = Biomes.LIST[biome].name if biome >= 0 and biome < Biomes.LIST.size() else "",
		region = [region.x, region.y], hour = hour, clock_day = floori(_clock_hour / 24.0), light = light,
		sunlight = day.sunlight, mist = day.local_mist, view = view, terrain_drop_240_m = drop,
		settlement = nearest.get("name", ""), settlement_id = nearest.get("id", ""),
		settlement_m = nearest.get("distance_m"), settlement_zone = nearest.get("zone", "far"),
		movement = "riding" if bike.riding else "walking", bike_speed_m_s = bike.speed if bike.riding else 0.0,
		world_rendering = not _map_disabled_3d,
	}


func _performance_settlement(at: Vector2) -> Dictionary:
	const SEARCH_METERS := 450.0
	var best_distance := pow(SEARCH_METERS / TILE, 2.0)
	var best_id := ""
	var best_name := ""
	for settlement: SettlementData in world.settlements:
		var distance := at.distance_squared_to(Vector2(settlement.x, settlement.y))
		if distance < best_distance:
			best_distance = distance
			best_id = WorldData.place_id("settlement", settlement.x, settlement.y)
			best_name = settlement.name
	if world.outer != null:
		for settlement: Dictionary in world.region_places().list:
			var distance := at.distance_squared_to(Vector2(settlement.x, settlement.y))
			if distance < best_distance:
				best_distance = distance
				best_id = settlement.id
				best_name = settlement.name
	if best_id.is_empty():
		return {}
	var meters := sqrt(best_distance) * TILE
	return {id = best_id, name = best_name, distance_m = meters, zone = "near" if meters <= 110.0 else "approach"}


func _restore_clock(saved: Dictionary) -> void:
	if saved.is_empty():
		_clock_hour = services.settings.pick_start_hour()
		_sky_time_offset = 0.0
	else:
		_clock_hour = float(saved.player.get("clock_day", 0)) * 24.0 + fposmod(saved.player.hour, 24.0)
		_sky_time_offset = float(saved.player.get("sky_seconds", 0.0))
	_prev_clock_hour = _clock_hour
	_prev_time = time
	_clock_frame_tick = -1.0
	_hour_skip = 0.0


func _advance_clock(dt: float) -> void:
	_prev_clock_hour = _clock_hour
	time += dt
	var settings := services.settings
	if settings.day_minutes > 0.0:
		_clock_hour += dt / (settings.day_minutes * 60.0) * 24.0
	if _hour_skip != 0.0:
		# The remaining offset depends only on manual input. Its size and direction
		# carry across midnight and changes in the natural rate of the clock.
		var step := _hour_skip if absf(_hour_skip) < 0.002 else _hour_skip * Util.damp(9.0, dt)
		_clock_hour += step
		_hour_skip -= step


func _apply_render_clock(alpha: float) -> void:
	# When a modal pause ends there may be a render frame before the next tick.
	# Do not revisit an earlier fraction of an already presented tick.
	_clock_frame_alpha = maxf(_clock_frame_alpha, alpha) if _clock_frame_tick == time else alpha
	_clock_frame_tick = time
	var clock_hour := lerpf(_prev_clock_hour, _clock_hour, _clock_frame_alpha)
	day.apply(clock_hour, _sky_time_offset + lerpf(_prev_time, time, _clock_frame_alpha), true)
	if hud != null:
		hud.set_clock(clock_hour)


func _physics_process(dt: float) -> void:
	if player == null or paused or travel_active() or _settlement_open():
		_cancel_repair()
		return
	if _placing_bike():
		_store_prev()
		return
	var t0 := Time.get_ticks_usec()
	tick_us.ticks = tick_us.get("ticks", 0) + 1
	world.open_around(player.x / TILE, player.z / TILE)
	t0 = _tick_mark("open_around", t0)
	_store_prev()
	var yaw0 := yaw
	var pitch0 := pitch
	_advance_clock(dt)
	var fw := Input.get_action_strength("move_forward") - Input.get_action_strength("move_back")
	var st := Input.get_action_strength("move_right") - Input.get_action_strength("move_left")
	# «только что нажат» в такте физики срабатывает ровно в одном такте, даже если за кадр их несколько
	var jump := Input.is_action_just_pressed("jump")
	if _seat_id != "":
		# сидя: пошевелились или прыгнули — встаём, иначе ходьба заперта
		if jump or absf(fw) > 0.2 or absf(st) > 0.2 or bike.riding or crash.active():
			_stand_up()
		else:
			fw = 0.0
			st = 0.0
			jump = false
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
	# при открытой карте руль, газ и прыжок не работают (велосипед катится по инерции)
	var map_lock := show_map or _journal_open() or _plaque_open()
	var input_lock := time < _rescue_input_until or map_lock
	if input_lock:
		fw = 0.0
		st = 0.0
		jump = false
	# 20.11: удержание руля и тормоза с клавиатуры копится только от ввода игрока. Под картой, журналом и во вступлении
	# (там руль ведёт сама дорога) оно сбрасывается, иначе после закрытия клавиша сразу давала набранную дугу.
	if bike.riding and not _opening and not input_lock:
		st = services.controls.bike_steer(st, dt, bike.speed)
		fw = services.controls.bike_brake(fw, dt)
	else:
		services.controls.reset_motion()
	if hud != null:
		hud.set_ride_activity(bike.riding and not crash.active() and not _opening and not map_lock
			and time >= _rescue_input_until and (fw < -0.01 or Input.is_action_pressed("run")))
	_moving = false
	var crashed := false
	heights.obstacles.update(player.x, player.z, vegetation.obstacles, vegetation.obstacles_version)
	heights.obstacles.set_bumps(vegetation.bumps, vegetation.obstacles_version)
	t0 = _tick_mark("obstacles", t0)
	if crash.active():
		crashed = bike_controller.recover(dt, player, bike, crash, world, heights)
	elif bike.riding:
		var h0 := bike.heading
		services.controls.read_bike_body(bike, not _opening and not input_lock)
		fw = bike_controller.ride(dt, player, bike, world, heights, fw, st, Input.is_action_pressed("run") and not map_lock, jump, _opening)
		if _opening and (bike.airborne or bike.crashed or bike.speed < 0.3):
			_finish_opening()
		camera_controller.follow_bike(bike, bike.heading - h0, time, dt)
		_bike_impacts()
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
	t0 = _tick_mark("bike", t0)
	water_effects.tick(dt, player, bike, _prev, heights)
	if brake_effects != null:
		brake_effects.tick(dt, bike, world, heights)
	_tick_pitch = pitch - pitch0
	# пружина проседания и затухающая тряска камеры
	camera_controller.tick_effects(dt)
	if not crash.active():
		bike_view.watch_requested = hud.summary_visible() and not _opening and not show_map and not photo.active
		bike_view.tick(bike, dt, fw, bike.riding and not _opening and stamina.surging(fw))
	bike.clear_tick_events()
	t0 = _tick_mark("effects", t0)
	audio.tick(player, bike.riding)
	t0 = _tick_mark("audio", t0)
	if crashed:
		_snap()
	# 18.11.2026: трек и счётчики пути ведутся и пешком, и на велосипеде (при езде player — положение велосипеда)
	if not _opening and not crashed and not crash.active():
		hud.map_journal.record(Vector2(player.x, player.z), dt, bike.riding)
		hud.explore.tick(dt, player.feet)
		hud.ride_log.tick(player.feet)
	else:
		hud.map_journal.end_trip()
		# 15.11: открытия мест — 10 раз в секунду, а не каждый такт (стресс-тест: 0,13–0,16 мс на такт). Самый малый
	# радиус открытия — 2,5 клетки (10 м), за 0,1 с даже на спуске игрок проезжает 1–2 м
	_discovery_tick += 1
	if _discovery_tick >= DISCOVERY_TICKS:
		_discovery_tick = 0
		var known := hud.visited.size()
		for text: String in player.check_discoveries(world, hud.visited, hud.ride_log.places):
			hud.toast(text, &"discovery")
		if hud.visited.size() != known:
			hud.sync_map_places()
			for pk in world.peaks:
				var peak_id := WorldData.place_id("peak", pk.x, pk.y)
				if hud.visited.has(peak_id) and not hud.explore.scanned.has(peak_id) and Grid.hypot(pk.x - player.x / TILE, pk.y - player.z / TILE) < 6.0:
					_look_around(peak_id, Exploration.PEAK_RADIUS, "С вершины")
		for tower: Dictionary in heights.towers:
			if not hud.explore.scanned.has(tower.id) and TowerLayout.on_deck(tower, player.x, player.z, player.feet):
				_look_around(tower.id, Exploration.TOWER_RADIUS, "С вышки")
		if not quests.thanks.is_empty():
			hud.toast(quests.thank(_at_village), &"quest")
	# шаг задания раньше цели компаса: он сам переставит цель на следующее место
	_tick_repair(dt)
	# 18.11.2026: сумка сама надевается у доски, где её выдают (взяли задание или вернулись за новым грузом)
	if quests.step().get("do") == "pickup" and hud.at_place(quests.step().place, player.x, player.z):
		_quest_progress(quests.pick_up())
	_quest_progress(quests.tick(_quest_arrived))
	var reached := hud.check_goal(player.x, player.z) if navigation_line == null or navigation_line.can_arrive(Vector3(player.x, player.feet, player.z)) else ""
	if reached != "":
		hud.toast(reached, &"discovery")
	_tick_mark("places", t0)


## Запомнить положение игрока как предпоследний такт (для интерполяции кадра)
func _store_prev() -> void:
	camera_controller.store_previous(player, time)
	_prev_clock_hour = _clock_hour


## Последний такт становится и предпоследним: после переноса игрока (сел, слез, упал) кадр не тянет
## его плавно со старого места
func _snap() -> void:
	_store_prev()
	if water_effects != null:
		water_effects.clear()
	if brake_effects != null:
		brake_effects.clear()
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
	if player == null or travel_active():
		if hud != null: hud.note_interaction_target("")
		return
	if services.resource_profile != null: services.resource_profile.frame(get_viewport(), delta * 1000.0, self)
	var t0 := Time.get_ticks_usec()
	hud.lock_hint.visible = (not paused and not _opening and not has_cursor_overlay() and not photo.active
		and not services.controls.joypad and Input.mouse_mode != Input.MOUSE_MODE_CAPTURED)
	if paused:
		_tick_paused_preview(delta)
		_tick_mark("frame_paused_preview", t0)
		return
	if _live_veg_dirty:
		_tick_live_vegetation()
	if board_display != null and not _map_disabled_3d:
		board_display.tick(Vector3(player.x, player.feet + GameConfig.EYE, player.z))
	t0 = _tick_mark("frame_setup", t0)
	tick_us.frames = tick_us.get("frames", 0) + 1
	hud.set_summary_blocked(_opening or crash.active() or _placing_bike())
	var summary := hud.summary_visible()
	if not summary:
		info_timer = 0.0
	if not startup_input_locked and not show_map and not _settlement_open() and not _journal_open() and not _plaque_open():
		var stick := services.controls.look_delta(delta)
		if stick != Vector2.ZERO:
			look(stick.x, stick.y)
	hud.set_stamina(stamina.value, stamina.exhausted, stamina.state)
	hud.set_brakes(bike)
	# доля пути от предпоследнего такта физики к последнему, в которой сейчас кадр
	var alpha := 1.0 if _placing_bike() or _settlement_open() else Engine.get_physics_interpolation_fraction()
	var pos := _prev.lerp(Vector3(player.x, player.feet, player.z), alpha)
	if not _map_disabled_3d:
		if crash.active():
			crash.draw()
		else:
			bike_view.draw(alpha, summary)
	t0 = _tick_mark("frame_bike_view", t0)
	_update_camera(alpha, delta)
	_update_bike_placement(delta)
	if _speed_wind != null:
		_speed_wind.update_effect(_speed_rush, delta)
	if _opening:
		_draw_opening(alpha)
	t0 = _tick_mark("frame_camera", t0)
	if navigation_line != null:
		var navigating := not _opening and not show_map and not crash.active() and not photo.active and not _placing_bike() and not _settlement_open()
		navigation_line.update_line(pos, delta, navigating, hud.navigation_visible())
		t0 = _tick_mark("frame_route", t0)
		if navigation_line.route_revision != _route_revision:
			_route_revision = navigation_line.route_revision
			hud.minimap.set_route(navigation_line.path, navigation_line._road_first, navigation_line._road_last) # маршрут подсвечен и на мини-карте
		if navigating and navigation_line.status != _navigation_status:
			_navigation_status = navigation_line.status
			# 19.11.2026: в сообщения — только отказ («Проход к цели не найден»); «Расчёт маршрута…» не мелькает
			if _navigation_status != "" and _navigation_status != NavigationLine.SEARCHING: hud.toast_now(_navigation_status)
	t0 = _tick_mark("frame_route_ui", t0)
	if place_names != null and not _map_disabled_3d:
		place_names.update(camera, delta, hud.visited, not summary, quests.known, hud.explore.revealed)
	if _bag != null and _bag.visible and not _map_disabled_3d:
		# подпись над сумкой покачивается, чтобы её было видно издалека
		_bag_label.position.y = 0.75 + sin(time * 2.5) * 0.06
		_bag_label.visible = summary and camera.global_position.distance_to(_bag.position) < 60.0
		if _bag_label.visible:
			_update_bag_label()
	photo.bike_at = Vector3.INF if bike.riding or crash.active() else Vector3(bike.x, bike.y + 0.6, bike.z)
	photo.update(camera, delta)
	_target = _aim()
	_update_hints()
	var aim_kind: String = _target.get("kind", "")
	var aim_id: String = _target.get("id", aim_kind)
	if aim_kind == "board":
		aim_id = WorldData.place_id("settlement", _target.place.x, _target.place.y)
	hud.note_interaction_target(aim_id)
	t0 = _tick_mark("frame_view", t0)
	_apply_render_clock(alpha)
	t0 = _tick_mark("frame_day", t0)

	if ambient != null and not _map_disabled_3d:
		ambient.update(delta, camera.global_position, day.sunlight)
	t0 = _tick_mark("frame_ambient", t0)
	var decor_deadline := -1
	# While the atlas covers the world, defer visual uploads around the same spot.
	# Resume normal streaming if the rider coasts far enough to need new collision data.
	if not _map_disabled_3d or Vector2(pos.x, pos.z).distance_squared_to(_map_stream_origin) >= PlanTerrain.RECHECK * PlanTerrain.RECHECK:
		decor_deadline = stream_coordinator.update(pos)
	t0 = _tick_mark("frame_stream", t0)
	if not _map_disabled_3d:
		local_mist.update(camera.global_position, delta)
		if _ocean != null:
			_ocean.position = Vector3(pos.x, 0.0, pos.z)
		update_lights(pos, camera.global_position, lerpf(_prev_time, time, _clock_frame_alpha), delta, decor_deadline)
	t0 = _tick_mark("frame_lights_mist", t0)
	audio.update(pos, bike.speed if bike.riding else 0.0, bike.riding and not bike.airborne, delta, bike.lean if bike.riding else 0.0, bike.crank if bike.riding else 0.0, _bike_skid_sound() if bike.riding else 0.0)

	info_timer -= delta
	if summary and info_timer <= 0.0:
		info_timer = 0.15
		hud.update_info(player, yaw, heights.depth_at(player.x, player.z, player.feet))
	hud.set_player(pos.x, pos.z, bike.heading if bike.riding else yaw)
	hud.set_bike(bike.x, bike.z, not bike.riding)
	_tick_mark("frame_rest", t0)


## Камера на велосипеде упирается в землю, настил моста или стену (перила, стены туннеля) в точке p
func _cam_blocked(p: Vector3, feet: float) -> bool:
	return camera_controller._cam_blocked(p, feet)

func opening_active() -> bool:
	return _opening


func _opening_welcome() -> void:
	if opening_place.is_empty():
		return
	# 18.11.2026: старт на дороге к удалённой деревне (OpeningRoute) — она впереди и становится целью компаса
	if opening_place.kind == "settlement":
		hud.toast_now("Впереди — «%s»" % opening_place.name, &"discovery")
		if hud.goal.is_empty():
			hud.set_goal(InteractionService.target(opening_place))
	else:
		hud.toast_now("Начало пути: «%s»" % opening_place.name, &"discovery")


func _finish_opening() -> void:
	_opening = false
	_opening_time = 0.0
	if is_instance_valid(_opening_caption):
		# вместе с пустым CanvasLayer, в который подпись вложена
		var caption_layer := _opening_caption.get_parent()
		if caption_layer is CanvasLayer:
			caption_layer.queue_free()
		else:
			_opening_caption.queue_free()
	# Тот же велосипед, скорость и камера: никаких переносов при передаче управления.
	_rescue_input_until = time + 0.2
	hud.visible = not paused and not startup_input_locked
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
	if not startup_input_locked and not is_instance_valid(_opening_caption):
		var layer := CanvasLayer.new()
		add_child(layer)
		_opening_caption = PanelContainer.new()
		layer.add_child(_opening_caption)
		_opening_caption.set_anchors_and_offsets_preset(Control.PRESET_CENTER_BOTTOM)
		_opening_caption.offset_top = -96
		_opening_caption.offset_bottom = -18
		_opening_caption.grow_horizontal = Control.GROW_DIRECTION_BOTH
		_opening_caption.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_opening_caption.add_theme_stylebox_override("panel", HudStyle.panel(HudStyle.SURFACE, HudStyle.BORDER, 13, Vector2(18, 10)))
		var rows := VBoxContainer.new()
		rows.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_opening_caption.add_child(rows)
		var title := Label.new()
		title.text = opening_place.name
		title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		HudStyle.label(title, 22)
		rows.add_child(title)
		var controls_hint := Label.new()
		controls_hint.text = "%s · пропустить     %s · пауза" % [services.controls.label("jump"), services.controls.label("pause")]
		controls_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		HudStyle.label(controls_hint, 13, HudStyle.MUTED)
		rows.add_child(controls_hint)
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
		hud.toast_now("Груз разбит\n" + broken, &"warning")
	if bike.land_impact <= 0.0:
		audio.land(bike.x, bike.z, bike.y, 12.0) # удар в стену: глухой стук, как от жёсткой посадки
	pitch = -0.35
	_dip_v -= 3.0
	_trauma = 1.0


## Подсказки внизу экрана и у прицела — по тому, что игрок делает сейчас.
## Действия к месту чипами [клавиша] действие; полная раскладка — в паузе.
func _update_hints() -> void:
	# 19.11.2026: подсказки собираются заново (подписи клавиш из InputMap, массивы) только когда сменилось то,
	# от чего они зависят; раньше — каждый кадр
	var kind: String = _target.get("kind", "")
	var key := [_placing_bike(), bike_placement.reason if _placing_bike() else "", _opening or show_map or _settlement_open() or photo.active,
		crash.active(), kind, _target.place.name if kind == "board" else "", _target.get("repair_kind", ""), _seat_id,
		bike.riding, services.controls.joypad]
	if key == _hints_key:
		return
	_hints_key = key
	var k := services.controls.label
	if _placing_bike():
		var confirm_key: String = k.call("jump") if services.controls.joypad else "ЛКМ / " + k.call("interact")
		var cancel_key: String = k.call("back") if services.controls.joypad else "ПКМ / " + k.call("recover_bike") + " / " + k.call("pause")
		var help := [[cancel_key, "Отмена"], ["Левый стик", "Поворот и расстояние"]] if services.controls.joypad else [[cancel_key, "Отмена"], ["A/D / колесо", "Поворот"], ["W/S", "Расстояние"]]
		hud.set_hints(help, [[confirm_key, bike_placement.reason]], true, false)
		return
	if _opening or show_map or _settlement_open() or photo.active:
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
		"beacon": near = [[k.call("interact"), "Установить маяк"]]
		"paint": near = [[k.call("interact"), "Нанести метку"]]
		"bench": near = [[k.call("interact"), "Присесть"]]
		"plaque": near = [[k.call("interact"), "Прочитать табличку"]]
		"repair": near = [[k.call("interact"), "Удерживайте: починить %s" % Repairables.KINDS[_target.repair_kind].title]]
	if _seat_id != "":
		near = [[k.call("interact"), "Встать"]]
	# Внизу сводки — главное для того, чем игрок занят.
	if bike.riding:
		var hints := [[k.call("run"), "Сильнее"], [k.call("jump"), "Прыжок"], [k.call("interact"), "Слезть"], [k.call("recover_bike"), "Поставить велосипед"]]
		if not services.controls.joypad:
			hints.insert(2, [k.call("bike_back") + " → " + k.call("bike_forward"), "Баннихоп"])
			hints.insert(3, [services.controls.labels(&"bike_pump"), "Памп (держать)"])
		hud.set_hints(hints, near)
		return
	var photo_key: String = k.call("photo") if services.controls.joypad else "ПКМ"
	hud.set_hints([[k.call("run"), "Бег"], [k.call("jump"), "Прыжок"], [photo_key, "Фотоаппарат"], [k.call("recover_bike"), "Поставить велосипед"]], near, false, _seat_id.is_empty())


func _update_bag_label() -> void:
	var key := services.controls.label(&"interact")
	var caption := "▼ Сумка" if key.is_empty() else "▼ Сумка · %s" % key
	if _bag_label.text != caption:
		_bag_label.text = caption


func _settlement_open() -> bool:
	return hud != null and hud.settlement_panel != null and hud.settlement_panel.visible


## Наведение: каждый предмет — коробка по его форме (велосипед — узкая и длинная по ходу, доска — щит).
## Луч из камеры по центру экрана:
## 1) если он попадает в коробки, выбирается та, что ближе к глазам, — то, на что игрок смотрит прямо
##    (велосипед у самой доски выбирается, когда взгляд на нём, а не на щите за ним);
## 2) если не попал никуда, луч «толще» на AIM_R: из задетых краем — ближайший к центру взгляда по углу.
## Берутся только предметы рядом: велосипед, на который можно сесть, доски не дальше REACH от глаз.
## Подсказку взаимодействия показывают только для выбранного.
func _aim() -> Dictionary:
	if player == null or paused or show_map or _opening or startup_input_locked or not _seat_id.is_empty() \
			or crash.active() or _settlement_open() or _journal_open() or _plaque_open() or photo.active or _placing_bike():
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
	if not bike.riding and repair_layer != null:
		items.append_array(repair_layer.items(eye, REACH))
	if not bike.riding and player.on_ground and _paint_layer != null:
		var mark := _paint_layer.item(eye, REACH)
		if not mark.is_empty():
			items.append(mark)
	if not bike.riding:
		for plate: Dictionary in _plaques:
			if eye.distance_squared_to(plate.at.origin) < REACH * REACH:
				items.append({kind = "plaque", id = plate.id, at = plate.at, half = Vector3(plate.size.x * 0.5 + 0.1, plate.size.y * 0.5 + 0.1, 0.25)})
	if _bag != null and _bag.visible and not bike.riding and eye.distance_squared_to(_bag.position) < REACH * REACH:
		var at := _bag.transform
		at.origin += at.basis * Vector3(0.0, 0.0, CargoBag.SIZE.z * 0.5)
		items.append({kind = "cargo", at = at, half = CargoBag.SIZE * 0.5 + Vector3(0.05, 0.08, 0.05)})
	var selected := interaction_service.select(items, from, dir)
	return _beacon_interaction() if selected.is_empty() else selected


func _beacon_interaction() -> Dictionary:
	if bike.riding or not player.on_ground or quests == null or not quests.cargo:
		return {}
	var step := quests.step()
	if step.get("do") != "install":
		return {}
	var x := float(step.place.x) * TILE
	var z := float(step.place.y) * TILE
	if Vector2(player.x, player.z).distance_to(Vector2(x, z)) > Quests.BeaconSites.REACH:
		return {}
	if absf(player.feet - heights.ground_at(x, z)) > 1.0:
		return {}
	return {kind = "beacon", id = step.place.key}


## Действие с тем, на что смотрит игрок; на велосипеде без цели — слезть.
func interact() -> void:
	_set_photo(false) # С фотоаппаратом у глаз — сначала убрать его.
	_target = _aim()
	if _seat_id != "":
		_stand_up()
		return
	match _target.get("kind", ""):
		"board": _open_settlement(_target.place)
		"bike": toggle_bike()
		"cargo": _quest_progress(quests.pick_up())
		"beacon": _quest_progress(quests.install_beacon(_target.id))
		"paint": _quest_progress(quests.paint_object(_target.id))
		"bench": _sit(_target)
		"plaque": _read_plaque(_target)
		"repair": pass # чинят удержанием (_tick_repair), с заданием и без
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
			hud.toast("Остановитесь у костра, чтобы прочитать указатель", &"warning")
			return
		toggle_bike()
	services.controls.release_motion()
	services.controls.read_bike_body(bike, false)
	player.vx = 0.0
	player.vz = 0.0
	_snap()
	_dragging = false
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	var catalog := hud.all_places()
	hud.settlement_panel.open(village, world, hud.board_places(village, catalog), bike.distance_to(player) < 4.0,
		quests, _offers(village, catalog), hud.map_data)


## Задания доски поселения village (Quests.offers): соседи по дорогам и дальнее поселение — из индекса мира
func _offers(village: Variant, catalog: Variant = null) -> Array:
	return interaction_service.offers(village, catalog)


func _accept_quest(q: QuestData) -> void:
	interaction_service.accept(q)

func _abandon_quest() -> void:
	interaction_service.abandon()

func _quest_progress(text: String) -> void:
	interaction_service.progress(text)


func _quest_reward_note(ids: Array) -> String:
	var points := shop_progress.award(world.seed_text, ids)
	if points < 0:
		return "\nОчки пока не сохранены. Магазин повторит запись при открытии."
	if points == 0:
		return ""
	var note := " · +%d очк." % points
	var target := shop_progress.purchase_goal
	if target != "":
		var scheme_name: String = ShopProgress.Palette.SCHEME_NAMES[target]
		var remaining := shop_progress.remaining(target)
		if remaining > 0:
			note += "\nДо покупки комплекта «%s» — %d очк." % [scheme_name, remaining]
		elif shop_progress.balance - points < int(ShopProgress.PRICES[target]):
			note += "\n«%s» теперь можно купить в магазине." % scheme_name
	elif shop_progress.first_purchase_unlocked(points):
		note += "\nХватает на первую расцветку. Откройте «Магазин» в дневнике."
	return note

## Лавка: сесть (камера ниже, взгляд вперёд по лавке, ходьба заперта до шага или прыжка). Только пешком, цела
func _sit(item: Dictionary) -> void:
	var seat := repair_layer.seat(item.id)
	if seat.is_empty() or bike.riding or _opening or crash.active():
		return
	_set_photo(false)
	player.x = seat.position.x
	player.z = seat.position.z
	player.vx = 0.0
	player.vz = 0.0
	player.feet = heights.surface_at(player.x, player.z, player.feet)
	yaw = seat.yaw
	_seat_id = item.id
	camera_controller.seated = true
	_snap()
	hud.toast("Вы сели на лавку. Шаг или прыжок — встать")


func _stand_up() -> void:
	_seat_id = ""
	camera_controller.seated = false


## Удержание «взаимодействия» у сломанного объекта: кольцо в HUD растёт HOLD_TIME секунд, по завершении объект цел
## (RepairLayer). Отпустили или отвернулись — кольцо спадает, прогресс не копится.
## 18.11.2026: чинить можно и без задания с доски. Если объект — шаг активного «Ремонта», задание засчитано как раньше;
## иначе ближайшее поселение ждёт игрока с благодарностью (Quests.repaired_on_way, засчитывается в Quests.thank)
func _tick_repair(dt: float) -> void:
	if _target.get("kind") != "repair" or not Input.is_action_pressed("interact") or bike.riding \
			or _seat_id != "" or show_map or _journal_open() or _plaque_open() or photo.active or crash.active():
		_cancel_repair()
		return
	var id: String = _target.id
	if not repair_layer.repairs.is_broken(id):
		_cancel_repair()
		return
	if id != _fix_target:
		_cancel_repair()
		_fix_target = id
		hud.begin_repair()
	var previous_tick := floori((_fix_elapsed + REPAIR_TIME_EPSILON) / REPAIR_TICK_SECONDS)
	_fix_elapsed += dt
	if _fix_elapsed >= Repairables.HOLD_TIME - REPAIR_TIME_EPSILON:
		_complete_repair(id)
		return
	hud.set_repair(_fix_elapsed / Repairables.HOLD_TIME)
	var work_tick := floori((_fix_elapsed + REPAIR_TIME_EPSILON) / REPAIR_TICK_SECONDS)
	if work_tick > previous_tick:
		var last_tick := floorf(Repairables.HOLD_TIME / REPAIR_TICK_SECONDS)
		var work_pitch := remap(work_tick, 1.0, last_tick, 0.9, 1.25)
		hud.pulse_repair(work_pitch)
		services.controls.rumble(0.12, 0.0, 0.055)


func _cancel_repair() -> void:
	if _fix_target.is_empty():
		return
	_fix_target = ""
	_fix_elapsed = 0.0
	hud.cancel_repair()


func _complete_repair(id: String) -> void:
	_fix_target = ""
	_fix_elapsed = 0.0
	repair_layer.repair(id)
	hud.finish_repair()
	services.controls.rumble(0.35, 0.5, 0.12)
	var text := quests.repaired(id)
	if not text.is_empty():
		_quest_progress(text)
		return
	var place := world.place(id)
	if not place.is_empty():
		hud.toast(quests.repaired_on_way(InteractionService.target(place), _thanks_village(place)), &"quest")


## Поселение, где отблагодарят за ремонт по пути: ближайшее к месту на открытой земле (InteractionService.target) или пусто
func _thanks_village(place: Dictionary) -> Dictionary:
	return _nearest_village(Vector2(place.x, place.y))


## Ближайшее к точке (клетки) поселение на открытой земле (InteractionService.target) или пусто
func _nearest_village(at: Vector2) -> Dictionary:
	var best := {}
	var best_d := INF
	for p: Dictionary in hud.all_places():
		if p.kind != "settlement" or not hud.in_open_land(p):
			continue
		var d := Vector2(p.x, p.y).distance_squared_to(at)
		if d < best_d:
			best_d = d
			best = p
	return best


## Игрок у поселения, где ждут благодарность за ремонт по пути (Quests.thanks)
func _at_village(id: String) -> bool:
	var village := world.place(id)
	return not village.is_empty() and hud.at_place(InteractionService.target(village), player.x, player.z)


## Игрок у места шага задания. Припасы на вышку засчитываются только на её верхней площадке (шаг climb): сумку надо
## занести по лестнице пешком; тот же признак площадки, что у открытия мест с вышки (TowerLayout.on_deck)
func _quest_arrived(place: Dictionary) -> bool:
	if quests.step().get("do") == "climb":
		for tower: Dictionary in heights.towers:
			if tower.id == place.key:
				return TowerLayout.on_deck(tower, player.x, player.z, player.feet)
	return hud.at_place(place, player.x, player.z)


func _quest_photo(shot: Dictionary) -> void:
	interaction_service.photographed(shot)
	# табличка обелиска в кадре вблизи (PhotoCamera.plaque_view ok): шаг серии «Летопись обелисков» (идёт рядом с активным)
	if shot.get("plaque", "") != "":
		var text := quests.plaque_photographed(shot.plaque)
		if text != "":
			hud.toast(text, &"quest")


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
	_sync_delivery_bag()
	_beacon_layer.sync(quests.beacons_in_world(), goal, heights)
	_paint_layer.sync(quests.painted_objects, goal)
	bike_view.set_pack(quests.cargo)
	hud.quest_changed()


func _sync_region_settlements() -> void:
	audio.regional_fires = regions.fires
	if quests != null:
		_sync_delivery_bag()


func _sync_delivery_bag() -> void:
	var s := quests.step()
	var board := {}
	if s.get("do") == "pickup":
		for b: Dictionary in _boards + (regions.boards if regions != null else []):
			if WorldData.place_id("settlement", b.place.x, b.place.y) == s.place.key:
				board = b
				break
	if board.is_empty():
		if _bag != null:
			_bag.hide()
		return
	if _bag == null:
		_bag = CargoBag.build()
		add_child(_bag)
		_bag_label = Label3D.new()
		_update_bag_label()
		_bag_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		_bag_label.no_depth_test = true
		_bag_label.fixed_size = true
		_bag_label.pixel_size = 0.0015
		_bag_label.font_size = 28
		_bag_label.outline_size = 8
		_bag_label.modulate = Quests.KINDS.delivery.color
		_bag.add_child(_bag_label)
	var face: Transform3D = board.at
	var at := face * SettlementsBuilder.Courtyard.BAG_OFFSET
	at.y = heights.ground_at(at.x, at.z) + CargoBag.SIZE.y * 0.5 + 0.03
	_bag.transform = Transform3D(face.basis.rotated(Vector3.UP, 0.4), at)
	_bag.show()


func _close_settlement(capture := true) -> void:
	if not _settlement_open():
		return
	hud._close_travel()
	hud.settlement_panel.clear()
	if capture and not paused and not show_map:
		capture_mouse()


## Табличка обелиска: E у неё — текст (ObeliskLore) в окне, игра идёт, управление заперто; E, Esc или «Закрыть» — закрыть
func _plaque_open() -> bool:
	return hud != null and hud.plaque_panel != null and hud.plaque_panel.visible


func _read_plaque(item: Dictionary) -> void:
	var place := world.place(item.id)
	if place.is_empty() or _opening or crash.active() or _plaque_open():
		return
	_set_photo(false)
	services.controls.release_motion()
	services.controls.read_bike_body(bike, false)
	_dragging = false
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	var lore := ObeliskLore.describe(world, place)
	var series := quests.series_note(item.id) if quests != null else ""
	var ikey := services.controls.label(&"interact")
	var meta := {
		form = lore.form,
		in_album = hud.explore.album.has("plaque:" + item.id),
		series = quests.series_progress() if quests != null else Vector2i.ZERO,
		key_hint = "%s / Esc" % ikey if not ikey.is_empty() else "E / Esc",
	}
	if not hud.plaque_panel.closed.is_connected(close_plaque):
		hud.plaque_panel.closed.connect(close_plaque)
	hud.plaque_panel.open(lore.title, lore.text, series, meta)


func close_plaque(capture := true) -> void:
	if not _plaque_open():
		return
	hud.plaque_panel.clear()
	if capture and not paused and not show_map:
		capture_mouse()


func _journal_open() -> bool:
	return hud != null and hud.journal_panel != null and hud.journal_panel.visible \
			and hud.journal_panel.active_tab != Hud.Tablet.Tab.MAP


func open_journal(album := false) -> void:
	if not _placing_bike():
		_open_tablet(Hud.Tablet.Tab.ALBUM if album else Hud.Tablet.Tab.PATH)


func close_journal(capture := true) -> void:
	if _journal_open():
		close_tablet(capture)


## С верхней площадки вышки и с вершины видно далеко: все малые места в радиусе, не закрытые склоном, открываются
## на картах и в подписях мира. Один источник — один раз (Exploration.scanned).
func _look_around(source: String, radius: float, from_text: String) -> void:
	var explore := hud.explore
	explore.scanned[source] = true
	var eye := Vector3(player.x, player.feet + 1.7, player.z)
	var found := explore.reveal_from(hud.all_places(), eye, radius, TILE, hud.is_open, heights.ground_at, _occluded)
	if found.is_empty():
		hud.toast("%s новых мест не видно" % from_text)
	else:
		hud.toast("%s видно новых мест: %d" % [from_text, found.size()], &"discovery")
	hud.sync_map_places()


## Снимок попадает в альбом: биом под камерой, место в рамке, ночное явление над горизонтом
func _album_photo(shot: Dictionary) -> void:
	var place: Dictionary = {}
	if str(shot.get("place", "")) != "":
		place = world.place(shot.place)
	var info := world.tile_info(player.x / TILE, player.z / TILE)
	var events: Dictionary = day.events
	var shower: float = events.get("meteor", 0.0)
	var sky := {dark = _night, up = -camera.global_basis.z.y, aurora = events.get("aurora", 0.0), comet = events.get("comet", 0.0),
		meteor = shower if shower >= DayCycle.METEOR_SHOWER else 0.0}
	# 18.11.2026: место засчитывается только вблизи (Exploration.ALBUM_REACH), приближение не помогает
	var far := not place.is_empty() and float(shot.get("dist", 0.0)) > Exploration.album_reach(place.kind)
	var keys := Exploration.classify({} if far else place, int(info.biome) if not info.is_empty() else -1, sky, str(shot.get("plaque", "")))
	var titles := hud.explore.add_photo(shot, keys, Time.get_datetime_string_from_system(false, true), hud.ride_log.session_start())
	var photographed: String = shot.get("plaque", "")
	if photographed.is_empty() and not far:
		photographed = place.get("id", "")
	hud.explore.record_place_photo(photographed, str(shot.get("path", "")))
	if not titles.is_empty():
		hud.toast("Новая страница альбома: «%s»" % "», «".join(titles), &"album")
	if far:
		for key: String in Exploration.classify(place, -1, {}):
			if not hud.explore.album.has(key):
				hud.toast("Для альбома слишком далеко: подойдите к «%s» ближе %s" % [place.name, Util.distance_text(Exploration.album_reach(place.kind))], &"warning")
				break


func _navigation_goal(place: Dictionary) -> void:
	navigation_line.set_goal(place, Vector2(player.x, player.z), player.feet)
	place_names.set_goal(place)


func _board_travel(place: Dictionary) -> void:
	if not _settlement_open() or not hud.in_open_land(place) or quests.cargo:
		return
	for offered: Dictionary in hud.settlement_panel.board_map.places.slice(1):
		if offered.key == place.key:
			hud.ask_travel(offered)
			return


func _recall_bike() -> void:
	if not _settlement_open() or paused or not player.on_ground:
		return
	var parked := BikeRide.park_near(player, yaw, world, heights)
	if parked == null:
		hud.toast_now("Рядом нет свободного места для велосипеда", &"warning")
		return
	bike = parked
	bike_view.snap(bike)
	bike_view.draw(1.0)
	_close_settlement()
	hud.toast_now("Велосипед ждёт рядом с костром")


## Фонарик (F): с 10.4 это фара на руле велосипеда (BikeView.lamp), светит туда, куда повёрнут руль.
## Пешком переключается только рядом с велосипедом, в пределах доступности посадки.
func toggle_flashlight() -> void:
	if not bike.riding and not bike.can_mount(player):
		hud.toast_now("Подойдите к велосипеду, чтобы переключить фару", &"warning")
		return
	bike_view.set_lamp(not bike_view.lamp_on())


## Камера в доле alpha пути между двумя последними тактами; dt — длина кадра, для сглаживания
func _update_camera(alpha: float, dt: float) -> void:
	camera_controller.update(alpha, dt, player, bike, camera, time, _opening, _moving,
		crash.active(), photo != null and photo.active,
		photo.fov(services.settings.fov) if photo != null else services.settings.fov, bike_view.view_squash())


## Хруст покрытия под тормозом: уверенное торможение в пределах сцепления слышно мягко, насыщение шин (тормоз
## просит больше, чем держат колёса) и снос — как юз. Нажатая кнопка сама по себе блокировку не изображает.
func _bike_skid_sound() -> float:
	return maxf(bike.braking * (0.3 + 0.7 * bike.brakes.skid), smoothstep(0.04, 0.18, absf(bike.slip)) * 0.65)


## Удары велосипеда за такт — три отдельных события, ни одно не подавляет другое:
## приземление (вся рама, тряска и проседание камеры), удар колеса о кромку (короткий стук; переднее отдаёт в руль —
## лёгкий мотор геймпада, заднее в раму — тяжёлый) и пробой подвески (удар в упор). Проседание камеры — по самому
## сильному из них, а не сумма: одно падение рамы не считается трижды.
func _bike_impacts() -> void:
	var land := bike.land_impact
	var wheel := bike.wheel_impact
	var dip := 0.0
	var trauma := 0.0
	var weak := 0.0
	var strong := 0.0
	_shake_on_landing(land, 6.0)
	if land > 0.0:
		dip = clampf(land - 2.5, 0.0, 8.0) * 0.12
		audio.land(bike.x, bike.z, bike.y, land)
		weak = clampf(land / 10.0, 0.0, 0.6)
		strong = clampf((land - 4.0) / 8.0, 0.0, 1.0)
	var knock := maxf(wheel.x, wheel.y)
	if knock > 0.0:
		var hit := clampf(knock / 3.0, 0.0, 1.0)
		dip = maxf(dip, 0.15 + hit * 0.35)
		trauma += 0.04 + hit * 0.1
		audio.wheel_knock(knock, wheel.x >= wheel.y)
		weak = maxf(weak, (0.25 + hit * 0.35) if wheel.x >= wheel.y else 0.1)
		strong = maxf(strong, (0.2 + hit * 0.4) if wheel.y > wheel.x else 0.1)
	if bike.bottom_out > 0.0:
		audio.bottom_out(bike.bottom_out)
		# 14.1: пробой вилки — удар рамы: камера проседает и вздрагивает, геймпад отдаёт тяжёлым мотором
		var hit := clampf(bike.bottom_out - BikeRide.BOTTOM_OUT, 0.0, 3.0)
		dip = maxf(dip, 0.4 + hit * 0.35)
		trauma += 0.12 + hit * 0.08
		weak = maxf(weak, 0.3)
		strong = maxf(strong, 0.45 + hit * 0.15)
	if services.settings.head_bob:
		_dip_v -= dip
	_trauma = minf(1.0, _trauma + trauma)
	if weak > 0.0 or strong > 0.0:
		services.controls.rumble(weak, strong, 0.15 if land > 0.0 else 0.1)
