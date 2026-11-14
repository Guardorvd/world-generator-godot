class_name GroundCarpet
extends RefCounted
## 14.11.2026 (2): дернина — плотный ковёр мелкой травы вокруг и впереди игрока.
##
## Отдельный от травы и подлеска слой со своим лёгким конвейером. Первый вариант (внутри фоновой раскладки травы)
## не успевал на скорости: раскладка считает весь радиус заново каждые 8 м и занимает секунды, а дернина видна
## только в 15 м, поэтому игрок обгонял покрытие и ковёр появлялся лишь при торможении.
##
## Здесь:
## - земля делится на плитки 4 м (клетки плана); у плитки — готовый кусок буфера MultiMesh (куртинки на сетке
##   ~0,45 м с дрожанием, высота земли, наклон по склону, цвет). Плитка считается один раз и хранится в кэше;
## - фоновая задача только дополняет кэш недостающими плитками капсулы «игрок — упреждение» и склеивает буфер
##   из готовых кусков (десятки мс даже на скорости, число новых плиток зависит от пути, а не от радиуса);
## - упреждение берётся от своей задержки (она короткая), а не от задержки раскладки травы;
## - кэш сбрасывается при смене настроек и стирается там, где перестроили землю (refresh).
## Куртинки раскладываются с запасом MARGIN за видимой дальностью; шейдер растворяет край, поэтому
## новые куртинки появляются в невидимой полосе. Меш — Models.build_carpet_mesh.
##
## Густота: доля занятых ячеек от тех же данных, что у травы (влага, свет, уклон, полог, сообщество), и пятна
## голой земли. Не рисуется на воде, на полотне дорог и троп (RoadRefinement.weight_at), на скале без укрытия.

const StreamPolicy := preload("res://scripts/render/vegetation_stream_policy.gd")
const TILE := GameConfig.TILE
const STRIDE := 20          # преобразование (12), цвет (4), custom (4) — как у травы
const SUB := 9              # ячеек на сторону плитки: 4 м / 9 = 0,44 м
const CAP := 20000          # экземпляров в MultiMesh (на высокой густоте у игрока ~3,5 тыс., остальное — упреждение)
const FADE := 0.4           # полоса растворения, доля дальности
const MARGIN := 5.0         # запас раскладки за видимой дальностью, м
const STEP := 2.5           # на сколько метров сдвигается игрок до новой склейки

var world: WorldData
var heights: Heightfield
var layer: Node3D            # VegetationLayer: общие функции множителя травы и снимок леса
var forest: Image
var mm: MultiMesh
var mat: ShaderMaterial
var node: MultiMeshInstance3D
var stream := StreamPolicy.new()

## Настройки игрока (GameSettings.CARPET_DENSITY / CARPET_RANGE) и качество растительности
var density := 1.0           # множитель доли занятых ячеек
var base_range := 15.0       # м, видимость целиком до base_range × (1 − FADE), растворение до base_range
var grass_keep := 1.0        # flora.grass
var grow := 1.0              # flora.grow
var detail := 1.0            # flora.detail

var count := 0               # экземпляров на экране (замер)
var capped := 0              # сколько раз склейка упёрлась в CAP
var last_job_ms := 0.0
var max_job_ms := 0.0
var tiles_built := 0         # плиток, посчитанных с запуска (замер)

var _tiles := {}             # Vector2i -> PackedFloat32Array (экземпляры плитки)
var _tile_y := {}            # Vector2i -> Vector2(мин. и макс. высота)
var _task := -1
var _last := Vector2.INF
var _last_lead := Vector2.ZERO
var _started_clock := 0.0
var _out := PackedFloat32Array()
var _out_n := 0
var _out_box := AABB()
var _reset := false
var _cuts: Array[Rect2] = []
var _road_revision := -1
var _job_started := 0
var _enabled := true


