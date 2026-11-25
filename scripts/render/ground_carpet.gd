class_name GroundCarpet
extends RefCounted
## 14.11.2026: дернина — плотный ковёр мелкой травы вокруг и впереди игрока.
##
## Отдельный от травы и подлеска слой со своим лёгким конвейером. Первый вариант (внутри фоновой раскладки травы)
## не успевал на скорости: раскладка считает весь радиус заново каждые 8 м и занимает секунды, а дернина видна
## только в 15–30 м, поэтому игрок обгонял покрытие и ковёр появлялся лишь при торможении.
##
## Здесь:
## - земля делится на плитки 4 м (клетки плана); у плитки — готовые куски буферов MultiMesh по видам ковра
##   (куртинки на сетке ~0,45 м с дрожанием, высота земли, наклон по склону, цвет). Плитка считается один раз
##   и хранится в кэше;
## - фоновая задача только дополняет кэш недостающими плитками капсулы «игрок — упреждение» и склеивает буферы
##   из готовых кусков (десятки мс даже на скорости, число новых плиток зависит от пути, а не от радиуса);
## - упреждение берётся от своей задержки (она короткая), а не от задержки раскладки травы;
## - кэш сбрасывается при смене настроек и стирается там, где перестроили землю (refresh).
## Куртинки раскладываются с запасом MARGIN за видимой дальностью; шейдер растворяет край, поэтому
## новые куртинки появляются в невидимой полосе.
##
## Виды (Models.CARPET_*): луговая, сухая соломенная (сухие поляны и склоны), теневая (под пологом: широкие
## листья и мох) и цветы пятнами (в биомах с цветами). Вид выбирается по тем же данным, что густота травы.
## У каждого вида две формы: полная вблизи и дальняя (только травинки, которые шейдер и так оставляет вдали —
## смена формы не видна). Плитка целиком ближняя или дальняя, по расстоянию до пути игрока.
##
## Густота: доля занятых ячеек от тех же данных, что у травы (влага, свет, уклон, полог, сообщество), и пятна
## голой земли. Не рисуется на воде, на полотне дорог и троп (RoadRefinement.weight_at), на скале без укрытия.

const StreamPolicy := preload("res://scripts/render/vegetation_stream_policy.gd")
const Snapshots := preload("res://scripts/render/vegetation_snapshots.gd")
const ByteLru := preload("res://scripts/core/byte_lru.gd")
const TILE := GameConfig.TILE
const STRIDE := 20          # преобразование (12), цвет (4), custom (4) — как у травы
const SUB := 9              # ячеек на сторону плитки: 4 м / 9 = 0,44 м
const CAP := 36000          # экземпляров во всех MultiMesh вместе
const FADE := 0.35          # полоса растворения, доля дальности
const NEAR_SHARE := 0.5     # доля дальности, где стоит полная форма и травинки ещё не поредели до дальней
const VERGE_MASK := 0.22   # маска полотна (RoadRefinement.weight_at), до которой дернина заходит на обочину; покрытие видно с ~0,3
const MEADOW_MIDDLE := 0.24 # доля полуширины травяной колеи: середина между колеями (колеи на 0,47, RoadBump.RUT_AT)
const EXTRA_REACH := Vector3(2.0, 1.18, 0.85) # вперёд, вбок, назад; те же оси в ground_carpet.gdshaderinc
const EXTRA_DETAIL := Vector3(1.25, 0.59, 0.425)
const EXTRA_REAR_KEEP := 0.8
const TURN_COS := 0.9945    # пересборка при повороте примерно на 6°
const MARGIN := 5.0         # запас раскладки за видимой дальностью, м
const STEP := 2.5           # на сколько метров сдвигается игрок до новой склейки
## 15.11.2026: плиток на сторону квадрата отсечения (16 м). MultiMesh отсекается камерой только целиком, а ковёр
## лежит вокруг игрока: одним набором на вид GPU обсчитывал вершины всех куртинок, и за спиной тоже (на стенде луга
## около 2 мс из 5,5 — ковёр это 1 млн треугольников). Квадратами по 16 м в кадр попадает около половины вершин;
## по 8 м — чуть меньше, но втрое больше вызовов отрисовки, по 32 м — почти без отсечения
const SECTOR := 4
const MIN_CAPACITY := 64
## 19.11.2026: было 4 — при сотне изменившихся квадратов на склейку выкладка шла секунды, следующая склейка ждала её,
## и ковёр отставал всё сильнее. Квадрат выкладывается за десятки мкс; порцию держит срок UPLOAD_US
const SECTORS_PER_SLICE := 32
## 19.11.2026: своя доля кадра ковра на выкладку, мс×1000. Не из общего срока StreamFrameBudget и не по очереди с
## рельефом и деревьями: квадрат стоит ~0,1 мс (замер carpet_ride_probe), за кадр уходит до 15 квадратов, склейка
## выкладывается за 2–5 кадров. Прежде (900 мкс из общего срока, 4 квадрата, ~раз в 3–6 кадров) выкладка склейки
## тянулась 1–2 с, следующая склейка ждала её, и на 14 м/с ковёр впереди появлялся в 10–20 м от игрока.
const UPLOAD_US := 1500
## 19.11.2026: обязательная порция. Квадрат, который виден или станет виден до следующей склейки, выкладывается
## каждый кадр по одному — без доли общего срока кадра (StreamFrameBudget) и после него. Общий срок делят рельеф,
## вода, деревья и области; прежде ковёр получал его примерно раз в шесть кадров, на скорости очередь росла
## быстрее, чем выкладывалась, и ковёр появлялся рывками или только после остановки (регрессия 19.11, и раньше
## такая же после правок «пиков кадра»). Один квадрат — около 0,1–0,3 мс; дальние квадраты ждут бюджет, как прежде.
## 19.11.2026: упреждение ковра не длиннее пути за LEAD_MAX_S. Задержка склейки росла (новых плиток больше →
## склейка дольше → упреждение длиннее → ещё больше плиток) до 2 с и 80 м впереди, и ковёр у игрока не успевал.
const LEAD_MAX_S := 1.2
## 19.11.2026: новых плиток за одну склейку не больше JOB_TILES (ближние к пути — первыми), остальные — в следующей
## склейке сразу же; считаются они группой на BUILD_THREADS потоках пула. Плитка в GDScript стоит ~4,5 мс, на 4 потоках
## ~1,7 мс (больше потоков — медленнее: потоки GDScript мешают друг другу). Склейка на сотню плиток шла секунду и
## больше, и всё это время ничего нового не выкладывалось; теперь склейка ~0,1 с при любой скорости.
const JOB_TILES := 48
const BUILD_THREADS := 2
const URGENT_PAD := 6.0     # м за видимой дальностью, ещё обязательные (запас на ход до следующей склейки)
## Ветер и свет вида: [sway, flutter, sway_speed, ao, glow, base_shade] (см. VegetationLayer._wind_mat) и насколько трава расступается у игрока, м
const WIND := [
	[[0.05, 0.014, 1.7, 0.75, 0.4, 0.7], 0.12],
	[[0.08, 0.02, 1.9, 0.85, 0.45, 0.7], 0.14],
	[[0.02, 0.008, 1.3, 0.7, 0.3, 0.75], 0.05],
	[[0.06, 0.02, 1.6, 0.9, 0.3, 0.75], 0.1],
	[[0.0, 0.0, 1.0, 1.0, 0.0], 0.0], # камни и комья у полотна: не качаются и не расступаются
	[[0.0, 0.0, 1.0, 0.90, 0.0, 0.80], 0.0], # мох
	[[0.014, 0.005, 1.2, 0.83, 0.17, 0.80], 0.025],
	[[0.018, 0.006, 1.2, 0.80, 0.16, 0.78], 0.035],
	[[0.035, 0.012, 1.5, 0.84, 0.26, 0.76], 0.075],
]
## 15.11.2026: россыпь у дорожного полотна по покрытию (RoadSurface): доля занятых ячеек на обочине и кромке, на самом полотне.
## Гравий и камень выбрасывают щебень к краям и оставляют его между колеями; грунтовка и тропы — редкие комья; песок чистый.
## 15.11 (4): на обочине было почти по камню на ячейку 0,57 м — сплошная полоса щебня. Теперь втрое реже и кучками
## (stone_clump): осыпь у кромки местами, между ними чистая трава.
const STONE_CHANCE := [Vector2.ZERO, Vector2(0.26, 0.16), Vector2(0.12, 0.06), Vector2(0.05, 0.0), Vector2(0.32, 0.3),
	Vector2.ZERO, Vector2(0.08, 0.04), Vector2(0.05, 0.0)]
