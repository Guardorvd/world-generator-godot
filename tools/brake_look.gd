extends SceneTree
## Изолированный стенд проверки и съёмки эффектов торможения (BrakeEffects + BikeView) без генерации мира.
## Снимает серию ситуаций и проверяет инварианты:
##   1) гравий — экстренное торможение (камешки, бежевый шлейф пыли, борозда протектора),
##   2) песок — торможение с боковым заносом (широкий золотистый веер песка и глубокая колея),
##   3) лесная тропа / трава — торможение на корнях с вылетом хвои, листьев и комьев земли,
##   4) камень на крутом спуске — перегрев и свечение тормозных дисков, искры из калипера и светлый дым резины,
##   5) снег — снежная пудра и голубоватая колея,
##   6) мелкая вода (брод) — водяная взвесь и капли без сухого следа на дне.
## Запуск:
##   godot --path . --script res://tools/brake_look.gd -- [--out <папка>]

const DT := 1.0 / 60.0

class StandWorld extends WorldData:
	var surface := RoadSurface.GRAVEL
	var current_biome := Biomes.GRASS
	func tile_info(_x: float, _z: float) -> Dictionary:
		return {biome = current_biome, path = 3 if surface != RoadSurface.NONE else 0, surface = surface}

class StandGround extends Heightfield:
	var slope := 0.0
	var water_depth := 0.0
	var deck_height := -INF
	func _init(w: WorldData) -> void:
		super(w, false)
	func ground_at(_x: float, z: float, _raw := false) -> float:
		return -z * slope
	func surface_at(x: float, z: float, feet := -INF) -> float:
		return maxf(ground_at(x, z), deck_at(x, z, feet))
	func deck_at(_x: float, _z: float, _feet := -INF) -> float:
		return deck_height
	func depth_at(_x: float, _z: float, _feet := -INF) -> float:
		return water_depth
	func known(_x: float, _z: float) -> bool:
		return true

var out := ""
var world := StandWorld.new()
var ground := StandGround.new(world)
var player := PlayerState.new()
var bike := BikeRide.new()
var bike_view: BikeView
var effects: BrakeEffects
var floor_mesh: MeshInstance3D
var floor_mat: StandardMaterial3D
var camera: Camera3D
var fails := 0


func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 90)
	var args := OS.get_cmdline_user_args()
	out = _arg(args, "--out", OS.get_user_data_dir().path_join("brake_look"))
	DirAccess.make_dir_recursive_absolute(out)
	if DisplayServer.get_name() != "headless":
		root.size = Vector2i(1280, 720)
	_build_scene()
	_run.call_deferred()


static func _arg(args: PackedStringArray, key: String, def: String) -> String:
	var at := args.find(key)
	return args[at + 1] if at >= 0 and at + 1 < args.size() else def


func _check(ok: bool, msg: String) -> void:
	print(("✓ " if ok else "✗ ") + msg)
	if not ok:
		fails += 1


func _build_scene() -> void:
	var env := WorldEnvironment.new()
	var e := Environment.new()
	var sky := Sky.new()
	sky.sky_material = ProceduralSkyMaterial.new()
	e.background_mode = Environment.BG_SKY
	e.sky = sky
	e.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	e.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	e.glow_enabled = true
	e.glow_intensity = 0.6
	env.environment = e
	root.add_child(env)

	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-42.0, -35.0, 0.0)
	sun.light_energy = 1.15
	sun.shadow_enabled = true
	root.add_child(sun)

	var plane := PlaneMesh.new()
	plane.size = Vector2(160.0, 160.0)
	floor_mat = StandardMaterial3D.new()
	floor_mat.albedo_color = Color(0.45, 0.41, 0.34)
	floor_mat.roughness = 0.92
	floor_mesh = MeshInstance3D.new()
	floor_mesh.mesh = plane
	floor_mesh.material_override = floor_mat
	root.add_child(floor_mesh)

	bike_view = preload("res://scenes/bike.tscn").instantiate() as BikeView
	root.add_child(bike_view)

	effects = BrakeEffects.new()
	root.add_child(effects)

	camera = Camera3D.new()
	camera.fov = 62.0
	root.add_child(camera)
	camera.make_current()


func _reset_scenario(surf: int, biome: int, floor_col: Color, start_speed: float, slope := 0.0, water := 0.0) -> void:
	world.surface = surf
	world.current_biome = biome
	ground.slope = slope
	ground.water_depth = water
	floor_mat.albedo_color = floor_col
	floor_mesh.rotation.x = atan(slope)

	player = PlayerState.new()
	bike = BikeRide.new()
	bike.x = 0.0
	bike.z = 0.0
	bike.y = ground.ground_at(0.0, 0.0)
	bike.heading = 0.0
	bike.mount(player)
	bike.speed = start_speed
	bike_view.snap(bike)
	effects.clear()