func setup(layer_node: Node3D, w: WorldData, h: Heightfield, forest_image: Image, mesh: Mesh, material: ShaderMaterial) -> void:
	layer = layer_node
	world = w
	heights = h
	forest = forest_image
	mat = material
	node = MultiMeshInstance3D.new()
	node.name = "GroundCarpet"
	mm = MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.use_custom_data = true
	mm.mesh = mesh
	mm.instance_count = CAP
	mm.visible_instance_count = 0
	node.multimesh = mm
	node.material_override = material
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	node.lod_bias = 0.6
	layer_node.add_child(node)
	apply_ranges()


## Дальность видимости, м
func reach() -> float:
	return base_range * detail


## Настройки или качество изменились (на паузе): кэш плиток устарел.
func configure(density_scale: float, range_m: float, flora: Dictionary) -> void:
	var changed := not is_equal_approx(density, density_scale) or not is_equal_approx(base_range, range_m) \
		or not is_equal_approx(grass_keep, flora.grass) or not is_equal_approx(grow, flora.grow)
	density = density_scale
	base_range = range_m
	grass_keep = flora.grass
	grow = flora.grow
	detail = flora.detail
	_enabled = density_scale > 0.0 and range_m > 0.0
	if changed:
		_reset = true
	apply_ranges()
	if not _enabled and mm != null:
		mm.visible_instance_count = 0
		count = 0
	_last = Vector2.INF


## Границы растворения в шейдерах травы и земли
func apply_ranges() -> void:
	var r := reach() if _enabled else 0.0
	if mat != null:
		mat.set_shader_parameter("fade_far", maxf(r, 0.1))
		mat.set_shader_parameter("fade_len", maxf(r * FADE, 0.1))
		# Дальше 4 м травинок в куртинке меньше: к краю остаётся доля detail_keep (мелкие пиксели не нужны)
		mat.set_shader_parameter("detail_full", 3.5 * detail)
		mat.set_shader_parameter("detail_far", maxf(r * 0.85, 4.0))
		mat.set_shader_parameter("detail_keep", 0.38)
	# Тень дернины на дёрне материала земли (terrain.gdshader) — та же дальность и полоса
	RenderingServer.global_shader_parameter_set("ground_carpet", Vector2(r, maxf(r * FADE, 0.1)))


func finish() -> void:
	if _task != -1:
		WorkerThreadPool.wait_for_task_completion(_task)
		_task = -1


func release() -> void:
	finish()
	RenderingServer.global_shader_parameter_set("ground_carpet", Vector2(0.0, 1.0))


## Земля в rect (клетки плана) перестроена: плитки в ней устарели.
func invalidate(rect: Rect2i) -> void:
	_cuts.append(Rect2(Vector2(rect.position) * TILE, Vector2(rect.size) * TILE).grow(TILE))
	_last = Vector2.INF


## Сброс на паузе (смена мира, дальности): без задачи.
func clear() -> void:
	finish()
	_tiles.clear()
	_tile_y.clear()
	_reset = false
	_last = Vector2.INF
	count = 0
	if mm != null:
		mm.visible_instance_count = 0


## Каждый кадр из VegetationLayer.update. Не блокирует: считает фоновая задача, главный поток только
## передаёт готовый буфер.
func update(p: Vector2, dt: float, road_revision: int, may_work := true) -> void:
	stream.sample(p, maxf(dt, 0.000001), false)
	if not _enabled:
		return
	if _task != -1:
		if not WorkerThreadPool.is_task_completed(_task):
			return
		if not may_work:
			return
		WorkerThreadPool.wait_for_task_completion(_task)
		_task = -1
		stream.record_latency(maxf(last_job_ms / 1000.0, stream.clock - _started_clock))
		_present()
	var lead := stream.lead()
	if _last != Vector2.INF and p.distance_to(_last) < STEP and lead.distance_to(_last_lead) < STEP * 2.0 and road_revision == _road_revision:
		return
	_begin(p, lead, road_revision)
	_task = WorkerThreadPool.add_task(_job.bind(p, lead), true, "Дернина")


## Сразу, на месте (старт, возрождение): ковёр готов в том же кадре. Дальше — update.
func build_now(p: Vector2, road_revision: int) -> void:
	finish()
	stream.sample(p, 0.0, true)
	if not _enabled:
		return
	_begin(p, Vector2.ZERO, road_revision)
	_job(p, Vector2.ZERO)
	_present()


