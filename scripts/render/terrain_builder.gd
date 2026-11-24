class_name TerrainBuilder
extends RefCounted
## Меш рельефа: сетка с вершиной в центре каждой клетки, раскрашенная запечённой картой биомов.
## Треугольники те же, что в JS-версии и в Heightfield.ground_at; порядок вершин обратный,
## потому что в Godot лицевая сторона — по часовой стрелке.
## С 4.4 квадраты у дорог заменяются метровой сеткой RoadRefinement, остальные остаются прежними.

const TILE := GameConfig.TILE
const SHADER := preload("res://resources/terrain.gdshader")
const DETAIL_SIZE := 256   # сторона бесшовной текстуры шума для мелкой детали
static var allow_fast_refine := true # false — метровая сетка меша на GDScript (эталон для tools/dod_verify.gd)
static var use_community_texture := true

var _detail: Array[ImageTexture] = []   # [шум, нормали из него]: одни на ServiceScope
var _micro: Array[Texture2D] = []       # [высоты микроструктуры, нормали]: resources/ground/micro*.res
const MICRO_TEXTURE := "res://resources/ground/micro.res"
const MICRO_NORMAL := "res://resources/ground/micro_n.res"


## Нормаль вершины клетки (i, j) по соседним высотам (на краю соседи берутся с края карты)
static func _normal(hv: PackedFloat32Array, W: int, H: int, i: int, j: int) -> Vector3:
	var l := hv[j * W + maxi(0, i - 1)]
	var r := hv[j * W + mini(W - 1, i + 1)]
	var u := hv[maxi(0, j - 1) * W + i]
	var d := hv[mini(H - 1, j + 1) * W + i]
	if i > 0 and j > 0 and i < W - 1 and j < H - 1:
		return Vector3(l - r, 2.0 * TILE, u - d).normalized()
	var dx := TILE if i == 0 or i == W - 1 else 2.0 * TILE
	var dz := TILE if j == 0 or j == H - 1 else 2.0 * TILE
	return Vector3((l - r) / dx, 1.0, (u - d) / dz).normalized()


## Только CPU-массивы: подготовка в фоне, загрузка на GPU — в GameWorld.start.
static func build_arrays(w: WorldData, heights: Heightfield, cells := Rect2i(), patch_keys: Variant = null) -> Array:
	var W := w.W
	var H := w.H
	var hv := heights.hv
	if W < 2 or H < 2:
		return []
	var area := Rect2i(0, 0, W - 1, H - 1) if not cells.has_area() else cells.intersection(Rect2i(0, 0, W - 1, H - 1))
	if not area.has_area(): return []
	var columns := area.size.x + 1
	var rows := area.size.y + 1
	var pos := PackedVector3Array()
	var nor := PackedVector3Array()
	var uv := PackedVector2Array()
	pos.resize(columns * rows)
	nor.resize(pos.size())
	uv.resize(pos.size())
	for j in range(area.position.y, area.end.y + 1):
		for i in range(area.position.x, area.end.x + 1):
			var k := (j - area.position.y) * columns + i - area.position.x
			pos[k] = Vector3((i + 0.5) * TILE, hv[j * W + i], (j + 0.5) * TILE)
			uv[k] = Vector2((i + 0.5) / W, (j + 0.5) / H)
			nor[k] = _normal(hv, W, H, i, j)
	var idx := PackedInt32Array()
	idx.resize(area.get_area() * 6)
	var p := 0
	for j in area.size.y:
		for i in area.size.x:
			var a := j * columns + i
			var b := a + 1
			var c := a + columns
			var d := c + 1
			idx[p] = a
			idx[p + 1] = b
			idx[p + 2] = c
			idx[p + 3] = b
			idx[p + 4] = d
			idx[p + 5] = c
			p += 6
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = pos
	arrays[Mesh.ARRAY_NORMAL] = nor
	arrays[Mesh.ARRAY_TEX_UV] = uv
	arrays[Mesh.ARRAY_INDEX] = idx
	if heights.road_refinement != null:
		refine_arrays(arrays, w, heights, area, patch_keys)
	return arrays


