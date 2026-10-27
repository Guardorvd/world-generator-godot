class_name VegetationLayer
extends Node3D
var settings: GameSettings = GameContext.scope.settings
## Неподвижные MultiMesh по чанкам, видам и силуэтам, Mesh LOD и точные AABB.
## Трава и подлесок готовятся одним снимком; деревья имеют независимую задачу и очередь передачи.
## Главный поток передаёт не больше одной группы за кадр, прерывая её между MultiMesh по бюджету.
## С 8.4 чанки — Vector2i(cx, cy) в общих координатах: за краем стартовой области их объекты считает
## OuterLand.vegetation тем же кодом, что и на карте (трава и подлесок пока только на карте).

const TILE := GameConfig.TILE
const WATER_MARGIN := 0.3
const LOAD_MARGIN := 64.0 # запас на фоновую подготовку при движении
const DROP_MARGIN := 96.0 # гистерезис: не пересоздаём чанк на границе
const RECHECK := 24.0
const TREE_UPLOAD_US := 2000 # хотя бы один MultiMesh; продолжение группы — в следующих кадрах
const Understory := preload("res://scripts/render/understory_models.gd")
const OUTER_LIGHT := 0.6 # 14.4: освещённость клеток за краем плана (у плана — из StageClimate)
const Floor := preload("res://scripts/render/forest_floor.gd")
const Placement := preload("res://scripts/render/vegetation_placement.gd")
const StreamPolicy := preload("res://scripts/render/vegetation_stream_policy.gd")
const Snapshots := preload("res://scripts/render/vegetation_snapshots.gd")
const UNDERSTORY_MAX := 2048 # на форму мелкого подлеска, только в радиусе травы
## С 9.8+ крупный подлесок (кусты, подрост, молодые деревья, валежник, сухостой, камни) виден дальше травы:
## с 9.4 он гуще и на границе GRASS_R (52 м) вырастал прямо перед игроком. Мелкие растения — как прежде.
const UNDERSTORY_FAR_R := 140.0
const UNDERSTORY_FAR_MAX := 12288 # на форму крупного подлеска: площадь круга в 7 раз больше
## С 9.8+ дальность — настройка игрока (GameSettings.DRAW_LEVELS). Полная густота травы и мелких растений —
## до GRASS_R, крупного подлеска — до UNDERSTORY_FAR_R; дальше они редеют как (радиус / расстояние)²,
## поэтому их число растёт как логарифм дальности, а не как площадь круга (своя простая LOD-ступень).
## 9.9+: растения растворяются у края дальности (fade_far/fade_len в vegetation.gdshaderinc) на этой доле радиуса.
## Деревья гаснут к tree_r: чанк включается, когда его ближайшие деревья уже дальше tree_r, — без рывка.
## Трава и подлесок гаснут на _ahead(радиус) раньше своего радиуса: раскладка обновляется через 8 м пути
## и догоняет игрока не сразу, а её край должен быть уже невидим.
const FADE_SHARE := 0.2
## 9.9+: смена уровней детализации деревьев — [середина полосы, ширина], м; копия LOD1_*/LOD2_* в шейдере.
## Узлы уровней видны с запасом на полосу и полдиагонали чанка (видимость считается от центра чанка).
const LOD_STEPS := [[70.0, 24.0], [160.0, 48.0]]
## Трава и подлесок: преобразование (12), цвет (4) и порог поредения в INSTANCE_CUSTOM.x (4)
const STRIDE := 20
## Запас буферов травы и подлеска на пучки, положенные с запасом _ahead (они ещё невидимы)
const AHEAD_CAP := 1.8
## Пучки травы за GRASS_R крупнее до 35 % (с 9.9+ — в шейдере, по нынешнему расстоянию)
const GRASS_GROW := 0.35
const OBSTACLE_R := GameConfig.GRASS_R + 16.0 # столкновения нужны только рядом с игроком
const SHADER := preload("res://resources/vegetation.gdshader")
const CUTOUT_SHADER := preload("res://resources/vegetation_cutout.gdshader")
const TRUNK_SHADER := preload("res://resources/vegetation_trunk.gdshader")
# [sway, flutter, sway_speed, ao, glow]; см. _wind_mat
const CALM := [0.0, 0.0, 1.0, 1.0, 0.0]
const WIND := {
	Biomes.T_OAK: [0.14, 0.035, 0.8, 0.72, 0.32],
	Biomes.T_BIRCH: [0.22, 0.06, 1.0, 0.8, 0.42],
	Biomes.T_PINE: [0.1, 0.012, 0.65, 0.7, 0.15],
	Biomes.T_SNOWPINE: [0.07, 0.008, 0.6, 0.62, 0.08],
	Biomes.T_PALM: [0.3, 0.08, 0.7, 0.8, 0.35],
	Biomes.T_JUNGLE: [0.1, 0.03, 0.6, 0.65, 0.25],
	Biomes.T_ACACIA: [0.1, 0.03, 0.7, 0.7, 0.25],
	Biomes.T_BUSH: [0.06, 0.035, 1.3, 0.75, 0.3],
	Biomes.T_REED: [0.16, 0.03, 1.4, 0.8, 0.3],
	Biomes.T_DEAD: [0.04, 0.0, 0.8, 0.8, 0.0],
}
const GRASS_WIND := [0.09, 0.02, 1.6, 0.85, 0.3]
const PLANT_WIND := [0.05, 0.02, 1.2, 0.85, 0.25]

var world: WorldData
var heights: Heightfield
var veg := {} # Vector3i(cx, cy, вид) -> буферы, MultiMesh и узлы
var grass: MultiMesh
var _grass_low := Vector3.INF   # 14.4: границы раскладки травы, пока она собирается (_grass_cell)
var _grass_high := -Vector3.INF
var _outer_regions := {}       # 14.4: снимок закреплённых областей для фоновой раскладки травы
var grass_buf: PackedFloat32Array
var last_fill := Vector2.INF
var last_trees := Vector2.INF
var _task := -1
var _tree_task := -1
var stream := StreamPolicy.new()
var snapshots := Snapshots.new()
var _fill_lead := Vector2.ZERO # неизменен, пока задача деталей работает
var _job_lead := Vector2.ZERO
var _detail_epoch := 0
var _detail_seconds := 0.0
var _detail_started_clock := 1.0
var _detail_frames := {}
var _retired: Array = []
var _appearing: Array = [] # временные материалы только на полсекунды проявления
var _queued := {}
var _tree_target := Vector2.INF
var _pending: Array = [] # готовые чанки, ближайшие в конце
var _built: Array = []   # пишет задача, читаем после wait_for_task_completion
var _loaded := {}       # включая пустые чанки
var _epoch := 0         # 13.9: номер закрепления областей; чанк, посчитанный раньше, устарел
var _dirty := {}        # чанк за краем -> _epoch, когда его область закрепили
var _defs := {}         # неизменяемые меши, материалы и локальные AABB
var _grass_n := 0
var _grass_bounds := AABB()
var _grass_margin := 0.0
var _grass_box := AABB()
var understory: Array = [] # те же фоновые буферы и цикл обновления, что у травы
var _forest_surface: Image
var placement: Placement
var _understory_sites: Array = []
var obstacles := PackedFloat32Array() # 7.7: валежник и сухостой рядом с игроком для ForestObstacles (тот же формат)
var obstacles_version := 0            # растёт с каждой новой раскладкой подлеска
var _obstacles_next := PackedFloat32Array() # пишет фоновая задача
var road: RoadObstacles                # 11.6: препятствия на полотне путей
var bumps := PackedFloat32Array()      # их кочки под колёсом для ForestObstacles.set_bumps (та же версия, что obstacles)
var _bumps_next := PackedFloat32Array()
var _fill_at := Vector2.ZERO # центр последней раскладки травы и подлеска, м (фоновая задача)
var draw_level := -1
var grass_at := Vector2.INF # начало принятой капсулы деталей, м
var grass_lead := Vector2.ZERO # упреждающий отрезок принятого снимка (не текущей фоновой задачи)
var fill_capped := 0        # сколько раз раскладка упёрлась в буфер (check.gd)
var _grass_mat: ShaderMaterial
var tree_r := GameConfig.TREE_R      # деревья, м
var grass_r := GameConfig.GRASS_R    # трава и мелкие растения, м
var under_r := UNDERSTORY_FAR_R      # крупный подлесок, м
var load_radius := tree_r + LOAD_MARGIN
var drop_radius := load_radius + DROP_MARGIN


