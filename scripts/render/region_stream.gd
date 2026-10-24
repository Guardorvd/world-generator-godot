class_name RegionStream
extends Node3D
## 13.9: соседние области в игре. Ближайшая к игроку неготовая область за краем плана готовится
## в задаче WorkerThreadPool (по одной): заготовка, реки, поселения, дороги, закрепление в журнале.
## Готовая область передаётся в существующую загрузку: OuterLand берёт её клетки (рельеф кусков,
## высоты, вода, растительность), а здесь в главном потоке собираются вода, дороги, мосты и дома.
## Порядок подготовки зависит от пути игрока, но закреплённое потом не перестраивается.
## 13.9+: журнал хранится на диске (store_dir, общий для слотов сохранения этого мира) и
## восстанавливается при загрузке. Далёкие области освобождаются: узлы — дальше HIDE, поля
## клеток — дальше EVICT (остаются в файле и читаются снова при возвращении ближе KEEP).
## 14.4: меши воды и дорог области считаются в фоновой задаче (build_arrays), главный поток только
## собирает узлы — меньше заметных подёргиваний у края плана. Дороги — мягкая лента по рельефу
## (ROAD_SHADER): сглаженные повороты, плотная сетка поперёк, рваный прозрачный край и фактура;
## там, где у плана уже есть своя дорога, лента не кладётся поверх неё.

const Regions := preload("res://scripts/world/region_preparation.gd")
const TILE := GameConfig.TILE
const HS := GameConfig.HS
const REACH := OuterTerrain.RADIUS + 400.0 # м: области ближе готовятся заранее, до того как их видно
const QUEUE := 4                            # сколько ближайших неготовых областей держать в очереди
const HIDE := OuterTerrain.DROP + 200.0     # м: дальше узлы области (вода, дороги, мосты, дома) убираются
const KEEP := 2800.0                        # м: ближе поля клеток в памяти (соседи готовящейся области — ближе)
const EVICT := 3400.0                       # м: дальше поля клеток выгружаются из памяти
const RECHECK := 32.0                       # м пути между пересмотром очереди и выгрузки
const FORMAT := 2                           # 14.4: гуще поселения областей — прежние журналы не читаются
const ROAD_LIFT := 0.05                     # м: полотно над рельефом без мерцания
const ROAD_COLOR := Color8(0x8e, 0x7d, 0x62)
const ROAD_STEP := 1.0                      # м: шаг точек ленты вдоль дороги
const ROAD_ACROSS := [-1.15, -0.6, 0.0, 0.6, 1.15] # доли полуширины: края чуть шире полотна и прозрачны
const ROAD_SHADER := """shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_disabled;
uniform sampler2D detail_tex : hint_default_white, filter_linear_mipmap, repeat_enable;
uniform vec3 road_color : source_color;
varying vec3 wpos;
void vertex() {
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}
void fragment() {
	float n1 = texture(detail_tex, wpos.xz * 0.09).r;
	float n2 = texture(detail_tex, wpos.xz * 0.47).r;
	// край полотна рваный: прозрачность по поперечной доле с шумом, а не ровной линией
	float edge = COLOR.a + (n1 - 0.5) * 0.4 + (n2 - 0.5) * 0.15;
	ALPHA = smoothstep(0.12, 0.5, edge);
	float ruts = exp(-pow((abs(UV.x) - 0.42) / 0.12, 2.0));
	ALBEDO = road_color * (0.85 + (n1 - 0.5) * 0.32 + (n2 - 0.5) * 0.2) * (1.0 - ruts * 0.09);
	ROUGHNESS = 0.95;
}
"""
static var root := "user://regions"         # тесты подменяют