## One requested chunk plus a cell halo. Global normals, patch ordering and UVs are unchanged.
static func build_chunk(w: WorldData, heights: Heightfield, key: Vector2i, patch_keys: Variant = null) -> Array:
	var area := Rect2i(key * PlanTerrain.CELLS, Vector2i.ONE * PlanTerrain.CELLS).grow(1)
	return PlanTerrain.partition(build_arrays(w, heights, area, patch_keys)).get(key, [])


## Поправить высоты меша в клетках changed (и нормали вокруг них) по heights.hv
static func patch(arrays: Array, w: WorldData, heights: Heightfield, changed: PackedInt32Array) -> void:
	var W := w.W
	var H := w.H
	var hv := heights.hv
	if changed.is_empty() or arrays.is_empty():
		return
	var pos: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var nor: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
	var touched := PackedByteArray()
	touched.resize(w.N)
	for k: int in changed:
		pos[k] = Vector3(pos[k].x, hv[k], pos[k].z)
		var ci := k % W
		var cj := k / W
		for j in range(maxi(0, cj - 1), mini(H, cj + 2)):
			for i in range(maxi(0, ci - 1), mini(W, ci + 2)):
				var n := j * W + i
				if touched[n] == 0:
					nor[n] = _normal(hv, W, H, i, j)
					touched[n] = 1
	arrays[Mesh.ARRAY_VERTEX] = pos
	arrays[Mesh.ARRAY_NORMAL] = nor


## DOD (ноябрь 2026): весь проход одним вызовом C# (FastGrid.RefineTerrain), патчи — столбцами. Результат тот же, что у
## цикла в refine_arrays ниже (он остаётся эталоном для tools/dod_verify.gd).
static func _refine_native(fast: Object, arrays: Array, w: WorldData, heights: Heightfield, area: Rect2i, patch_keys: Variant) -> bool:
	var keys := PackedInt32Array()
	var ph := PackedFloat32Array()
	var pc := PackedColorArray()
	var pu := PackedVector2Array()
	var patches := heights.road_refinement.patches
	var sampled := area.grow(1)
	for key: int in patch_keys:
		if not sampled.has_point(Vector2i(key % w.W, key / w.W)):
			continue
		keys.append(key)
		var p: Dictionary = patches[key]
		ph.append_array(p.h)
		pc.append_array(p.color)
		pu.append_array(p.uv)
	var out: Variant = fast.RefineTerrain(w.W, w.H, TILE, RoadRefinement.DIV, area.position.x, area.position.y, area.size.x, area.size.y,
		arrays[Mesh.ARRAY_VERTEX], arrays[Mesh.ARRAY_NORMAL], arrays[Mesh.ARRAY_TEX_UV], arrays[Mesh.ARRAY_INDEX], keys, ph, pc, pu, heights.hv)
	if not out is Dictionary:
		push_error("TerrainBuilder: C# вернул null, сетка 1 м считается на GDScript")
		return false   # arrays не тронуты
	arrays[Mesh.ARRAY_VERTEX] = out.pos
	arrays[Mesh.ARRAY_NORMAL] = out.nor
	arrays[Mesh.ARRAY_TEX_UV] = out.uv
	arrays[Mesh.ARRAY_TEX_UV2] = out.uv2
	arrays[Mesh.ARRAY_COLOR] = out.color
	arrays[Mesh.ARRAY_INDEX] = out.idx
	return true