func setup(w: WorldData, h: Heightfield, defs: Dictionary, grass_mesh: Mesh, forest: Image = null) -> void:
	world = w
	heights = h
	placement = Placement.new(w, h)
	road = RoadObstacles.new(w)
	_forest_surface = forest if forest != null else Floor.surface_image(w)
	for kind in defs:
		var def: Dictionary = defs[kind]
		var entry := {leaves = def.get("leaves", []), box = AABB()}
		var first := true
		var wind: Array = WIND.get(kind % ForestModels.MODEL_STRIDE, CALM)
		for part in ["trunk", "crown"]:
			if not def.has(part):
				continue
			entry[part] = def[part]
			for level_mesh: Mesh in ForestModels.lod_meshes(def[part]):
				var box := level_mesh.get_aabb()
				entry.box = box if first else entry.box.merge(box)
				first = false
			var shader := TRUNK_SHADER if part == "trunk" else (CUTOUT_SHADER if def.get("cutout", false) else SHADER)
			if kind % ForestModels.MODEL_STRIDE == Biomes.T_ROCK:
				shader = preload("res://resources/rock.gdshader")
			var mat := _wind_mat(shader, wind, part == "crown")
			if def.has(part + "_texture"):
				mat.set_shader_parameter("albedo_tex", def[part + "_texture"])
			if part == "trunk":
				mat.set_shader_parameter("use_vertex_color", def.get("colored_bark", false))
				mat.set_shader_parameter("albedo_color", def.bark)
			if kind % ForestModels.MODEL_STRIDE == Biomes.T_REED:
				mat.set_shader_parameter("detail_full", 18.0)
				mat.set_shader_parameter("detail_far", 65.0)
				mat.set_shader_parameter("detail_keep", 0.6)
			# 9.9+: у дерева с отдельными уровнями (ForestModels, meta "levels") своя копия материала на уровень.
			var mats: Array[ShaderMaterial] = [mat]
			var levels: Array = ForestModels.lod_meshes(def[part])
			if levels.size() > 1:
				mats.clear()
				for level in levels.size():
					var copy: ShaderMaterial = mat.duplicate()
					copy.set_shader_parameter("lod_level", level)
					mats.append(copy)
			entry[part + "_mats"] = mats
		# Ветер и более широкие дальние объёмы тоже должны попадать в границы отсечения.
		entry.box = entry.box.grow(wind[0] * 1.2 + wind[1] * 2.0)
		# Высота у кроны и ствола общая, иначе листва отрывается от веток.
		for part in ["trunk", "crown"]:
			for mat: ShaderMaterial in entry.get(part + "_mats", []):
				mat.set_shader_parameter("height", maxf(entry.box.end.y, 0.3))
		_defs[kind] = entry
	var grass_mat := _wind_mat(SHADER, GRASS_WIND, true)
	grass_mat.set_shader_parameter("height", grass_mesh.get_aabb().end.y)
	grass_mat.set_shader_parameter("grass_variation", true)
	grass_mat.set_shader_parameter("stream_instances", true)
	_set_radii(settings.draw)
	grass = _multimesh(grass_mesh, grass_mat, _grass_cap(), true, false, true).multimesh
	_grass_margin = _radius(grass_mesh) * 1.5
	_grass_box = grass_mesh.get_aabb().grow(0.1) # запас на индивидуальный изгиб кончиков
	grass_buf = _buffer(_grass_cap(), STRIDE)
	var meshes := Understory.meshes()
	meshes.append_array(Floor.meshes())
	for mesh in meshes:
		var kind := understory.size() - Floor.FIRST
		var shadows := kind in [Floor.LOG, Floor.MOSS_LOG, Floor.SNAG, Floor.STUMP, Floor.BOULDER] or understory.size() in [Understory.SAPLING, Understory.PINE, Understory.YOUNG, Understory.YOUNG_PINE]
		# Мох, подстилка, валежник и камни неподвижны.
		var still := kind >= 0 or understory.size() in [Understory.MOSS, Understory.MUSHROOM]
		var wind := CALM if still else _plant_wind(understory.size())
		var mat := _wind_mat(SHADER, wind, true)
		mat.set_shader_parameter("stream_instances", true)
		mat.set_shader_parameter("height", maxf(mesh.get_aabb().end.y, 0.2))
		var blades := understory.size() in [Understory.GRASS, Understory.HIGH_GRASS]
		mat.set_shader_parameter("grass_variation", blades)
		if not still and not blades:
			var woody := Placement.priority(understory.size()) == 1
			mat.set_shader_parameter("detail_full", 35.0 if woody else 12.0)
			mat.set_shader_parameter("detail_far", 120.0 if woody else 45.0)
			mat.set_shader_parameter("detail_keep", 0.5 if woody else 0.6)
		var far := Placement.priority(understory.size()) < 2
		var cap := _understory_cap(far)
		var node := _multimesh(mesh, mat, cap, true, shadows, true)
		if shadows and kind < 0:
			node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_DOUBLE_SIDED
		# Один MultiMesh покрывает всю раскладку: её центр не является расстоянием до каждого растения.
		# Дальность и растворение задаёт общий шейдер, AABB оставляем для отсечения по фрустуму.
		understory.append({mm = node.multimesh, node = node, buf = _buffer(cap, STRIDE), count = 0, cap = cap, far = far,
			low = Vector3.INF, high = -Vector3.INF, box = mesh.get_aabb(),
			margin = wind[0] * 1.2 + wind[1] * 2.0 + (0.18 if blades else 0.0)})
	_grass_mat = grass_mat
	_apply_fade()


## Базовый невидимый край раскладки. Дальности не «дышат» от скорости:
## скоростной запас готовится отдельной капсулой StreamPolicy, этот край страхует её границу.
static func _ahead(r: float) -> float:
	return clampf(r * 0.15, 12.0, 45.0)


func coverage_lag(point: Vector2) -> float:
	return INF if grass_at == Vector2.INF else StreamPolicy.distance_to_coverage(point, grass_at, grass_lead)


## Полдиагонали чанка растительности, м
func _half_chunk() -> float:
	return world.CS * TILE * 0.7072


## Границы растворения по нынешним дальностям (с 9.9+)
func _apply_fade() -> void:
	for kind: int in _defs:
		for part in ["trunk", "crown"]:
			for mat: ShaderMaterial in _defs[kind].get(part + "_mats", []):
				_fade(mat, tree_r, 0.0)
			if _defs[kind].has(part + "_small_mat"):
				_fade(_defs[kind][part + "_small_mat"], minf(tree_r, 70.0), 0.0)
	for entry: Dictionary in veg.values():
		for node: MultiMeshInstance3D in entry.nodes:
			_fade(node.material_override, minf(tree_r, 70.0) if entry.get("small_rocks", false) else tree_r, 0.0)
	_fade(_grass_mat, grass_r, _ahead(grass_r))
	_grass_mat.set_shader_parameter("thin_full", GameConfig.GRASS_R)
	_grass_mat.set_shader_parameter("thin_grow", GRASS_GROW)
	for kind in understory.size():
		var entry: Dictionary = understory[kind]
		var radius := under_r if entry.far else grass_r
		if kind == Floor.FIRST + Floor.ROOTS:
			# Корни раскладываются только у больших деревьев до GRASS_R (+ запас), без поредения.
			radius = GameConfig.GRASS_R
		_fade(entry.node.material_override, radius, _ahead(radius))
		entry.node.material_override.set_shader_parameter("thin_full", UNDERSTORY_FAR_R if entry.far else GameConfig.GRASS_R)


static func _fade(mat: ShaderMaterial, radius: float, ahead: float) -> void:
	mat.set_shader_parameter("fade_far", radius - ahead)
	mat.set_shader_parameter("fade_len", radius * FADE_SHARE)


## Дальности уровня GameSettings.DRAW_LEVELS[level]
func _set_radii(level: int) -> void:
	draw_level = clampi(level, 0, GameSettings.DRAW_LEVELS.size() - 1)
	var d: Dictionary = GameSettings.DRAW_LEVELS[draw_level]
	tree_r = d.trees
	grass_r = d.grass
	under_r = maxf(d.under, UNDERSTORY_FAR_R)
	load_radius = tree_r + LOAD_MARGIN
	drop_radius = load_radius + DROP_MARGIN


## Во сколько раз больше объектов при дальности r и полной густоте до full (с поредением за ней)
static func _spread(r: float, full: float) -> float:
	return 1.0 + 2.0 * log(maxf(r, full) / full)


## Запас буфера: на минимальной дальности прежний, на большей — с запасом на неровную густоту
static func _cap(base: int, spread: float) -> int:
	return roundi(base * (spread * 1.25 - 0.25) * AHEAD_CAP)


func _grass_cap() -> int:
	return _cap(GameConfig.GRASS_MAX, _spread(grass_r, GameConfig.GRASS_R))


func _understory_cap(far: bool) -> int:
	if far:
		return _cap(UNDERSTORY_FAR_MAX, _spread(under_r, UNDERSTORY_FAR_R))
	return _cap(UNDERSTORY_MAX, _spread(grass_r, GameConfig.GRASS_R))