func _simulate(ticks: int, throttle: float, turn: float, keep_min_speed := 0.0) -> void:
	for i in ticks:
		if keep_min_speed > 0.0 and bike.speed < keep_min_speed:
			bike.speed = keep_min_speed
		bike.step(player, throttle, turn, false, false, DT, world, ground)
		bike_view.tick(bike, DT, throttle, false)
		effects.tick(DT, bike, world, ground)
	bike_view.draw(1.0)


func _shot(name: String, cam_offset: Vector3, look_offset: Vector3) -> void:
	if DisplayServer.get_name() == "headless":
		return
	var bike_pos := Vector3(bike.x, bike.y, bike.z)
	camera.look_at_from_position(bike_pos + cam_offset, bike_pos + look_offset)
	for i in 4:
		await process_frame
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png(out.path_join(name + ".png"))


func _run() -> void:
	# 1. Гравий: прямое экстренное торможение
	_reset_scenario(RoadSurface.GRAVEL, Biomes.GRASS, Color(0.50, 0.46, 0.39), 14.5)
	_simulate(48, -1.0, 0.0, 5.5)
	_check(effects.last_surface_f == BrakeEffects.SURF_GRAVEL, "Гравий распознан под колёсами")
	_check(effects._debris_mm.visible and effects._plume_mm.visible and effects._track_node.visible, "На гравии активны частицы, клубы пыли и след на земле")
	await _shot("brake_gravel", Vector3(-1.85, 0.95, 2.25), Vector3(0.0, 0.35, 0.4))

	# 2. Песок: торможение в крутом повороте с боковым сносом
	_reset_scenario(RoadSurface.SAND, Biomes.BEACH, Color(0.76, 0.68, 0.48), 14.0)
	_simulate(52, -1.0, 0.85, 5.0)
	_check(effects.last_surface_r == BrakeEffects.SURF_SAND, "Песок распознан под колёсами")
	_check(effects._t_count[0] > 3 and effects._t_count[1] > 3, "В заносе на песке оба колеса оставляют широкие борозды")
	await _shot("brake_sand_drift", Vector3(2.1, 1.05, 2.1), Vector3(0.0, 0.32, 0.2))

	# 3. Лесная тропа: торможение на хвое, листьях и корнях
	_reset_scenario(RoadSurface.FOREST, Biomes.FOREST, Color(0.32, 0.26, 0.18), 13.5)
	_simulate(46, -1.0, -0.55, 5.0)
	_check(effects.last_surface_f == BrakeEffects.SURF_FOREST, "Лесная подстилка распознана")
	await _shot("brake_forest", Vector3(-1.7, 0.88, 2.0), Vector3(0.0, 0.32, 0.3))

	# 4. Камень и затяжной спуск: раскалённые тормозные диски, искры и дым резины
	_reset_scenario(RoadSurface.STONE, Biomes.ROCK, Color(0.38, 0.37, 0.35), 16.5, -0.18)
	_simulate(110, -1.0, 0.25, 9.5)
	_check(effects.last_surface_f == BrakeEffects.SURF_STONE, "Каменистое покрытие распознано")
	_check(effects.heat_f > 0.45 and bike_view._heat_f > 0.45, "При затяжном торможении на спуске тормозной ротор нагревается (heat_f=%.2f)" % effects.heat_f)
	await _shot("brake_stone_rotor_glow", Vector3(-0.95, 0.52, 0.65), Vector3(-0.04, 0.34, -0.15))

	# 5. Снег: торможение в снегу со снежной пудрой и голубоватой колеёй
	_reset_scenario(RoadSurface.NONE, Biomes.SNOW, Color(0.84, 0.88, 0.93), 13.5)
	_simulate(48, -1.0, -0.45, 5.0)
	_check(effects.last_surface_f == BrakeEffects.SURF_SNOW, "Снежный биом распознан")
	await _shot("brake_snow", Vector3(-1.9, 1.0, 2.2), Vector3(0.0, 0.35, 0.3))

	# 6. Брод (мелкая вода): водяная взвесь без сухого следа на грунте
	_reset_scenario(RoadSurface.GRAVEL, Biomes.GRASS, Color(0.25, 0.38, 0.42), 13.0, 0.0, 0.08)
	_simulate(40, -1.0, 0.35, 5.0)
	_check(effects.last_surface_f == BrakeEffects.SURF_WATER, "Водная поверхность распознана при глубине > 2.5 см")
	_check(not effects._track_node.visible, "На воде не остаётся сухой след протектора")
	await _shot("brake_water", Vector3(-1.8, 0.95, 2.0), Vector3(0.0, 0.35, 0.2))

	# 7. Проверка отрыва колеса: в полёте новые точки следа не пишутся
	effects.clear()
	bike.airborne = true
	effects.tick(DT, bike, world, ground)
	_check(effects._t_count[0] == 0 and effects._t_count[1] == 0, "В воздухе колёса не оставляют следов и частиц")

	print("brake_look: снимки сохранены в ", out, " | ошибок: ", fails)
	quit(1 if fails > 0 else 0)