func _begin(p: Vector2, lead: Vector2, road_revision: int) -> void:
	if _reset or road_revision != _road_revision:
		_tiles.clear()
		_tile_y.clear()
		_reset = false
	_road_revision = road_revision
	if not _cuts.is_empty():
		for key: Vector2i in _tiles.keys():
			var box := Rect2(Vector2(key) * TILE, Vector2.ONE * TILE)
			for cut: Rect2 in _cuts:
				if cut.intersects(box):
					_tiles.erase(key)
					_tile_y.erase(key)
					break
		_cuts.clear()
	_last = p
	_last_lead = lead
	_started_clock = stream.clock
	_job_started = Time.get_ticks_usec()


## Фоновая задача: плитки капсулы, недостающие досчитываются, буфер склеивается из кусков.
func _job(p: Vector2, lead: Vector2) -> void:
	var reach_all := reach() + MARGIN
	var lo := p.min(p + lead) / TILE - Vector2.ONE * (reach_all / TILE + 1.0)
	var hi := p.max(p + lead) / TILE + Vector2.ONE * (reach_all / TILE + 1.0)
	var need: Array = []
	for j in range(maxi(0, floori(lo.y)), mini(world.H - 1, ceili(hi.y)) + 1):
		for i in range(maxi(0, floori(lo.x)), mini(world.W - 1, ceili(hi.x)) + 1):
			var d := StreamPolicy.distance_to_coverage(Vector2(i + 0.5, j + 0.5) * TILE, p, lead)
			if d <= reach_all + TILE * 0.72:
				need.append([d, i, j])
	need.sort_custom(func(a: Array, b: Array) -> bool: return a[0] < b[0])
	var out := PackedFloat32Array()
	var n := 0
	var low := Vector3(INF, INF, INF)
	var high := Vector3(-INF, -INF, -INF)
	var used := {}
	var overflow := false
	for entry: Array in need:
		var key := Vector2i(entry[1], entry[2])
		used[key] = true
		var tile: PackedFloat32Array
		if _tiles.has(key):
			tile = _tiles[key]
		else:
			tile = _build_tile(key.x, key.y)
			_tiles[key] = tile
			tiles_built += 1
		var m := tile.size() / STRIDE
		if m == 0:
			continue
		if n + m > CAP:
			overflow = true
			continue
		out.append_array(tile)
		n += m
		var y: Vector2 = _tile_y[key]
		low = low.min(Vector3(key.x * TILE, y.x, key.y * TILE))
		high = high.max(Vector3((key.x + 1) * TILE, y.y, (key.y + 1) * TILE))
	if overflow:
		capped += 1
	# Кэш: плитки далеко за капсулой уходят (запас на возврат назад)
	var keep_d := reach_all + TILE * 0.72 + 28.0
	for key: Vector2i in _tiles.keys():
		if used.has(key):
			continue
		if StreamPolicy.distance_to_coverage(Vector2(key.x + 0.5, key.y + 0.5) * TILE, p, lead) > keep_d:
			_tiles.erase(key)
			_tile_y.erase(key)
	out.resize(CAP * STRIDE)
	_out = out
	_out_n = n
	# Травинки и ветер выходят за точки основания куртинок
	_out_box = AABB(low, high - low).grow(0.9) if n > 0 else AABB()
	last_job_ms = (Time.get_ticks_usec() - _job_started) / 1000.0
	max_job_ms = maxf(max_job_ms, last_job_ms)


func _present() -> void:
	mm.buffer = _out
	mm.visible_instance_count = _out_n
	mm.custom_aabb = _out_box
	count = _out_n
	_out = PackedFloat32Array()