const STONE_SUB := 7        # ячеек россыпи на сторону плитки: 4 м / 7 = 0,57 м
## Венчики цветов: белый, жёлтый, лиловый, розовый
const PETALS := [Color(1.0, 1.0, 0.94), Color(1.0, 0.84, 0.2), Color(0.66, 0.52, 0.98), Color(1.0, 0.6, 0.76)]

var world: WorldData
var heights: Heightfield
var layer: Node3D            # VegetationLayer: общие функции множителя травы и снимок леса
var forest: Image
var layers: Array = []       # вид × 2 + дальняя: {mesh, mat, tris, n, name, nodes: квадрат -> {node, mm}, pool}
var stream := StreamPolicy.new()

## Настройки игрока (GameSettings.CARPET_DENSITY / CARPET_RANGE) и качество растительности
var density := 1.0           # множитель доли занятых ячеек
var stones := 1.0            # доля россыпи камней у дорог (GameSettings.ROAD_QUALITY)
var base_range := 22.0       # м, видимость целиком до base_range × (1 − FADE), растворение до base_range
var directional := false
var grass_keep := 1.0        # flora.grass
var grow := 1.0              # flora.grow
var detail := 1.0            # flora.detail

var _expedition := false
var _kinds := Models.CARPET_MOSS # прежние пять групп в исходном мире
var count := 0               # экземпляров на экране (замер)
var capped := 0              # сколько раз склейка упёрлась в CAP
var last_job_ms := 0.0
var max_job_ms := 0.0
var tiles_built := 0         # плиток, посчитанных с запуска (замер)
var job_parts := {}          # 19.11.2026: части последней склейки, мс — очередь пула, новые плитки, публикация (замер)
var job_parts_max := {}
var present_us := 0          # замер: время выкладки квадратов на GPU и их число с запуска
var present_sectors := 0

var _tiles := {}             # Vector2i -> { id, full, rear, bytes }
var _tile_y := {}            # Vector2i -> Vector2(мин. и макс. высота)
var _tile_id := 0
var _tile_bytes := 0
var cpu_budget: RefCounted
var _shown := {}             # квадрат и вид -> опубликованные плитки и история обеих форм
var _cleanup_at := INF
var _task := -1
var _last := Vector2.INF
var _last_lead := Vector2.ZERO
var _last_forward := Vector2.UP
var _published_forward := Vector2.INF
var _started_clock := 0.0
var _out: Array = []         # изменившиеся пары форм, ближайшие в конце
var _reset := false
var _cuts: Array[Rect2] = []
var _road_revision := -1
var _job_started := 0
var _incomplete := false     # прошлая склейка отложила часть новых плиток: следующая — сразу, без ожидания шага
var _enabled := true
var use_native_tiles := true
var _ride: Object = null
var _ride_rev := -1
var _veg_cfg: WorldVegetationConfig = null
var _atm_cfg: WorldAtmosphereConfig = null


func setup(layer_node: Node3D, w: WorldData, h: Heightfield, forest_image: Image) -> void:
	layer = layer_node
	world = w
	heights = h
	forest = forest_image
	_veg_cfg = WorldTemplate.vegetation_config(w.template_id)
	_atm_cfg = WorldTemplate.atmosphere_config(w.template_id)
	_expedition = w.template_id == WorldTemplate.EXPEDITION_ID
	_kinds = Models.CARPET_KINDS if _expedition else Models.CARPET_MOSS
	for kind in _kinds:
		var near_mesh := Models.build_carpet_mesh(kind, false)
		var mat: ShaderMaterial = VegetationLayer._wind_mat(VegetationLayer.SHADER, WIND[kind][0], true)
		mat.set_shader_parameter("height", near_mesh.get_aabb().end.y)
		mat.set_shader_parameter("grass_variation", kind != Models.CARPET_STONES and kind != Models.CARPET_MOSS)
		mat.set_shader_parameter("trample", WIND[kind][1])
		for far in 2:
			var mesh := near_mesh if far == 0 else Models.build_carpet_mesh(kind, true)
			layers.append({mesh = mesh, mat = mat, n = 0, tris = mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX].size() / 3,
				name = "GroundCarpet%d%s" % [kind, "Far" if far == 1 else ""], nodes = {}, pool = []})
	apply_ranges()


## Узел квадрата: из запаса слоя или новый
func _sector_node(entry: Dictionary) -> Dictionary:
	if not entry.pool.is_empty():
		var kept: Dictionary = entry.pool.pop_back()
		kept.node.visible = true
		return kept
	var node := MultiMeshInstance3D.new()
	node.name = entry.name
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.use_custom_data = true
	mm.mesh = entry.mesh
	mm.instance_count = MIN_CAPACITY
	mm.visible_instance_count = 0
	node.multimesh = mm
	node.material_override = entry.mat
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	node.lod_bias = 0.6
	layer.add_child(node)
	return {node = node, mm = mm}


## Все квадраты слоя убрать в запас (спрятаны, без экземпляров)
static func _hide_layer(entry: Dictionary) -> void:
	for key: Vector2i in entry.nodes:
		_stash(entry, entry.nodes[key])
	entry.nodes.clear()
	entry.n = 0


static func _stash(entry: Dictionary, part: Dictionary) -> void:
	part.mm.visible_instance_count = 0
	part.node.visible = false
	entry.pool.append(part)


## Дальность видимости, м
func reach() -> float:
	return base_range * detail