## Final terrain directly from the authoritative heightfield. Each worker owns its chunk arrays.
static func build_chunks(w: WorldData, heights: Heightfield) -> Dictionary:
	var columns := ceili(float(w.W - 1) / PlanTerrain.CELLS)
	var rows := ceili(float(w.H - 1) / PlanTerrain.CELLS)
	var chunks := {}
	if columns <= 0 or rows <= 0:
		return chunks
	var patches := {}
	if heights.road_refinement != null:
		# Порядок патчей задаёт порядок вершин меша. Раскладываем его один раз,
		# с запасом на клетку меша и ещё клетку для нормалей.
		const CELLS := PlanTerrain.CELLS
		for k: int in heights.road_refinement.patches:
			var x := k % w.W
			var y := k / w.W
			for cy in range(maxi(0, (y - 2) / CELLS), mini(rows - 1, (y + 2) / CELLS) + 1):
				for cx in range(maxi(0, (x - 2) / CELLS), mini(columns - 1, (x + 2) / CELLS) + 1):
					var key := Vector2i(cx, cy)
					if not patches.has(key):
						patches[key] = PackedInt32Array()
					patches[key].append(k)
	var count := columns * rows
	var band := maxi(1, ceili(count / 8.0))
	for part: Dictionary in Parallel.bands(count, func(first: int, last: int) -> Dictionary:
		var result := {}
		for i in range(first, last):
			var key := Vector2i(i % columns, i / columns)
			result[key] = build_chunk(w, heights, key, patches.get(key, PackedInt32Array()))
		return result, band):
		chunks.merge(part)
	return chunks


## Заменить только квадраты у путей сеткой 1 м. Это часть земли, отдельной накладной ленты нет.
static func refine_arrays(arrays: Array, w: WorldData, heights: Heightfield, cells := Rect2i(), patch_keys: Variant = null) -> void:
	var refinement := heights.road_refinement
	if arrays.is_empty() or refinement == null:
		return
	if patch_keys != null and patch_keys.is_empty():
		var colors := PackedColorArray()
		var uv2 := PackedVector2Array()
		var vertices: int = arrays[Mesh.ARRAY_VERTEX].size()
		colors.resize(vertices)
		colors.fill(Color(0, 0, 0, 0))
		uv2.resize(vertices)
		arrays[Mesh.ARRAY_COLOR] = colors
		arrays[Mesh.ARRAY_TEX_UV2] = uv2
		return
	var keys: Variant = refinement.patches if patch_keys == null else patch_keys
	var area := Rect2i(0, 0, w.W - 1, w.H - 1) if not cells.has_area() else cells
	# At the plan rim normal samples can reach OuterLand; interior chunks only sample the plan.
	var interior := Rect2i(1, 1, w.W - 3, w.H - 3)
	if allow_fast_refine and (w.outer == null or interior.encloses(area)):
		var native := Grid.fast_grid()
		if native != null:
			if _refine_native(native, arrays, w, heights, area, keys):
				return
	var patches := {}
	for key: int in keys:
		if area.has_point(Vector2i(key % w.W, key / w.W)): patches[key] = refinement.patches[key]
	var pos: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var nor: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
	var uv: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV]
	var colors := PackedColorArray()
	colors.resize(pos.size())
	colors.fill(Color(0, 0, 0, 0))
	var uv2 := PackedVector2Array()
	uv2.resize(pos.size())
	var idx := PackedInt32Array()
	var old: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	# Число индексов известно заранее: каждый дорожный квадрат заменяется DIV² квадратами.
	idx.resize(old.size() + patches.size() * (RoadRefinement.DIV * RoadRefinement.DIV - 1) * 6)
	var write := 0
	var vertex_ids := {} # общие метровые вершины соседних патчей не дублируются
	for j in range(area.position.y, area.end.y):
		for i in range(area.position.x, area.end.x):
			if not refinement.patches.has(j * w.W + i):
				var at := ((j - area.position.y) * area.size.x + i - area.position.x) * 6
				for k in 6:
					idx[write] = old[at + k]
					write += 1
	var grid := PackedInt32Array()
	grid.resize(RoadRefinement.STRIDE * RoadRefinement.STRIDE)
	for key: int in patches:
		var p: Dictionary = refinement.patches[key]
		var cx := key % w.W
		var cz := key / w.W
		var right_patch := refinement.patches.has(key + 1)
		var lower_patch := refinement.patches.has(key + w.W)
		for z in RoadRefinement.STRIDE:
			for x in RoadRefinement.STRIDE:
				var n := z * RoadRefinement.STRIDE + x
				var vk := (cz * RoadRefinement.DIV + z) * (w.W * RoadRefinement.DIV) + cx * RoadRefinement.DIV + x
				if vertex_ids.has(vk):
					grid[n] = vertex_ids[vk]
					continue
				var px := (cx + 0.5) * TILE + x * RoadRefinement.STEP
				var pz := (cz + 0.5) * TILE + z * RoadRefinement.STEP
				var id := pos.size()
				var normal: Vector3
				# При выборке на правой/нижней границе height_at читает соседний патч.
				# Если его нет, нужна прежняя выборка исходного рельефа в double.
				if x > 0 and x < RoadRefinement.DIV and z > 0 and z < RoadRefinement.DIV \
						and (x < RoadRefinement.DIV - 1 or right_patch) \
						and (z < RoadRefinement.DIV - 1 or lower_patch):
					normal = Vector3(p.h[n - 1] - p.h[n + 1], 2.0, p.h[n - RoadRefinement.STRIDE] - p.h[n + RoadRefinement.STRIDE]).normalized()
				else:
					normal = _local_normal(heights, px, pz)
				if x % RoadRefinement.DIV == 0 and z % RoadRefinement.DIV == 0:
					id = (cz + z / RoadRefinement.DIV - area.position.y) * (area.size.x + 1) + cx + x / RoadRefinement.DIV - area.position.x
					pos[id].y = p.h[n]
					if px > TILE * 0.5 and pz > TILE * 0.5 and px < (w.W - 0.5) * TILE and pz < (w.H - 0.5) * TILE:
						nor[id] = normal
					colors[id] = p.color[n]
					uv2[id] = p.uv[n]
				else:
					pos.append(Vector3(px, p.h[n], pz))
					nor.append(normal)
					uv.append(Vector2(px / (w.W * TILE), pz / (w.H * TILE)))
					colors.append(p.color[n])
					uv2.append(p.uv[n])
				vertex_ids[vk] = id
				grid[n] = id
		for z in RoadRefinement.DIV:
			for x in RoadRefinement.DIV:
				var a := z * RoadRefinement.STRIDE + x
				idx[write] = grid[a]
				idx[write + 1] = grid[a + 1]
				idx[write + 2] = grid[a + RoadRefinement.STRIDE]
				idx[write + 3] = grid[a + 1]
				idx[write + 4] = grid[a + RoadRefinement.STRIDE + 1]
				idx[write + 5] = grid[a + RoadRefinement.STRIDE]
				write += 6
	arrays[Mesh.ARRAY_VERTEX] = pos
	arrays[Mesh.ARRAY_NORMAL] = nor
	arrays[Mesh.ARRAY_TEX_UV] = uv
	arrays[Mesh.ARRAY_TEX_UV2] = uv2
	arrays[Mesh.ARRAY_COLOR] = colors
	arrays[Mesh.ARRAY_INDEX] = idx