## Смена дальности на паузе. true — уровень другой: вызывающий затем делает update(..., true).
func set_draw(level: int) -> bool:
	if clampi(level, 0, GameSettings.DRAW_LEVELS.size() - 1) == draw_level:
		return false
	_finish()
	snapshots.reset()
	_set_radii(level)
	grass.visible_instance_count = 0
	grass.instance_count = _grass_cap()
	grass_buf = _buffer(grass.instance_count, STRIDE)
	_grass_n = 0
	for entry: Dictionary in understory:
		entry.cap = _understory_cap(entry.far)
		entry.mm.visible_instance_count = 0
		entry.mm.instance_count = entry.cap
		entry.buf = _buffer(entry.cap, STRIDE)
		entry.count = 0
	for key: Vector3i in veg:
		for node: MultiMeshInstance3D in veg[key].nodes:
			if node.get_meta("level", 2) == 2:
				node.visibility_range_end = (minf(tree_r, 70.0) if veg[key].get("small_rocks", false) else tree_r) + _half_chunk()
	_apply_fade()
	last_fill = Vector2.INF
	return true


## 6.7: ветер и свет по виду. sway/flutter — м, ao — свет неба у основания и в глубине кроны,
## glow — просвечивание листвы. Хвоя жёсткая и густая, берёза лёгкая и дрожит, пальма гибкая.
static func _wind_mat(shader: Shader, wind: Array, leaves: bool) -> ShaderMaterial:
	var mat := ShaderMaterial.new()
	mat.shader = shader
	mat.set_shader_parameter("sway", wind[0])
	mat.set_shader_parameter("flutter", wind[1] if leaves else 0.0)
	mat.set_shader_parameter("sway_speed", wind[2])
	mat.set_shader_parameter("ao_low", wind[3])
	mat.set_shader_parameter("translucency", wind[4] if leaves else 0.0)
	return mat


static func _plant_wind(kind: int) -> Array:
	if kind in [Understory.GRASS, Understory.HIGH_GRASS]:
		return [0.13, 0.018, 1.4, 0.85, 0.25]
	if kind in [Understory.BUSH, Understory.SAPLING, Understory.YOUNG]:
		return [0.08, 0.02, 0.85, 0.8, 0.25]
	if kind in [Understory.PINE, Understory.YOUNG_PINE]:
		return [0.045, 0.006, 0.7, 0.8, 0.1]
	return [0.06, 0.012, 1.15, 0.85, 0.22]


static func _buffer(cap: int, stride: int) -> PackedFloat32Array:
	var b := PackedFloat32Array()
	b.resize(cap * stride)
	return b


static func _radius(mesh: Mesh) -> float:
	var box := mesh.get_aabb()
	return box.position.length() + box.size.length()


func _multimesh(mesh: Mesh, mat: Material, count: int, colors: bool, shadows: bool = true, custom: bool = false) -> MultiMeshInstance3D:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = colors
	mm.use_custom_data = custom
	mm.mesh = mesh
	mm.instance_count = count
	mm.visible_instance_count = 0
	var node := MultiMeshInstance3D.new()
	node.multimesh = mm
	node.material_override = mat
	node.lod_bias = 0.6
	if not shadows:
		node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(node)
	return node


## true — в кадре была передача на GPU; дальний рельеф уступает этот кадр.
## force используется при появлении/переносе: дождаться фона и показать только нужное место.
func update_frame(px: float, pz: float, force: bool, allow_upload: bool) -> bool:
	return update(px, pz, force, -1.0, allow_upload)


func update(px: float, pz: float, force: bool, delta := -1.0, allow_upload := true) -> bool:
	var p := Vector2(px, pz)
	var dt := delta if delta >= 0.0 else get_process_delta_time()
	stream.sample(p, maxf(dt, 0.000001), force)
	RenderingServer.global_shader_parameter_set("veg_center", p)
	RenderingServer.global_shader_parameter_set("vegetation_clock", stream.clock)
	_clean_retired()
	if world.outer != null:
		_outer_regions = world.outer.get_ledger().get("regions", {})
	if force:
		_finish()
		_clear_pending()
		_built.clear()
		snapshots.reset()
		_fill_lead = Vector2.ZERO
		_drop(p)
		last_trees = p
		last_fill = p
		_fill(px, pz, _wanted(p))
		for built: Dictionary in _built:
			_apply_chunk(built)
		_built.clear()
		_apply_grass(true)
		return true
	var uploaded := false
	if _tree_task != -1 and WorkerThreadPool.is_task_completed(_tree_task):
		WorkerThreadPool.wait_for_task_completion(_tree_task)
		_tree_task = -1
		last_trees = Vector2.INF
		for built: Dictionary in _built:
			if _distance(built.chunk, p) <= load_radius + StreamPolicy.MAX_LEAD:
				_pending.append(built)
			else:
				_queued.erase(built.chunk)
		_built = []
	if allow_upload and _task != -1 and WorkerThreadPool.is_task_completed(_task):
		WorkerThreadPool.wait_for_task_completion(_task)
		_task = -1
		stream.record_latency(maxf(_detail_seconds, stream.clock - _detail_started_clock))
		if _detail_epoch == _epoch and p.distance_to(_fill_at) < maxf(grass_r, under_r) + StreamPolicy.MAX_LEAD:
			_apply_grass()
			uploaded = true
		else:
			last_fill = Vector2.INF
			_detail_frames.clear()
	var lead := stream.lead()
	if last_trees == Vector2.INF or p.distance_to(last_trees) >= RECHECK or (p + lead).distance_to(_tree_target) >= RECHECK:
		last_trees = p
		_tree_target = p + lead
		_drop(p)
		var kept: Array = []
		for built: Dictionary in _pending:
			if _distance(built.chunk, p) <= load_radius + lead.length():
				kept.append(built)
			else:
				_discard_partial(built)
				_queued.erase(built.chunk)
		_pending = kept
		_pending.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return _distance(a.chunk, p) > _distance(b.chunk, p))
		if _tree_task == -1:
			var missing := _wanted(p, p + lead)
			if not missing.is_empty():
				for chunk in missing:
					_queued[chunk] = true
				_tree_task = WorkerThreadPool.add_task(_fill_trees.bind(missing, _epoch), true, "Деревья")
	if _task == -1 and (last_fill == Vector2.INF or p.distance_to(last_fill) >= StreamPolicy.REFILL_STEP or lead.distance_to(_job_lead) >= StreamPolicy.REFILL_STEP or snapshots.cleanup_due(stream.clock)):
		last_fill = p
		_job_lead = lead
		_reserve_details(lead)
		_detail_started_clock = stream.clock
		_task = WorkerThreadPool.add_task(_fill_details.bind(px, pz, lead, _epoch, stream.clock), true, "Трава и подлесок")
	if allow_upload and not uploaded and not _pending.is_empty():
		_upload_next()
		uploaded = true
	return uploaded

func _finish() -> void:
	if _task != -1:
		WorkerThreadPool.wait_for_task_completion(_task)
		_task = -1
	if _tree_task != -1:
		WorkerThreadPool.wait_for_task_completion(_tree_task)
		_tree_task = -1


func _exit_tree() -> void:
	_finish()


func _distance(chunk: Vector2i, p: Vector2) -> float:
	var side := world.CS * TILE
	var corner := Vector2(chunk) * side
	return p.distance_to(p.clamp(corner, corner + Vector2.ONE * side))


func _on_map(chunk: Vector2i) -> bool:
	return chunk.x >= 0 and chunk.y >= 0 and chunk.x < world.CW and chunk.y < world.CH


func _wanted(p: Vector2, ahead: Vector2 = p) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	var side := world.CS * TILE
	var x0 := floori((minf(p.x, ahead.x) - load_radius) / side)
	var x1 := floori((maxf(p.x, ahead.x) + load_radius) / side)
	var y0 := floori((minf(p.y, ahead.y) - load_radius) / side)
	var y1 := floori((maxf(p.y, ahead.y) + load_radius) / side)
	if world.outer == null: # без местности за краем — только чанки карты
		x0 = maxi(0, x0)
		y0 = maxi(0, y0)
		x1 = mini(world.CW - 1, x1)
		y1 = mini(world.CH - 1, y1)
	for cy in range(y0, y1 + 1):
		for cx in range(x0, x1 + 1):
			var c := Vector2i(cx, cy)
			if not _loaded.has(c) and not _queued.has(c) and minf(_distance(c, p), _distance(c, ahead)) <= load_radius:
				out.append(c)
	# Фон строит список от дальних к ближним; главный поток берёт с конца.
	out.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		return _distance(a, p) + _distance(a, ahead) > _distance(b, p) + _distance(b, ahead))
	return out