## Настройки или качество изменились (на паузе): кэш плиток устарел.
func configure(density_scale: float, range_m: float, flora: Dictionary, use_direction := false, stone_share := 1.0) -> void:
	var changed := not is_equal_approx(density, density_scale) or not is_equal_approx(base_range, range_m) or not is_equal_approx(stones, stone_share) \
		or not is_equal_approx(grass_keep, flora.grass) or not is_equal_approx(grow, flora.grow)
	density = density_scale
	stones = stone_share
	base_range = range_m
	directional = use_direction
	grass_keep = flora.grass
	grow = flora.grow
	detail = flora.detail
	_enabled = density_scale > 0.0 and range_m > 0.0
	if changed:
		_reset = true
	apply_ranges()
	if not _enabled:
		for entry: Dictionary in layers:
			_hide_layer(entry)
		_shown.clear()
		_cleanup_at = INF
		count = 0
	_last = Vector2.INF


## Границы растворения в шейдерах травы и земли
func apply_ranges() -> void:
	var r := reach() if _enabled else 0.0
	for entry: Dictionary in layers:
		var mat: ShaderMaterial = entry.mat
		mat.set_shader_parameter("fade_far", maxf(r, 0.1))
		mat.set_shader_parameter("fade_len", maxf(r * FADE, 0.1))
		mat.set_shader_parameter("directional_carpet", directional)
		# Дальше 3,5 м травинок в куртинке меньше; к NEAR_SHARE дальности остаётся доля CARPET_FAR_KEEP —
		# ровно те травинки, из которых собрана дальняя форма
		mat.set_shader_parameter("detail_full", 3.5 * detail)
		mat.set_shader_parameter("detail_far", r if directional and _enabled else maxf(r * NEAR_SHARE, 4.0))
		mat.set_shader_parameter("detail_keep", Models.CARPET_FAR_KEEP)
	# Тень дернины на дёрне материала земли (terrain.gdshader) — та же дальность и полоса
	RenderingServer.global_shader_parameter_set("ground_carpet", Vector2(r, maxf(r * FADE, 0.1)))
	_publish_forward(_view_forward() if directional else Vector2.ZERO, true)


func busy() -> bool:
	return _task != -1 and not WorkerThreadPool.is_task_completed(_task)


func finish() -> void:
	if _task != -1:
		WorkerThreadPool.wait_for_task_completion(_task)
		_task = -1
	_out.clear()


func _account_tile_bytes(delta: int) -> void:
	if delta == 0:
		return
	_tile_bytes = maxi(0, _tile_bytes + delta)
	if cpu_budget == null:
		return
	if delta > 0:
		cpu_budget.reserve(delta)
	else:
		cpu_budget.release(-delta)


func _clear_tiles() -> void:
	_tiles.clear()
	_tile_y.clear()
	_account_tile_bytes(-_tile_bytes)


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE and _tile_bytes > 0:
		_account_tile_bytes(-_tile_bytes)


func release() -> void:
	finish()
	_clear_tiles()
	_ride = null
	_ride_rev = -1
	RenderingServer.global_shader_parameter_set("ground_carpet", Vector2(0.0, 1.0))
	_publish_forward(Vector2.ZERO, true)


## Земля в rect (клетки плана) перестроена: плитки в ней устарели.
func invalidate(rect: Rect2i) -> void:
	_cuts.append(Rect2(Vector2(rect.position) * TILE, Vector2(rect.size) * TILE).grow(TILE))
	_last = Vector2.INF


## Сброс на паузе (смена мира, дальности): без задачи.
func clear() -> void:
	finish()
	_clear_tiles()
	_ride = null
	_ride_rev = -1
	_shown.clear()
	_cleanup_at = INF
	_reset = false
	_last = Vector2.INF
	count = 0
	for entry: Dictionary in layers:
		_hide_layer(entry)


## Каждый кадр из VegetationLayer.update. Не блокирует: считает фоновая задача, главный поток только
## передаёт готовые буферы.
func update(p: Vector2, dt: float, road_revision: int, may_work := true, may_upload := true,
		deadline_usec := 0, fade_clock := 0.0) -> bool:
	stream.sample(p, maxf(dt, 0.000001), false)
	if fade_clock == 0.0:
		fade_clock = stream.clock
	if not _enabled:
		return false
	var forward := _view_forward() if directional else Vector2.UP
	if directional:
		_publish_forward(forward)
	# 19.11.2026: опрос задачи, обязательная порция и запуск следующей склейки идут и без доли общего срока
	# (may_work/may_upload): они дешёвые, а без них ковёр стоит, пока кадр занят рельефом и деревьями
	if _task != -1:
		if not WorkerThreadPool.is_task_completed(_task):
			return false
		WorkerThreadPool.wait_for_task_completion(_task)
		_task = -1
	if not _out.is_empty():
		if _last == Vector2.INF or road_revision != _road_revision:
			_out.clear()
		else:
			# своя доля кадра (UPLOAD_US), независимо от общего срока и очереди групп подгрузки (may_work, may_upload,
			# deadline_usec больше не ограничивают ковёр). 19.11.2026: выкладка возвращается честно (true) — порцию это
			# не урезает, но координатор не кладёт в тот же кадр меш рельефа, воды или дальней местности
			var uploaded := _present_next(fade_clock, Time.get_ticks_usec() + UPLOAD_US, p)
			if uploaded and _out.is_empty():
				stream.record_latency(maxf(last_job_ms / 1000.0, stream.clock - _started_clock))
			return uploaded
	var lead := stream.lead().limit_length(stream.velocity.length() * LEAD_MAX_S)
	if _last != Vector2.INF and p.distance_to(_last) < STEP and lead.distance_to(_last_lead) < STEP * 2.0 \
			and forward.dot(_last_forward) >= TURN_COS and road_revision == _road_revision and fade_clock < _cleanup_at 			and not _incomplete:
		return false
	_last_forward = forward
	_begin(p, lead, road_revision)
	_task = WorkerThreadPool.add_task(_job.bind(p, lead, forward, fade_clock, false), true, "Дернина")
	return false


## Сразу, на месте (старт, возрождение): ковёр готов в том же кадре. Дальше — update.
func build_now(p: Vector2, road_revision: int) -> void:
	finish()
	var build := prepare_arrival(p, road_revision, _view_forward())
	if build.is_valid():
		build.call()
		present_arrival(0)
		finish_arrival()


## Возвращает чисто фоновую часть. Узлы и шейдеры обновляются на главном потоке.
func prepare_arrival(p: Vector2, road_revision: int, forward: Vector2) -> Callable:
	stream.sample(p, 0.0, true)
	if not _enabled:
		return Callable()
	_last_forward = forward if directional else Vector2.UP
	_begin(p, Vector2.ZERO, road_revision)
	return _job.bind(p, Vector2.ZERO, _last_forward, stream.clock, true)


func present_arrival(deadline_usec: int) -> bool:
	_present_next(stream.clock, deadline_usec)
	return _out.is_empty()


func finish_arrival() -> void:
	if directional:
		_publish_forward(_last_forward, true)


func _publish_forward(forward: Vector2, force := false) -> void:
	if force or forward != _published_forward:
		_published_forward = forward
		RenderingServer.global_shader_parameter_set("ground_carpet_forward", forward)