static func _local_normal(heights: Heightfield, x: float, z: float) -> Vector3:
	return Vector3(heights.ground_at(x - 1.0, z) - heights.ground_at(x + 1.0, z), 2.0,
		heights.ground_at(x, z - 1.0) - heights.ground_at(x, z + 1.0)).normalized()


## Материал рельефа с запечённой картой биомов (картинка получает мип-уровни).
## С 2.5 это шейдер resources/terrain.gdshader: вблизи поверх карты мелкая деталь, см. комментарий в нём
func material(base: Image, forest: Image = null, template_id := "") -> ShaderMaterial:
	base.generate_mipmaps()
	var mat := _detail_material(template_id)
	mat.set_shader_parameter("base_tex", ImageTexture.create_from_image(base))
	mat.set_shader_parameter("base_texel", Vector2(1.0 / base.get_width(), 1.0 / base.get_height()))
	if forest != null:
		var masks := forest.duplicate() as Image
		masks.generate_mipmaps()
		mat.set_shader_parameter("forest_tex", ImageTexture.create_from_image(masks))
		mat.set_shader_parameter("forest_enabled", true)
	return mat


## 16.11.2026: затенение впадин (свет неба, AO рельефа). Замер видимости неба (SVF) показал: в крупном масштабе
## суша почти вся открыта (SVF ≥ 0,93 у ~75 %), поэтому затенение слабое и только во впадинах: насколько клетка ниже
## средней высоты окрестности ~16 м (ложбины, промоины, русла) и ~64 м (днища долин, котловины). На ровном склоне
## среднее равно высоте — склоны не темнеют, гребни тоже. Влияет только на свет неба (AO), не на солнце: при солнце
## почти не видно, в тени и в пасмурную погоду впадины читаются. Карта — R8 на клетку плана (как forest_tex),
## ~десятки мс на загрузке; без неё (меню, Trail Lab, области за краем) шейдер берёт белый — без затенения.
const CAVITY_NEAR := 0.18   # наибольшее ослабление света неба в мелких ложбинах
const CAVITY_FAR := 0.12    # в днищах долин

