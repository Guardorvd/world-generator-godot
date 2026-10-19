class_name VegetationLayer
extends Node3D
## Растительность вокруг игрока: деревья, кусты, камни и трава — мультимеши, которые
## перезаполняются, когда игрок отходит достаточно далеко. Копия js/render3d/vegetation.js.
## Буферы экземпляров заполняются в задаче WorkerThreadPool, а в мультимеши попадают в главном потоке,
## когда задача готова: так ходьба не подтормаживает на каждом обновлении.

const TILE := GameConfig.TILE
const WATER_MARGIN := 0.3  # на сколько метров вода должна быть выше земли, чтобы дерево сочли затопленным

var world: WorldData
var heights: Heightfield
var veg := {}             # вид -> {cap, def, trunk: MultiMesh, crown: MultiMesh}
var grass: MultiMesh
var grass_buf: PackedFloat32Array
var last_fill := Vector2.INF
var last_trees := Vector2.INF
var _task := -1           # задача заполнения буферов или -1
var _task_trees := false  # задача заполняет и деревья, не только траву
var _tree_counts := {}    # вид -> число экземпляров в буферах (пишет задача, читает главный поток после её конца)
var _grass_n := 0
var _pending: Array = []  # виды деревьев, буферы которых ещё нужно передать; до конца передачи не пишем их
var _tree_bounds := {}
var _grass_bounds := AABB()
var _grass_margin := 0.0


func setup(w: WorldData, h: Heightfield, defs: Dictionary, grass_mesh: Mesh) -> void:
	world = w
	heights = h
	# По паре мультимешей (ствол, крона) на каждый вид, который есть в мире
	var totals := {}
	for k in w.obj_k:
		totals[k] = totals.get(k, 0) + 1
	for k in defs:
		if not totals.has(k):
			continue
		var def: Dictionary = defs[k]
		var cap := mini(totals[k], 24000)
		var entry := {cap = cap, def = def, radius = 0.0}
		if def.has("trunk"):
			var mat := StandardMaterial3D.new()
			mat.albedo_color = def.bark
			mat.roughness = 1.0
			entry.trunk = _multimesh(def.trunk, mat, cap, false)
			entry.tbuf = _buffer(cap, 12)
			entry.radius = maxf(entry.radius, _radius(def.trunk))
		if def.has("crown"):
			entry.crown = _multimesh(def.crown, _vcolor_mat(false), cap, true)
			entry.cbuf = _buffer(cap, 16)
			entry.radius = maxf(entry.radius, _radius(def.crown))
		veg[k] = entry
	# Трава у ног
	grass = _multimesh(grass_mesh, _vcolor_mat(true), GameConfig.GRASS_MAX, true, false)
	_grass_margin = _radius(grass_mesh) * 1.5
	grass_buf = _buffer(GameConfig.GRASS_MAX, 16)


## Материал для мешей с цветом вершин (крона, трава)
static func _vcolor_mat(two_sided: bool) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.vertex_color_is_srgb = true
	mat.roughness = 1.0
	if two_sided:
		mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	return mat


## Буфер экземпляров: по stride чисел на экземпляр (матрица 3×4 и, если есть, цвет)
static func _buffer(cap: int, stride: int) -> PackedFloat32Array:
	var b := PackedFloat32Array()
	b.resize(cap * stride)
	return b


static func _radius(mesh: Mesh) -> float:
	var box := mesh.get_aabb()
	return box.position.length() + box.size.length()


func _multimesh(mesh: Mesh, mat: Material, cap: int, colors: bool, shadows: bool = true) -> MultiMesh:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = colors
	mm.mesh = mesh
	mm.instance_count = cap
	mm.visible_instance_count = 0
	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = mm
	mmi.material_override = mat
	if not shadows:
		mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mmi)
	return mm