var world: WorldData
var heights: Heightfield
var terrain: OuterTerrain
var vegetation: VegetationLayer
var ledger := {}
var failed := {}        # области, которые не удалось подготовить: остаются внешним рельефом
var fires: Array = []   # костры поселений показанных областей (как SettlementsBuilder.build)
var windows: Array = [] # материалы окон, ночью ярче
var boards: Array = []  # доски маршрутов показанных поселений: {at, place}, как GameWorld._boards
var queue: Array[Vector2i] = []
var stats := {prepared = 0, loaded = 0, evicted = 0, built = 0, hidden = 0, apply_ms = 0.0, show_ms = 0.0}
var _task := -1
var _out := {}
var _key := Vector2i.ZERO
var _shown := {}        # область -> {node, fires, windows}
var _bridges := {}      # область -> её мосты в Heightfield (регистрируются один раз)
var _checked_at := Vector2.INF
var _road_mat: ShaderMaterial
var _build_task := -1   # 14.4: фоновый расчёт мешей воды и дорог области _build_key
var _build_key := Vector2i.ZERO
var _build_out := {}


func setup(w: WorldData, h: Heightfield, t: OuterTerrain, v: VegetationLayer) -> void:
	world = w
	heights = h
	terrain = t
	vegetation = v
	_road_mat = ShaderMaterial.new()
	_road_mat.shader = Shader.new()
	_road_mat.shader.code = ROAD_SHADER
	_road_mat.set_shader_parameter("road_color", ROAD_COLOR)
	_road_mat.set_shader_parameter("detail_tex", TerrainBuilder.outer_material().get_shader_parameter("detail_tex"))


## Папка журнала этого мира: тот же план (зерно, размер, рельеф, пути) — те же области.
static func store_dir(w: WorldData) -> String:
	var id := "%s|%d|%d|%d|%d|%d" % [w.seed_text, w.W, w.H, hash(w.h), hash(w.path_mask), FORMAT]
	return root.path_join(id.sha256_text().substr(0, 24))


## Сохранённый журнал мира без полей клеток или {} (места и задания читают его и до игры)
static func read_ledger(w: WorldData) -> Dictionary:
	var path := store_dir(w).path_join("ledger.bin")
	if not FileAccess.file_exists(path):
		return {}
	var f := FileAccess.open_compressed(path, FileAccess.READ, FileAccess.COMPRESSION_ZSTD)
	var saved: Variant = f.get_var() if f != null else null
	if not saved is Dictionary or saved.get("format") != FORMAT:
		push_warning("Журнал областей не прочитан: %s" % path)
		return {}
	return saved.ledger


## Восстановить сохранённый журнал; поля областей ближе KEEP к точке (x, z) — сразу.
func restore(x: float, z: float) -> void:
	ledger = read_ledger(world)
	if ledger.is_empty():
		return
	for key: Vector2i in ledger.regions:
		if _distance(key, Vector2(x, z)) <= KEEP:
			_load_fields(key)
	world.outer.set_ledger(ledger)


## Каждый кадр: забрать готовую область, затем одно действие — показать, убрать, подгрузить,
## выгрузить или начать следующую. true — в кадре была заметная работа главного потока.
func update(x: float, z: float) -> bool:
	var p := Vector2(x, z)
	if _task != -1 and WorkerThreadPool.is_task_completed(_task):
		WorkerThreadPool.wait_for_task_completion(_task)
		_task = -1
		_apply(_key, _out.get("r", {}))
		return true
	if _build_task != -1 and WorkerThreadPool.is_task_completed(_build_task):
		WorkerThreadPool.wait_for_task_completion(_build_task)
		_build_task = -1
		var entry: Variant = ledger.get("regions", {}).get(_build_key)
		if entry != null and entry.has("fields") and not _shown.has(_build_key) and _distance(_build_key, p) <= REACH:
			_show(_build_key, _build_out)
			return true
	if p.distance_to(_checked_at) > RECHECK:
		_checked_at = p
		_plan(p)
	for key: Vector2i in ledger.get("regions", {}):
		var d := _distance(key, p)
		var entry: Dictionary = ledger.regions[key]
		if d <= KEEP and not entry.has("fields"):
			_load_fields(key)
			world.outer.set_ledger(ledger)
			terrain.refresh(entry.rect.grow(2))
			vegetation.refresh(entry.rect.grow(2))
			return true
		if d > EVICT and entry.has("fields"):
			_evict(key)
			return false
		if d <= REACH and not _shown.has(key) and entry.has("fields"):
			if _build_task == -1:
				_start_build(key)
			continue
		if d > HIDE and _shown.has(key):
			_hide(key)
			return true
	if _task == -1 and not queue.is_empty():
		var key: Vector2i = queue.pop_front()
		if ledger.get("regions", {}).has(key) or failed.has(key) or not _neighbors_ready(key):
			_checked_at = Vector2.INF # пересмотреть очередь в следующем кадре
			return false
		_key = key
		_out = {}
		var out := _out
		var snapshot := ledger
		var w := world
		var dir := store_dir(world)
		_task = WorkerThreadPool.add_task(func() -> void: out.r = prepare_region(w, key, snapshot, dir), false, "Область")
	return false


