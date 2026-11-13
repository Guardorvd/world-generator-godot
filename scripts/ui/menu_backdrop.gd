extends Node
## Постановочный привал. Вызывающий даёт сцене исключительный доступ к глобальным параметрам
## отрисовки и вызывает stop() или freeze() до открытия игры или Лаборатории.

signal prepared
signal failed(reason: String)
signal performance_fallback

const Lighting := preload("res://scripts/render/lighting_quality.gd")
const Floor := preload("res://scripts/render/forest_floor.gd")
const FarForest := preload("res://scripts/render/distant_forest.gd")
const Catalog := preload("res://scripts/render/asset_catalog.gd")
const GROUND_SHADER := preload("res://resources/menu/ground.gdshader")
const LAKE_SHADER := preload("res://resources/menu/lake.gdshader")
const GAME_SCENE := "res://scenes/game_world.tscn"
const BIKE_SCENE := "res://scenes/bike.tscn"
const SIDE := 256
const LAKE_AT := Vector2(465.0, 551.0)
const LAKE_RADII := Vector2(225.0, 232.0)
const LAKE_LEVEL := 12.0
const EYE_AT := Vector2(500.0, 820.0)
const BIKE_AT := Vector2(502.1, 813.2)
const OAK_AT := Vector2(506.3, 807.0)
const HOUR := 17.0 + 20.0 / 60.0
const GLOBALS := [&"cloud_shadow", &"sun_dir", &"vegetation_night", &"style_haze",
	&"style_depth", &"veg_center", &"vegetation_clock", &"veg_seeds", &"distant_vegetation"]
const BUILD_STEPS := [&"light", &"site_north", &"site_south", &"heightfield", &"surface", &"terrain_far", &"terrain_near",
	&"water", &"mountains", &"vegetation", &"far_forest_north", &"far_forest_south", &"rider"]
const QUALITY := [0.5, 0.67, 1.0]
const RIDER_TICK := 1.0 / 60.0
const SAMPLE_FRAMES := 60
const SLOW_FRAME := 0.050
const ATMOSPHERE_STEP := 0.10
const SITE_SEED := 4821

static var _owner: Node

var step_ms := {}
var build_ms := 0.0
var is_prepared := false
var _view: SubViewport
var _scene: Node3D
var _camera: Camera3D
var _cycle: DayCycle
var _world: WorldData
var _heights: Heightfield
var _surface: Image
var _terrain_material: ShaderMaterial
var _lake_material: ShaderMaterial
var _site_fields := {}
var _site_rng: RandomNumberGenerator
var _vegetation: VegetationLayer
var _bike: BikeView
var _rider: BikeRide
var _settings: GameSettings
var _origin: Vector3
var _quality := 0
var _render_divisor := 1
var _draw_frame := 0
var _step := 0
var _started := 0
var _warm_frames := 0
var _render_delta := 0.0
var _rider_delta := 0.0
var _seconds := 0.0
var _next_atmosphere := 0.0
var _wind_offset := 0.0
var _display_size := Vector2i.ZERO
var _adaptive := false
var _sample_frames := 0
var _slow_frames := 0
var _previous_style_on := {}
var _previous_style_amount := {}


static func recommended_quality() -> int:
	return 0 if RenderingServer.get_current_rendering_method() == "gl_compatibility" else 2


## quality: 0 — экономный, 1 — средний, 2 — полный. native_size нужен для съёмки афиши.
func start(display_size: Vector2i, settings: GameSettings, quality: int, native_size := false, interactive := false) -> bool:
	if _view != null or not is_inside_tree() or DisplayServer.get_name() == "headless":
		return false
	if is_instance_valid(_owner) or VisualStyle.is_bound():
		return false
	_owner = self
	_previous_style_on = VisualStyle.on.duplicate()
	_previous_style_amount = VisualStyle.amount.duplicate()
	_settings = GameSettings.new()
	_settings.style_on = settings.style_on.duplicate()
	_settings.style_amount = settings.style_amount.duplicate()
	_quality = clampi(quality, 0, QUALITY.size() - 1)
	_render_divisor = 2 if _quality == 0 and not native_size else 1
	_adaptive = interactive
	_sample_frames = 0
	_slow_frames = 0
	_step = 0
	_warm_frames = 0
	_seconds = 0.0
	_next_atmosphere = 0.0
	_wind_offset = 0.0
	_render_delta = 0.0
	_rider_delta = 0.0
	_draw_frame = 0
	step_ms.clear()
	build_ms = 0.0
	_started = Time.get_ticks_usec()
	_view = SubViewport.new()
	_view.name = "MenuWorld"
	_view.own_world_3d = true
	_view.gui_disable_input = true
	_view.render_target_update_mode = SubViewport.UPDATE_DISABLED
	_view.msaa_3d = Viewport.MSAA_2X if _quality == 2 else Viewport.MSAA_DISABLED
	add_child(_view)
	resize(display_size, native_size)
	_scene = Node3D.new()
	_view.add_child(_scene)
	set_process(true)
	return true