## Заполнение деревьев и травы вокруг игрока (x, z в метрах). force — сразу и в этом же кадре
## (при появлении игрока), иначе в фоне: сначала трава, затем деревья по видам в следующих кадрах.
## Пока задача или передача идут, новую не запускаем. В кадре передаём траву либо один вид деревьев.
## true — в этом кадре передавались буферы (дальний рельеф может отложить свою передачу).
func update(px: float, pz: float, force: bool) -> bool:
	if force:
		_pending.clear()
	elif not _pending.is_empty():
		_apply_tree(_pending.pop_back())
		return true
	if _task != -1:
		if not force and not WorkerThreadPool.is_task_completed(_task):
			return false
		WorkerThreadPool.wait_for_task_completion(_task)
		_task = -1
		if not force:
			_apply(false)
			if _task_trees:
				_pending = veg.keys()
			return true
	var p := Vector2(px, pz)
	if not force and last_fill != Vector2.INF and p.distance_to(last_fill) < 8.0:
		return false
	var move_trees := force or last_trees == Vector2.INF or p.distance_to(last_trees) > 30.0
	last_fill = p
	if move_trees:
		last_trees = p
	if force:
		_fill(px, pz, move_trees)
		_apply(move_trees)
	else:
		_task_trees = move_trees
		_task = WorkerThreadPool.add_task(_fill.bind(px, pz, move_trees), true, "Растительность")
	return force


func _exit_tree() -> void:
	# Задача обращается к узлу, поэтому дожидаемся её до выхода из дерева
	if _task != -1:
		WorkerThreadPool.wait_for_task_completion(_task)
		_task = -1


## Заполнить буферы (в задаче пула потоков): мультимеши здесь не трогаются
func _fill(px: float, pz: float, trees: bool) -> void:
	if trees:
		_fill_trees(px, pz)
	_fill_grass(px, pz)


## Передать заполненные буферы мультимешам (в главном потоке)
func _apply(trees: bool) -> void:
	if trees:
		for k in veg:
			_apply_tree(k)
	grass.buffer = grass_buf
	grass.custom_aabb = _grass_bounds
	grass.visible_instance_count = _grass_n


func _apply_tree(kind: int) -> void:
	var e: Dictionary = veg[kind]
	var count: int = _tree_counts[kind]
	if e.has("trunk"):
		e.trunk.buffer = e.tbuf
		e.trunk.custom_aabb = _tree_bounds[kind]
		e.trunk.visible_instance_count = count
	if e.has("crown"):
		e.crown.buffer = e.cbuf
		e.crown.custom_aabb = _tree_bounds[kind]
		e.crown.visible_instance_count = count


## Строка матрицы экземпляра: поворот вокруг вертикали, масштаб (s, sy, s), положение
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


func _fill_trees(px: float, pz: float) -> void:
	var w := world
	var rT := GameConfig.TREE_R / TILE
	var tx := px / TILE
	var tz := pz / TILE
	var cx0 := maxi(0, floori((tx - rT) / w.CS))
	var cx1 := mini(w.CW - 1, floori((tx + rT) / w.CS))
	var cy0 := maxi(0, floori((tz - rT) / w.CS))
	var cy1 := mini(w.CH - 1, floori((tz + rT) / w.CS))
	var counts := {}
	var bounds := {}
	var tbufs := {}
	var cbufs := {}
	for k in veg:
		counts[k] = 0
		bounds[k] = AABB()
		var e: Dictionary = veg[k]
		if e.has("trunk"):
			tbufs[k] = e.tbuf
		if e.has("crown"):
			cbufs[k] = e.cbuf
	for cy in range(cy0, cy1 + 1):
		for cx in range(cx0, cx1 + 1):
			for o in w.chunks[cy * w.CW + cx]:
				var ox := w.obj_x[o]
				var oy := w.obj_y[o]
				var dx := ox - tx
				var dz := oy - tz
				if dx * dx + dz * dz > rT * rT:
					continue
				var kind := w.obj_k[o]
				if not veg.has(kind):
					continue
				var e: Dictionary = veg[kind]
				var n: int = counts[kind]
				if n >= e.cap:
					continue
				var x := ox * TILE
				var z := oy * TILE
				# Дорогу и мост не занимаем; дерево, стоящее под водой, не показываем.
				# Тростник растёт у воды, его не трогаем
				var cell := floori(oy) * w.W + floori(ox)
				if w.path_mask[cell] >= 2:
					continue
				var ground := heights.ground_at(x, z)
				if kind != Biomes.T_REED and ground < heights.water_level[cell] - WATER_MARGIN:
					continue
				counts[kind] = n + 1
				var rot := WGRandom.hash2(floori(ox * 97), floori(oy * 89), 7) * PI * 2.0
				var v := w.obj_v[o]
				var s := w.obj_s[o] * (1.2 if kind == Biomes.T_ROCK else 1.0)
				var sy := s * (0.9 + (v % 3) * 0.08)
				var y := ground - 0.1
				var margin: float = e.radius * maxf(s, sy)
				var box := AABB(Vector3(x, y, z) - Vector3.ONE * margin, Vector3.ONE * margin * 2.0)
				bounds[kind] = box if n == 0 else bounds[kind].merge(box)
				if tbufs.has(kind):
					_put_xform(tbufs[kind], n * 12, x, y, z, rot, s, sy)
				if cbufs.has(kind):
					var buf: PackedFloat32Array = cbufs[kind]
					_put_xform(buf, n * 16, x, y, z, rot, s, sy)
					var leaves: Array = e.def.leaves
					var col: Color = leaves[v % leaves.size()]
					buf[n * 16 + 12] = col.r
					buf[n * 16 + 13] = col.g
					buf[n * 16 + 14] = col.b
					buf[n * 16 + 15] = 1.0
	_tree_counts = counts
	_tree_bounds = bounds