func finish() -> void:
	if _task != -1:
		WorkerThreadPool.wait_for_task_completion(_task)
		_task = -1
	if _build_task != -1:
		WorkerThreadPool.wait_for_task_completion(_build_task)
		_build_task = -1


## 14.4: меши воды и дорог области — в фоне, по снимку журнала (поля областей там не меняются)
func _start_build(key: Vector2i) -> void:
	_build_key = key
	_build_out = {}
	var out := _build_out
	var entry: Dictionary = ledger.regions[key]
	var regions: Dictionary = ledger.regions
	var w := world
	var h := heights
	_build_task = WorkerThreadPool.add_task(func() -> void:
		out.water = water_arrays(entry)
		out.roads = road_arrays(w, func(x: float, z: float) -> float: return snapshot_ground(w, h, regions, x, z), entry.decor.trails),
		false, "Узлы области")


func _exit_tree() -> void:
	finish()


## Подготовить, закрепить и записать одну область (в фоне). Река без допустимого русла не принимается:
## тогда область готовится без входящих рек, и вода кончается у её границы.
static func prepare_region(w: WorldData, key: Vector2i, current: Dictionary, dir := "") -> Dictionary:
	var r := Regions.prepare(w, key, current)
	var network := Regions.prepare_rivers(r)
	var batch := Regions.finish_neighbors(w, [r], [network])
	var dropped := 0
	if not batch.ready:
		dropped = r.river_inputs.size()
		r.river_inputs = []
		network = Regions.prepare_rivers(r)
		batch = Regions.finish_neighbors(w, [r], [network])
		if not batch.ready:
			return {ready = false, reason = batch.reason}
	var roads := Regions.prepare_roads(w, [r], batch, current)
	var done := Regions.commit(current, [r], [network], batch, roads)
	done.dropped_rivers = dropped
	done.roads = roads
	if done.ready:
		# Картинка области для большой карты: остаётся в журнале и после выгрузки полей.
		var entry: Dictionary = done.ledger.regions[key]
		entry.map = map_png(entry)
	if done.ready and not dir.is_empty():
		var err := save(dir, done.ledger, key)
		if err != OK:
			push_warning("Область %s не записана: ошибка %d" % [key, err])
	return done


## Поля области — в свой файл, журнал без полей — в ledger.bin; запись через временный файл.
static func save(dir: String, current: Dictionary, key: Vector2i) -> Error:
	var err := DirAccess.make_dir_recursive_absolute(dir)
	if err != OK:
		return err
	var entry: Dictionary = current.regions[key]
	err = _write(dir.path_join("%d_%d.region" % [key.x, key.y]), {format = FORMAT, rect = entry.rect, fields = entry.fields})
	if err != OK:
		return err
	var light := current.duplicate()
	light.regions = {}
	for k: Vector2i in current.regions:
		var e: Dictionary = current.regions[k]
		light.regions[k] = {rect = e.rect, decor = e.decor, map = e.get("map", PackedByteArray())}
	return _write(dir.path_join("ledger.bin"), {format = FORMAT, ledger = light})