func resize(display_size: Vector2i, native_size := false) -> void:
	if _view == null:
		return
	_display_size = display_size
	var scale_factor: float = 1.0 if native_size else QUALITY[_quality]
	_view.size = Vector2i(maxi(2, roundi(display_size.x * scale_factor)),
		maxi(2, roundi(display_size.y * scale_factor)))


func viewport() -> SubViewport:
	return _view


func render_count() -> int:
	return _draw_frame / _render_divisor


## Снимок берётся только из уже прогретой сцены. При отмене сборки вызывающий оставляет афишу.
func freeze() -> Image:
	var image: Image
	if is_prepared and _view != null:
		image = _view.get_texture().get_image()
	stop()
	return image


func stop() -> void:
	set_process(false)
	is_prepared = false
	if _view != null:
		_view.render_target_update_mode = SubViewport.UPDATE_DISABLED
		# VegetationLayer._exit_tree дожидается начатой раскладки перед освобождением её данных.
		_view.free()
		_view = null
	_scene = null
	_camera = null
	_cycle = null
	_vegetation = null
	_bike = null
	_rider = null
	_world = null
	_heights = null
	_surface = null
	_terrain_material = null
	_lake_material = null
	_site_fields.clear()
	_site_rng = null
	_settings = null
	if _owner == self:
		VisualStyle.release()
		# Если стиль меняли в настройках меню, эти значения уже принадлежат игроку.
		if not _adaptive:
			VisualStyle.configure(_previous_style_on, _previous_style_amount)
		for parameter: StringName in GLOBALS:
			var entry: Dictionary = ProjectSettings.get_setting("shader_globals/" + String(parameter))
			RenderingServer.global_shader_parameter_set(parameter, entry.value)
		_owner = null


func _exit_tree() -> void:
	stop()


func _process(delta: float) -> void:
	if _view == null or get_window().mode == Window.MODE_MINIMIZED:
		return
	if is_prepared and _adaptive and not _sample_performance(delta):
		return
	if _step < BUILD_STEPS.size():
		var started := Time.get_ticks_usec()
		var step: StringName = BUILD_STEPS[_step]
		match step:
			&"light": _build_light()
			&"site_north":
				_begin_site()
				_build_site_rows(0, SIDE / 2)
			&"site_south":
				_build_site_rows(SIDE / 2, SIDE)
				_finish_site()
			&"heightfield": _build_heightfield()
			&"surface":
				var problem := Catalog.check()
				if not problem.is_empty():
					stop()
					failed.emit(problem)
					return
				_build_surface()
			&"terrain_far": _build_terrain(Rect2i(0, 0, SIDE - 1, 112))
			&"terrain_near": _build_terrain(Rect2i(0, 112, SIDE - 1, 100))
			&"water": _build_water()
			&"mountains": _build_mountains()
			&"vegetation":
				_build_vegetation()
			&"far_forest_north": _build_far_forest(0)
			&"far_forest_south": _build_far_forest(1)
			&"rider": _build_rider()
		step_ms[step] = (Time.get_ticks_usec() - started) / 1000.0
		_step += 1
		return
	if _warm_frames == 4 and not is_prepared:
		return
	if not is_prepared and _warm_frames == 0:
		var started := Time.get_ticks_usec()
		_vegetation.update(EYE_AT.x, EYE_AT.y, false, minf(delta, 0.1))
		step_ms["vegetation_upload_max"] = maxf(step_ms.get("vegetation_upload_max", 0.0),
			(Time.get_ticks_usec() - started) / 1000.0)
		# Первый вид целиком: частичная раскладка успела бы показать дырки и прогреть лишние варианты.
		if not _vegetation.placement_ready():
			return
		_draw_frame = _render_divisor - 1
		# Часы растений сразу за окном проявления: первый показанный кадр уже без дорисовки.
		_wind_offset = _vegetation.stream.clock - _seconds + VegetationLayer.StreamPolicy.FADE_SECONDS + 0.1
	var dt := minf(delta, 0.1)
	_seconds += dt
	_render_delta += dt
	_draw_frame += 1
	if _draw_frame % _render_divisor != 0:
		return
	_animate(_render_delta)
	_render_delta = 0.0
	_view.render_target_update_mode = SubViewport.UPDATE_ONCE
	if not is_prepared:
		_warm_frames += 1
		if _warm_frames == 4:
			_finish_warmup(_view)