## Трава: детерминированно по клеткам, чтобы не «прыгала» при обновлении.
## Плотность и цвет берутся из поля grass биома (scripts/data/biomes.gd)
func _fill_grass(px: float, pz: float) -> void:
	var w := world
	var rT := GameConfig.GRASS_R / TILE
	var tx := px / TILE
	var tz := pz / TILE
	var buf := grass_buf
	var n := 0
	var low := Vector3.INF
	var high := -Vector3.INF
	for j in range(maxi(0, floori(tz - rT)), mini(w.H - 1, floori(tz + rT)) + 1):
		for i in range(maxi(0, floori(tx - rT)), mini(w.W - 1, floori(tx + rT)) + 1):
			# Буфер полон: остальные клетки уже не поместятся
			if n >= GameConfig.GRASS_MAX:
				break
			var k := j * w.W + i
			var bd: Dictionary = Biomes.LIST[w.biome[k]]
			if not bd.has("grass") or w.river[k] != 0 or w.path_mask[k] >= 2:
				continue
			if (i + 0.5 - tx) ** 2 + (j + 0.5 - tz) ** 2 > rT * rT:
				continue
			var gr: Dictionary = bd.grass
			# с 2.8: на кручах травы меньше, у воды гуще
			var lush := clampf(1.0 - 0.45 * (w.slope[k] - 0.5), 0.35, 1.0) * (1.25 if w.dist_water[k] < 3.0 else 1.0)
			var cnt := floori(gr.dens * (0.5 + WGRandom.hash2(i, j, 5)) * lush)
			var tc: Array = gr.tint
			for m in cnt:
				if n >= GameConfig.GRASS_MAX:
					break
				var x := (i + WGRandom.hash2(i * 7 + m, j, 11)) * TILE
				var z := (j + WGRandom.hash2(i, j * 7 + m, 13)) * TILE
				var y := heights.ground_at(x, z)
				if y < heights.water_level[k]:
					continue
				var s := 0.8 + WGRandom.hash2(i + m, j - m, 17) * 0.7
				_put_xform(buf, n * 16, x, y - 0.05, z, WGRandom.hash2(i - m, j + m, 19) * 6.28, s, s)
				var origin := Vector3(x, y - 0.05, z)
				low = low.min(origin)
				high = high.max(origin)
				var v := 1.0 + WGRandom.hash2(m, i + j, 23) * 0.3
				buf[n * 16 + 12] = tc[0] * v
				buf[n * 16 + 13] = tc[1] * v
				buf[n * 16 + 14] = tc[2] * v
				buf[n * 16 + 15] = 1.0
				n += 1
	_grass_n = n
	_grass_bounds = AABB(low, high - low).grow(_grass_margin) if n > 0 else AABB()
