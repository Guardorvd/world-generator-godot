class_name VegetationLayer
extends Node3D
var settings: GameSettings = GameContext.scope.settings
## Неподвижные MultiMesh по чанкам, видам и силуэтам, Mesh LOD и точные AABB.
## Трава и подлесок готовятся одним снимком; деревья имеют независимую задачу и очередь передачи.
## Главный поток передаёт не больше одной группы за кадр, прерывая её между MultiMesh по бюджету.
## С 8.4 чанки — Vector2i(cx, cy) в общих координатах: за краем стартовой области их объекты считает
## OuterLand.vegetation тем же кодом, что и на карте (трава и подлесок пока только на карте).

const TILE := GameConfig.TILE
const WATER_MARGIN := GameConfig.WATER_MARGIN
const LOAD_MARGIN := 64.0 # запас на фоновую подготовку при движении
const DROP_MARGIN := 96.0 # гистерезис: не пересоздаём чанк на границе
const RECHECK := 24.0
const TREE_UPLOAD_US := 2000 # хотя бы один MultiMesh; продолжение группы — в следующих кадрах
const DETAIL_UPLOAD_US := 1500 # трава и формы подлеска готового снимка: хотя бы одна группа за кадр
const FREE_US := 800 # удаление ушедших узлов за кадр: ряд чанков на скорости — тысячи MultiMesh
const TREE_NODES_PER_SLICE := 4
const FAR_TRUNKLESS := [Biomes.T_OAK, Biomes.T_BIRCH, Biomes.T_PINE, Biomes.T_SNOWPINE] # виды без ствола на дальнем уровне
const FAR_FORM_R := 24.0 # м: дальше от центра раскладки мох, папоротник, корни и камни рисуются упрощённой формой
## 15.0: на самом дальнем уровне все силуэты вида одного чанка рисуются одним узлом с мешом первого силуэта
## (высота выровнена по ряду Y): у дерева за 160 м силуэт различим меньше, чем стоит лишний draw call.
## Цвет и поворот у экземпляров свои. Ключ такой записи в veg - вид + FAR_KEY.
const FAR_KEY := 1 << 20
const FAR_LOD_NO_SHADOW := 2 # с этого уровня LOD деревья не отбрасывают тень (дальше теней солнца)
const TREE_POOL_LIMIT := 64 # Empty MultiMeshes only; no retired instance buffers/material copies.
const Understory := preload("res://scripts/render/understory_models.gd")
## Модель первого скального выхода (RockModels.OUTCROP_V); без неё в каталоге выходы не рисуются.
const OUTCROP_MODEL := Biomes.T_ROCK + RockModels.VARIANTS * ForestModels.MODEL_STRIDE
## Скалы без своей травы: низкая сухая трава только в сырых ложбинах (_rock_shelter).
const ROCK_GRASS := {dens = 2.4, tint = [0.5, 0.56, 0.31]}
## Cumulative weights: no zero-weight forms or per-cell array allocations.
const ROCK_HOLLOW := [[Understory.MOSS, 1.0], [Understory.HERB, 1.45], [Understory.GRASS, 1.95],
	[Understory.BUSH, 2.2], [Understory.FLOWERS, 2.32], [Understory.FORBS, 2.5], [Understory.MEADOW, 2.62],
	[Floor.FIRST + Floor.STONES, 3.15]]
## 16.0: только для сравнения «было» в изолированной сцене: открытые места без сообществ, как до 16.0
static var legacy_open := false
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
## 16.0: куртины открытых мест полной густоты до 45 м, дальше редеют как (45 / d)² и растут
## (OPEN_GROW): массив вдали — меньше, но крупнее куртин. Один MultiMesh на форму рисует всю раскладку
## (и за спиной), поэтому число экземпляров важнее треугольников одного.
const OPEN_FULL_R := 45.0
const OPEN_GROW := 1.0
const OPEN_MAX_R := 200.0 # дальше куртины растворяются (за 160–200 м куртина — пара пикселей)
## 16.0: кусты и подрост переходят на дальнюю форму позже мелочи (крупнее, заметнее)
const WOODY_FAR_FORM := 1.6
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
var _appearing: Array = [] # узлы до конца проявления
var _trash: Array[Node] = [] # скрытые узлы, удаляются по FREE_US за кадр
var _tree_pool: Array[MultiMeshInstance3D] = []
var frame_budget: RefCounted
var node_stats := {created = 0, reused = 0, pooled = 0}
var phase_stats := {names = ["cleanup", "tree_poll", "details", "tree_queue", "detail_schedule", "tree_upload"],
	last_us = [0, 0, 0, 0, 0, 0], max_us = [0, 0, 0, 0, 0, 0]}

func _record_phase(index: int, began: int) -> int:
	var now := Time.get_ticks_usec()
	var elapsed := now - began
	phase_stats.last_us[index] = elapsed
	phase_stats.max_us[index] = maxi(phase_stats.max_us[index], elapsed)
	return now