func _drop(p: Vector2) -> void:
	for key: Vector3i in veg.keys():
		if _distance(Vector2i(key.x, key.y), p) > drop_radius + stream.lead().length():
			for node: MultiMeshInstance3D in veg[key].nodes:
				node.visible = false
				node.queue_free()
			veg.erase(key)
	for chunk: Vector2i in _loaded.keys():
		if _distance(chunk, p) > drop_radius + stream.lead().length():
			_loaded.erase(chunk)
			if world.outer != null:
				world.outer.veg.erase(chunk)


func _fill(px: float, pz: float, missing: Array[Vector2i]) -> void:
	_fill_trees(missing, _epoch)
	_fill_details(px, pz, Vector2.ZERO, _epoch, stream.clock, true)


func _fill_trees(missing: Array[Vector2i], epoch: int) -> void:
	_built = []
	for chunk in missing:
		var built := _build_chunk(chunk) if _on_map(chunk) else _build_outer(chunk)
		built.epoch = epoch
		_built.append(built)


func _fill_details(px: float, pz: float, lead: Vector2, epoch: int, clock: float, immediate := false) -> void:
	var started := Time.get_ticks_usec()
	_fill_lead = lead
	_detail_epoch = epoch
	_fill_grass(px, pz)
	_detail_frames = {-1: snapshots.prepare(-1, grass_buf, _grass_n, _grass_bounds, _grass_margin * 2.0, clock, immediate)}
	for kind in understory.size():
		var entry: Dictionary = understory[kind]
		var bounds := AABB(entry.low, entry.high - entry.low) if entry.count > 0 else AABB()
		_detail_frames[kind] = snapshots.prepare(kind, entry.buf, entry.count, bounds, _radius(entry.mm.mesh) + entry.margin, clock, immediate)
	_detail_seconds = (Time.get_ticks_usec() - started) / 1000000.0


func _reserve_details(lead: Vector2) -> void:
	var cap := ceili(_grass_cap() * StreamPolicy.reserve_factor(grass_r, lead))
	if grass_buf.size() < cap * STRIDE:
		grass_buf.resize(cap * STRIDE)
	for entry: Dictionary in understory:
		cap = ceili(_understory_cap(entry.far) * StreamPolicy.reserve_factor(under_r if entry.far else grass_r, lead))
		if entry.cap < cap:
			entry.cap = cap
			entry.buf.resize(cap * STRIDE)


## Чанк за краем стартовой области (в фоновой задаче): объекты OuterLand.vegetation, земля под ними — той же
## триангуляцией, что у меша OuterTerrain (клетки карты у края — из Heightfield.hv, остальные — из куска).
## Карта OuterLand.chunks здесь не читается: она главного потока.
func _build_outer(chunk: Vector2i) -> Dictionary:
	var f := OuterLand.vegetation(world, chunk)
	return _build_outer_snapshot(chunk, f)


func _build_outer_snapshot(chunk: Vector2i, f: Dictionary) -> Dictionary:
	f.plan_water = heights.water_level
	var fx: PackedFloat64Array = f.x
	var fy: PackedFloat64Array = f.y
	var fk: PackedInt32Array = f.k
	var fh: PackedFloat32Array = f.h
	var side: int = f.side
	var hx0: int = f.x0
	var hy0: int = f.y0
	var hv := heights.hv
	var W := world.W
	var H := world.H
	var items := {x = PackedFloat64Array(), y = PackedFloat64Array(), k = PackedInt32Array(), v = PackedInt32Array(),
		s = PackedFloat64Array(), ground = PackedFloat32Array()}
	var corner := PackedFloat32Array([0.0, 0.0, 0.0, 0.0])
	for o in fx.size():
		var kind := fk[o]
		if not _defs.has(kind):
			continue
		var gx := fx[o] - 0.5
		var rock_probe := Vector4.ZERO
		if kind == Biomes.T_ROCK:
			rock_probe = RockModels.seat_snapshot(f, hv, W, H, fx[o] * TILE, fy[o] * TILE, f.s[o] * 1.2)
			if rock_probe.x == INF: continue
		var gz := fy[o] - 0.5
		var i := floori(gx)
		var j := floori(gz)
		for c in 4:
			var ci := i + (c & 1)
			var cj := j + (c >> 1)
			if ci >= 0 and cj >= 0 and ci < W and cj < H:
				corner[c] = hv[cj * W + ci]
			else:
				corner[c] = Heightfield.outer_meters(fh[(cj - hy0) * side + ci - hx0])
		var tx := gx - i
		var tz := gz - j
		var ground: float
		if tx + tz <= 1.0:
			ground = corner[0] + (corner[1] - corner[0]) * tx + (corner[2] - corner[0]) * tz
		else:
			ground = corner[3] + (corner[2] - corner[3]) * (1.0 - tx) + (corner[1] - corner[3]) * (1.0 - tz)
		# за краем вода только морская, её уровень 0
		if kind != Biomes.T_REED and kind != Biomes.T_ROCK and ground < -WATER_MARGIN:
			continue
		items.x.append(fx[o])
		items.y.append(fy[o])
		items.k.append(kind)
		items.v.append(f.v[o])
		items.s.append(f.s[o])
		items.ground.append(ground)
		if not items.has("normals"):
			items.normals = PackedVector3Array()
		var dx: float = corner[1] - corner[0] if tx + tz <= 1.0 else corner[3] - corner[2]
		var dz: float = corner[2] - corner[0] if tx + tz <= 1.0 else corner[3] - corner[1]
		items.normals.append(Vector3(rock_probe.y, rock_probe.z, rock_probe.w) if kind == Biomes.T_ROCK else Vector3(-dx, TILE, -dz).normalized())
	var built := _build_entries(items)
	built.chunk = chunk
	built.outer = items
	return built


func _build_chunk(chunk: Vector2i) -> Dictionary:
	var items := {x = PackedFloat64Array(), y = PackedFloat64Array(), k = PackedInt32Array(), v = PackedInt32Array(),
		s = PackedFloat64Array(), ground = PackedFloat32Array()}
	for o in world.chunks[chunk.y * world.CW + chunk.x]:
		var kind := world.obj_k[o]
		if not _defs.has(kind):
			continue
		var ox := world.obj_x[o]
		var oy := world.obj_y[o]
		var cell := floori(oy) * world.W + floori(ox)
		if world.path_mask[cell] >= 2:
			continue
		var x := ox * TILE
		var z := oy * TILE
		var ground := heights.ground_at(x, z)
		var normal := RockModels.normal_at(heights, x, z) if kind == Biomes.T_ROCK else Vector3.UP
		if kind == Biomes.T_ROCK and not RockModels.has_seat(heights, x, z, world.obj_s[o] * 1.2, normal, ground):
			continue
		if kind != Biomes.T_REED and kind != Biomes.T_ROCK:
			if heights.depth_at(x, z) > WATER_MARGIN:
				continue
		items.x.append(ox)
		items.y.append(oy)
		items.k.append(kind)
		items.v.append(world.obj_v[o])
		items.s.append(world.obj_s[o])
		items.ground.append(ground)
		if not items.has("normals"):
			items.normals = PackedVector3Array()
		items.normals.append(normal)
	var built := _build_entries(items)
	built.chunk = chunk
	return built