## Текстура готова только после завершения отрисовки, в том числе на медленном GPU.
func _finish_warmup(view: SubViewport) -> void:
	await RenderingServer.frame_post_draw
	if not is_instance_valid(view) or _view != view:
		return
	build_ms = (Time.get_ticks_usec() - _started) / 1000.0
	is_prepared = true
	prepared.emit()


## Несколько медленных кадров нужны, чтобы случайный рывок окна не выключил сцену.
func _sample_performance(delta: float) -> bool:
	if _sample_frames >= SAMPLE_FRAMES:
		return true
	_sample_frames += 1
	if delta > SLOW_FRAME:
		_slow_frames += 1
	if _sample_frames != SAMPLE_FRAMES or _slow_frames < 6:
		return true
	if _quality == 0:
		performance_fallback.emit()
		return false
	_quality -= 1
	_render_divisor = 2 if _quality == 0 else 1
	_view.msaa_3d = Viewport.MSAA_DISABLED
	_cycle.light.shadow_enabled = false
	resize(_display_size)
	_sample_frames = 0
	_slow_frames = 0
	return true


func _build_light() -> void:
	var env_node := WorldEnvironment.new()
	var template: Node = load(GAME_SCENE).instantiate()
	var env: Environment = template.get_node("WorldEnvironment").environment.duplicate()
	template.free()
	env.glow_enabled = false
	env_node.environment = env
	_scene.add_child(env_node)
	var sun := DirectionalLight3D.new()
	_scene.add_child(sun)
	_cycle = DayCycle.new(env, sun)
	_cycle.world_seed = SITE_SEED
	_cycle.cloud_cover_override = 0.3
	Lighting.apply(env, sun, 0, _quality == 2, 0)
	sun.directional_shadow_max_distance = 80.0
	VisualStyle.configure(_settings.style_on, _settings.style_amount)
	VisualStyle.bind(env)
	_camera = Camera3D.new()
	_camera.fov = 43.0
	_camera.far = 3700.0
	_scene.add_child(_camera)
	_camera.make_current()
	_camera.add_child(StyleGrain.new())


func _begin_site() -> void:
	var world := WorldData.new()
	world.W = SIDE
	world.H = SIDE
	world.N = SIDE * SIDE
	world.CS = WorldData.CHUNK_SIZE
	world.CW = SIDE / world.CS
	world.CH = SIDE / world.CS
	world.seed_num = SITE_SEED
	for key in ["elevation", "filled", "moist", "water_distance"]:
		var field := PackedFloat32Array()
		field.resize(world.N)
		_site_fields[key] = field
	for key in ["biome", "lake"]:
		var field := PackedByteArray()
		field.resize(world.N)
		_site_fields[key] = field
	var chunks: Array[PackedInt32Array] = []
	chunks.resize(world.CW * world.CH)
	world.chunks = chunks
	_world = world
	_site_rng = RandomNumberGenerator.new()
	_site_rng.seed = SITE_SEED