## Плитка (i, j): куртинки на сетке SUB × SUB с дрожанием. Пустой массив — травы здесь нет.
func _build_tile(i: int, j: int) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	_tile_y[Vector2i(i, j)] = Vector2.ZERO
	var w := world
	var k := j * w.W + i
	var bd: Dictionary = Biomes.LIST[w.biome[k]]
	var rocky: bool = w.biome[k] == Biomes.ROCK
	if (not bd.has("grass") and not rocky) or w.river[k] != 0:
		return out
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
	var cover: float = clampf(gr.dens * lush * (1.0 - 0.9 * surface.a) / 3.0, 0.0, 1.0) * (1.0 - 0.4 * surface.r) * grass_keep * density
	if w.path_mask[k] == 1:
		cover *= 0.4 # звериная тропа: вытоптано
	if cover < 0.03:
		return out
	var path: int = w.path_mask[k]
	var tc: Array = gr.tint
	var straw := VegetationLayer._straw(gr, i, j, surface)
	var tall: float = clampf(0.6 + 0.45 * lush, 0.55, 1.15) * grow
	var step := TILE / SUB
	var refine = heights.road_refinement
	var y_low := INF
	var y_high := -INF
	var count_local := 0
	out.resize(SUB * SUB * STRIDE)
	for m in SUB * SUB:
		var gx := i * SUB + m % SUB
		var gz := j * SUB + m / SUB
		var x := (gx + 0.12 + 0.76 * WGRandom.hash2(gx, gz, 211)) * step
		var z := (gz + 0.12 + 0.76 * WGRandom.hash2(gx, gz, 223)) * step
		# Просветы грунта пятнами ~6 м; на малой густоте пятна шире
		var patch := VegetationLayer._value_noise(x / 6.0, z / 6.0, 229)
		var keep: float = cover * smoothstep(0.06, 0.38, patch)
		if WGRandom.hash2(gx, gz, 227) > keep:
			continue
		if refine != null:
			if refine.weight_at(x, z, w.W) > 0.04:
				continue
		elif path >= 2:
			continue
		if heights.depth_at(x, z) > 0.0:
			continue
		var y := heights.ground_at(x, z)
		var normal := Vector3(y - heights.ground_at(x + 0.4, z), 0.4, y - heights.ground_at(x, z + 0.4)).normalized()
		var h1 := WGRandom.hash2(gx, gz, 233)
		var h2 := WGRandom.hash2(gx, gz, 239)
		var sc := 0.85 + 0.45 * h1
		var sy: float = sc * tall * (0.7 + 0.6 * h2)
		var basis := Basis(Vector3.UP, h2 * TAU)
		var axis := Vector3.UP.cross(normal)
		if axis.length_squared() > 1e-6:
			basis = Basis(axis.normalized(), Vector3.UP.angle_to(normal)) * basis
		basis = basis.scaled_local(Vector3(sc, sy, sc))
		var o := count_local * STRIDE
		y -= 0.015
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
		# Цвет: тон биома, крупные пятна светлее и суше (80 м и 9 м), каждая куртинка чуть своя — ковёр не плоский
		var lum := 0.78 + 0.5 * VegetationLayer._value_noise(x / 2.6, z / 2.6, 251) * (0.6 + 0.8 * h1)
		var dry := clampf(straw * (0.5 + h2 * 1.1) + 0.3 * smoothstep(0.6, 0.9, VegetationLayer._value_noise(x / 9.0, z / 9.0, 257)) * (1.0 - 0.6 * surface.r), 0.0, 0.85)
		out[o + 12] = lerpf(tc[0] * 0.9, 0.66, dry) * lum * 1.15
		out[o + 13] = lerpf(tc[1], 0.58, dry) * lum * 1.15
		out[o + 14] = lerpf(tc[2], 0.31, dry) * lum * 1.15
		out[o + 15] = 1.0 - surface.r # открытость неба: свет и ветер под пологом
		out[o + 16] = 0.0
		out[o + 17] = WGRandom.hash2(gx, gz, 241)
		out[o + 18] = 0.3 * h1
		out[o + 19] = 0.0
		y_low = minf(y_low, y)
		y_high = maxf(y_high, y)
		count_local += 1
	out.resize(count_local * STRIDE)
	if count_local > 0:
		_tile_y[Vector2i(i, j)] = Vector2(y_low, y_high + 0.6)
	return out