## Буферы MultiMesh по силуэтам для объектов items (столбцы x, y в клетках, k, v, s, ground — земля, м)
func _build_entries(items: Dictionary) -> Dictionary:
	var groups := {}
	var xs: PackedFloat64Array = items.x
	var ys: PackedFloat64Array = items.y
	for o in xs.size():
		var kind: int = items.k[o]
		if kind == Biomes.T_ROCK and items.has("normals") and not RockModels.supported(items.normals[o]):
			continue
		var ox := xs[o]
		var oy := ys[o]
		var ground: float = items.ground[o]
		# Выбор силуэта по координатам независим от оттенка и возраста дерева.
		var model := kind
		if _defs.has(kind + ForestModels.MODEL_STRIDE):
			var variants := RockModels.VARIANTS if kind == Biomes.T_ROCK else ForestModels.VARIANTS
			var variant := mini(variants - 1, int(WGRandom.hash2(floori(ox * 113), floori(oy * 109), 65) * variants))
			model += variant * ForestModels.MODEL_STRIDE
		if not groups.has(model):
			groups[model] = {ids = [], ground = [], max_scale = 0.0}
		groups[model].ids.append(o)
		groups[model].ground.append(ground)
		if kind == Biomes.T_ROCK:
			groups[model].max_scale = maxf(groups[model].max_scale, items.s[o])
	var entries: Array = []
	for kind: int in groups:
		var rock := kind % ForestModels.MODEL_STRIDE == Biomes.T_ROCK
		var def: Dictionary = _defs[kind]
		var group: Dictionary = groups[kind]
		var count: int = group.ids.size()
		var entry := {kind = kind, count = count, bounds = AABB()}
		entry.small_rocks = rock and group.max_scale < 0.42
		if def.has("trunk"):
			entry.tbuf = _buffer(count, 12)
		if def.has("crown"):
			entry.cbuf = _buffer(count, 16)
		for n in count:
			var o: int = group.ids[n]
			var ox := xs[o]
			var oy := ys[o]
			var v: int = items.v[o]
			var s: float = items.s[o] * (1.2 if kind % ForestModels.MODEL_STRIDE == Biomes.T_ROCK else 1.0)
			var sy := s * (0.9 + (v % 3) * 0.08)
			var rot := WGRandom.hash2(floori(ox * 97), floori(oy * 89), 7) * TAU
			var pos := Vector3(ox * TILE, group.ground[n] - 0.1, oy * TILE)
			# Точный повёрнутый AABB вместо большой сферы вокруг всего вида.
			var xf := Transform3D(Basis(Vector3.UP, rot).scaled(Vector3(s, sy, s)), pos)
			if rock:
				var normal: Vector3 = items.normals[o] if items.has("normals") else Vector3.UP
				var shape := WGRandom.hash2(floori(ox * 127), floori(oy * 131), 15632)
				# Embed outcrops into the slope; horizontal flat bases looked like floating shelves.
				xf.basis = Basis(Quaternion(Vector3.UP, normal)) * Basis(Vector3.UP, rot)
				xf.basis = xf.basis.scaled_local(Vector3(s, sy * lerpf(0.75, 1.25, shape), s * lerpf(0.8, 1.0, shape)))
				xf.origin.y = group.ground[n] - s * 0.08
			var box: AABB = xf * def.box
			entry.bounds = box if n == 0 else entry.bounds.merge(box)
			if entry.has("tbuf"):
				if rock:
					_put_transform(entry.tbuf, n * 12, xf)
				else:
					_put_xform(entry.tbuf, n * 12, pos.x, pos.y, pos.z, rot, s, sy)
			if entry.has("cbuf"):
				var buf: PackedFloat32Array = entry.cbuf
				if rock:
					_put_transform(buf, n * 16, xf)
				else:
					_put_xform(buf, n * 16, pos.x, pos.y, pos.z, rot, s, sy)
				var col: Color = def.leaves[v % def.leaves.size()]
				buf[n * 16 + 12] = col.r
				buf[n * 16 + 13] = col.g
				buf[n * 16 + 14] = col.b
				buf[n * 16 + 15] = 1.0
		entries.append(entry)
	return {entries = entries}


## 13.9: область rect (клетки) закреплена: её чанки за краем убираются и строятся заново
## по окончательной географии (вода, дороги, поселения).
func refresh(rect: Rect2i) -> void:
	_epoch += 1
	var side := world.CS
	for chunk: Vector2i in _loaded.keys():
		if _on_map(chunk) or not Rect2i(chunk * side, Vector2i.ONE * side).intersects(rect):
			continue
		_dirty[chunk] = _epoch
		_loaded.erase(chunk)
		world.outer.veg.erase(chunk)
		for key: Vector3i in veg.keys():
			if key.x == chunk.x and key.y == chunk.y:
				_retire_nodes(veg[key].nodes)
				veg.erase(key)
	for x in range(floori(float(rect.position.x) / side), floori(float(rect.end.x - 1) / side) + 1):
		for y in range(floori(float(rect.position.y) / side), floori(float(rect.end.y - 1) / side) + 1):
			if not _on_map(Vector2i(x, y)):
				_dirty[Vector2i(x, y)] = _epoch
	last_fill = Vector2.INF
	last_trees = Vector2.INF


func _upload_next() -> void:
	var built: Dictionary = _pending.back()
	if _apply_chunk(built, 1, Time.get_ticks_usec() + TREE_UPLOAD_US):
		_pending.pop_back()
		_queued.erase(built.chunk)


func _clear_pending() -> void:
	for built: Dictionary in _pending:
		_discard_partial(built)
	_pending.clear()
	_queued.clear()


## Частично переданный чанк нельзя оставить помеченным готовым после переноса или отмены.
func _discard_partial(built: Dictionary) -> void:
	var cursor: int = built.get("cursor", 0)
	if built.get("node_cursor", 0) > 0:
		cursor += 1
	if cursor == 0:
		return
	var chunk: Vector2i = built.chunk
	for i in cursor:
		var key := Vector3i(chunk.x, chunk.y, built.entries[i].kind)
		if veg.has(key):
			_retire_nodes(veg[key].nodes)
			veg.erase(key)
	_loaded.erase(chunk)


## limit = 0 — полный синхронный перенос при появлении игрока; иначе ограниченная порция.
func _apply_chunk(built: Dictionary, limit := 0, deadline_usec := 0) -> bool:
	var chunk: Vector2i = built.chunk
	if built.get("epoch", _epoch) < _dirty.get(chunk, -1):
		_discard_partial(built)
		last_trees = Vector2.INF
		return true
	if _loaded.has(chunk) and not built.has("cursor"):
		return true
	if built.has("outer"):
		world.outer.veg[chunk] = built.outer
	var first: int = built.get("cursor", 0)
	var end: int = built.entries.size() if limit == 0 else mini(first + limit, built.entries.size())
	var uploaded := 0
	for i in range(first, end):
		var entry: Dictionary = built.entries[i]
		var kind: int = entry.kind
		var def: Dictionary = _defs[kind]
		var resume: int = built.get("node_cursor", 0)
		if resume == 0:
			entry.nodes = []
			veg[Vector3i(chunk.x, chunk.y, kind)] = entry
		var node_index := 0
		for part in ["trunk", "crown"]:
			if not def.has(part):
				continue
			var mesh: Mesh = def[part]
			var levels: Array = ForestModels.lod_meshes(mesh)
			var small: bool = entry.get("small_rocks", false)
			if small and levels.size() > 1:
				# Мелочь не доживает до дальних LOD: один 100-треугольный меш, без теней.
				levels = [levels[1]]
			for level in levels.size():
				if node_index < resume:
					node_index += 1
					continue
				if deadline_usec > 0 and uploaded > 0 and Time.get_ticks_usec() >= deadline_usec:
					built.cursor = i
					built.node_cursor = node_index
					return false
				var mat := _shared_tree_material(def, part, level, small)
				var node := _multimesh(levels[level], mat, entry.count, part == "crown", not small)
				if limit > 0:
					_reveal_node(node, mat)
				if part == "crown" and not small:
					node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_DOUBLE_SIDED
				var mm := node.multimesh
				mm.buffer = entry.tbuf if part == "trunk" else entry.cbuf
				mm.custom_aabb = entry.bounds
				mm.visible_instance_count = entry.count
				# Выбор LOD и видимость — по локальному чанку, а не всему лесу.
				if levels.size() > 1:
					node.set_meta("level", level)
					if level > 0:
						node.visibility_range_begin = maxf(0.0, LOD_STEPS[level - 1][0] - LOD_STEPS[level - 1][1] * 0.5 - _half_chunk())
				if level < levels.size() - 1:
					node.visibility_range_end = LOD_STEPS[level][0] + LOD_STEPS[level][1] * 0.5 + _half_chunk()
				else:
					node.visibility_range_end = (minf(tree_r, 70.0) if small else tree_r) + _half_chunk()
				node.visibility_range_end_margin = 16.0
				entry[part] = mm
				entry.nodes.append(node)
				node_index += 1
				uploaded += 1
		built.node_cursor = 0
		built.cursor = i + 1
	_loaded[chunk] = true
	built.cursor = end
	return end == built.entries.size()


func _apply_grass(immediate := false) -> void:
	grass_at = _fill_at
	grass_lead = _fill_lead
	obstacles = _obstacles_next
	bumps = _bumps_next
	obstacles_version += 1
	_present_frame(-1, grass, grass_buf, _grass_n, _grass_bounds, _grass_margin * 2.0, immediate)
	for kind in understory.size():
		var entry: Dictionary = understory[kind]
		var bounds := AABB(entry.low, entry.high - entry.low) if entry.count > 0 else AABB()
		_present_frame(kind, entry.mm, entry.buf, entry.count, bounds, _radius(entry.mm.mesh) + entry.margin, immediate)
	_detail_frames.clear()


func _present_frame(group: int, mm: MultiMesh, source: PackedFloat32Array, count: int, bounds: AABB, radius: float, immediate: bool) -> void:
	var frame := snapshots.commit(group, _detail_frames[group], stream.clock) if _detail_frames.has(group) else snapshots.merge(group, source, count, bounds, radius, stream.clock, immediate)
	var data: PackedFloat32Array = frame.buffer
	var capacity := 64
	while capacity < frame.count:
		capacity *= 2
	data.resize(maxi(capacity, mm.instance_count) * STRIDE)
	_upload_instances(mm, data, frame.count)
	mm.custom_aabb = frame.bounds