func _view_forward() -> Vector2:
	var camera := layer.get_viewport().get_camera_3d()
	if camera != null:
		var heading := Vector2(-camera.global_basis.z.x, -camera.global_basis.z.z)
		if heading.length_squared() > 0.0001:
			return heading.normalized()
	return _last_forward


## Расстояние в профиле с упреждением. На стыке полуэллипсов у отрезка меняется масштаб.
static func _profile_coverage(start: Vector2, end: Vector2, axes: Vector3) -> float:
	var a := Vector2(start.x / (axes.x if start.x >= 0.0 else axes.z), start.y / axes.y)
	var b := Vector2(end.x / (axes.x if end.x >= 0.0 else axes.z), end.y / axes.y)
	if start.x * end.x < 0.0:
		var seam := Vector2(0.0, lerpf(a.y, b.y, start.x / (start.x - end.x)))
		return minf(StreamPolicy.distance_to_coverage(Vector2.ZERO, a, seam - a),
			StreamPolicy.distance_to_coverage(Vector2.ZERO, seam, b - seam))
	return StreamPolicy.distance_to_coverage(Vector2.ZERO, a, b - a)


## Замеры и проверки стенда: точки оснований всех куртинок на экране и число их треугольников
func positions() -> PackedVector3Array:
	var out := PackedVector3Array()
	for entry: Dictionary in layers:
		for key: Vector2i in entry.nodes:
			var mm: MultiMesh = entry.nodes[key].mm
			var live: PackedFloat32Array = mm.buffer
			for n: int in mm.visible_instance_count:
				out.append(Vector3(live[n * STRIDE + 3], live[n * STRIDE + 7], live[n * STRIDE + 11]))
	return out


func triangles() -> int:
	var total := 0
	for entry: Dictionary in layers:
		total += entry.n * entry.tris
	return total


func kind_counts() -> Array:
	var out := []
	for entry: Dictionary in layers:
		out.append(entry.n)
	return out


func _begin(p: Vector2, lead: Vector2, road_revision: int) -> void:
	# A committed region already supplies its exact changed rectangle. A revision
	# without a rectangle still invalidates everything.
	if _reset or (road_revision != _road_revision and _cuts.is_empty()):
		_clear_tiles()
		_reset = false
	_road_revision = road_revision
	if not _cuts.is_empty():
		var freed_bytes := 0
		for key: Vector2i in _tiles.keys():
			var box := Rect2(Vector2(key) * TILE, Vector2.ONE * TILE)
			for cut: Rect2 in _cuts:
				if cut.intersects(box):
					freed_bytes += int(_tiles[key].get("bytes", 0))
					_tiles.erase(key)
					_tile_y.erase(key)
					break
		_account_tile_bytes(-freed_bytes)
		_cuts.clear()
	_last = p
	_last_lead = lead
	_started_clock = stream.clock
	_job_started = Time.get_ticks_usec()
	if use_native_tiles and heights != null and (_ride == null or _ride_rev != heights._ground_rev):
		_ride = heights.ride_snapshot(true)
		_ride_rev = heights._ground_rev


## Фоновая задача: плитки капсулы, недостающие досчитываются, буферы склеиваются из кусков.
func _job(p: Vector2, lead: Vector2, forward: Vector2, fade_clock: float, immediate: bool) -> void:
	var job_began := Time.get_ticks_usec()
	var built_before := tiles_built
	var build_us := 0
	var r := reach()
	var reach_all := r * (EXTRA_REACH.x if directional else 1.0) + MARGIN
	var coverage_lead := Vector2(lead.dot(forward), forward.cross(lead))
	var tile_pad := TILE * 0.72
	var fade_axes := EXTRA_REACH * r + Vector3.ONE * (MARGIN + tile_pad)
	# Геометрию упрощаем после поредения в шейдере, с запасом на размер плитки и движение.
	var detail_axes := EXTRA_DETAIL * (r * 1.12) + Vector3.ONE * (STEP + tile_pad + 1.0)
	# Плитка дальняя, если до следующей склейки ни одна её куртинка не окажется ближе границы поредения
	var far_from := r * NEAR_SHARE + STEP + 1.0 + TILE * 0.72
	var lo := p.min(p + lead) / TILE - Vector2.ONE * (reach_all / TILE + 1.0)
	var hi := p.max(p + lead) / TILE + Vector2.ONE * (reach_all / TILE + 1.0)
	var need: Array = []
	for j in range(maxi(0, floori(lo.y)), mini(world.H - 1, ceili(hi.y)) + 1):
		for i in range(maxi(0, floori(lo.x)), mini(world.W - 1, ceili(hi.x)) + 1):
			var offset := Vector2(i + 0.5, j + 0.5) * TILE - p
			var d := StreamPolicy.distance_to_coverage(offset, Vector2.ZERO, lead)
			var visible := d <= reach_all + TILE * 0.72
			var far := d >= far_from
			if directional:
				var start := Vector2(offset.dot(forward), forward.cross(offset))
				var end := start - coverage_lead
				visible = _profile_coverage(start, end, fade_axes) <= 1.0
				far = visible and _profile_coverage(start, end, detail_axes) >= 1.0
			if visible:
				need.append([d, i, j, far, directional and offset.dot(forward) < -tile_pad])
	need.sort_custom(func(a: Array, b: Array) -> bool: return a[0] < b[0])
	var missing: Array[Vector2i] = []
	for entry: Array in need:
		var key := Vector2i(entry[1], entry[2])
		if not _tiles.has(key):
			missing.append(key)
			if missing.size() >= JOB_TILES and not immediate:
				break
	if not missing.is_empty():
		var build_began := Time.get_ticks_usec()
		var built: Array = []
		built.resize(missing.size())
		var group := WorkerThreadPool.add_group_task(func(index: int) -> void:
			built[index] = _build_tile(missing[index].x, missing[index].y), missing.size(), BUILD_THREADS, true, "Дернина: плитки")
		WorkerThreadPool.wait_for_group_task_completion(group)
		var added_bytes := 0
		for index in missing.size():
			var result: Dictionary = built[index]
			var tile_bytes := ByteLru.size_of(result.parts)
			_tile_id += 1
			_tiles[missing[index]] = {id = _tile_id, full = result.parts, rear = [], bytes = tile_bytes}
			_tile_y[missing[index]] = result.y
			tiles_built += 1
			added_bytes += tile_bytes
		_account_tile_bytes(added_bytes)
		build_us += Time.get_ticks_usec() - build_began
	var outs: Array = []        # слой -> квадрат -> набор плиток
	for n in _kinds * 2:
		outs.append({})
	var total := 0
	var used := {}
	var overflow := false
	_incomplete = false
	for entry: Array in need:
		var key := Vector2i(entry[1], entry[2])
		if not _tiles.has(key):
			_incomplete = true  # плитка — в следующей склейке
			continue
		used[key] = true
		var tile := _cached_tile(key, entry[4])
		var parts: Array = tile.rear if entry[4] else tile.full
		if parts.is_empty():
			continue
		var far := 1 if entry[3] else 0
		var sector := Vector2i(key.x / SECTOR, key.y / SECTOR)
		var y: Vector2 = _tile_y[key]
		var tile_low := Vector3(key.x * TILE, y.x, key.y * TILE)
		var tile_high := Vector3((key.x + 1) * TILE, y.y, (key.y + 1) * TILE)
		for kind in _kinds:
			var part: PackedFloat32Array = parts[kind]
			var m := part.size() / STRIDE
			if m == 0:
				continue
			if total + m > CAP:
				overflow = true
				continue
			var buckets: Dictionary = outs[kind * 2 + far]
			if not buckets.has(sector):
				buckets[sector] = {parts = [], ids = [], bounds = AABB(tile_low, tile_high - tile_low)}
			var bucket: Dictionary = buckets[sector]
			bucket.parts.append(part)
			bucket.ids.append(tile.id * 2 + int(entry[4]))
			bucket.bounds = (bucket.bounds as AABB).merge(AABB(tile_low, tile_high - tile_low))
			total += m
	if overflow:
		capped += 1
	# Кэш: плитки далеко за капсулой уходят (запас на возврат назад)
	var keep_d := reach_all + TILE * 0.72 + 28.0
	var evicted_bytes := 0
	for key: Vector2i in _tiles.keys():
		if used.has(key):
			continue
		if StreamPolicy.distance_to_coverage(Vector2(key.x + 0.5, key.y + 0.5) * TILE, p, lead) > keep_d:
			evicted_bytes += int(_tiles[key].get("bytes", 0))
			_tiles.erase(key)
			_tile_y.erase(key)
	_account_tile_bytes(-evicted_bytes)
	var publish_began := Time.get_ticks_usec()
	_prepare_publication(outs, p, lead, fade_clock, immediate)
	var ended := Time.get_ticks_usec()
	job_parts = {queue = (job_began - _job_started) / 1000.0, tiles = tiles_built - built_before, build = build_us / 1000.0,
		gather = (publish_began - job_began - build_us) / 1000.0, publish = (ended - publish_began) / 1000.0, pairs = _out.size(), need = need.size()}
	for k: String in job_parts:
		job_parts_max[k] = maxf(job_parts_max.get(k, 0.0), job_parts[k])
	last_job_ms = (Time.get_ticks_usec() - _job_started) / 1000.0
	max_job_ms = maxf(max_job_ms, last_job_ms)