static func cavity_image(hv: PackedFloat32Array, W: int, H: int) -> Image:
	var src := Image.create_from_data(W, H, false, Image.FORMAT_RF, hv.to_byte_array())
	var near := _blurred(src, 2).get_data().to_float32_array()
	var far := _blurred(src, 4).get_data().to_float32_array()
	var out := PackedByteArray()
	out.resize(W * H)
	for k in W * H:
		var h := hv[k]
		var occ := CAVITY_NEAR * smoothstep(0.3, 1.6, near[k] - h) + CAVITY_FAR * smoothstep(0.6, 6.0, far[k] - h)
		out[k] = clampi(roundi((1.0 - occ) * 255.0), 0, 255)
	return Image.create_from_data(W, H, false, Image.FORMAT_R8, out)


## Среднее по блокам 2^levels клеток (каждое уменьшение вдвое усредняет 2×2) и обратно до исходного размера
static func _blurred(src: Image, levels: int) -> Image:
	var img := src.duplicate() as Image
	for i in levels:
		img.resize(maxi(1, img.get_width() / 2), maxi(1, img.get_height() / 2), Image.INTERPOLATE_BILINEAR)
	img.resize(src.get_width(), src.get_height(), Image.INTERPOLATE_BILINEAR)
	return img


static func set_cavity(mat: ShaderMaterial, heights: Heightfield) -> void:
	var img := cavity_image(heights.hv, heights.world.W, heights.world.H)
	img.generate_mipmaps()
	mat.set_shader_parameter("cavity_tex", ImageTexture.create_from_image(img))


static func set_community_noise(mat: ShaderMaterial, w: WorldData) -> void:
	if not use_community_texture or mat == null or w == null or w.W <= 0 or w.H <= 0:
		return
	var fast := Grid.fast_grid()
	if fast == null:
		return
	var seeds := VegetationLayer.community_seeds(w.seed_num)
	var bytes: PackedByteArray = fast.BakeCommunityNoise(w.W, w.H, seeds.x, seeds.y, seeds.w)
	if bytes.size() != w.W * w.H * 3:
		return
	var img := Image.create_from_data(w.W, w.H, false, Image.FORMAT_RGB8, bytes)
	img.generate_mipmaps()
	mat.set_shader_parameter("community_tex", ImageTexture.create_from_image(img))
	mat.set_shader_parameter("community_tex_enabled", true)


## 15.11.2026: дальний вариант материала рельефа — тот же resources/terrain.gdshader, где вес ближней детали
## near — константа 0. Дальше DETAIL_FAR (110 м) near и так ровно 0, поэтому для частей рельефа целиком дальше
## этого картинка та же до пикселя. Но шейдер без ближних веток (микроструктура, подстилка, травинки, галька,
## цветы, камни осыпи, полотно вблизи) компилятор собирает гораздо короче, и видеокарта держит больше пикселей
## сразу: на виде с вершины дальняя земля — большая часть кадра (замер стресс-теста: near = 0 для всего кадра
## −1,7 мс на вершине). Шейдер строится из того же кода при загрузке: варианты не расходятся.
## null — строка near в шейдере не найдена (шейдер переписали): тогда дальних частей нет, всё как раньше.
const NEAR_LINE := "float near = 1.0 - smoothstep(DETAIL_FAR * 0.35, DETAIL_FAR, length(wpos - CAMERA_POSITION_WORLD));"
static var _far_shader: Shader
static var _far_tuned_road_shader: Shader
static var _tuned_road_shader: Shader