func _shared_tree_material(def: Dictionary, part: String, level: int, small: bool) -> ShaderMaterial:
	if not small:
		return def[part + "_mats"][level]
	var key := part + "_small_mat"
	if not def.has(key):
		var mat: ShaderMaterial = def[part + "_mats"][0].duplicate()
		mat.set_shader_parameter("lod_level", -1)
		_fade(mat, minf(tree_r, 70.0), 0.0)
		def[key] = mat
	return def[key]


func _reveal_node(node: MultiMeshInstance3D, shared: ShaderMaterial) -> void:
	var mat: ShaderMaterial = shared.duplicate()
	mat.set_shader_parameter("stream_birth", stream.clock)
	node.material_override = mat
	_appearing.append({node = node, shared = shared, until = stream.clock + StreamPolicy.FADE_SECONDS})


func _retire_nodes(nodes: Array) -> void:
	for node: MultiMeshInstance3D in nodes:
		var stamp: float = node.material_override.get_shader_parameter("stream_birth")
		var alpha := Snapshots.opacity(stamp, stream.clock)
		# Зрелый материал общий: уход одного чанка не должен гасить остальные.
		var mat: ShaderMaterial = node.material_override.duplicate()
		mat.set_shader_parameter("stream_birth", -(stream.clock - (1.0 - alpha) * StreamPolicy.FADE_SECONDS))
		node.material_override = mat
		node.set_meta("stream_retiring", true)
	_retired.append({until = stream.clock + StreamPolicy.FADE_SECONDS, nodes = nodes})


func _clean_retired() -> void:
	for i in range(_appearing.size() - 1, -1, -1):
		var entry: Dictionary = _appearing[i]
		if not is_instance_valid(entry.node):
			_appearing.remove_at(i)
			continue
		var node: MultiMeshInstance3D = entry.node
		if node.is_queued_for_deletion() or node.get_meta("stream_retiring", false):
			_appearing.remove_at(i)
		elif stream.clock >= entry.until:
			node.material_override = entry.shared
			_appearing.remove_at(i)
	for i in range(_retired.size() - 1, -1, -1):
		if stream.clock >= _retired[i].until:
			for node: Node in _retired[i].nodes:
				if is_instance_valid(node):
					node.queue_free()
			_retired.remove_at(i)


## CPU сохраняет максимальную ёмкость для фонового заполнения; GPU получает компактную порцию.
## Ступени и гистерезис не дают перераспределять память на каждой травинке.
static func _upload_instances(mm: MultiMesh, buffer: PackedFloat32Array, count: int) -> void:
	var capacity := 64
	while capacity < count:
		capacity *= 2
	capacity = mini(capacity, buffer.size() / STRIDE)
	if mm.instance_count < count or mm.instance_count > maxi(64, count * 4):
		mm.visible_instance_count = 0
		mm.instance_count = capacity
	if count > 0:
		mm.buffer = buffer if mm.instance_count * STRIDE == buffer.size() else buffer.slice(0, mm.instance_count * STRIDE)
	mm.visible_instance_count = count


static func _put_transform(buf: PackedFloat32Array, o: int, xf: Transform3D) -> void:
	for row in 3:
		for column in 3:
			buf[o + row * 4 + column] = xf.basis[column][row]
		buf[o + row * 4 + 3] = xf.origin[row]


static func _put_xform(buf: PackedFloat32Array, o: int, x: float, y: float, z: float, rot: float, s: float, sy: float) -> void:
	var c := cos(rot)
	var sn := sin(rot)
	buf[o] = c * s
	buf[o + 1] = 0.0
	buf[o + 2] = sn * s
	buf[o + 3] = x
	buf[o + 4] = 0.0
	buf[o + 5] = sy
	buf[o + 6] = 0.0
	buf[o + 7] = y
	buf[o + 8] = -sn * s
	buf[o + 9] = 0.0
	buf[o + 10] = c * s
	buf[o + 11] = z


func _fill_grass(px: float, pz: float) -> void:
	var w := world
	var rT := grass_r / TILE
	var rF := maxf(grass_r, under_r) / TILE
	var origin := Vector2(px, pz)
	var tip := origin + _fill_lead
	var scan_low := origin.min(tip) / TILE - Vector2.ONE * rF
	var scan_high := origin.max(tip) / TILE + Vector2.ONE * rF
	var n := 0
	var low := Vector3.INF
	var high := -Vector3.INF
	_grass_low = low
	_grass_high = high
	_fill_at = Vector2(px, pz)
	placement.clear_occupied()
	_obstacles_next = PackedFloat32Array()
	_bumps_next = PackedFloat32Array()
	placement.prepare(px + _fill_lead.x * 0.5, pz + _fill_lead.y * 0.5, rF * TILE + _fill_lead.length() * 0.5 + 12.0)
	_understory_sites.clear()
	# Препятствия на полотне — первыми: обочина, подлесок и трава обходят их, а не наоборот.
	_fill_road(px, pz)
	for entry: Dictionary in understory:
		entry.count = 0
		entry.low = Vector3.INF
		entry.high = -Vector3.INF
	# Без раннего выхода по полному буферу травы: подлесок дальних рядов собирается всегда.
	for j in range(maxi(0, floori(scan_low.y)), mini(w.H - 1, ceili(scan_high.y)) + 1):
		for i in range(maxi(0, floori(scan_low.x)), mini(w.W - 1, ceili(scan_high.x)) + 1):
			var k := j * w.W + i
			var bd: Dictionary = Biomes.LIST[w.biome[k]]
			if not bd.has("grass") or w.river[k] != 0:
				continue
			var d := StreamPolicy.distance_to_coverage(Vector2(i + 0.5, j + 0.5) * TILE, origin, _fill_lead) / TILE
			var d2 := d * d
			if d2 > rF * rF:
				continue
			if d2 > rT * rT:
				# За кругом травы — только крупный подлесок
				_fill_understory(i, j, _forest_surface.get_pixel(i, j), StageClimate.natural_conditions(w, i, j).x, px, pz)
				continue
			var gr: Dictionary = bd.grass
			# Почвенная влага и освещение общие с генератором леса.
			var lush := clampf(1.0 - 0.45 * (w.slope[k] - 0.5), 0.35, 1.0) * (1.25 if w.dist_water[k] < 3.0 else 1.0)
			var light := StageClimate.natural_conditions(w, i, j).x
			lush *= (0.45 + 0.75 * w.moist[k]) * (0.65 + 0.7 * light)
			var surface := _forest_surface.get_pixel(i, j)
			lush *= 1.0 - 0.65 * surface.r
			lush *= _fill_understory(i, j, surface, light, px, pz)
			n = _grass_cell(i, j, gr, lush, surface, d2, n, w.path_mask[k])
	# 14.4: за краем плана — трава и подлесок закреплённых соседних областей. Поля берутся из снимка
	# журнала (_outer_regions, его подменяют целиком в главном потоке), куски OuterLand не читаются
	var regions := _outer_regions
	if not regions.is_empty():
		for j in range(floori(scan_low.y), ceili(scan_high.y) + 1):
			for i in range(floori(scan_low.x), ceili(scan_high.x) + 1):
				if i >= 0 and j >= 0 and i < w.W and j < w.H:
					continue
				var d := StreamPolicy.distance_to_coverage(Vector2(i + 0.5, j + 0.5) * TILE, origin, _fill_lead) / TILE
				var d2 := d * d
				if d2 > rF * rF:
					continue
				var cell := _region_cell(regions, i, j)
				if cell.is_empty() or cell.river or cell.elev <= 0.0 or not _region_inner(regions, i, j):
					continue
				var bd: Dictionary = Biomes.LIST[cell.biome]
				if not bd.has("grass"):
					continue
				var surface := _outer_surface(cell)
				if d2 > rT * rT:
					_fill_understory_cell(i, j, cell.biome, cell.path, cell.slope, surface, OUTER_LIGHT, px, pz)
					continue
				var lush := clampf(1.0 - 0.45 * (cell.slope - 0.5), 0.35, 1.0)
				lush *= (0.45 + 0.75 * cell.moist) * (0.65 + 0.7 * OUTER_LIGHT)
				lush *= 1.0 - 0.65 * surface.r
				lush *= _fill_understory_cell(i, j, cell.biome, cell.path, cell.slope, surface, OUTER_LIGHT, px, pz)
				n = _grass_cell(i, j, bd.grass, lush, surface, d2, n, cell.path, regions)
	low = _grass_low
	high = _grass_high
	_grass_n = n
	_grass_bounds = AABB(low, high - low).grow(_grass_margin) if n > 0 else AABB()
	# 9.9+: внутри одного приоритета — по порогу поредения: место занимает тот, кто виден дальше.
	# Иначе невидимый ещё куст, попавший в раскладку с запасом, вытеснял бы видимый соседний.
	_understory_sites.sort_custom(func(a: Array, b: Array) -> bool: return a[6] < b[6])
	for priority in 3:
		for site: Array in _understory_sites:
			if Placement.priority(site[0]) == priority:
				_put_understory(site[0], site[1], site[2], site[3], site[4], site[5], -1, site[6])
	_fill_tree_roots(px, pz)
	_filter_grass()
	_understory_sites.clear()