func _cached_tile(key: Vector2i, rear: bool) -> Dictionary:
	if not _tiles.has(key):
		var result := _build_tile(key.x, key.y)
		var tile_bytes := ByteLru.size_of(result.parts)
		_tile_id += 1
		_tiles[key] = {id = _tile_id, full = result.parts, rear = [], bytes = tile_bytes}
		_tile_y[key] = result.y
		tiles_built += 1
		_account_tile_bytes(tile_bytes)
	var tile: Dictionary = _tiles[key]
	if rear and tile.rear.is_empty():
		for part: PackedFloat32Array in tile.full:
			tile.rear.append(_thin_rear(part))
		var rear_bytes := ByteLru.size_of(tile.rear)
		tile.bytes = int(tile.get("bytes", 0)) + rear_bytes
		_account_tile_bytes(rear_bytes)
	return tile


## Постоянная выборка по зерну куртинки: сзади меньше экземпляров в буфере MultiMesh.
static func _thin_rear(part: PackedFloat32Array) -> PackedFloat32Array:
	var kept := PackedFloat32Array()
	for offset in range(0, part.size(), STRIDE):
		if part[offset + 17] < EXTRA_REAR_KEEP:
			kept.append_array(part.slice(offset, offset + STRIDE))
	return kept


func _prepare_publication(buckets: Array, p: Vector2, lead: Vector2, now: float, immediate: bool) -> void:
	var pairs := _shown.duplicate()
	for n in buckets.size():
		for sector: Vector2i in buckets[n]:
			var key := Vector3i(sector.x, sector.y, n / 2)
			if not pairs.has(key):
				pairs[key] = {ids = [[], []], history = Snapshots.new()}
	var queue: Array = []
	for key: Vector3i in pairs:
		var sector := Vector2i(key.x, key.y)
		var n := key.z * 2
		var pair: Dictionary = pairs[key]
		var near: Dictionary = buckets[n].get(sector, {})
		var far: Dictionary = buckets[n + 1].get(sector, {})
		var ids := [near.get("ids", []), far.get("ids", [])]
		ids[0].sort()
		ids[1].sort()
		var history: Snapshots = pair.history
		if not immediate and ids == pair.ids and not history.cleanup_due(now):
			continue
		var sources := [_join_tiles(near), _join_tiles(far)]
		var frames: Array[Dictionary] = []
		for lod in 2:
			var bucket: Dictionary = near if lod == 0 else far
			var data: PackedFloat32Array = sources[lod]
			var peer: PackedFloat32Array = sources[1 - lod]
			var other := {}
			if not immediate and not peer.is_empty():
				other = history.form_history(1 - lod, peer, peer.size() / STRIDE)
			elif not immediate and history.shown.get(1 - lod, 0) > 0 and not data.is_empty():
				other = history.form_history(1 - lod, peer, 0)
			var bounds: AABB = bucket.get("bounds", AABB())
			if not data.is_empty():
				bounds = bounds.grow(0.9)
			var frame := history.prepare(lod, data, data.size() / STRIDE, bounds, 0.9, now, immediate, false, other)
			var capacity := MIN_CAPACITY
			while capacity < frame.count:
				capacity *= 2
			var previous: PackedFloat32Array = history.displayed.get(lod, PackedFloat32Array())
			var old_capacity := previous.size() / STRIDE
			if old_capacity >= frame.count and old_capacity <= maxi(MIN_CAPACITY, frame.count * 4):
				capacity = maxi(MIN_CAPACITY, old_capacity)
			frame.buffer.resize(capacity * STRIDE if frame.count > 0 else 0)
			frames.append(frame)
		var center := (Vector2(sector) + Vector2.ONE * 0.5) * (SECTOR * TILE)
		# Prefer additions along the rider's path. Expired tails outside the new coverage can wait.
		var priority := INF if near.is_empty() and far.is_empty() else (
			StreamPolicy.distance_to_coverage(center, p, lead) + center.distance_to(p) * 0.25)
		queue.append({key = key, ids = ids, history = history, frames = frames, priority = priority})
	queue.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a.priority > b.priority)
	_out = queue


static func _join_tiles(bucket: Dictionary) -> PackedFloat32Array:
	var buffer := PackedFloat32Array()
	for part: PackedFloat32Array in bucket.get("parts", []):
		buffer.append_array(part)
	return buffer