static func _write(path: String, value: Variant) -> Error:
	var f := FileAccess.open_compressed(path + ".tmp", FileAccess.WRITE, FileAccess.COMPRESSION_ZSTD)
	if f == null:
		return FileAccess.get_open_error()
	f.store_var(value)
	f.close()
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)
	return DirAccess.rename_absolute(path + ".tmp", path)


## Очередь: ближайшие неготовые области за краем плана ближе REACH, не больше QUEUE
func _plan(p: Vector2) -> void:
	var c := p / TILE
	var reach := REACH / TILE
	var size := WorldData.REGION_SIZE
	var plan := Rect2i(0, 0, world.W, world.H)
	var regions: Dictionary = ledger.get("regions", {})
	var found: Array = []
	for ky in range(floori((c.y - reach) / size), floori((c.y + reach) / size) + 1):
		for kx in range(floori((c.x - reach) / size), floori((c.x + reach) / size) + 1):
			var key := Vector2i(kx, ky)
			if Regions.rect_for(key).intersects(plan) or regions.has(key) or failed.has(key) or (_task != -1 and key == _key):
				continue
			var d := _distance(key, p)
			if d <= REACH:
				found.append([d, key])
	found.sort_custom(func(a: Array, b: Array) -> bool:
		return a[0] < b[0] or a[0] == b[0] and (a[1].y < b[1].y or a[1].y == b[1].y and a[1].x < b[1].x))
	queue.clear()
	for item: Array in found.slice(0, QUEUE):
		queue.append(item[1])


## Соседи готовящейся области передают ей окончательные клетки: их поля должны быть в памяти
func _neighbors_ready(key: Vector2i) -> bool:
	for dy in range(-1, 2):
		for dx in range(-1, 2):
			var e: Variant = ledger.get("regions", {}).get(key + Vector2i(dx, dy))
			if e != null and not e.has("fields"):
				return false
	return true


func _distance(key: Vector2i, p: Vector2) -> float:
	var rect := Regions.rect_for(key)
	var a := Vector2(rect.position) * TILE
	return p.distance_to(p.clamp(a, a + Vector2(rect.size) * TILE))


func _load_fields(key: Vector2i) -> void:
	var path := store_dir(world).path_join("%d_%d.region" % [key.x, key.y])
	var f := FileAccess.open_compressed(path, FileAccess.READ, FileAccess.COMPRESSION_ZSTD)
	var saved: Variant = f.get_var() if f != null else null
	if not saved is Dictionary or saved.get("format") != FORMAT:
		push_warning("Поля области %s не прочитаны" % key)
		return
	ledger = ledger.duplicate()
	ledger.regions = ledger.regions.duplicate()
	var entry: Dictionary = ledger.regions[key].duplicate()
	entry.fields = saved.fields
	ledger.regions[key] = entry
	stats.loaded += 1


## Поля далёкой области остаются только в файле; запись журнала (rect, decor) — в памяти
func _evict(key: Vector2i) -> void:
	ledger = ledger.duplicate()
	ledger.regions = ledger.regions.duplicate()
	var entry: Dictionary = ledger.regions[key].duplicate()
	entry.erase("fields")
	ledger.regions[key] = entry
	world.outer.set_ledger(ledger)
	stats.evicted += 1


func _apply(key: Vector2i, done: Dictionary) -> void:
	var started := Time.get_ticks_usec()
	if not done.get("ready", false):
		failed[key] = true
		push_warning("Область %s не подготовлена: %s" % [key, done.get("reason", "")])
		return
	# Результат строился на снимке журнала: перенести прочитанные и выгруженные с тех пор поля.
	var next: Dictionary = done.ledger
	next.regions = next.regions.duplicate()
	for k: Vector2i in ledger.get("regions", {}):
		if next.regions.has(k) and ledger.regions[k].has("fields") != next.regions[k].has("fields"):
			next.regions[k] = ledger.regions[k]
	ledger = next
	world.outer.set_ledger(ledger)
	var rect := Regions.rect_for(key)
	terrain.refresh(rect.grow(2))
	vegetation.refresh(rect.grow(2))
	stats.prepared += 1
	stats.apply_ms = maxf(stats.apply_ms, (Time.get_ticks_usec() - started) / 1000.0)
	_checked_at = Vector2.INF # узлы покажет следующий кадр: принятие и сборка в разных кадрах