## Пучки травы клетки (i, j) в grass_buf начиная с n; возвращает новое n. path — путь клетки
## (без локальной детализации дорог на нём травы нет)
func _grass_cell(i: int, j: int, gr: Dictionary, lush: float, surface: Color, d2: float, n: int, path: int, regions := {}) -> int:
	var buf := grass_buf
	var w := world
	var cnt := floori(gr.dens * (0.5 + WGRandom.hash2(i, j, 5)) * lush)
	var tc: Array = gr.tint
	# Дальше GRASS_R трава редеет, а пучки чуть крупнее (на средней и высокой дальности). С 9.9+ это
	# решает шейдер по нынешнему расстоянию и порогу пучка; здесь — с запасом на _ahead ближе.
	var keep := _keep(sqrt(d2) * TILE, GameConfig.GRASS_R, _ahead(grass_r))
	var inside := i >= 0 and j >= 0 and i < w.W and j < w.H
	for m in cnt:
		if n >= grass_buf.size() / STRIDE:
			fill_capped += 1
			break
		var rank := WGRandom.hash2(i * 5 + m, j, 41)
		if rank > keep:
			continue
		var x := (i + WGRandom.hash2(i * 7 + m, j, 11)) * TILE
		var z := (j + WGRandom.hash2(i, j * 7 + m, 13)) * TILE
		# Плавная, неодинаковая обочина вместо пустых квадратов клеточной маски.
		var verge := 0.0
		if inside and heights.road_refinement != null:
			var weight := heights.road_refinement.weight_at(x, z, w.W)
			if weight > 0.0 and weight > WGRandom.hash2(i + m, j, 29) * 0.8 + 0.08:
				continue
			# 11.4: уцелевшая у полотна трава — выше и суше (некошеная обочина), та же раскладка.
			verge = clampf(weight * 5.0, 0.0, 1.0)
		elif path >= 2:
			continue
		var y: float
		if inside:
			y = heights.ground_at(x, z)
			if heights.depth_at(x, z) > 0.0:
				continue
		else:
			y = RegionStream.snapshot_ground(w, heights, regions, x, z)
		var sc := 0.8 + WGRandom.hash2(i + m, j - m, 17) * 0.7
		var sy := sc * (0.55 + WGRandom.hash2(i + m, j, 31) * 0.9) * (1.0 + verge * 0.35)
		_put_xform(buf, n * STRIDE, x, y - 0.05, z, WGRandom.hash2(i - m, j + m, 19) * 6.28, sc, sy)
		var origin := Vector3(x, y - 0.05, z)
		_grass_low = _grass_low.min(origin)
		_grass_high = _grass_high.max(origin)
		var v := 1.25 + WGRandom.hash2(m, i + j, 23) * 0.3 # 9.4: светлее, основание темнит меш
		buf[n * STRIDE + 12] = tc[0] * v * (1.0 + verge * 0.12)
		buf[n * STRIDE + 13] = tc[1] * v
		buf[n * STRIDE + 14] = tc[2] * v * (1.0 - verge * 0.2)
		buf[n * STRIDE + 15] = 1.0 - surface.r # открытость неба: свет и ветер под пологом
		buf[n * STRIDE + 16] = rank
		buf[n * STRIDE + 17] = WGRandom.hash2(i * 13 + m, j, 73)
		buf[n * STRIDE + 18] = WGRandom.hash2(i, j * 11 + m, 79)
		n += 1
	return n


## 14.4: клетка закреплённой области из снимка журнала: биом, путь, уклон, вода, высота; {} — нет
static func _region_cell(regions: Dictionary, i: int, j: int) -> Dictionary:
	var size := WorldData.REGION_SIZE
	var r: Variant = regions.get(Vector2i(floori(float(i) / size), floori(float(j) / size)))
	if r == null or not r.has("fields"):
		return {}
	var f: Dictionary = r.fields
	var rect: Rect2i = r.rect
	var q := (j - rect.position.y) * rect.size.x + i - rect.position.x
	# влажности в полях области нет: у воды трава гуще, как у плана (dist_water)
	return {biome = f.biome[q], path = f.path[q], slope = f.slope[q], river = f.river[q] != 0 or f.lake[q] != 0,
		elev = f.h[q], moist = 0.45 + 0.4 * exp(-f.dw[q] / 3.0)}


## Вокруг клетки (3 × 3) только план и закреплённые области: высоты подлеска (Heightfield) здесь
## не трогают куски OuterLand, которые главный поток в это время меняет
func _region_inner(regions: Dictionary, i: int, j: int) -> bool:
	for dj in range(-1, 2):
		for di in range(-1, 2):
			var a := i + di
			var b := j + dj
			if a >= 0 and b >= 0 and a < world.W and b < world.H:
				continue
			var r: Variant = regions.get(Vector2i(floori(float(a) / WorldData.REGION_SIZE), floori(float(b) / WorldData.REGION_SIZE)))
			if r == null or not r.has("fields"):
				return false
	return true


## 14.4: полог, хвоя, влага и каменистость клетки за краем плана — по биому (у плана это картинка леса)
static func _outer_surface(cell: Dictionary) -> Color:
	match cell.biome:
		Biomes.FOREST, Biomes.JUNGLE:
			return Color(0.6, 0.25, cell.moist, 0.15)
		Biomes.TAIGA:
			return Color(0.55, 0.85, cell.moist, 0.2)
		Biomes.SWAMP:
			return Color(0.35, 0.3, 0.9, 0.05)
	return Color(0.0, 0.0, cell.moist, 0.2)


## Доля травы или подлеска, что остаётся на расстоянии d (м) при полной густоте до full,
## с запасом: игрок до следующей раскладки может подъехать на ahead ближе (шейдер считает без запаса).
static func _keep(d: float, full: float, ahead: float) -> float:
	var near := maxf(d - ahead, 1.0)
	return minf(1.0, full * full / (near * near))


## Возвращает множитель низкой травы по характеру леса (вне леса 1).
func _fill_understory(i: int, j: int, surface: Color, sunlight: float, px: float, pz: float) -> float:
	var k := j * world.W + i
	return _fill_understory_cell(i, j, world.biome[k], world.path_mask[k], world.slope[k], surface, sunlight, px, pz)


## Подлесок клетки по её биому, пути и уклону (на плане — из WorldData, за краем — OuterLand.info)
func _fill_understory_cell(i: int, j: int, bi: int, path: int, slope: float, surface: Color, sunlight: float, px: float, pz: float) -> float:
	var canopy := surface.r
	if bi not in [Biomes.FOREST, Biomes.TAIGA, Biomes.JUNGLE, Biomes.SWAMP] and canopy < 0.15:
		return 1.0
	var moisture := surface.b
	# 8.2: характер леса от полога, хвои, влаги, солнца и возраста участка
	var ch := Understory.character(canopy, surface.g, moisture, sunlight, StageVegetation.age_at(world, i, j))
	var grass_mul := Understory.mix(Understory.LOW_GRASS, ch)
	if path > 0 or slope > 0.9:
		return grass_mul
	var light := sunlight * (1.0 - canopy * 0.85)
	var weights := Understory.weights(bi, moisture, light, canopy, ch)
	var floor_weights := Floor.weights(canopy, surface.g, moisture, light, surface.a)
	var deadwood := Understory.mix(Understory.DEADWOOD, ch)
	for f in [Floor.LOG, Floor.MOSS_LOG, Floor.SNAG, Floor.STUMP]:
		floor_weights[f] *= deadwood
	weights.append_array(floor_weights)
	var total := 0.0
	for weight in weights:
		total += weight
	# Пятна по 12 м и случайные пропуски; соседние клетки связаны без нового шума.
	var seed := world.seed_num ^ 6601
	var patch := WGRandom.hash2(floori(i / 3.0), floori(j / 3.0), seed)
	var density := (0.3 + 0.75 * patch) * (0.5 + 0.5 * moisture) * Understory.mix(Understory.DENSITY, ch) # 9.4: гуще
	# В чаще мест больше: кусты и подрост стоят стеной.
	for m in 5 + roundi(3.0 * ch[Understory.THICKET]):
		if WGRandom.hash2(i * 8 + m, j, seed + 1) > density:
			continue
		var pick := WGRandom.hash2(i * 8 + m, j, seed + 2) * total
		var kind := 0
		while kind < weights.size() - 1 and pick >= weights[kind]:
			pick -= weights[kind]
			kind += 1
		var x := (i + 0.1 + 0.8 * WGRandom.hash2(i * 8 + m, j, seed + 3)) * TILE
		var z := (j + 0.1 + 0.8 * WGRandom.hash2(i * 8 + m, j, seed + 4)) * TILE
		var far: bool = understory[kind].far
		var d := StreamPolicy.distance_to_coverage(Vector2(x, z), Vector2(px, pz), _fill_lead)
		if d > (under_r if far else grass_r):
			continue
		var full := UNDERSTORY_FAR_R if far else GameConfig.GRASS_R
		var rank := WGRandom.hash2(i * 8 + m, j, seed + 8)
		if rank > _keep(d, full, _ahead(under_r if far else grass_r)):
			continue
		var scale := 0.7 + WGRandom.hash2(i * 8 + m, j, seed + 5) * 0.6
		var rot := WGRandom.hash2(i * 8 + m, j, seed + 6) * TAU
		var tint := 0.85 + WGRandom.hash2(i * 8 + m, j, seed + 7) * 0.3
		_understory_sites.append([kind, x, z, rot, scale, tint, rank])
	return grass_mul