## deadline_usec: 0 — всё сразу; > 0 — порция до срока; < 0 — только обязательная. Квадрат в видимой дальности от
## urgent_from (игрок) выкладывается и после срока — один за вызов
func _present_next(now: float, deadline_usec := 0, urgent_from := Vector2.INF) -> bool:
	var sectors_done := 0
	while not _out.is_empty():
		if deadline_usec != 0 and (sectors_done >= SECTORS_PER_SLICE or Time.get_ticks_usec() >= deadline_usec):
			if sectors_done > 0 or not _urgent(_out.back().key, urgent_from):
				return sectors_done > 0
		var pair_began := Time.get_ticks_usec()
		var pair: Dictionary = _out.pop_back()
		var key: Vector3i = pair.key
		var sector := Vector2i(key.x, key.y)
		var history: Snapshots = pair.history
		for lod in 2:
			var frame := history.commit(lod, pair.frames[lod], now)
			_present_sector(key.z * 2 + lod, sector, frame)
		present_us += Time.get_ticks_usec() - pair_began
		present_sectors += 1
		if history.shown[0] + history.shown[1] == 0:
			_shown.erase(key)
		else:
			_shown[key] = {ids = pair.ids, history = history}
			for expires: float in history.deadlines.values():
				if expires > 0.0:
					_cleanup_at = minf(_cleanup_at, expires)
		sectors_done += 1
	_cleanup_at = INF
	for pair: Dictionary in _shown.values():
		for expires: float in pair.history.deadlines.values():
			if expires > 0.0:
				_cleanup_at = minf(_cleanup_at, expires)
	return sectors_done > 0


## Квадрат виден или станет виден до следующей склейки: его ковёр нельзя откладывать до бюджета кадра
func _urgent(key: Vector3i, from: Vector2) -> bool:
	if not from.is_finite():
		return false
	var side := SECTOR * TILE
	var low := Vector2(key.x, key.y) * side
	var d := from.distance_to(from.clamp(low, low + Vector2.ONE * side))
	return d <= reach() * (EXTRA_REACH.x if directional else 1.0) + URGENT_PAD


func _present_sector(n: int, sector: Vector2i, frame: Dictionary) -> void:
	var entry: Dictionary = layers[n]
	var part: Variant = entry.nodes.get(sector)
	var previous := 0
	if part != null:
		previous = part.mm.visible_instance_count
	if frame.count == 0:
		if part != null:
			_stash(entry, part)
			entry.nodes.erase(sector)
			entry.n -= previous
			count -= previous
		return
	if part == null:
		part = _sector_node(entry)
		entry.nodes[sector] = part
	var mm: MultiMesh = part.mm
	var capacity: int = frame.buffer.size() / STRIDE
	if mm.instance_count != capacity:
		mm.visible_instance_count = 0
		mm.instance_count = capacity
	mm.buffer = frame.buffer
	mm.visible_instance_count = frame.count
	mm.custom_aabb = frame.bounds
	entry.n += frame.count - previous
	count += frame.count - previous


## Плитка (i, j): куртинки на сетке SUB × SUB с дрожанием, по видам. Пустой массив — травы здесь нет.
## Возвращает {parts, y — мин. и макс. высота куртинок}. Общего состояния не пишет: плитки считаются параллельно
func _build_tile(i: int, j: int) -> Dictionary:
	var ys := [Vector2.ZERO]
	var parts := _grass_tile(i, j, ys)
	var stones := _road_stones(i, j, ys)
	if not stones.is_empty():
		if parts.is_empty():
			for kind in _kinds:
				parts.append(PackedFloat32Array())
		parts[Models.CARPET_STONES] = stones
	return {parts = parts, y = ys[0]}


## Размер россыпи в точке полотна (0 — нет): weight — маска полотна, across — поперечная координата (0 — ось, 1 — кромка),
## h — случайное 0..1. На обочине и кромке — чаще; на полотне — только между колеями и у края, в колеях чисто;
## на тропе в одну колею — только у края. Общая с изолированной сценой road_look.
static func road_stone(weight: float, across: float, surface: int, road: bool, h: float, clump := 1.0) -> float:
	if surface <= 0 or surface >= STONE_CHANCE.size():
		return 0.0
	var chance: Vector2 = STONE_CHANCE[surface]
	var a := absf(across)
	var p := 0.0
	if weight < 0.5:
		p = chance.x * smoothstep(0.08, 0.22, weight) * clump
	elif a > 0.72 or (road and a < 0.2):
		p = chance.y * clump
	if h >= p:
		return 0.0
	return lerpf(1.0, 2.0, h / p) * (1.0 if weight < 0.5 else 0.7)


## Кучность россыпи в точке мира (x, z), 0..2, в среднем около 1: медленное поле ~12–20 м — осыпь местами,
## а не ровной полосой вдоль всей дороги. Общая с изолированной сценой road_look.
static func stone_clump(x: float, z: float) -> float:
	var f := 0.5 + 0.5 * (0.6 * sin(0.37 * x + 0.21 * z + 1.3) + 0.4 * sin(-0.17 * x + 0.43 * z + 4.0))
	return 2.2 * smoothstep(0.3, 0.85, f)


## Цвет россыпи: покрытие, сведённое к серому камню тем сильнее, чем оно каменистее (комья земли остаются цвета земли)
static func road_stone_tint(surface: int, h: float) -> Color:
	var s: Dictionary = RoadSurface.LIST[surface]
	var c := Color(s.color[0] / 255.0, s.color[1] / 255.0, s.color[2] / 255.0).lerp(Color(0.56, 0.55, 0.52), 0.2 + 0.6 * s.grain)
	return c * (0.95 + 0.3 * h) # материал растительности переводит цвет из sRGB: светлее, чем кажется по числу


## Россыпь камней и комьев плитки (i, j) у дорожного полотна; пусто — полотна здесь нет.
func _road_stones(i: int, j: int, ys: Array) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	var refine = heights.road_refinement
	if refine == null or stones <= 0.0:
		return out
	var width := world.W
	# Плитка 4×4 м пересекает не больше четырёх патчей сетки с началом в центрах клеток.
	var key := j * width + i
	var patches: Dictionary = refine.patches
	if not patches.has(key) and not patches.has(key - 1) and not patches.has(key - width) and not patches.has(key - width - 1):
		return out
	var step := TILE / STONE_SUB
	var sky := 1.0 - forest.get_pixel(i, j).r
	var n := 0
	var y_low := INF
	var y_high := -INF
	for m in STONE_SUB * STONE_SUB:
		var gx := i * STONE_SUB + m % STONE_SUB
		var gz := j * STONE_SUB + m / STONE_SUB
		var x := (gx + WGRandom.hash2(gx, gz, 311)) * step
		var z := (gz + WGRandom.hash2(gx, gz, 313)) * step
		if refine.weight_at(x, z, width) < 0.08:
			continue
		var at: Dictionary = refine.sample(x, z, width)
		if at.is_empty():
			continue
		var h := WGRandom.hash2(gx, gz, 317)
		var size := road_stone(at.weight, at.across, at.surface, at.road, h / maxf(stones, 0.001), stone_clump(x, z))
		if size <= 0.0 or heights.depth_at(x, z) > 0.0:
			continue
		if out.is_empty():
			out.resize(STONE_SUB * STONE_SUB * STRIDE)
		var y := heights.placement_ground_at(x, z)
		var tint := road_stone_tint(at.surface, WGRandom.hash2(gx, gz, 331))
		tint.a = sky
		_put(out, n, Basis(Vector3.UP, h * TAU * 7.0).scaled_local(Vector3(size, size * (0.8 + 0.5 * WGRandom.hash2(gx, gz, 337)), size)), x, y, z, tint, h, 0.0)
		n += 1
		y_low = minf(y_low, y)
		y_high = maxf(y_high, y)
	out.resize(n * STRIDE)
	if n > 0:
		var old: Vector2 = ys[0]
		ys[0] = Vector2(y_low, y_high + 0.7) if old == Vector2.ZERO else Vector2(minf(old.x, y_low), maxf(old.y, y_high + 0.7))
	return out