## Узлы области: вода по мокрым клеткам, лента дорог, мосты и дома штатными сборщиками.
## arrays — посчитанные в фоне {water, roads}; без них считаются здесь
func _show(key: Vector2i, arrays := {}) -> void:
	var started := Time.get_ticks_usec()
	var entry: Dictionary = ledger.regions[key]
	var decor: Dictionary = entry.decor
	var node := Node3D.new()
	node.name = "Region_%d_%d" % [key.x, key.y]
	add_child(node)
	var water := WaterBuilder._flat_mesh(arrays.water if arrays.has("water") else water_arrays(entry), WaterBuilder._material(), "Water")
	if water != null:
		water.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		node.add_child(water)
	var ribbons: Array = arrays.roads if arrays.has("roads") else _road_arrays(decor.trails)
	if not ribbons.is_empty():
		var mesh := ArrayMesh.new()
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, ribbons)
		var mi := MeshInstance3D.new()
		mi.name = "Roads"
		mi.mesh = mesh
		mi.material_override = _road_mat
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		node.add_child(mi)
	if not _bridges.has(key):
		_bridges[key] = heights.add_outer_bridges(decor.bridges)
	StructuresBuilder.build(node, heights, _bridges[key])
	# Тот же сборщик домов, что у плана: временный мир только со списком поселений области.
	var places := WorldData.new()
	places.seed_num = world.seed_num ^ (key.x * 73856093) ^ (key.y * 19349663)
	places.settlements = decor.settlements
	var built := SettlementsBuilder.build(node, places, heights)
	var own: Array = []
	for s: Dictionary in decor.settlements:
		var foot := SettlementsBuilder.board_foot(s, heights)
		own.append({at = Transform3D(Basis(Vector3.UP, -PI / 4.0), foot + Vector3(0, 1.35, 0)), place = s})
	_shown[key] = {node = node, fires = built.fires, windows = built.windows, boards = own}
	stats.built += 1
	stats.show_ms = maxf(stats.get("show_ms", 0.0), (Time.get_ticks_usec() - started) / 1000.0)
	_collect()


func _hide(key: Vector2i) -> void:
	_shown[key].node.queue_free()
	_shown.erase(key)
	stats.hidden += 1
	_collect()


func _collect() -> void:
	fires = []
	windows = []
	boards = []
	for key: Vector2i in _shown:
		fires.append_array(_shown[key].fires)
		windows.append(_shown[key].windows)
		boards.append_array(_shown[key].boards)


## Сколько областей с полями в памяти и показанных (для проверок памяти)
func counts() -> Dictionary:
	var with_fields := 0
	for key: Vector2i in ledger.get("regions", {}):
		with_fields += int(ledger.regions[key].has("fields"))
	return {regions = ledger.get("regions", {}).size(), fields = with_fields, shown = _shown.size()}


## Карта области в PNG, клетка — пиксель: цвет биома с отмывкой склонов, вода, дороги.
static func map_png(region: Dictionary) -> PackedByteArray:
	var rect: Rect2i = region.rect
	var f: Dictionary = region.fields
	var W := rect.size.x
	var H := rect.size.y
	var img := Image.create(W, H, false, Image.FORMAT_RGB8)
	var water := Color8(0x4a, 0x7f, 0xb0)
	var road := Color8(0xb8, 0x9a, 0x6a)
	for y in H:
		for x in W:
			var i := y * W + x
			var c: Color
			if f.river[i] != 0 or f.lake[i] != 0:
				c = water
			elif f.path[i] >= 2:
				c = road
			else:
				var rgb: Array = Biomes.LIST[f.biome[i]].color
				c = Color8(rgb[0], rgb[1], rgb[2])
				# свет с северо-запада, как отмывка карты плана
				var dx: float = f.h[y * W + mini(x + 1, W - 1)] - f.h[y * W + maxi(x - 1, 0)]
				var dy: float = f.h[mini(y + 1, H - 1) * W + x] - f.h[maxi(y - 1, 0) * W + x]
				c = c * clampf(1.0 - (dx + dy) * 6.0, 0.6, 1.3)
			img.set_pixel(x, y, c)
	return img.save_png_to_buffer()