## 11.6: на полотне путей — препятствия RoadObstacles в радиусе подлеска, тем же размещением, что подстилка
func _fill_road(px: float, pz: float) -> void:
	if road == null:
		return
	var pairs := road.around(px + _fill_lead.x * 0.5, pz + _fill_lead.y * 0.5, maxf(grass_r, under_r) + _fill_lead.length() * 0.5)
	for p in range(0, pairs.size(), 2):
		var o := road.pick(heights, _forest_surface, pairs[p], pairs[p + 1])
		if o.is_empty():
			continue
		var kind: int = Floor.FIRST + [Floor.BRANCH, Floor.STONES, Floor.MOSS_LOG if o.moss else Floor.LOG, Floor.BOULDER][o.kind]
		if StreamPolicy.distance_to_coverage(Vector2(o.x, o.z), Vector2(px, pz), _fill_lead) > (under_r if understory[kind].far else grass_r):
			continue
		_put_understory(kind, o.x, o.z, o.rot, o.scale, 1.0, -1, 0.0, true)


## on_road — препятствие на полотне (RoadObstacles): дорога ему не помеха, свои проверки места оно прошло
func _put_understory(kind: int, x: float, z: float, rot: float, scale: float, tint: float = 1.0, owner: int = -1, rank: float = 0.0, on_road := false) -> void:
	var entry: Dictionary = understory[kind]
	if entry.count >= entry.cap:
		fill_capped += 1
		return
	var floor_kind := kind - Floor.FIRST
	var local_box: AABB = entry.box
	var reach := local_box.position.abs().max(local_box.end.abs()) * scale
	var radius := Vector2(reach.x, reach.z).length()
	if not on_road and not placement.ground_clear(x, z, radius):
		return
	if not placement.objects_clear(x, z, rot, scale, local_box, radius, owner):
		return
	var pos := Vector3(x, heights.ground_at(x, z) - 0.015, z)
	var offset: int = entry.count * STRIDE
	var xf := Transform3D(Basis(Vector3.UP, rot).scaled(Vector3.ONE * scale), pos)
	if kind == Understory.MOSS or (floor_kind >= 0 and floor_kind not in [Floor.SNAG, Floor.STUMP, Floor.BOULDER]):
		# Почвенные детали и валежник следуют склону; сухостой, пни и валуны остаются вертикальными.
		var dx := heights.ground_at(x + 0.3, z) - heights.ground_at(x - 0.3, z)
		var dz := heights.ground_at(x, z + 0.3) - heights.ground_at(x, z - 0.3)
		xf.basis.x.y = (dx * xf.basis.x.x + dz * xf.basis.x.z) / 0.6
		xf.basis.z.y = (dx * xf.basis.z.x + dz * xf.basis.z.z) / 0.6
		if not placement.terrain_fits(xf, local_box):
			return
	var box: AABB = xf * local_box
	if not placement.details_clear(box):
		return
	_put_xform(entry.buf, offset, x, pos.y, z, rot, scale, scale)
	entry.buf[offset + 4] = xf.basis.x.y
	entry.buf[offset + 6] = xf.basis.z.y
	for c in 3:
		entry.buf[offset + 12 + c] = tint
	entry.buf[offset + 15] = 1.0 - _forest_surface.get_pixel(floori(x / TILE), floori(z / TILE)).r
	entry.buf[offset + 16] = rank
	entry.buf[offset + 17] = WGRandom.hash2(floori(x * 13), floori(z * 11), 73)
	entry.buf[offset + 18] = WGRandom.hash2(floori(x * 7), floori(z * 17), 79)
	var render_box := box.grow(entry.margin * scale)
	entry.low = entry.low.min(render_box.position)
	entry.high = entry.high.max(render_box.end)
	entry.count += 1
	if Placement.priority(kind) < 2:
		placement.occupy(box.grow(0.03))
	if StreamPolicy.distance_to_coverage(Vector2(x, z), _fill_at, _fill_lead) > OBSTACLE_R:
		return
	if floor_kind == Floor.LOG or floor_kind == Floor.MOSS_LOG:
		# бревно — капсула вдоль ствола (меш: от -2,2 до 2,1 м по X, толщина 0,23 м), верх ~0,45 м
		var a := xf * Vector3(-2.2, 0.0, 0.0)
		var b := xf * Vector3(2.1, 0.0, 0.07)
		_obstacles_next.append_array([a.x, a.z, b.x, b.z, 0.2 * scale, pos.y, pos.y + 0.42 * scale])
	elif floor_kind == Floor.SNAG:
		_obstacles_next.append_array([x, z, x, z, 0.16 * scale, pos.y, INF])
	elif floor_kind == Floor.STUMP: # невысокий, перепрыгивается
		_obstacles_next.append_array([x, z, x, z, 0.3 * scale, pos.y, pos.y + 0.45 * scale])
	elif floor_kind == Floor.BOULDER:
		_obstacles_next.append_array([x, z, x, z, 0.75 * scale, pos.y, pos.y + 0.95 * scale])
	elif on_road and (floor_kind == Floor.BRANCH or floor_kind == Floor.STONES): # не держат, а встряхивают колесо
		_bumps_next.append_array(RoadObstacles.bump(RoadObstacles.BRANCH if floor_kind == Floor.BRANCH else RoadObstacles.STONES, xf, scale))


func _filter_grass() -> void:
	var write := 0
	for n in _grass_n:
		var offset := n * STRIDE
		var pos := Vector3(grass_buf[offset + 3], grass_buf[offset + 7], grass_buf[offset + 11])
		var xf := Transform3D(Basis(Vector3(grass_buf[offset], 0, grass_buf[offset + 8]), Vector3(0, grass_buf[offset + 5], 0), Vector3(grass_buf[offset + 2], 0, grass_buf[offset + 10])), pos)
		var box: AABB = xf * _grass_box
		if not placement.details_clear(box):
			continue
		var local_box := AABB(box.position - pos, box.size)
		var reach := local_box.position.abs().max(local_box.end.abs())
		if not placement.objects_clear(pos.x, pos.z, 0.0, 1.0, local_box, Vector2(reach.x, reach.z).length()):
			continue
		if write != n:
			for c in STRIDE:
				grass_buf[write * STRIDE + c] = grass_buf[offset + c]
		write += 1
	_grass_n = write


func _fill_tree_roots(px: float, pz: float) -> void:
	var reach := GameConfig.GRASS_R + _ahead(grass_r) # корни гаснут к GRASS_R от игрока, а не от раскладки
	var r := reach / TILE
	var tip := Vector2(px, pz) + _fill_lead
	for cy in range(maxi(0, floori((minf(pz, tip.y) / TILE - r) / world.CS)), mini(world.CH, ceili((maxf(pz, tip.y) / TILE + r) / world.CS))):
		for cx in range(maxi(0, floori((minf(px, tip.x) / TILE - r) / world.CS)), mini(world.CW, ceili((maxf(px, tip.x) / TILE + r) / world.CS))):
			for o in world.chunks[cy * world.CW + cx]:
				if not Biomes.is_tree(world.obj_k[o]) or world.obj_s[o] < 0.85:
					continue
				var x := world.obj_x[o] * TILE
				var z := world.obj_y[o] * TILE
				if StreamPolicy.distance_to_coverage(Vector2(x, z), Vector2(px, pz), _fill_lead) > reach:
					continue
				var k := floori(z / TILE) * world.W + floori(x / TILE)
				if world.slope[k] > 0.9:
					continue
				var rot := WGRandom.hash2(floori(x * 97.0), floori(z * 89.0), 6677) * TAU
				_put_understory(Floor.FIRST + Floor.ROOTS, x, z, rot, clampf(world.obj_s[o] * 0.7, 0.6, 1.3), 1.0, o)