var _present: Array[int] = [] # группы готового снимка (-1 — трава), ещё не переданные на GPU
var _last_contact_group := -1
var _queued := {}
var _tree_target := Vector2.INF
var _pending: Array = [] # готовые чанки, ближайшие в конце
var _built: Array = []   # пишет задача, читаем после wait_for_task_completion
var _loaded := {}       # включая пустые чанки
var _refresh_details := false
var _epoch := 0         # 13.9: номер закрепления областей; чанк, посчитанный раньше, устарел
var _dirty := {}        # чанк за краем -> _epoch, когда его область закрепили
var _defs := {}         # неизменяемые меши, материалы и локальные AABB
var _grass_n := 0
var _grass_bounds := AABB()
var _grass_margin := 0.0
var _grass_box := AABB()
var _far_of := {} # номер формы подлеска -> номер её упрощённой формы (отдельная группа)
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
## 16.0: качество растительности (GameSettings.FLORA_LEVELS): та же раскладка, меньше мелких растений.
## Валежник, сухостой, пни, валуны и препятствия на тропах от него не зависят (столкновения и физика).
var flora_level := -1
var flora: Dictionary = GameSettings.FLORA_LEVELS[GameSettings.DEFAULT_FLORA]
var far_form_r := FAR_FORM_R
## 16.0: сообщества открытых клеток плана, по OPEN_CACHE байт (0 в первом — не посчитано). Пишет
## и читает только раскладка деталей (одна задача за раз); мир не меняется — кэш не сбрасывается.
const OPEN_CACHE := 13
## 16.1: стелющийся можжевельник — тот же меш куста, распластанный (ниже и шире) и сизо-тёмный
const JUNIPER_HUE := Color(0.6, 0.84, 0.95)
const JUNIPER_SQUASH := 0.42
const JUNIPER_SPREAD := 1.45
var _open_cache := PackedByteArray()
var _open_valid := PackedByteArray() # 16.0: по 2 байта на клетку плана — места открытых клеток проверены / свободны
var fill_stats := {} # время частей последней раскладки деталей, мс (замеры)
enum RoadPlacement { RANGE, CAPACITY, OBJECT, TERRAIN, DETAIL, VISUAL, CONTACT }
var measure_road_clutter := false
var road_clutter_stats := {} # only populated by the road corridor probe
var _fill_started := 0
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
	_set_flora(settings.flora)
	grass = _multimesh(grass_mesh, grass_mat, _grass_cap(), true, false, true).multimesh
	_grass_margin = _radius(grass_mesh) * 1.5
	_grass_box = grass_mesh.get_aabb().grow(0.1) # запас на индивидуальный изгиб кончиков
	grass_buf = _buffer(_grass_cap(), STRIDE)
	var meshes := Understory.meshes()
	meshes.append_array(Floor.meshes())
	var specs: Array = []
	for form in meshes.size():
		specs.append([meshes[form], form])
	var far_forms: Dictionary = preload("res://scripts/render/asset_catalog.gd").get_catalog().far_forms
	for form: int in far_forms:
		_far_of[form] = specs.size()
		specs.append([far_forms[form], form])
	for spec: Array in specs:
		var mesh: Mesh = spec[0]
		var base: int = spec[1]
		var kind := base - Floor.FIRST
		var has_contacts := kind in [Floor.LOG, Floor.MOSS_LOG, Floor.SNAG, Floor.STUMP, Floor.BOULDER, Floor.BRANCH, Floor.STONES, Floor.ROOT_SPAN]
		if has_contacts:
			_last_contact_group = understory.size()
		var shadows := kind in [Floor.LOG, Floor.MOSS_LOG, Floor.SNAG, Floor.STUMP, Floor.BOULDER] or base in [Understory.SAPLING, Understory.PINE, Understory.YOUNG, Understory.YOUNG_PINE]
		# Мох, подстилка, валежник и камни неподвижны.
		var still := kind >= 0 or base in [Understory.MOSS, Understory.MUSHROOM]
		var wind := CALM if still else _plant_wind(base)
		var mat := _wind_mat(SHADER, wind, true)
		mat.set_shader_parameter("stream_instances", true)
		mat.set_shader_parameter("height", maxf(mesh.get_aabb().end.y, 0.2))
		var blades := base in [Understory.GRASS, Understory.HIGH_GRASS, Understory.MEADOW, Understory.SEDGE, Understory.STIPA]
		mat.set_shader_parameter("grass_variation", blades)
		var detail := []
		if not still and not blades:
			var woody := Placement.priority(base) == 1
			detail = [35.0, 120.0] if woody else [12.0, 45.0]
			mat.set_shader_parameter("detail_keep", 0.5 if woody else 0.6)
		# 16.0: куртины открытых мест видны дальше травы, как кусты; места не занимают (мягкие)
		var open_form := base in Understory.OPEN_FORMS
		var far := Placement.priority(base) < 2 or open_form
		# Ближняя форма с упрощённой дальней живёт только в FAR_FORM_R (кусты — в 1,6 раза дальше): ей хватает буфера мелочи
		var cap := _understory_cap(far and not (far_forms.has(base) and spec[0] != far_forms[base]))
		var node := _multimesh(mesh, mat, cap, true, shadows, true)
		if shadows and kind < 0:
			node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_DOUBLE_SIDED
		# Один MultiMesh покрывает всю раскладку: её центр не является расстоянием до каждого растения.
		# Дальность и растворение задаёт общий шейдер, AABB оставляем для отсечения по фрустуму.
		understory.append({mm = node.multimesh, node = node, buf = _buffer(cap, STRIDE), count = 0, cap = cap, far = far,
			low = Vector3.INF, high = -Vector3.INF, box = meshes[base].get_aabb(), base = base, detail = detail,
			shadows = shadows, near_cap = cap != _understory_cap(far), has_contacts = has_contacts,
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
		var radius := _reach_r(entry.base, entry.far)
		if entry.base == Floor.FIRST + Floor.ROOTS:
			# Корни раскладываются только у больших деревьев до GRASS_R (+ запас), без поредения.
			radius = GameConfig.GRASS_R
		var mat: ShaderMaterial = entry.node.material_override
		_fade(mat, radius, _ahead(radius))
		mat.set_shader_parameter("thin_full", _full_r(entry.base, entry.far))
		# 16.0: редеющие вдали куртины крупнее — массив сохраняет объём (как пучки травы за GRASS_R)
		mat.set_shader_parameter("thin_grow", OPEN_GROW if entry.base in Understory.OPEN_FORMS else 0.0)
		if not entry.detail.is_empty():
			mat.set_shader_parameter("detail_full", entry.detail[0] * flora.detail)
			mat.set_shader_parameter("detail_far", entry.detail[1] * flora.detail)
		if entry.shadows:
			entry.node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF if not flora.shadows and entry.base < Floor.FIRST \
				else (GeometryInstance3D.SHADOW_CASTING_SETTING_DOUBLE_SIDED if entry.base < Floor.FIRST else GeometryInstance3D.SHADOW_CASTING_SETTING_ON)


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


## 16.0: качество растительности GameSettings.FLORA_LEVELS[level]: доля мелких растений, их размер,
## граница упрощённых форм, поредение листьев и тени подроста. Раскладка и её места те же.
func _set_flora(level: int) -> void:
	flora_level = clampi(level, 0, GameSettings.FLORA_LEVELS.size() - 1)
	flora = GameSettings.FLORA_LEVELS[flora_level]
	far_form_r = flora.far_form


## Смена качества растительности на паузе; true — другое, вызывающий затем делает update(..., true).
func set_flora(level: int) -> bool:
	if clampi(level, 0, GameSettings.FLORA_LEVELS.size() - 1) == flora_level:
		return false
	_finish()
	snapshots.reset()
	_set_flora(level)
	_open_valid.fill(0) # размер куртин другой — места проверяются заново
	_apply_fade()
	last_fill = Vector2.INF
	return true


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
		entry.cap = _understory_cap(entry.far and not entry.near_cap)
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
	if kind in [Understory.GRASS, Understory.HIGH_GRASS, Understory.MEADOW]:
		return [0.13, 0.018, 1.4, 0.85, 0.25]
	if kind == Understory.SEDGE:
		return [0.07, 0.012, 1.2, 0.8, 0.2]
	if kind == Understory.STIPA:
		# 16.1: ковыль — длинные гибкие ости: сильный наклон и просвечивание против солнца (серебристая волна)
		return [0.22, 0.03, 1.5, 0.88, 0.4]
	if kind == Understory.FIREWEED:
		return [0.1, 0.02, 1.0, 0.85, 0.3]
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


func _multimesh(mesh: Mesh, mat: Material, count: int, colors: bool, shadows: bool = true, custom: bool = false, tree := false) -> MultiMeshInstance3D:
	var node: MultiMeshInstance3D
	if tree and not _tree_pool.is_empty():
		node = _tree_pool.pop_back()
		node_stats.reused += 1
	else:
		node = MultiMeshInstance3D.new()
		node.multimesh = MultiMesh.new()
		if tree: node_stats.created += 1
	var mm := node.multimesh
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = colors
	mm.use_custom_data = custom
	mm.mesh = mesh
	mm.instance_count = count
	mm.visible_instance_count = 0
	node.material_override = mat
	node.lod_bias = 0.6
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if shadows else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	node.visibility_range_begin = 0.0
	node.visibility_range_end = 0.0
	node.visibility_range_end_margin = 0.0
	if node.has_meta("stream_retiring"): node.remove_meta("stream_retiring")
	if node.has_meta("level"): node.remove_meta("level")
	if tree: node.set_meta("stream_tree", true)
	if node.get_parent() == null: add_child(node)
	node.visible = true
	return node


## true — в кадре была передача на GPU; дальний рельеф уступает этот кадр.
## force используется при появлении/переносе: дождаться фона и показать только нужное место.
func update_frame(px: float, pz: float, force: bool, allow_upload: bool) -> bool:
	return update(px, pz, force, -1.0, allow_upload)


func update(px: float, pz: float, force: bool, delta := -1.0, allow_upload := true) -> bool:
	var phase_started := Time.get_ticks_usec()
	phase_stats.last_us.fill(0)
	var p := Vector2(px, pz)
	var dt := delta if delta >= 0.0 else get_process_delta_time()
	stream.sample(p, maxf(dt, 0.000001), force)
	RenderingServer.global_shader_parameter_set("veg_center", p)
	RenderingServer.global_shader_parameter_set("vegetation_clock", stream.clock)
	_clean_retired()
	if force or frame_budget == null or frame_budget.allows_work():
		var free_us := FREE_US if frame_budget == null else maxi(1, frame_budget.deadline(FREE_US) - Time.get_ticks_usec())
		_free_trash(0 if force else free_us)
	if world.outer != null:
		_outer_regions = world.outer.get_ledger().get("regions", {})
	phase_started = _record_phase(0, phase_started)
	if force:
		_finish()
		_present.clear()
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
	if (frame_budget == null or frame_budget.allows_work()) and _tree_task != -1 and WorkerThreadPool.is_task_completed(_tree_task):
		WorkerThreadPool.wait_for_task_completion(_tree_task)
		_tree_task = -1
		last_trees = Vector2.INF
		for built: Dictionary in _built:
			if _distance(built.chunk, p) <= load_radius + StreamPolicy.MAX_LEAD:
				_pending.append(built)
			else:
				_queued.erase(built.chunk)
		_built = []
	phase_started = _record_phase(1, phase_started)
	if allow_upload and (frame_budget == null or frame_budget.allows_work()) and _task != -1 and WorkerThreadPool.is_task_completed(_task):
		WorkerThreadPool.wait_for_task_completion(_task)
		_task = -1
		stream.record_latency(maxf(_detail_seconds, stream.clock - _detail_started_clock))
		if _detail_epoch == _epoch and p.distance_to(_fill_at) < maxf(grass_r, under_r) + StreamPolicy.MAX_LEAD:
			_begin_present()
		else:
			last_fill = Vector2.INF
			_detail_frames.clear()
	if allow_upload and not _present.is_empty():
		if frame_budget == null or frame_budget.allows_work():
			_present_next(Time.get_ticks_usec() + DETAIL_UPLOAD_US if frame_budget == null else frame_budget.deadline(DETAIL_UPLOAD_US))
			uploaded = true
	phase_started = _record_phase(2, phase_started)
	var lead := stream.lead()
	if (frame_budget == null or frame_budget.allows_work()) and (last_trees == Vector2.INF or p.distance_to(last_trees) >= RECHECK or (p + lead).distance_to(_tree_target) >= RECHECK):
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
		_pending = _by_distance(kept, p)
		if _tree_task == -1:
			var missing := _wanted(p, p + lead)
			if not missing.is_empty():
				for chunk in missing:
					_queued[chunk] = true
				_tree_task = WorkerThreadPool.add_task(_fill_trees.bind(missing, _epoch), true, "Деревья")
	phase_started = _record_phase(3, phase_started)
	if _task == -1 and _present.is_empty() and _refresh_details:
		snapshots.reset()
		_refresh_details = false
	# Новый снимок — только когда прежний передан целиком: задача пишет те же буферы.
	if (frame_budget == null or frame_budget.allows_work()) and _task == -1 and _present.is_empty() and (last_fill == Vector2.INF or p.distance_to(last_fill) >= StreamPolicy.REFILL_STEP or lead.distance_to(_job_lead) >= StreamPolicy.REFILL_STEP or snapshots.cleanup_due(stream.clock)):
		last_fill = p
		_job_lead = lead
		_detail_started_clock = stream.clock
		_task = WorkerThreadPool.add_task(_fill_details.bind(px, pz, lead, _epoch, stream.clock), true, "Трава и подлесок")
	phase_started = _record_phase(4, phase_started)
	if allow_upload and not uploaded and not _pending.is_empty() and (frame_budget == null or frame_budget.allows_work()):
		_upload_next()
		uploaded = true
	_record_phase(5, phase_started)
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
	# Ключ сортировки считается один раз на чанк (раньше — в каждом сравнении); сравнения те же, порядок тот же.
	var keyed: Array = []
	for c in out:
		keyed.append([_distance(c, p) + _distance(c, ahead), c])
	keyed.sort_custom(func(a: Array, b: Array) -> bool: return a[0] > b[0])
	var sorted: Array[Vector2i] = []
	for item: Array in keyed:
		sorted.append(item[1])
	return sorted


## Готовые чанки от дальних к ближним (главный поток берёт с конца); расстояние — один раз на чанк
func _by_distance(list: Array, p: Vector2) -> Array:
	var keyed: Array = []
	for built: Dictionary in list:
		keyed.append([_distance(built.chunk, p), built])
	keyed.sort_custom(func(a: Array, b: Array) -> bool: return a[0] > b[0])
	var out: Array = []
	for item: Array in keyed:
		out.append(item[1])
	return out


func _drop(p: Vector2) -> void:
	# Дальность считается один раз на чанк, а не на каждый вид в нём (в езде это было ~6 мс на проверку)
	var limit := drop_radius + stream.lead().length()
	var far := {}
	for key: Vector3i in veg.keys():
		var chunk := Vector2i(key.x, key.y)
		if not far.has(chunk):
			far[chunk] = _distance(chunk, p) > limit
		if far[chunk]:
			for node: MultiMeshInstance3D in veg[key].nodes:
				_trash_node(node)
			veg.erase(key)
	for chunk: Vector2i in _loaded.keys():
		if far[chunk] if far.has(chunk) else _distance(chunk, p) > limit:
			_loaded.erase(chunk)
			if world.outer != null:
				world.outer.veg.erase(chunk)


## Заполнение при появлении: трава, подлесок и деревья — в задачах пула. Те же функции, что у фоновой подгрузки,
## поэтому результат тот же; _built — в порядке missing.
func _fill(px: float, pz: float, missing: Array[Vector2i]) -> void:
	var details := WorkerThreadPool.add_task(_fill_details.bind(px, pz, Vector2.ZERO, _epoch, stream.clock, true), true, "Трава и подлесок")
	var results: Array = []
	results.resize(missing.size())
	if not missing.is_empty():
		var lock := Mutex.new()
		var trees := WorkerThreadPool.add_group_task(func(j: int) -> void:
			var chunk := missing[j]
			var built := _build_chunk(chunk) if _on_map(chunk) else _build_outer(chunk)
			lock.lock()
			results[j] = built
			lock.unlock(), missing.size(), clampi(OS.get_processor_count() / 2, 1, 8), true, "Деревья")
		WorkerThreadPool.wait_for_group_task_completion(trees)
	WorkerThreadPool.wait_for_task_completion(details)
	_built = []
	for built: Dictionary in results:
		built.epoch = _epoch
		_built.append(built)


func _fill_trees(missing: Array[Vector2i], epoch: int) -> void:
	_built = []
	for chunk in missing:
		var built := _build_chunk(chunk) if _on_map(chunk) else _build_outer(chunk)
		built.epoch = epoch
		_built.append(built)


## Раскладка и ёмкость GPU-буферов готовятся в задаче. Отметки появления предварительные:
## перед публикацией короткий нативный проход привязывает их к фактическому времени передачи.
func _fill_details(px: float, pz: float, lead: Vector2, epoch: int, clock: float, immediate := false) -> void:
	var started := Time.get_ticks_usec()
	_fill_lead = lead
	_detail_epoch = epoch
	_reserve_details(lead)
	_fill_grass(px, pz)
	var frames := {-1: snapshots.prepare(-1, grass_buf, _grass_n, _grass_bounds, _grass_margin * 2.0, clock, immediate)}
	for kind in understory.size():
		var entry: Dictionary = understory[kind]
		var bounds := AABB(entry.low, entry.high - entry.low) if entry.count > 0 else AABB()
		frames[kind] = snapshots.prepare(kind, entry.buf, entry.count, bounds, _radius(entry.mm.mesh) + entry.margin, clock, immediate, entry.has_contacts)
	var now := clock + (Time.get_ticks_usec() - started) / 1000000.0
	for group: int in frames:
		snapshots.stamp(frames[group], now)
		_fit_capacity(frames[group], grass if group < 0 else understory[group].mm)
	_detail_frames = frames
	_detail_seconds = (Time.get_ticks_usec() - started) / 1000000.0


## Ёмкость MultiMesh, которую выберет _upload_instances (ступени и гистерезис те же); буфер дополняется
## до неё заранее, чтобы при передаче не было ни resize, ни slice. MultiMesh в это время не меняется.
static func _fit_capacity(frame: Dictionary, mm: MultiMesh) -> void:
	var count: int = frame.count
	var capacity := 64
	while capacity < count:
		capacity *= 2
	var keep := mm.instance_count >= count and mm.instance_count <= maxi(64, count * 4)
	var data: PackedFloat32Array = frame.buffer
	data.resize((mm.instance_count if keep else capacity) * STRIDE)
	frame.buffer = data
	frame.fitted = true


func _reserve_details(lead: Vector2) -> void:
	var cap := ceili(_grass_cap() * StreamPolicy.reserve_factor(grass_r, lead))
	if grass_buf.size() < cap * STRIDE:
		grass_buf.resize(cap * STRIDE)
	for entry: Dictionary in understory:
		cap = ceili(_understory_cap(entry.far and not entry.near_cap) * StreamPolicy.reserve_factor(under_r if entry.far else grass_r, lead))
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
	f.plan_path = world.path_mask
	f.world_origin = Vector2(world.world_origin) * TILE
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
			if RockModels.is_outcrop(f.v[o]) and not _defs.has(OUTCROP_MODEL): continue
			rock_probe = RockModels.seat_snapshot_any(f, hv, W, H, fx[o] * TILE, fy[o] * TILE, f.s[o] * 1.2, f.v[o])
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
		var refined := OuterLand.refined_at(world.outer.get_ledger().get("regions", {}), fx[o] * TILE, fy[o] * TILE)
		if not refined.is_empty():
			ground = refined.h
			# A rock footprint cannot straddle a newly cut slope; skip it rather than float or bury it.
			if kind == Biomes.T_ROCK: continue
		# за краем вода только морская, её уровень 0
		if kind != Biomes.T_REED and kind != Biomes.T_ROCK and ground < -WATER_MARGIN:
			continue
		# Выход стоит на своём основании, утопленном в склон, а не на земле в центре.
		if kind == Biomes.T_ROCK and RockModels.is_outcrop(f.v[o]):
			ground = rock_probe.x
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
		items.normals.append(Vector3(rock_probe.y, rock_probe.z, rock_probe.w) if kind == Biomes.T_ROCK else (refined.normal if not refined.is_empty() else Vector3(-dx, TILE, -dz).normalized()))
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
		var x := ox * TILE
		var z := oy * TILE
		# 15.0: ствол у тропы законен (просвет StageVegetation по кромке полотна); не рисуется только то, что стоит
		# на самом полотне (путь проложен позже растительности) — та же проверка, что у ForestObstacles
		if ForestObstacles.on_tread(heights, x, z):
			continue
		var ground := 0.0
		var normal := Vector3.UP
		if kind == Biomes.T_ROCK:
			if RockModels.is_outcrop(world.obj_v[o]) and not _defs.has(OUTCROP_MODEL):
				continue
			var seat := RockModels.seat(heights, x, z, world.obj_s[o] * 1.2, world.obj_v[o])
			if seat.x == INF:
				continue
			ground = seat.x
			normal = Vector3(seat.y, seat.z, seat.w)
		else:
			ground = heights.ground_at(x, z)
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
		var outcrop := kind == Biomes.T_ROCK and RockModels.is_outcrop(items.v[o])
		if kind == Biomes.T_ROCK and not outcrop and items.has("normals") and not RockModels.supported(items.normals[o]):
			continue
		var ox := xs[o]
		var oy := ys[o]
		var ground: float = items.ground[o]
		# Выбор силуэта по координатам независим от оттенка и возраста дерева.
		var model := kind
		if outcrop:
			# Одна форма выходов на чанк (характер отдельности массива): не больше одной группы MultiMesh
			# и её LOD на чанк вместо трёх.
			var form := RockModels.form_of(items.v[o], ox * TILE, oy * TILE, Vector2(world.world_origin) * TILE)
			model = OUTCROP_MODEL + form * ForestModels.MODEL_STRIDE
			# Каталог без моделей массивов (старый) — массив не рисуется, как выходы без своей модели.
			if not _defs.has(model): continue
		elif _defs.has(kind + ForestModels.MODEL_STRIDE):
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
				if RockModels.is_outcrop(v):
					# Основание уже опущено до нижней точки опоры (RockModels.outcrop_seat); ось — между
					# вертикалью и склоном, поэтому плиты и уступы почти горизонтальны.
					xf = RockModels.outcrop_transform(ox * TILE, oy * TILE, s, normal, group.ground[n], Vector2(world.world_origin) * TILE, v)
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
	_merge_far_variants(entries)
	return {entries = entries}


## Записи силуэтов одного вида чанка -> одна запись дальнего уровня (см. FAR_KEY). Вызывается и в фоне.
func _merge_far_variants(entries: Array) -> void:
	var groups := {}
	for entry: Dictionary in entries:
		var base: int = entry.kind % ForestModels.MODEL_STRIDE
		if base == Biomes.T_ROCK or base == Biomes.T_REED or not _defs.has(base + ForestModels.MODEL_STRIDE) or entry.get("small_rocks", false):
			continue
		if not _defs.has(base) or ForestModels.lod_meshes(_defs[base].get("crown", _defs[base].get("trunk"))).size() < 3:
			continue
		if not groups.has(base):
			groups[base] = []
		groups[base].append(entry)
	for base: int in groups:
		var list: Array = groups[base]
		if list.size() < 2:
			continue
		var def: Dictionary = _defs[base]
		var merged := {kind = base, key_kind = base + FAR_KEY, count = 0, far_only = true, bounds = AABB()}
		var trunk := def.has("trunk") and not FAR_TRUNKLESS.has(base)
		var crown := def.has("crown")
		var tbuf := PackedFloat32Array()
		var cbuf := PackedFloat32Array()
		for entry: Dictionary in list:
			var ratio: float = _defs[entry.kind].box.end.y / maxf(def.box.end.y, 0.01)
			if trunk and entry.has("tbuf"):
				var t: PackedFloat32Array = entry.tbuf.duplicate()
				for at in range(5, t.size(), 12):
					t[at] *= ratio
				tbuf.append_array(t)
			if crown and entry.has("cbuf"):
				var c: PackedFloat32Array = entry.cbuf.duplicate()
				for at in range(5, c.size(), 16):
					c[at] *= ratio
				cbuf.append_array(c)
			merged.bounds = entry.bounds if merged.count == 0 else merged.bounds.merge(entry.bounds)
			merged.count += entry.count
			entry.merged_far = true
		if trunk:
			merged.tbuf = tbuf
		if crown:
			merged.cbuf = cbuf
		entries.append(merged)


## 13.9: область rect (клетки) закреплена: её чанки за краем убираются и строятся заново
## по окончательной географии (вода, дороги, поселения).
func refresh(rect: Rect2i) -> void:
	_epoch += 1
	# Unpublished groups belong to the old terrain. Keep only the live buffers
	# and let the normal worker rebuild the snapshot under the frame budget.
	if not _present.is_empty():
		_present.clear()
		_detail_frames.clear()
	# Published earthworks cannot leave old trees, rocks or undergrowth floating over the cut.
	var box := Rect2(Vector2(rect.position) * TILE, Vector2(rect.size) * TILE)
	var meshes: Array[MultiMesh] = []
	if grass != null: meshes.append(grass)
	for e: Dictionary in understory: meshes.append(e.mm)
	for mm in meshes:
		var bounds := mm.custom_aabb
		if not Rect2(Vector2(bounds.position.x, bounds.position.z), Vector2(bounds.size.x, bounds.size.z)).intersects(box): continue
		var buffer := mm.buffer
		var kept := 0
		for at in range(0, mini(mm.visible_instance_count if mm.visible_instance_count >= 0 else mm.instance_count, mm.instance_count) * STRIDE, STRIDE):
			if box.has_point(Vector2(buffer[at + 3], buffer[at + 11])): continue
			for c in STRIDE: buffer[kept * STRIDE + c] = buffer[at + c]
			kept += 1
		mm.buffer = buffer
		mm.visible_instance_count = kept
	_refresh_details = true
	obstacles = _without_region(obstacles, 7, box)
	bumps = _without_region(bumps, 6, box)
	obstacles_version += 1
	var side := world.CS
	for chunk: Vector2i in _loaded.keys():
		if _on_map(chunk) or not Rect2i(chunk * side, Vector2i.ONE * side).intersects(rect):
			continue
		_dirty[chunk] = _epoch
		_loaded.erase(chunk)
		world.outer.veg.erase(chunk)
		for key: Vector3i in veg.keys():
			if key.x == chunk.x and key.y == chunk.y:
				for node: MultiMeshInstance3D in veg[key].nodes:
					_trash_node(node)
				veg.erase(key)
	for x in range(floori(float(rect.position.x) / side), floori(float(rect.end.x - 1) / side) + 1):
		for y in range(floori(float(rect.position.y) / side), floori(float(rect.end.y - 1) / side) + 1):
			if not _on_map(Vector2i(x, y)):
				_dirty[Vector2i(x, y)] = _epoch
	last_fill = Vector2.INF
	last_trees = Vector2.INF


func _upload_next() -> void:
	var built: Dictionary = _pending.back()
	if _apply_chunk(built, 1, Time.get_ticks_usec() + TREE_UPLOAD_US if frame_budget == null else frame_budget.deadline(TREE_UPLOAD_US)):
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
		var key := Vector3i(chunk.x, chunk.y, built.entries[i].get("key_kind", built.entries[i].kind))
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
	if limit > 0 and deadline_usec > 0 and Time.get_ticks_usec() >= deadline_usec:
		return false
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
			veg[Vector3i(chunk.x, chunk.y, entry.get("key_kind", kind))] = entry
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
				# 15.0: сгруппированный дальний уровень рисует запись FAR_KEY, у силуэтов его нет
				if levels.size() > 1 and (entry.get("far_only", false) != (level == levels.size() - 1)) and (entry.get("far_only", false) or entry.get("merged_far", false)):
					node_index += 1
					continue
				# 15.0: за 160 м ствол леса тоньше пикселя и скрыт кроной: его узел (draw call на каждый чанк и силуэт) не нужен.
				if part == "trunk" and level == 2 and not small and def.has("crown") and FAR_TRUNKLESS.has(kind % ForestModels.MODEL_STRIDE):
					node_index += 1
					continue
				var shadow_proxy: bool = part == "trunk" and level == 0 and not small and levels.size() > 2
				var node_count := 2 if shadow_proxy else 1
				if limit > 0 and (uploaded + node_count > TREE_NODES_PER_SLICE or deadline_usec > 0 and Time.get_ticks_usec() >= deadline_usec):
					built.cursor = i
					built.node_cursor = node_index
					return false
				var mat := _shared_tree_material(def, part, level, small)
				var node := _multimesh(levels[level], mat, entry.count, part == "crown", not small, false, true)
				if limit > 0:
					_reveal_node(node, mat)
				if level >= FAR_LOD_NO_SHADOW:
					# Дальний LOD лежит за плавным краем теней солнца: теневой проход его не рисует.
					node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
				elif part == "trunk" and level >= 1:
					node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF # тень тонкого ствола за 60 м не видна
				elif shadow_proxy:
					# 15.0: тень ближнего ствола считает дальний меш (в 10-15 раз меньше треугольников): ствол сам
					# рисуется ближним мешом, а в каждый из каскадов теней попадал бы ещё раз.
					node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
					var caster := _multimesh(levels[levels.size() - 1], mat, entry.count, false, true, false, true)
					caster.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY
					if limit > 0:
						_reveal_node(caster, mat)
					caster.multimesh.buffer = entry.tbuf
					caster.multimesh.custom_aabb = entry.bounds
					caster.multimesh.visible_instance_count = entry.count
					caster.visibility_range_end = LOD_STEPS[0][0] + LOD_STEPS[0][1] * 0.5 + _half_chunk()
					caster.visibility_range_end_margin = 16.0
					entry.nodes.append(caster)
				elif part == "crown" and not small and kind % ForestModels.MODEL_STRIDE != Biomes.T_ROCK:
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
				uploaded += node_count
		built.node_cursor = 0
		built.cursor = i + 1
	_loaded[chunk] = true
	built.cursor = end
	return end == built.entries.size()


func _apply_grass(immediate := false) -> void:
	_present.clear()
	_present_group(-1, immediate)
	for kind in understory.size():
		_present_group(kind, immediate)
	_accept_contacts()
	_detail_frames.clear()


## Готовый снимок передаётся по группам в пределах бюджета кадра.
func _begin_present() -> void:
	_present.clear()
	_present.append(-1)
	for kind in understory.size():
		_present.append(kind)


func _accept_contacts() -> void:
	obstacles = _obstacles_next
	bumps = _bumps_next
	obstacles_version += 1


## deadline_usec = 0 — передать всё оставшееся сразу.
func _present_next(deadline_usec: int) -> void:
	while not _present.is_empty() and (deadline_usec == 0 or Time.get_ticks_usec() < deadline_usec):
		var group: int = _present.pop_front()
		_present_group(group, false)
		# Even a prepared worker snapshot can spend several frames in this queue.
		if group == _last_contact_group:
			_accept_contacts()
	if _present.is_empty():
		_detail_frames.clear()


func _present_group(group: int, immediate: bool) -> void:
	if group < 0:
		_present_frame(-1, grass, grass_buf, _grass_n, _grass_bounds, _grass_margin * 2.0, immediate)
		grass_at = _fill_at
		grass_lead = _fill_lead
		return
	var entry: Dictionary = understory[group]
	var bounds := AABB(entry.low, entry.high - entry.low) if entry.count > 0 else AABB()
	_present_frame(group, entry.mm, entry.buf, entry.count, bounds, _radius(entry.mm.mesh) + entry.margin, immediate)


func _present_frame(group: int, mm: MultiMesh, source: PackedFloat32Array, count: int, bounds: AABB, radius: float, immediate: bool) -> void:
	var instant_arrival: bool = group >= 0 and understory[group].has_contacts
	var frame := snapshots.commit(group, _detail_frames[group], stream.clock) if _detail_frames.has(group) else snapshots.merge(group, source, count, bounds, radius, stream.clock, immediate, instant_arrival)
	if not frame.has("fitted"):
		_fit_capacity(frame, mm)
	_upload_instances(mm, frame.buffer, frame.count)
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
	node.material_override = shared
	_set_tree_stamp(node, stream.clock)
	_appearing.append({node = node, until = stream.clock + StreamPolicy.FADE_SECONDS})


static func _set_tree_stamp(node: MultiMeshInstance3D, stamp: float) -> void:
	node.set_meta("stream_birth", stamp)
	node.set_instance_shader_parameter("stream_birth", stamp)


func _retire_nodes(nodes: Array) -> void:
	for node: MultiMeshInstance3D in nodes:
		var stamp: float = node.get_meta("stream_birth", 0.0)
		var alpha := Snapshots.opacity(stamp, stream.clock)
		_set_tree_stamp(node, -(stream.clock - (1.0 - alpha) * StreamPolicy.FADE_SECONDS))
		node.set_meta("stream_retiring", true)
	_retired.append({until = stream.clock + StreamPolicy.FADE_SECONDS, nodes = nodes})


func _clean_retired() -> void:
	for i in range(_appearing.size() - 1, -1, -1):
		if frame_budget != null and not frame_budget.allows_work(): break
		var entry: Dictionary = _appearing[i]
		if not is_instance_valid(entry.node):
			_appearing.remove_at(i)
			continue
		var node: MultiMeshInstance3D = entry.node
		if node.is_queued_for_deletion() or node.get_meta("stream_retiring", false):
			_appearing.remove_at(i)
		elif stream.clock >= entry.until:
			_set_tree_stamp(node, 0.0)
			_appearing.remove_at(i)
	for i in range(_retired.size() - 1, -1, -1):
		if frame_budget != null and not frame_budget.allows_work(): break
		if stream.clock >= _retired[i].until:
			var entry: Dictionary = _retired[i]
			var cursor: int = entry.get("cursor", 0)
			while cursor < entry.nodes.size():
				if frame_budget != null and not frame_budget.allows_work():
					entry.cursor = cursor
					return
				var node: Node = entry.nodes[cursor]
				if is_instance_valid(node):
					_trash_node(node)
				cursor += 1
			_retired.remove_at(i)


## Узел больше не нужен: скрыть сразу, удалить позже по бюджету. queue_free удалял весь ряд чанков
## (на 45 м/с — тысячи MultiMesh) в конце одного кадра.
func _trash_node(node: Node) -> void:
	node.visible = false
	node.set_meta("stream_retiring", true)
	_trash.append(node)


## budget_us = 0 — удалить всё.
func _free_trash(budget_us: int) -> void:
	var until := Time.get_ticks_usec() + budget_us
	var freed := 0
	while not _trash.is_empty() and (budget_us == 0 or freed < 1 or Time.get_ticks_usec() < until):
		var node: Node = _trash.pop_back()
		if is_instance_valid(node):
			if budget_us > 0 and node is MultiMeshInstance3D and node.get_meta("stream_tree", false) and _tree_pool.size() < TREE_POOL_LIMIT:
				# Keep the scene/render instance, release all per-chunk GPU data.
				node.multimesh.instance_count = 0
				node.multimesh.mesh = null
				_set_tree_stamp(node, 0.0)
				node.material_override = null
				_tree_pool.append(node)
				node_stats.pooled += 1
			else:
				node.free()
		freed += 1


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
	_fill_started = Time.get_ticks_usec()
	_grass_low = low
	_grass_high = high
	_fill_at = Vector2(px, pz)
	placement.clear_occupied()
	_obstacles_next = PackedFloat32Array()
	_bumps_next = PackedFloat32Array()
	placement.prepare(px + _fill_lead.x * 0.5, pz + _fill_lead.y * 0.5, rF * TILE + _fill_lead.length() * 0.5 + 12.0)
	_understory_sites.clear()
	for entry: Dictionary in understory:
		entry.count = 0
		entry.low = Vector3.INF
		entry.high = -Vector3.INF
	# Препятствия на полотне — первыми: обочина, подлесок и трава обходят их, а не наоборот.
	_fill_road(px, pz)
	# Без раннего выхода по полному буферу травы: подлесок дальних рядов собирается всегда.
	for j in range(maxi(0, floori(scan_low.y)), mini(w.H - 1, ceili(scan_high.y)) + 1):
		for i in range(maxi(0, floori(scan_low.x)), mini(w.W - 1, ceili(scan_high.x)) + 1):
			var k := j * w.W + i
			var bd: Dictionary = Biomes.LIST[w.biome[k]]
			var rocky_cell := w.biome[k] == Biomes.ROCK
			if (not bd.has("grass") and not rocky_cell) or w.river[k] != 0:
				continue
			var d := StreamPolicy.distance_to_coverage(Vector2(i + 0.5, j + 0.5) * TILE, origin, _fill_lead) / TILE
			var d2 := d * d
			if d2 > rF * rF:
				continue
			if d2 > rT * rT:
				# За кругом травы — только крупный подлесок
				_fill_understory(i, j, _forest_surface.get_pixel(i, j), StageClimate.natural_conditions(w, i, j).x, px, pz)
				continue
			var gr: Dictionary = ROCK_GRASS if rocky_cell else bd.grass
			# Почвенная влага и освещение общие с генератором леса.
			var lush := clampf(1.0 - 0.45 * (w.slope[k] - 0.5), 0.35, 1.0) * (1.25 if w.dist_water[k] < 3.0 else 1.0)
			var light := StageClimate.natural_conditions(w, i, j).x
			lush *= (0.45 + 0.75 * w.moist[k]) * (0.65 + 0.7 * light)
			var surface := _forest_surface.get_pixel(i, j)
			lush *= 1.0 - 0.65 * surface.r
			lush *= _fill_understory(i, j, surface, light, px, pz)
			if rocky_cell: lush *= _rock_shelter(surface, i + world.world_origin.x, j + world.world_origin.y)
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
				var rocky_cell: bool = cell.biome == Biomes.ROCK
				if not bd.has("grass") and not rocky_cell:
					continue
				var surface := _outer_surface(cell)
				if d2 > rT * rT:
					_fill_understory_cell(i, j, cell.biome, cell.path, cell.slope, surface, OUTER_LIGHT, px, pz, cell.elev, cell.dw)
					continue
				var lush := clampf(1.0 - 0.45 * (cell.slope - 0.5), 0.35, 1.0)
				lush *= (0.45 + 0.75 * cell.moist) * (0.65 + 0.7 * OUTER_LIGHT)
				lush *= 1.0 - 0.65 * surface.r
				lush *= _fill_understory_cell(i, j, cell.biome, cell.path, cell.slope, surface, OUTER_LIGHT, px, pz, cell.elev, cell.dw)
				if rocky_cell: lush *= _rock_shelter(surface, i, j)
				n = _grass_cell(i, j, ROCK_GRASS if rocky_cell else bd.grass, lush, surface, d2, n, cell.path, regions)
	low = _grass_low
	high = _grass_high
	_grass_n = n
	_grass_bounds = AABB(low, high - low).grow(_grass_margin) if n > 0 else AABB()
	var t_scan := Time.get_ticks_usec()
	# 9.9+: внутри одного приоритета — по порогу поредения: место занимает тот, кто виден дальше.
	# Иначе невидимый ещё куст, попавший в раскладку с запасом, вытеснял бы видимый соседний.
	_understory_sites.sort_custom(func(a: Array, b: Array) -> bool: return a[6] < b[6])
	var t_sort := Time.get_ticks_usec()
	for priority in 3:
		for site: Array in _understory_sites:
			if Placement.priority(site[0]) == priority:
				if site.size() > 7:
					_put_understory(site[0], site[1], site[2], site[3], site[4], site[5], -1, site[6], false, 1.0, 0.0, site[7], site[8],
						site[9] if site.size() > 9 else 1.0)
				else:
					_put_understory(site[0], site[1], site[2], site[3], site[4], site[5], -1, site[6])
	var t_place := Time.get_ticks_usec()
	_fill_tree_roots(px, pz)
	_filter_grass()
	fill_stats = {scan_ms = (t_scan - _fill_started) / 1000.0, sort_ms = (t_sort - t_scan) / 1000.0,
		place_ms = (t_place - t_sort) / 1000.0, grass_filter_ms = (Time.get_ticks_usec() - t_place) / 1000.0,
		sites = _understory_sites.size()}
	_understory_sites.clear()


## Пучки травы клетки (i, j) в grass_buf начиная с n; возвращает новое n. path — путь клетки
## (без локальной детализации дорог на нём травы нет)
func _grass_cell(i: int, j: int, gr: Dictionary, lush: float, surface: Color, d2: float, n: int, path: int, regions := {}) -> int:
	var buf := grass_buf
	var w := world
	var cnt := floori(gr.dens * (0.5 + WGRandom.hash2(i, j, 5)) * lush * (1.0-0.9*surface.a))
	var tc: Array = gr.tint
	# Дальше GRASS_R трава редеет, а пучки чуть крупнее (на средней и высокой дальности). С 9.9+ это
	# решает шейдер по нынешнему расстоянию и порогу пучка; здесь — с запасом на _ahead ближе.
	var keep: float = _keep(sqrt(d2) * TILE, GameConfig.GRASS_R, _ahead(grass_r)) * flora.grass
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
		var sc: float = (0.8 + WGRandom.hash2(i + m, j - m, 17) * 0.7) * flora.grow
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
		elev = f.h[q], moist = 0.45 + 0.4 * exp(-f.dw[q] / 3.0), dw = float(f.dw[q])}


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
	var exposed:=StageVegetation.Surface.exposure(cell.elev,cell.slope,cell.moist)
	match cell.biome:
		Biomes.FOREST, Biomes.JUNGLE:
			return Color(0.6, 0.25, cell.moist, exposed)
		Biomes.TAIGA:
			return Color(0.55, 0.85, cell.moist, exposed)
		Biomes.SWAMP:
			return Color(0.35, 0.3, 0.9, exposed)
	return Color(0.0, 0.0, cell.moist, exposed)


## Скалы не зеленеют: трава пятнами 8 м только в сырых защищённых местах (влага и открытость
## породы — те же каналы, что у материала рельефа, поэтому пучки стоят на тёмном грунте).
static func _rock_shelter(surface: Color, i: int, j: int) -> float:
	var patch := WGRandom.hash2(floori(i / 2.0), floori(j / 2.0), 9127)
	if legacy_open:
		return smoothstep(0.5, 0.74, surface.b) * smoothstep(0.35, 0.75, patch) * (1.0 - surface.a)
	# 16.0: чуть суше и чаще — дернина и цветы пятнами, открытая порода (surface.a) по-прежнему голая
	# 09.11.2026: на пологих скальных вершинах без открытой породы — каменистая тундра: дерновина и суше
	# (тот же признак, что у материала рельефа: малая открытость на сером биоме).
	var gentle := 1.0 - smoothstep(0.1, 0.4, surface.a)
	return smoothstep(0.42 - 0.16 * gentle, 0.7, surface.b) * smoothstep(0.25, 0.65, patch) * (1.0 - surface.a)


## Доля травы или подлеска, что остаётся на расстоянии d (м) при полной густоте до full,
## с запасом: игрок до следующей раскладки может подъехать на ahead ближе (шейдер считает без запаса).
static func _keep(d: float, full: float, ahead: float) -> float:
	var near := maxf(d - ahead, 1.0)
	return minf(1.0, full * full / (near * near))


## Возвращает множитель низкой травы по характеру леса (вне леса 1).
func _fill_understory(i: int, j: int, surface: Color, sunlight: float, px: float, pz: float) -> float:
	var k := j * world.W + i
	return _fill_understory_cell(i, j, world.biome[k], world.path_mask[k], world.slope[k], surface, sunlight, px, pz, world.elev[k], world.dist_water[k])


## Подлесок клетки по её биому, пути и уклону (на плане — из WorldData, за краем — OuterLand.info).
## alt — высота, water — расстояние до воды в клетках (для сообществ открытых мест).
func _fill_understory_cell(i: int, j: int, bi: int, path: int, slope: float, surface: Color, sunlight: float, px: float, pz: float,
		alt := 0.2, water := 99.0) -> float:
	var canopy := surface.r
	if bi == Biomes.ROCK and canopy < 0.15:
		_fill_rock_hollow(i, j, path, slope, surface, px, pz)
		return 1.0
	if canopy < 0.15:
		# 16.0: открытые места — растительные сообщества (раньше подлеска здесь не было вовсе)
		if legacy_open:
			return 1.0 if bi not in [Biomes.FOREST, Biomes.TAIGA, Biomes.JUNGLE, Biomes.SWAMP] else _fill_forest_cell(i, j, bi, path, slope, surface, sunlight, px, pz)
		return _fill_open_cell(i, j, bi, path, slope, surface, sunlight, px, pz, alt, water)
	return _fill_forest_cell(i, j, bi, path, slope, surface, sunlight, px, pz)


## Подлесок под пологом: характер леса (8.2) и, с 16.0, опушка — кусты, подрост и высокотравье у края
func _fill_forest_cell(i: int, j: int, bi: int, path: int, slope: float, surface: Color, sunlight: float, px: float, pz: float) -> float:
	var canopy := surface.r
	var moisture := surface.b
	# 8.2: характер леса от полога, хвои, влаги, солнца и возраста участка
	var ch := Understory.character(canopy, surface.g, moisture, sunlight, StageVegetation.age_at(world, i, j))
	var grass_mul := Understory.mix(Understory.LOW_GRASS, ch)
	# 15.0: у дорог и троп подлесок решает ground_clear по настоящему полотну; клетка звериной тропы и путь за краем плана — пусто
	if path == 1 or (path > 0 and not _in_plan(i, j)) or slope > 0.9:
		return grass_mul
	var light := sunlight * (1.0 - canopy * 0.85)
	var weights := Understory.weights(bi, moisture, light, canopy, ch)
	var floor_weights := Floor.weights(canopy, surface.g, moisture, light, surface.a)
	var deadwood := Understory.mix(Understory.DEADWOOD, ch)
	for f in [Floor.LOG, Floor.MOSS_LOG, Floor.SNAG, Floor.STUMP]:
		floor_weights[f] *= deadwood
	# 16.0: опушка — рядом (8–12 м) открытое место: кусты, подрост и высокотравье стеной, полог редеет к краю
	if legacy_open:
		for f: int in Understory.OPEN_FORMS: weights[f] = 0.0
	var rim := 0.0 if legacy_open or not _in_plan(i, j) else smoothstep(0.3, 0.05, _ring_canopy(i, j).y) * (1.0 - smoothstep(0.55, 0.9, canopy))
	if rim > 0.0:
		var conifer := surface.g > 0.5
		weights[Understory.BUSH] += rim * 0.55
		weights[Understory.PINE if conifer else Understory.SAPLING] += rim * 0.25
		weights[Understory.YOUNG_PINE if conifer else Understory.YOUNG] += rim * 0.1
		weights[Understory.MEADOW] += rim * 0.35 * light
		weights[Understory.HIGH_GRASS] += rim * 0.2
		weights[Understory.FIREWEED] += rim * 0.4 * light
	# 16.1: иван-чай — теми же пятнами, что на лугу (общий шум), иначе его нет
	if weights[Understory.FIREWEED] > 0.0:
		weights[Understory.FIREWEED] *= 3.0 * smoothstep(0.58, 0.82, _vnoise(i, j, 6.0, (world.seed_num ^ 8803) + 41))
	weights.append_array(floor_weights)
	var total := 0.0
	for weight in weights:
		total += weight
	# Пятна по 12 м и случайные пропуски; соседние клетки связаны без нового шума.
	var seed := world.seed_num ^ 6601
	var patch := WGRandom.hash2(floori(i / 3.0), floori(j / 3.0), seed)
	var density := (0.3 + 0.75 * patch) * (0.5 + 0.5 * moisture) * Understory.mix(Understory.DENSITY, ch) # 9.4: гуще
	density *= 1.0-0.65*surface.a
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
		if d > _reach_r(kind, far):
			continue
		var full := _full_r(kind, far)
		var rank := WGRandom.hash2(i * 8 + m, j, seed + 8)
		if rank > _keep(d, full, _ahead(_reach_r(kind, far))) * _flora_keep(kind):
			continue
		var scale := (0.7 + WGRandom.hash2(i * 8 + m, j, seed + 5) * 0.6) * _flora_grow(kind)
		var rot := WGRandom.hash2(i * 8 + m, j, seed + 6) * TAU
		var tint := 0.85 + WGRandom.hash2(i * 8 + m, j, seed + 7) * 0.3
		_understory_sites.append([kind, x, z, rot, scale, tint, rank])
	return grass_mul


## 16.0: доля и размер растения по качеству растительности. Валежник, сухостой, пни и камни
## (столкновения) не зависят от настройки.
## Дальность раскладки формы, м
func _reach_r(kind: int, far: bool) -> float:
	if kind in Understory.OPEN_FORMS:
		return minf(under_r, OPEN_MAX_R * flora.reach)
	return under_r if far else grass_r


## Радиус полной густоты формы (за ним поредение): куртины открытых мест, крупный подлесок, мелочь
static func _full_r(kind: int, far: bool) -> float:
	if kind in Understory.OPEN_FORMS:
		return OPEN_FULL_R
	return UNDERSTORY_FAR_R if far else GameConfig.GRASS_R


func _flora_keep(kind: int) -> float:
	return flora.density if kind < Floor.FIRST else 1.0


func _flora_grow(kind: int) -> float:
	return flora.grow if kind < Floor.FIRST else 1.0


## 16.0: открытое место — растительное сообщество клетки (Understory.communities): массивы
## высокотравья и разнотравья на сотни метров, кустарник у опушек, обочин и в предгорьях, осока
## у воды, дернина в горах, а между ними — газон для контраста. Поля — существующие (влага, свет,
## высота, уклон, порода, вода, полог, пути) и плавный шум трёх масштабов; новых карт нет.
func _fill_open_cell(i: int, j: int, bi: int, path: int, slope: float, surface: Color, sunlight: float, px: float, pz: float,
		alt: float, water: float) -> float:
	if path == 1 or (path > 0 and not _in_plan(i, j)) or slope > 1.15:
		return 1.0
	var seed := world.seed_num ^ 8803
	var inside := _in_plan(i, j)
	# Сообщество клетки неизменно: на плане считается один раз и хранится байтами (раскладка
	# повторяется каждые несколько метров пути). Всегда используются квантованные значения —
	# первая и повторная раскладки совпадают.
	var at := -1
	if inside:
		if _open_cache.size() != world.N * OPEN_CACHE:
			_open_cache.resize(world.N * OPEN_CACHE)
			_open_cache.fill(0)
			_open_valid.resize(world.N * 2)
			_open_valid.fill(0)
		at = (j * world.W + i) * OPEN_CACHE
	var q: PackedByteArray
	var o := 0
	if at >= 0 and _open_cache[at] != 0:
		q = _open_cache
		o = at
	else:
		q = _open_community(i, j, bi, slope, surface, sunlight, alt, water, inside)
		if at >= 0:
			for n in OPEN_CACHE:
				_open_cache[at + n] = q[n]
	var com := PackedFloat32Array()
	com.resize(Understory.COMMUNITIES)
	for c in Understory.COMMUNITIES:
		com[c] = q[o + 1 + c] / 255.0
	var density := q[o + 7] / 255.0
	var grass_mul := q[o + 8] / 200.0
	var parch := q[o + 9] / 255.0
	var verge := q[o + 10] / 255.0
	var steppe := q[o + 11] / 255.0
	var bloom := q[o + 12] / 255.0
	if density <= 0.004:
		return grass_mul
	var weights := PackedFloat32Array()
	weights.resize(Understory.COUNT)
	var total := 0.0
	var conifer := bi in [Biomes.TAIGA, Biomes.TUNDRA] or alt > 0.3
	for c in Understory.COMMUNITIES:
		if com[c] < 0.02:
			continue
		var row: Array = Understory.COMMUNITY[c]
		for f in Understory.COUNT:
			weights[f] += com[c] * row[f]
	if conifer:
		weights[Understory.PINE] += weights[Understory.SAPLING]
		weights[Understory.YOUNG_PINE] += weights[Understory.YOUNG]
		weights[Understory.SAPLING] = 0.0
		weights[Understory.YOUNG] = 0.0
	# 16.1: в сухом и степном высокотравье место куртин и высоких пучков занимает ковыль (не поверх них);
	# в степном газоне — ковыль куртинами. Иван-чай — только в своих пятнах (bloom), там гуще.
	weights[Understory.STIPA] += steppe * (weights[Understory.MEADOW] * 0.8 + weights[Understory.HIGH_GRASS] + com[Understory.C_LAWN] * 2.5)
	weights[Understory.MEADOW] *= 1.0 - 0.8 * steppe
	weights[Understory.HIGH_GRASS] *= 1.0 - steppe
	weights[Understory.FIREWEED] *= bloom * 3.0 * (1.0 - steppe)
	for weight in weights:
		total += weight
	var hue := Color(1.0 + 0.16 * parch, 1.0 - 0.03 * parch, 1.0 - 0.3 * parch)
	# Стелющийся можжевельник: куст в горах и на каменистых склонах
	var juniper := alt > 0.27 or surface.a > 0.3 or com[Understory.C_TURF] > 0.5
	var hx := i * 8
	for m in Understory.OPEN_SLOTS:
		if WGRandom.hash2(hx + m, j, seed + 1) > density:
			continue
		var pick := WGRandom.hash2(hx + m, j, seed + 2) * total
		var kind := 0
		while kind < Understory.COUNT - 1 and pick >= weights[kind]:
			pick -= weights[kind]
			kind += 1
		var x := (i + 0.05 + 0.9 * WGRandom.hash2(hx + m, j, seed + 3)) * TILE
		var z := (j + 0.05 + 0.9 * WGRandom.hash2(hx + m, j, seed + 4)) * TILE
		var far: bool = understory[kind].far
		var d := StreamPolicy.distance_to_coverage(Vector2(x, z), Vector2(px, pz), _fill_lead)
		if d > _reach_r(kind, far):
			continue
		var rank := WGRandom.hash2(hx + m, j, seed + 8)
		if rank > _keep(d, _full_r(kind, far), _ahead(_reach_r(kind, far))) * flora.density:
			continue
		var scale := 0.75 + WGRandom.hash2(hx + m, j, seed + 5) * 0.5
		if kind == Understory.MEADOW:
			# В сердцевине массива и у обочины куртины выше: местами по пояс и выше
			scale *= 0.8 + 0.35 * com[Understory.C_TALL] + 0.2 * verge
		var squash := 1.0
		var site_hue := hue
		if kind == Understory.BUSH and juniper:
			scale *= JUNIPER_SPREAD
			squash = JUNIPER_SQUASH
			site_hue = JUNIPER_HUE
		elif kind == Understory.BUSH:
			scale *= 1.0 + 0.5 * com[Understory.C_SHRUB]
		elif kind == Understory.STIPA:
			site_hue = Color.WHITE # серебро остей не желтим
		elif kind == Understory.FIREWEED:
			scale *= 0.85 + 0.3 * bloom
		var tint := 0.88 + WGRandom.hash2(hx + m, j, seed + 7) * 0.24
		_understory_sites.append([kind, x, z, WGRandom.hash2(hx + m, j, seed + 6) * TAU, scale * flora.grow, tint, rank, site_hue,
			(j * world.W + i) * 8 + m if inside else -1, squash])
	return grass_mul


## 16.0: сообщество открытой клетки байтами (OPEN_CACHE): флаг, 6 долей, густота, множитель травы, сушь, обочина
func _open_community(i: int, j: int, bi: int, slope: float, surface: Color, sunlight: float, alt: float, water: float, inside: bool) -> PackedByteArray:
	var seed := world.seed_num ^ 8803
	var big := _vnoise(i, j, 36.0, seed)
	var mid := _vnoise(i, j, 11.0, seed + 17)
	var edge := _ring_canopy(i, j).x if inside else 0.0
	var verge := _verge(i, j) if inside else 0.0
	var dry := 1.0 if bi in [Biomes.STEPPE, Biomes.SAVANNA, Biomes.DESERT] else (0.6 if bi == Biomes.BEACH else 0.0)
	var com := Understory.communities(big, mid, surface.b, sunlight, slope, alt, surface.a, water, edge, verge, dry)
	var density := 0.0
	var grass_mul := 0.0
	for c in Understory.COMMUNITIES:
		density += com[c] * Understory.COMMUNITY_DENSITY[c]
		grass_mul += com[c] * Understory.COMMUNITY_GRASS[c]
	# Пятна ~12 м с просветами внутри массива; крутизна и голая порода редят.
	density *= smoothstep(0.1, 0.45, _vnoise(i, j, 3.0, seed + 31)) * (1.0 - 0.6 * surface.a)
	density *= 1.0 - 0.75 * smoothstep(0.55, 1.1, slope)
	# Сушь желтит и высушивает метёлки, сырость — сочная зелень; оттенок общий у соседей.
	var parch := clampf((0.55 - surface.b) * 1.6 + dry * 0.35 + alt * 0.4, 0.0, 1.0)
	# 16.1: степь и сухие солнечные склоны — ковыль. Раньше газон степи был почти пуст (густота 0,06):
	# пятнами (средний шум) там встают куртины ковыля, между ними — открытая степь.
	var steppe := clampf(maxf(dry, smoothstep(0.45, 0.8, parch) * sunlight * 1.3), 0.0, 1.0)
	density += com[Understory.C_LAWN] * steppe * 0.7 * smoothstep(0.35, 0.7, mid) * smoothstep(0.1, 0.45, _vnoise(i, j, 3.0, seed + 31))
	# Иван-чай — группами: свой шум ~25 м, большие цветущие участки только где он высок
	var bloom := smoothstep(0.58, 0.82, _vnoise(i, j, 6.0, seed + 41))
	var q := PackedByteArray([1, 0, 0, 0, 0, 0, 0, roundi(minf(density, 1.0) * 255.0), mini(255, roundi(grass_mul * 200.0)), roundi(parch * 255.0), roundi(verge * 255.0),
		roundi(steppe * 255.0), roundi(bloom * 255.0)])
	for c in Understory.COMMUNITIES:
		q[1 + c] = roundi(com[c] * 255.0)
	return q


## 16.0: плавный шум по клеткам: значения в узлах решётки шага scale клеток, сглаженная интерполяция
static func _vnoise(i: int, j: int, scale: float, seed: int) -> float:
	var fx := (i + 0.5) / scale
	var fy := (j + 0.5) / scale
	var x0 := floori(fx)
	var y0 := floori(fy)
	var tx := fx - x0
	var ty := fy - y0
	tx = tx * tx * (3.0 - 2.0 * tx)
	ty = ty * ty * (3.0 - 2.0 * ty)
	var a := lerpf(WGRandom.hash2(x0, y0, seed), WGRandom.hash2(x0 + 1, y0, seed), tx)
	var b := lerpf(WGRandom.hash2(x0, y0 + 1, seed), WGRandom.hash2(x0 + 1, y0 + 1, seed), tx)
	return lerpf(a, b, ty)


## 16.0: полог кольца 8–12 м вокруг клетки плана: x — наибольший (рядом лес — опушка), y — наименьший
## (рядом поляна или луг — край леса)
func _ring_canopy(i: int, j: int) -> Vector2:
	var high := 0.0
	var low := 1.0
	for o: Vector2i in [Vector2i(2, 0), Vector2i(-2, 0), Vector2i(0, 2), Vector2i(0, -2), Vector2i(2, 2), Vector2i(-2, -2), Vector2i(2, -2), Vector2i(-2, 2),
			Vector2i(3, 1), Vector2i(-3, -1), Vector2i(1, -3), Vector2i(-1, 3)]:
		var a := clampi(i + o.x, 0, world.W - 1)
		var b := clampi(j + o.y, 0, world.H - 1)
		var c := _forest_surface.get_pixel(a, b).r
		high = maxf(high, c)
		low = minf(low, c)
	return Vector2(high, low)


## 16.0: 1 — клетка у дороги или тропы (не звериной), 0 — дальше 4 м: некошеная полоса вдоль пути
func _verge(i: int, j: int) -> float:
	var near := 0.0
	for dj in range(-1, 2):
		for di in range(-1, 2):
			var a := i + di
			var b := j + dj
			if a < 0 or b < 0 or a >= world.W or b >= world.H:
				continue
			if world.path_mask[b * world.W + a] >= 2:
				near = 1.0 if di == 0 and dj == 0 else maxf(near, 0.8)
	return near


## Скальные ложбины (07.11.2026): редкие мох, травы, низкий кустарник и мелкие камни из общих форм
## подлеска (их MultiMesh общие на весь круг — новых узлов и вызовов отрисовки нет). Только там,
## где _rock_shelter: сыро и закрыто; открытая порода остаётся голой.
func _fill_rock_hollow(i: int, j: int, path: int, slope: float, surface: Color, px: float, pz: float) -> void:
	if path == 1 or (path > 0 and not _in_plan(i, j)) or slope > 0.9:
		return
	var origin: Vector2i = world.world_origin if i >= 0 and j >= 0 and i < world.W and j < world.H else Vector2i.ZERO
	var hx := i + origin.x
	var hy := j + origin.y
	var shelter := _rock_shelter(surface, hx, hy)
	if shelter <= 0.02:
		return
	var seed := world.seed_num ^ 7717
	# 16.0: дернина гуще (было 3 места и 0,55): ложбины среди камней зелёные, а не точечные
	for m in (3 if legacy_open else 5):
		if WGRandom.hash2(hx * 8 + m, hy, seed + 1) > shelter * (0.55 if legacy_open else 0.8):
			continue
		var pick := WGRandom.hash2(hx * 8 + m, hy, seed + 2) * float(ROCK_HOLLOW[-1][1])
		if legacy_open: pick *= 2.85 / float(ROCK_HOLLOW[-1][1])
		var choice := 0
		while choice < ROCK_HOLLOW.size() - 1 and pick >= ROCK_HOLLOW[choice][1]: choice += 1
		var kind: int = ROCK_HOLLOW[choice][0]
		var x := (i + 0.1 + 0.8 * WGRandom.hash2(hx * 8 + m, hy, seed + 3)) * TILE
		var z := (j + 0.1 + 0.8 * WGRandom.hash2(hx * 8 + m, hy, seed + 4)) * TILE
		var far: bool = understory[kind].far
		var d := StreamPolicy.distance_to_coverage(Vector2(x, z), Vector2(px, pz), _fill_lead)
		if d > _reach_r(kind, far):
			continue
		var rank := WGRandom.hash2(hx * 8 + m, hy, seed + 8)
		if rank > _keep(d, _full_r(kind, far), _ahead(_reach_r(kind, far))) * _flora_keep(kind):
			continue
		var scale := (0.6 + WGRandom.hash2(hx * 8 + m, hy, seed + 5) * 0.5) * _flora_grow(kind)
		var tint := 0.8 + WGRandom.hash2(hx * 8 + m, hy, seed + 7) * 0.25
		if kind == Understory.BUSH and not legacy_open:
			# 16.1: среди камней куст — стелющийся можжевельник
			_understory_sites.append([kind, x, z, WGRandom.hash2(hx * 8 + m, hy, seed + 6) * TAU, scale * JUNIPER_SPREAD, tint, rank, JUNIPER_HUE, -1, JUNIPER_SQUASH])
		else:
			_understory_sites.append([kind, x, z, WGRandom.hash2(hx * 8 + m, hy, seed + 6) * TAU, scale, tint, rank])


func _in_plan(i: int, j: int) -> bool:
	return i >= 0 and j >= 0 and i < world.W and j < world.H


## 11.6: на полотне путей — препятствия RoadObstacles в радиусе подлеска, тем же размещением, что подстилка
## Выключатель игрока (settings.trail_clutter) действует на вновь подгружаемые участки: уже лежащие остаются, пока не выгрузятся.
func _fill_road(px: float, pz: float) -> void:
	if measure_road_clutter:
		road_clutter_stats.clear()
	if road == null or not settings.trail_clutter:
		return
	var pairs := road.around(px + _fill_lead.x * 0.5, pz + _fill_lead.y * 0.5, maxf(grass_r, under_r) + _fill_lead.length() * 0.5)
	for p in range(0, pairs.size(), 2):
		var o := road.pick(heights, _forest_surface, pairs[p], pairs[p + 1])
		if o.is_empty():
			continue
		var counts := {}
		if measure_road_clutter:
			counts = road_clutter_stats.get(o.kind, {})
			counts.candidates = counts.get("candidates", 0) + 1
			road_clutter_stats[o.kind] = counts
		# 15.0: у препятствия может быть несколько частей (корни от одного ствола), у каждой своя длина и посадка
		for part: Dictionary in o.parts:
			var kind: int = Floor.FIRST + [Floor.BRANCH, Floor.STONES, Floor.MOSS_LOG if o.moss else Floor.LOG, Floor.BOULDER, Floor.ROOT_SPAN][part.kind]
			var outcome: int = RoadPlacement.RANGE
			if StreamPolicy.distance_to_coverage(Vector2(part.x, part.z), Vector2(px, pz), _fill_lead) <= (under_r if understory[kind].far else grass_r):
				outcome = _put_understory(kind, part.x, part.z, part.rot, part.scale, 1.0, o.owner, 0.0, true, part.stretch, part.sink)
			if measure_road_clutter:
				var label: String = RoadPlacement.keys()[outcome]
				counts[label] = counts.get(label, 0) + 1


## on_road — препятствие на полотне (RoadObstacles): дорога ему не помеха, свои проверки места оно прошло.
## stretch — длина вдоль локальной X в долях масштаба (бревно, ветка, корень), sink — насколько утоплено в грунт, м
func _put_understory(kind: int, x: float, z: float, rot: float, scale: float, tint: float = 1.0, owner: int = -1, rank: float = 0.0, on_road := false, stretch := 1.0, sink := 0.0, hue := Color.WHITE, key := -1, squash := 1.0) -> int:
	var entry: Dictionary = understory[kind]
	# 15.0: дальше FAR_FORM_R от центра раскладки - упрощённая форма в своей группе (та же посадка и проверки)
	# 16.0: граница — по качеству растительности (far_form_r)
	var woody := Placement.priority(kind) == 1
	var switch_r := far_form_r * (WOODY_FAR_FORM if woody else 1.0)
	if _far_of.has(kind) and not (legacy_open and woody) and Vector2(x, z).distance_squared_to(_fill_at) > switch_r * switch_r:
		entry = understory[_far_of[kind]]
	if entry.count >= entry.cap:
		fill_capped += 1
		return RoadPlacement.CAPACITY
	var floor_kind := kind - Floor.FIRST
	var local_box: AABB = entry.box
	# Проверка стволов должна видеть ту же длину, что меш и капсула столкновения.
	var object_box := AABB(local_box.position * Vector3(stretch, 1.0, 1.0), local_box.size * Vector3(stretch, 1.0, 1.0))
	var reach := object_box.position.abs().max(object_box.end.abs()) * scale
	var radius := Vector2(reach.x, reach.z).length()
	# 16.0: куртина проверяет у полотна и воды свою сердцевину: края травы склоняются к кромке
	var ground_r := radius * (0.5 if kind in Understory.OPEN_FORMS else 1.0)
	# 16.0: у мест открытых клеток (key = клетка * 8 + место) проверка воды, путей, домов и стволов
	# неизменна — считается один раз (бит «посчитано» и бит «можно»), а не в каждой раскладке.
	var cell := key >> 3
	var bit := 1 << (key & 7)
	if key >= 0 and (_open_valid[cell * 2] & bit) != 0:
		if (_open_valid[cell * 2 + 1] & bit) == 0:
			return RoadPlacement.OBJECT
	else:
		var ok := (on_road or placement.ground_clear(x, z, ground_r)) and placement.objects_clear(x, z, rot, scale, object_box, radius, owner)
		if key >= 0:
			_open_valid[cell * 2] |= bit
			if ok:
				_open_valid[cell * 2 + 1] |= bit
		if not ok:
			return RoadPlacement.OBJECT
		if measure_road_clutter and on_road and owner >= 0 and not placement.objects_clear(x, z, rot, scale, object_box, radius):
			var roots: Dictionary = road_clutter_stats[RoadObstacles.ROOT]
			roots.owner_overlap = roots.get("owner_overlap", 0) + 1
	var pos := Vector3(x, heights.ground_at(x, z) - 0.015 - sink, z)
	var offset: int = entry.count * STRIDE
	var xf := Transform3D(Basis(Vector3.UP, rot).scaled(Vector3.ONE * scale), pos)
	xf.basis.x *= stretch
	xf.basis.y *= squash # 16.1: распластанный куст (можжевельник)
	if kind == Understory.MOSS or (floor_kind >= 0 and floor_kind not in [Floor.SNAG, Floor.STUMP, Floor.BOULDER]):
		# Почвенные детали и валежник следуют склону; сухостой, пни и валуны остаются вертикальными.
		var dx := heights.ground_at(x + 0.3, z) - heights.ground_at(x - 0.3, z)
		var dz := heights.ground_at(x, z + 0.3) - heights.ground_at(x, z - 0.3)
		xf.basis.x.y = (dx * xf.basis.x.x + dz * xf.basis.x.z) / 0.6
		xf.basis.z.y = (dx * xf.basis.z.x + dz * xf.basis.z.z) / 0.6
		if on_road and floor_kind in [Floor.ROOT_SPAN, Floor.LOG, Floor.MOSS_LOG, Floor.BRANCH]:
			match floor_kind:
				Floor.ROOT_SPAN:
					xf = placement.seat_road_span(xf, Vector2(-0.5, 0.5), sink, 0.16, 0.48)
				Floor.BRANCH:
					xf = placement.seat_road_span(xf, Vector2(-1.1, 1.1), sink, 0.23, 0.60)
				_:
					xf = placement.seat_road_span(xf, Vector2(-2.2, 2.1), sink, 0.34, 0.70)
			if xf == Transform3D.IDENTITY:
				return RoadPlacement.TERRAIN
		elif not placement.terrain_fits(xf, local_box, 0.25 if on_road and floor_kind == Floor.STONES else 0.18):
			return RoadPlacement.TERRAIN
	var box: AABB = xf * local_box
	if not placement.details_clear(box):
		return RoadPlacement.DETAIL
	_put_transform(entry.buf, offset, xf)
	entry.buf[offset + 12] = tint * hue.r
	entry.buf[offset + 13] = tint * hue.g
	entry.buf[offset + 14] = tint * hue.b
	entry.buf[offset + 15] = 1.0 - _forest_surface.get_pixel(floori(x / TILE), floori(z / TILE)).r
	entry.buf[offset + 16] = rank
	entry.buf[offset + 17] = WGRandom.hash2(floori(x * 13), floori(z * 11), 73)
	entry.buf[offset + 18] = WGRandom.hash2(floori(x * 7), floori(z * 17), 79)
	var render_box := box.grow(entry.margin * scale)
	entry.low = entry.low.min(render_box.position)
	entry.high = entry.high.max(render_box.end)
	entry.count += 1
	# The roots of one tree fan out from a shared base. Their boxes may overlap.
	if (on_road and floor_kind != Floor.ROOT_SPAN) or Placement.priority(kind) < 2:
		placement.occupy(box.grow(0.03))
	if StreamPolicy.distance_to_coverage(Vector2(x, z), _fill_at, _fill_lead) > OBSTACLE_R:
		return RoadPlacement.VISUAL
	if floor_kind == Floor.LOG or floor_kind == Floor.MOSS_LOG:
		# бревно — капсула вдоль ствола (меш: от -2,2 до 2,1 м по X, толщина 0,23 м), верх ~0,45 м
		var a := xf * Vector3(-2.2, 0.0, 0.0)
		var b := xf * Vector3(2.1, 0.0, 0.07)
		if on_road:
			# Existing capsules, with local height along the seated mesh.
			var pieces := clampi(ceili(absf(a.y - b.y) / 0.09), 1, 8)
			for j in pieces:
				var start := a.lerp(b, float(j) / pieces)
				var end := a.lerp(b, float(j + 1) / pieces)
				var center_y := (start.y + end.y) * 0.5
				var taper := lerpf(1.0, 0.72, (j + 0.5) / pieces)
				_obstacles_next.append_array([start.x, start.z, end.x, end.z, 0.22 * scale * taper, center_y, center_y + 0.44 * scale * taper])
		else:
			_obstacles_next.append_array([a.x, a.z, b.x, b.z, 0.2 * scale, pos.y, pos.y + 0.42 * scale])
	elif floor_kind == Floor.SNAG:
		_obstacles_next.append_array([x, z, x, z, 0.16 * scale, pos.y, INF])
	elif floor_kind == Floor.STUMP: # невысокий, перепрыгивается
		_obstacles_next.append_array([x, z, x, z, 0.3 * scale, pos.y, pos.y + 0.45 * scale])
	elif floor_kind == Floor.BOULDER:
		_obstacles_next.append_array([x, z, x, z, 0.75 * scale, pos.y, pos.y + 0.95 * scale])
	elif on_road and floor_kind in [Floor.BRANCH, Floor.STONES, Floor.ROOT_SPAN]: # не держат, а встряхивают колесо
		var bump_kind := RoadObstacles.BRANCH if floor_kind == Floor.BRANCH else (RoadObstacles.ROOT if floor_kind == Floor.ROOT_SPAN else RoadObstacles.STONES)
		var contact := RoadObstacles.bump(bump_kind, xf, scale, heights)
		_bumps_next.append_array(contact)
		return RoadPlacement.VISUAL if contact.is_empty() else RoadPlacement.CONTACT
	else:
		return RoadPlacement.VISUAL
	return RoadPlacement.CONTACT


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


static func _without_region(values: PackedFloat32Array, stride: int, box: Rect2) -> PackedFloat32Array:
	var kept := PackedFloat32Array()
	for at in range(0, values.size(), stride):
		var a := Vector2(values[at], values[at + 1])
		var b := Vector2(values[at + 2], values[at + 3])
		if box.intersects(Rect2(a.min(b), a.max(b) - a.min(b)).grow(values[at + 4])): continue
		kept.append_array(values.slice(at, at + stride))
	return kept