## Плоская вода области: квадрат на каждую мокрую клетку, углы — средний уровень соседних мокрых
## клеток, поэтому поверхность непрерывна и вдоль русла понижается без ступенек.
static func water_arrays(region: Dictionary) -> Array:
	var rect: Rect2i = region.rect
	var f: Dictionary = region.fields
	var W := rect.size.x
	var H := rect.size.y
	var level: PackedFloat32Array = f.water_level
	var wet := PackedByteArray()
	wet.resize(W * H)
	var any := false
	for i in W * H:
		if (f.river[i] != 0 or f.lake[i] != 0) and is_finite(level[i]):
			wet[i] = 1
			any = true
	var pos := PackedVector3Array()
	if not any:
		return []
	var corner := PackedVector3Array()
	corner.resize(4)
	for y in H:
		for x in W:
			if wet[y * W + x] == 0:
				continue
			for c in 4:
				var cx := x + (c & 1)
				var cy := y + (c >> 1)
				var sum := 0.0
				var n := 0
				for d in 4:
					var nx := cx - 1 + (d & 1)
					var ny := cy - 1 + (d >> 1)
					if nx >= 0 and ny >= 0 and nx < W and ny < H and wet[ny * W + nx] != 0:
						sum += level[ny * W + nx]
						n += 1
				corner[c] = Vector3((rect.position.x + cx) * TILE, maxf(0.0, sum / n) * HS, (rect.position.y + cy) * TILE)
			pos.append_array([corner[0], corner[1], corner[2], corner[1], corner[3], corner[2]])
	return WaterBuilder._arrays(pos)


## Полотно дорог области лентой над рельефом в главном потоке (Heightfield игры)
func _road_arrays(trails: Array) -> Array:
	return road_arrays(world, func(x: float, z: float) -> float: return heights.ground_at(x, z), trails)


## Высота земли для фоновой задачи: внутри плана — Heightfield (его поля после загрузки не меняются),
## за краем — поля закреплённых областей из снимка журнала, той же триангуляцией, что сетка рельефа.
## Куски OuterLand не читаются: главный поток в это время их меняет.
static func snapshot_ground(w: WorldData, heights: Heightfield, regions: Dictionary, x: float, z: float) -> float:
	var fx := x / TILE - 0.5
	var fz := z / TILE - 0.5
	if fx >= 0.0 and fz >= 0.0 and fx <= w.W - 1.001 and fz <= w.H - 1.001:
		return heights.ground_at(x, z)
	var i := floori(fx)
	var j := floori(fz)
	var a := _cell_m(w, heights, regions, i, j)
	var b := _cell_m(w, heights, regions, i + 1, j)
	var c := _cell_m(w, heights, regions, i, j + 1)
	var d := _cell_m(w, heights, regions, i + 1, j + 1)
	var tx := fx - i
	var tz := fz - j
	if tx + tz <= 1.0:
		return a + (b - a) * tx + (c - a) * tz
	return d + (c - d) * (1.0 - tx) + (b - d) * (1.0 - tz)


static func _cell_m(w: WorldData, heights: Heightfield, regions: Dictionary, i: int, j: int) -> float:
	if i >= 0 and j >= 0 and i < w.W and j < w.H:
		return heights.hv[j * w.W + i]
	var size := WorldData.REGION_SIZE
	var r: Variant = regions.get(Vector2i(floori(float(i) / size), floori(float(j) / size)))
	if r == null or not r.has("fields"):
		return heights.hv[clampi(j, 0, w.H - 1) * w.W + clampi(i, 0, w.W - 1)]
	var rect: Rect2i = r.rect
	return Heightfield.outer_meters(r.fields.h[(j - rect.position.y) * rect.size.x + i - rect.position.x])