func far_material(near_mat: ShaderMaterial) -> ShaderMaterial:
	var shader := near_mat.shader
	var is_tuned := shader != SHADER
	var far_shader := _far_tuned_road_shader if is_tuned else _far_shader
	if far_shader == null:
		var code := shader.code
		if code.count(NEAR_LINE) != 1:
			push_warning("TerrainBuilder.far_material: строка near в terrain.gdshader не найдена, дальнего варианта нет")
			return null
		far_shader = Shader.new()
		far_shader.code = code.replace(NEAR_LINE, "const float near = 0.0; // дальний вариант (TerrainBuilder.far_material)")
		if is_tuned:
			_far_tuned_road_shader = far_shader
		else:
			_far_shader = far_shader
	var mat := ShaderMaterial.new()
	mat.shader = far_shader
	for u: Dictionary in shader.get_shader_uniform_list():
		mat.set_shader_parameter(u.name, near_mat.get_shader_parameter(u.name))
	return mat


## Тот же материал для рельефа за краем карты: цвет из вершин
func outer_material(template_id := "") -> ShaderMaterial:
	var mat := _detail_material(template_id)
	mat.set_shader_parameter("use_vertex_color", true)
	return mat


## Compile the original edge expression at the shipped settings to preserve its rounding.
static func _terrain_shader(template_id := "") -> Shader:
	if RoadTuning.for_template(template_id).tread_cache_suffix().is_empty():
		return SHADER
	if _tuned_road_shader == null:
		_tuned_road_shader = Shader.new()
		_tuned_road_shader.code = "#define ROAD_TUNED_EDGE\n" + SHADER.code
	return _tuned_road_shader


func _detail_material(template_id := "") -> ShaderMaterial:
	if _detail.is_empty():
		var catalog := preload("res://scripts/render/asset_catalog.gd").get_catalog()
		_detail.assign([catalog.textures[3], catalog.textures[4]])
	var mat := ShaderMaterial.new()
	mat.shader = _terrain_shader(template_id)
	mat.set_shader_parameter("detail_tex", _detail[0])
	mat.set_shader_parameter("detail_normal", _detail[1])
	# 13.11: микроструктура земли (tools/bake_ground_micro.gd); без файлов шейдер работает как прежде
	if _micro.is_empty() and ResourceLoader.exists(MICRO_TEXTURE) and ResourceLoader.exists(MICRO_NORMAL):
		_micro.assign([load(MICRO_TEXTURE), load(MICRO_NORMAL)])
	if not _micro.is_empty():
		mat.set_shader_parameter("micro_tex", _micro[0])
		mat.set_shader_parameter("micro_n", _micro[1])
		mat.set_shader_parameter("micro_enabled", true)
	var surfaces := PackedVector3Array([Vector3.ZERO])
	for s: Dictionary in RoadSurface.LIST.slice(1):
		surfaces.append(Vector3(s.grain, s.organic, s.rough))
	mat.set_shader_parameter("surface_detail", surfaces)
	mat.set_shader_parameter("surface_bump", RoadBump.surface_list(template_id))
	mat.set_shader_parameter("surface_crack", PackedFloat32Array(RoadBump.CRACKS))
	mat.set_shader_parameter("surface_look", PackedVector4Array(RoadBump.LOOK))
	mat.set_shader_parameter("road_rut", RoadBump.rut_params(template_id))
	var cfg := WorldTemplate.config(template_id)
	mat.set_shader_parameter("trail_look", Vector4(cfg.trail_loam_darkness, cfg.trail_wet_gloss, cfg.trail_edge_litter, cfg.forest_micro_bump))
	mat.set_shader_parameter("trail_litter_col", cfg.trail_russet_litter)
	mat.set_shader_parameter("expedition_floor", template_id == WorldTemplate.EXPEDITION_ID)
	if mat.shader != SHADER:
		var section := RoadTuning.for_template(template_id).section
		mat.set_shader_parameter("road_edge", Vector3(section.edge, section.litter, 1.0 / section.fade))
	return mat


func reset() -> void:
	_detail.clear()
	_micro.clear()