func _build_site_rows(first: int, last: int) -> void:
	var elevation: PackedFloat32Array = _site_fields.elevation
	var filled: PackedFloat32Array = _site_fields.filled
	var moist: PackedFloat32Array = _site_fields.moist
	var water_distance: PackedFloat32Array = _site_fields.water_distance
	var biome: PackedByteArray = _site_fields.biome
	var lake: PackedByteArray = _site_fields.lake
	var chunks := _world.chunks
	for j in range(first, last):
		var z := (j + 0.5) * GameConfig.TILE
		for i in SIDE:
			var x := (i + 0.5) * GameConfig.TILE
			var k := j * SIDE + i
			var p := Vector2(x, z)
			var shore := ((p - LAKE_AT) / LAKE_RADII).length() - 1.0
			shore += sin(x * 0.038 + cos(z * 0.027)) * 0.035 + cos((x + z) * 0.019) * 0.025
			var upland := smoothstep(0.0, 0.48, shore)
			var north := 1.0 - smoothstep(85.0, 360.0, z)
			var hills := north * (44.0 + 19.0 * cos(x * 0.009 + z * 0.013) + 11.0 * sin(x * 0.016 - z * 0.018))
			var bluff := 4.6 * exp(-p.distance_squared_to(EYE_AT) / 3600.0)
			var grass_relief := 1.1 * sin(x * 0.08 + z * 0.018) * cos(z * 0.062 - x * 0.009)
			var height := LAKE_LEVEL + clampf(shore * 29.0, -10.0, 1.6) + bluff + upland * (hills + grass_relief)
			var shore_distance := maxf(0.0, shore * 55.0)
			elevation[k] = height / GameConfig.HS
			filled[k] = (LAKE_LEVEL + GameConfig.LAKE_DROP) / GameConfig.HS if height < LAKE_LEVEL else elevation[k]
			moist[k] = 0.45 + 0.14 * exp(-shore_distance / 4.0) + 0.09 * sin(x * 0.035 + z * 0.021)
			water_distance[k] = shore_distance
			if height < LAKE_LEVEL:
				lake[k] = 1
				biome[k] = Biomes.LAKE
			elif height < LAKE_LEVEL + 0.75:
				biome[k] = Biomes.STONESHORE
			else:
				var wooded := z < 405.0 + 45.0 * sin(x * 0.014) and shore > 0.035
				biome[k] = Biomes.FOREST if wooded else Biomes.GRASS
				if wooded and absf(x - EYE_AT.x) < (EYE_AT.y - z) * 0.78 + 35.0 and _site_rng.randf() < 0.24:
					var kind := Biomes.T_PINE if _site_rng.randf() < 0.58 else (Biomes.T_BIRCH if _site_rng.randf() < 0.5 else Biomes.T_OAK)
					_plant(_world, chunks, p + Vector2(_site_rng.randf_range(-1.6, 1.6), _site_rng.randf_range(-1.6, 1.6)),
						kind, _site_rng.randi_range(0, 2), _site_rng.randf_range(0.58, 1.22))
	_site_fields = {elevation = elevation, filled = filled, moist = moist, water_distance = water_distance, biome = biome, lake = lake}


func _finish_site() -> void:
	var world := _world
	var chunks := world.chunks
	_plant(world, chunks, OAK_AT, Biomes.T_OAK, ForestModels.OLD_AGE * 3, 1.08)
	_plant(world, chunks, Vector2(448.0, 795.0), Biomes.T_BIRCH, 4, 0.67)
	_plant(world, chunks, Vector2(519.0, 790.0), Biomes.T_BUSH, 1, 1.25)
	world.chunks = chunks
	world.obj_count = world.obj_x.size()
	var elevation: PackedFloat32Array = _site_fields.elevation
	world.h = elevation
	world.elev = elevation
	world.filled = _site_fields.filled
	world.moist = _site_fields.moist
	world.dist_water = _site_fields.water_distance
	world.biome = _site_fields.biome
	world.lake = _site_fields.lake
	_site_fields.clear()
	_site_rng = null


func _build_heightfield() -> void:
	var world := _world
	var elevation := world.elev
	var slope := PackedFloat32Array()
	slope.resize(world.N)
	for j in SIDE:
		for i in SIDE:
			var gx := elevation[j * SIDE + mini(SIDE - 1, i + 1)] - elevation[j * SIDE + maxi(0, i - 1)]
			var gz := elevation[mini(SIDE - 1, j + 1) * SIDE + i] - elevation[maxi(0, j - 1) * SIDE + i]
			slope[j * SIDE + i] = Vector2(gx, gz).length() * 30.0
	var empty := PackedByteArray()
	empty.resize(world.N)
	var temperature := PackedFloat32Array()
	temperature.resize(world.N)
	temperature.fill(0.53)
	world.temp = temperature
	world.slope = slope
	world.ocean = empty
	world.river = empty
	world.path_mask = empty
	_heights = Heightfield.new(world, false)
	_origin = Vector3(EYE_AT.x, _heights.ground_at(EYE_AT.x, EYE_AT.y) + 1.4, EYE_AT.y)