func _grass_tile(i: int, j: int, ys: Array) -> Array:
	var w := world
	var k := j * w.W + i
	var bd: Dictionary = Biomes.LIST[w.biome[k]]
	var rocky: bool = w.biome[k] == Biomes.ROCK
	if (not bd.has("grass") and not rocky) or w.river[k] != 0:
		return []
	var surface := forest.get_pixel(i, j)
	var light := StageClimate.natural_conditions(w, i, j).x
	var gr: Dictionary = VegetationLayer.ROCK_GRASS if rocky else bd.grass
	# Те же поля, что у раскладки пучков травы (_fill_grass): влага, свет, уклон, полог, сообщество места
	var lush := clampf(1.0 - 0.45 * (w.slope[k] - 0.5), 0.35, 1.0) * (1.25 if w.dist_water[k] < 3.0 else 1.0)
	lush *= (0.45 + 0.75 * w.moist[k]) * (0.65 + 0.7 * light)
	lush *= 1.0 - 0.65 * surface.r
	lush *= layer.ground_grass_mul(i, j, surface, light)
	if rocky:
		lush *= VegetationLayer._rock_shelter(surface, i + w.world_origin.x, j + w.world_origin.y)
	var cover: float = clampf(gr.dens * lush * (1.0 - 0.9 * surface.a) / 3.0, 0.0, 1.0) * (1.0 - 0.4 * surface.r)
	if cover < 0.03:
		return []
	var forest_k := smoothstep(0.15, 0.55, surface.r) if _veg_cfg != null else 0.0
	# Где трава есть, ковёр сплошной: редкую траву сухих и каменистых мест дополняет соломенная дернина
	if not rocky:
		cover = lerpf(cover, 1.0, 0.5 * (1.0 - forest_k * 0.85) if _veg_cfg != null else 0.5)
	cover *= grass_keep * density
	if _veg_cfg != null and forest_k > 0.0:
		cover *= lerpf(0.85, _veg_cfg.carpet_forest_cover_mul, forest_k)
	var path: int = w.path_mask[k]
	if path == 1:
		cover *= 0.4 # звериная тропа: вытоптано
	var tc: Array = gr.tint
	if _veg_cfg != null:
		var dark_m := lerpf(1.0, _veg_cfg.carpet_darken_mul, maxf(forest_k, smoothstep(0.2, 0.7, surface.g)))
		tc = [float(tc[0]) * dark_m, float(tc[1]) * lerpf(dark_m, dark_m * 0.90, forest_k), float(tc[2]) * lerpf(dark_m, dark_m * 0.82, forest_k)]
	if _atm_cfg != null and _atm_cfg.autumn_strength > 0.0:
		var ak := _atm_cfg.autumn_strength * 0.55
		tc = [lerpf(float(tc[0]), float(tc[0]) * 1.04, ak), lerpf(float(tc[1]), float(tc[1]) * 0.86, ak), lerpf(float(tc[2]), float(tc[2]) * 0.68, ak)]
	var straw := VegetationLayer._straw(gr, i, j, surface)
	if _atm_cfg != null and _atm_cfg.autumn_strength > 0.0:
		straw = clampf(straw + _atm_cfg.autumn_strength * 0.35, 0.0, 1.0)
	# Сухость места: мало влаги, каменисто, сухой биом — здесь ковёр соломенный
	var parched := clampf((0.5 - w.moist[k]) * 1.6 + surface.a * 0.8 + VegetationLayer.open_dry(w.biome[k]) * 0.5, 0.0, 1.0)
	var shade := smoothstep(0.3, 0.6, surface.r)
	var forest_mix := 0.0
	if _expedition:
		forest_mix = smoothstep(0.12, 0.46, surface.r) * (1.0 - 0.62 * surface.a)
		if w.biome[k] in [Biomes.FOREST, Biomes.TAIGA]:
			forest_mix = maxf(forest_mix, 0.24 * (1.0 - surface.a))
		if _veg_cfg != null:
			forest_mix = clampf(maxf(forest_mix, smoothstep(0.15, 0.52, surface.r) * (1.0 - 0.35 * surface.a)), 0.0, 1.0)
		else:
			cover *= 1.0 - 0.28 * forest_mix
	var flowers: bool = bd.get("flowers", false) and surface.r < 0.4 and forest_mix < 0.35
	var flower_mul := 1.0
	if _veg_cfg != null:
		shade = clampf(shade + _veg_cfg.carpet_shade_boost * clampf(surface.r * 1.4, 0.0, 1.0), 0.0, 1.0)
		flower_mul = _veg_cfg.carpet_flowers_mul
		flowers = flowers and flower_mul > 0.0
	var tall: float = clampf(0.6 + 0.45 * lush, 0.55, 1.15) * grow
	var step := TILE / SUB
	var refine = heights.road_refinement
	var has_road_patch := false
	if refine != null:
		var w_w := w.W
		var patches: Dictionary = refine.patches
		has_road_patch = patches.has(k) or (i > 0 and patches.has(k - 1)) \
			or (j > 0 and patches.has(k - w_w)) or (i > 0 and j > 0 and patches.has(k - w_w - 1))
	if use_native_tiles and _ride != null and not has_road_patch and (refine != null or path < 2):
		var fast: Variant = Grid.fast_grid()
		if fast != null:
			var res: Variant = fast.BuildCarpetGrassTile(_ride, i, j, TILE, SUB, cover, shade, parched, straw, tall, grow, flowers, tc[0], tc[1], tc[2], surface.r, forest_mix, _expedition, flower_mul)
			if res is Dictionary and res.get("ok", false):
				if not res.get("any", false):
					return []
				ys[0] = res.y
				return res.parts
	var y_low := INF
	var y_high := -INF
	var parts: Array = []
	var filled := PackedInt32Array()
	filled.resize(_kinds)
	for kind in _kinds:
		var part := PackedFloat32Array()
		part.resize(SUB * SUB * STRIDE)
		parts.append(part)
	for m in SUB * SUB:
		var gx := i * SUB + m % SUB
		var gz := j * SUB + m / SUB
		var x := (gx + 0.12 + 0.76 * WGRandom.hash2(gx, gz, 211)) * step
		var z := (gz + 0.12 + 0.76 * WGRandom.hash2(gx, gz, 223)) * step
		# Просветы грунта пятнами ~6 м; на малой густоте пятна шире
		var patch := VegetationLayer._value_noise(x / 6.0, z / 6.0, 229)
		# Под пологом ковёр островами: между ними остаётся лесная подстилка
		var keep: float = cover * smoothstep(0.03 + 0.37 * shade, 0.22 + 0.46 * shade, patch)
		if WGRandom.hash2(gx, gz, 227) > keep:
			continue
		# 15.11.2026: у полотна дернина не обрывается стеной. На обочине (до видимой кромки покрытия) она редеет и
		# ниже; на травяной колее низкая дернина остаётся на середине между колеями. На самом покрытии её нет.
		var low := 1.0
		var verge_mask := _veg_cfg.carpet_verge_mask if _veg_cfg != null else VERGE_MASK
		if refine != null:
			var tread: float = refine.edge_at(x, z, w.W) # 15.11: кромка без ступенек метровой сетки, как в шейдере
			if tread > 0.04:
				if tread < verge_mask:
					if WGRandom.hash2(gx, gz, 293) < tread / verge_mask:
						continue
					low = lerpf(0.9, 0.6, tread / verge_mask)
				else:
					var at: Dictionary = refine.sample(x, z, w.W)
					if at.is_empty() or at.surface != RoadSurface.MEADOW or absf(at.across) > MEADOW_MIDDLE:
						continue
					low = 0.55
		elif path >= 2:
			continue
		if heights.depth_at(x, z) > 0.0:
			continue
		var y := heights.placement_ground_at(x, z)
		var normal := Vector3(y - heights.placement_ground_at(x + 0.4, z), 0.4, y - heights.placement_ground_at(x, z + 0.4)).normalized()
		var h1 := WGRandom.hash2(gx, gz, 233)
		var h2 := WGRandom.hash2(gx, gz, 239)
		# Цвет: тон биома, пятна светлее и суше (2,6 м и 9 м), каждая куртинка чуть своя — ковёр не плоский
		var lum := 0.78 + 0.5 * VegetationLayer._value_noise(x / 2.6, z / 2.6, 251) * (0.6 + 0.8 * h1)
		var dry_patch := smoothstep(0.6, 0.9, VegetationLayer._value_noise(x / 9.0, z / 9.0, 257))
		var dry := clampf(straw * (0.5 + h2 * 1.1) + 0.3 * dry_patch * (1.0 - 0.6 * surface.r), 0.0, 0.85)
		# Вид куртинки: под пологом — теневая, на сухом — соломенная (пятнами 9 м и по сухости места), иначе луговая
		var kind := Models.CARPET_MEADOW
		if WGRandom.hash2(gx, gz, 261) < shade:
			kind = Models.CARPET_SHADE
		elif WGRandom.hash2(gx, gz, 263) < parched * (0.15 + 0.85 * dry_patch) + dry * 0.3:
			kind = Models.CARPET_DRY
			dry = maxf(dry, 0.45)
		if forest_mix > 0.0 and WGRandom.hash2(gx, gz, 295) < forest_mix:
			var mix := 0.75 * VegetationLayer._value_noise(x / 4.7, z / 4.7, 297) + 0.25 * h2
			kind = Models.CARPET_MOSS if mix < 0.39 - 0.14 * parched else Models.CARPET_WOODLAND_LEAVES
			if mix > 0.69 - 0.13 * parched:
				kind = Models.CARPET_SEDGE if mix > 0.84 - 0.19 * parched else Models.CARPET_BERRY
		var sc := 0.85 + 0.45 * h1
		var sy: float = sc * tall * (0.7 + 0.6 * h2) * low
		var basis := Basis(Vector3.UP, h2 * TAU)
		var axis := Vector3.UP.cross(normal)
		if axis.length_squared() > 1e-6:
			basis = Basis(axis.normalized(), Vector3.UP.angle_to(normal)) * basis
		y -= 0.015
		var tint := Color(lerpf(tc[0] * 0.9, 0.6, dry) * lum * 1.15, lerpf(tc[1], 0.57, dry) * lum * 1.15, lerpf(tc[2], 0.32, dry) * lum * 1.15, 1.0 - surface.r)
		if kind == Models.CARPET_SHADE:
			tint = Color(tint.r * 0.66, tint.g * 0.8, tint.b * 0.74, tint.a)
		elif kind >= Models.CARPET_MOSS:
			tint = Color(0.28 + 0.10 * parched, 0.39 - 0.04 * parched, 0.19 + 0.035 * h2, tint.a)
			tint = Color(tint.r * lum, tint.g * lum, tint.b * lum, tint.a)
		_put(parts[kind], filled[kind], basis.scaled_local(Vector3(sc, sy, sc)), x, y, z, tint, WGRandom.hash2(gx, gz, 241), 0.3 * h1)
		filled[kind] += 1
		# Цветы — полянами ~5 м, цвет поляны общий (шум 14 м), изредка другой
		if flowers and kind < Models.CARPET_SHADE and low == 1.0:
			var bloom := smoothstep(0.52, 0.78, VegetationLayer._value_noise(x / 5.0, z / 5.0, 269)) * (1.0 - 0.7 * parched)
			if WGRandom.hash2(gx, gz, 271) < 0.16 * bloom * flower_mul:
				var pick := int(VegetationLayer._value_noise(x / 14.0, z / 14.0, 277) * 3.999)
				if WGRandom.hash2(gx, gz, 281) < 0.25:
					pick = int(WGRandom.hash2(gx, gz, 283) * 3.999)
				var petal: Color = PETALS[pick]
				petal.a = 1.0 - surface.r
				var fs := (0.8 + 0.5 * h2) * grow
				_put(parts[Models.CARPET_FLOWERS], filled[Models.CARPET_FLOWERS], basis.orthonormalized().scaled_local(Vector3(fs, fs, fs)), x, y, z, petal, h1, 0.2)
				filled[Models.CARPET_FLOWERS] += 1
		y_low = minf(y_low, y)
		y_high = maxf(y_high, y)
	var any := false
	for kind in _kinds:
		parts[kind].resize(filled[kind] * STRIDE)
		any = any or filled[kind] > 0
	if not any:
		return []
	ys[0] = Vector2(y_low, y_high + 0.7)
	return parts


static func _put(out: PackedFloat32Array, index: int, basis: Basis, x: float, y: float, z: float, tint: Color, seed: float, bend: float) -> void:
	var o := index * STRIDE
	out[o] = basis.x.x
	out[o + 1] = basis.y.x
	out[o + 2] = basis.z.x
	out[o + 3] = x
	out[o + 4] = basis.x.y
	out[o + 5] = basis.y.y
	out[o + 6] = basis.z.y
	out[o + 7] = y
	out[o + 8] = basis.x.z
	out[o + 9] = basis.y.z
	out[o + 10] = basis.z.z
	out[o + 11] = z
	out[o + 12] = tint.r
	out[o + 13] = tint.g
	out[o + 14] = tint.b
	out[o + 15] = tint.a # открытость неба: свет и ветер под пологом
	out[o + 16] = 0.0
	out[o + 17] = seed
	out[o + 18] = bend
	out[o + 19] = 0.0