## 14.4: лента дорог. Повороты сглажены (два прохода Чайкина), точки каждые ROAD_STEP м, поперёк пять
## рядов: высота каждой вершины — земля под ней, поэтому лента ложится по рельефу, а не висит хордой.
## Прозрачность края — в цвете вершины (шейдер рвёт её шумом), UV.x — поперечная доля для колей.
## Участки по клеткам, где у плана уже есть дорога (path_mask ≥ 2), пропускаются: её рисует план.
static func road_arrays(w: WorldData, ground: Callable, trails: Array) -> Array:
	var pos := PackedVector3Array()
	var col := PackedColorArray()
	var uv := PackedVector2Array()
	var idx := PackedInt32Array()
	for trail: Dictionary in trails:
		var pts: Array = trail.pts
		var line := PackedVector2Array()
		var half := PackedFloat32Array()
		for p: Dictionary in pts:
			line.append(Vector2(p.x, p.y) * TILE)
			half.append(float(p.w) * TILE * 0.5)
		for pass_n in 2:
			if line.size() < 3:
				break
			var sl := PackedVector2Array([line[0]])
			var sh := PackedFloat32Array([half[0]])
			for k in line.size() - 1:
				sl.append_array([line[k].lerp(line[k + 1], 0.25), line[k].lerp(line[k + 1], 0.75)])
				sh.append_array([lerpf(half[k], half[k + 1], 0.25), lerpf(half[k], half[k + 1], 0.75)])
			sl.append(line[-1])
			sh.append(half[-1])
			line = sl
			half = sh
		# ровный шаг вдоль дороги
		var dense := PackedVector2Array()
		var dhalf := PackedFloat32Array()
		for k in line.size():
			if k > 0:
				var q := line[k - 1]
				var steps := maxi(1, ceili(q.distance_to(line[k]) / ROAD_STEP))
				for st in range(1, steps):
					dense.append(q.lerp(line[k], float(st) / steps))
					dhalf.append(lerpf(half[k - 1], half[k], float(st) / steps))
			dense.append(line[k])
			dhalf.append(half[k])
		var run := -1 # номер первой вершины текущего непрерывного участка
		for k in dense.size():
			var at := dense[k]
			var cell := Vector2i(floori(at.x / TILE), floori(at.y / TILE))
			if cell.x >= 0 and cell.y >= 0 and cell.x < w.W and cell.y < w.H and w.path_mask[cell.y * w.W + cell.x] >= 2:
				run = -1
				continue
			var along := (dense[mini(k + 1, dense.size() - 1)] - dense[maxi(k - 1, 0)]).normalized()
			var side := along.orthogonal() * dhalf[k]
			var base := pos.size()
			for u: float in ROAD_ACROSS:
				var v := at + side * u
				pos.append(Vector3(v.x, ground.call(v.x, v.y) + ROAD_LIFT, v.y))
				col.append(Color(1, 1, 1, clampf((1.15 - absf(u)) / 0.55, 0.0, 1.0)))
				uv.append(Vector2(u, 0.0))
			if run != -1:
				var n := ROAD_ACROSS.size()
				for c in n - 1:
					var a0 := base - n + c
					var b0 := base + c
					idx.append_array([a0, b0, a0 + 1, a0 + 1, b0, b0 + 1])
			run = base
	if idx.is_empty():
		return []
	var nor := PackedVector3Array()
	nor.resize(pos.size())
	nor.fill(Vector3.UP)
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = pos
	arrays[Mesh.ARRAY_NORMAL] = nor
	arrays[Mesh.ARRAY_COLOR] = col
	arrays[Mesh.ARRAY_TEX_UV] = uv
	arrays[Mesh.ARRAY_INDEX] = idx
	return arrays