static func _plant(world: WorldData, chunks: Array[PackedInt32Array], p: Vector2, kind: int, variant: int, scale_factor: float) -> void:
	var cell := p / GameConfig.TILE
	var plants := world.climate
	chunks[floori(cell.y / world.CS) * world.CW + floori(cell.x / world.CS)].append(plants.obj_x.size())
	plants.obj_x.append(cell.x)
	plants.obj_y.append(cell.y)
	plants.obj_k.append(kind)
	plants.obj_v.append(variant)
	plants.obj_s.append(scale_factor)


func _build_surface() -> void:
	_surface = Floor.surface_image(_world)
	var colors := {
		Biomes.LAKE: Color("6e8a82"), Biomes.STONESHORE: Color("8c8974"),
		Biomes.GRASS: Color("7f965f"), Biomes.FOREST: Color("526a50"),
	}
	var pixels := PackedByteArray()
	pixels.resize(_world.N * 3)
	var biome := _world.biome
	var moist := _world.moist
	for k in _world.N:
		var tone: Color = colors[biome[k]]
		var variation := 1.0 + (moist[k] - 0.5) * 0.36
		pixels[k * 3] = roundi(tone.r * variation * 255.0)
		pixels[k * 3 + 1] = roundi(tone.g * variation * 255.0)
		pixels[k * 3 + 2] = roundi(tone.b * variation * 255.0)
	var base := Image.create_from_data(SIDE, SIDE, false, Image.FORMAT_RGB8, pixels)
	base.generate_mipmaps()
	var forest := _surface.duplicate() as Image
	forest.generate_mipmaps()
	_terrain_material = ShaderMaterial.new()
	_terrain_material.shader = GROUND_SHADER
	_terrain_material.set_shader_parameter("base_tex", ImageTexture.create_from_image(base))
	_terrain_material.set_shader_parameter("forest_tex", ImageTexture.create_from_image(forest))
	_terrain_material.set_shader_parameter("detail_tex", Catalog.get_catalog().textures[3])
	_terrain_material.set_shader_parameter("detail_normal", Catalog.get_catalog().textures[4])


func _build_terrain(area: Rect2i) -> void:
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, TerrainBuilder.build_arrays(_world, _heights, area))
	_add_mesh("Shore", mesh, _terrain_material)


func _build_water() -> void:
	# Берег режется теми же треугольниками, что и озёра в игре.
	var area := Rect2i(Vector2i((LAKE_AT - LAKE_RADII) / GameConfig.TILE),
		Vector2i(LAKE_RADII * 2.0 / GameConfig.TILE)).grow(9)
	_lake_material = ShaderMaterial.new()
	_lake_material.shader = LAKE_SHADER
	var lake := WaterBuilder.flat_mesh(WaterBuilder._lake_arrays(_world, _heights, area), _lake_material, "Lake")
	lake.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_scene.add_child(lake)


func _build_mountains() -> void:
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	const COLUMNS := 81
	const ROWS := 25
	const SPACING := 46.0
	var noise := FastNoiseLite.new()
	noise.seed = 1843
	noise.frequency = 0.012
	for j in ROWS:
		var z := -j * SPACING - 100.0
		for i in COLUMNS:
			var x := 500.0 + (i - 40) * SPACING
			var crest := 470.0 + 103.0 * sin(x * 0.0046) + 62.0 * cos(x * 0.009)
			var ridge := maxf(0.0, 1.0 - absf((-z - crest) / 520.0))
			var shoulders := 220.0 + 97.0 * cos(x * 0.0064) + 65.0 * sin(x * 0.014)
			var peak := 212.0 * exp(-pow((x - 315.0) / 250.0, 2.0))
			var height := ridge * (shoulders + peak + 143.0 * noise.get_noise_2d(x, z))
			var cold := smoothstep(200.0, 420.0, height + 65.0 * noise.get_noise_2d(x + 71.0, z))
			var rock := Color("74767c").lerp(Color("d1ced0"), cold)
			surface.set_color(Color("596751").lerp(rock, smoothstep(48.0, 160.0, height)))
			surface.add_vertex(Vector3(x, height - 18.0, z))
	for j in ROWS - 1:
		for i in COLUMNS - 1:
			var a := j * COLUMNS + i
			for index: int in [a, a + COLUMNS, a + 1, a + 1, a + COLUMNS, a + COLUMNS + 1]:
				surface.add_index(index)
	surface.generate_normals()
	var material := ShaderMaterial.new()
	material.shader = GROUND_SHADER
	material.set_shader_parameter("ridge", true)
	material.set_shader_parameter("detail_tex", Catalog.get_catalog().textures[3])
	var mountain := _add_mesh("Ridge", surface.commit(), material)
	mountain.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF


func _add_mesh(label: String, mesh: Mesh, material: Material) -> MeshInstance3D:
	var node := MeshInstance3D.new()
	node.name = label
	node.mesh = mesh
	node.material_override = material
	_scene.add_child(node)
	return node


func _build_vegetation() -> void:
	_vegetation = VegetationLayer.new()
	_vegetation.use_shared_forest_ranges = false
	_settings.draw = 0
	_settings.flora = _quality
	_settings.trail_clutter = false
	_vegetation.settings = _settings
	_scene.add_child(_vegetation)
	var defs := Models.tree_defs()
	for key: int in defs.keys():
		if key % ForestModels.MODEL_STRIDE not in [Biomes.T_OAK, Biomes.T_BIRCH, Biomes.T_PINE, Biomes.T_BUSH]:
			defs.erase(key)
	_vegetation.setup(_world, _heights, defs, Models.grass_mesh(), _surface)
	RenderingServer.global_shader_parameter_set("distant_vegetation",
		Vector4(_vegetation.tree_r, _vegetation.tree_r * VegetationLayer.FADE_SHARE, 1250.0, 1.0))


func _build_far_forest(row: int) -> void:
	var draw_range := Vector2(_vegetation.tree_r * (1.0 - VegetationLayer.FADE_SHARE) - 100.0, 1250.0)
	for i in ceili(float(SIDE) / PlanTerrain.CELLS):
		FarForest.attach(_scene, FarForest.plan(_world, _heights, Vector2i(i, row), false), draw_range)


func _build_rider() -> void:
	_bike = load(BIKE_SCENE).instantiate()
	_scene.add_child(_bike)
	_rider = BikeRide.new()
	_rider.riding = true
	_rider.x = BIKE_AT.x
	_rider.z = BIKE_AT.y
	_rider.y = _heights.ground_at(BIKE_AT.x, BIKE_AT.y)
	_rider.heading = 0.66
	_rider.crank = 0.9
	_bike.snap(_rider)
	# При первом появлении кадра нога уже на земле, рука на бедре.
	for i in 250:
		_bike.tick(_rider, RIDER_TICK)
	_bike.draw(1.0)


func _animate(delta: float) -> void:
	_rider_delta += delta
	while _rider_delta >= RIDER_TICK:
		_bike.tick(_rider, RIDER_TICK)
		_rider_delta -= RIDER_TICK
	_bike.draw(_rider_delta / RIDER_TICK)
	var phase := _seconds * TAU / 40.0
	var drift := Vector3(sin(phase) * 0.24, sin(phase * 2.0) * 0.045, (cos(phase) - 1.0) * 0.09)
	_camera.look_at_from_position(_origin + drift, _origin + Vector3(0.0, 0.5, -55.0), Vector3.UP)
	_lake_material.set_shader_parameter("ripple_time", _seconds)
	if _seconds >= _next_atmosphere:
		_next_atmosphere = _seconds + ATMOSPHERE_STEP
		_cycle.apply(HOUR, _seconds + 9.0)
		var env := _cycle.env
		env.fog_density *= 0.47
		env.fog_sun_scatter = 0.025
		env.fog_light_color = env.fog_light_color.lerp(Color("a3b6c9"), 0.72)
		VisualStyle.set_haze(env.fog_light_color)
	RenderingServer.global_shader_parameter_set("vegetation_clock", _wind_offset + _seconds)
