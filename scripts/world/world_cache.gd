class_name WorldCache
extends RefCounted
## Кэш готовых миров (с 10.0): данные генерации (WorldData) в файлах на диске игрока.
## Канонические слои отделены от базовой/окончательной поверхности и CPU-чанков отображения.
## Повреждение производного блока не удаляет канонический мир или прогресс игрока.
##
## С 10.2 кэш по слоям генерации (WorldGenerator.LAYERS): география, места и пути, природа — по файлу на слой.
## Ключ слоя — явная версия его схемы/результата генерации и ключ прошлого слоя, а не версия игры:
## после патча, который не трогал генерацию, мир берётся из кэша целиком; если поменялись только этапы мест
## и путей, география берётся из кэша, а генерация продолжается с мест. Первый слой хранит все поля мира,
## следующие — только поля, которые этот слой поменял.
## Четвёртый файл (VIEW) — готовые картинки мира: текстура рельефа, карта и лесная подстилка (их рисование —
## ~14 с загрузки из кэша), ключ — слой природы и версия картинок. Рядом — превью карты для меню (PREVIEW).
##
## Защиты:
## - ключ файла — формат кэша, сид, размеры и версии слоёв: старый файл не подходит и перезаписывается;
## - заголовок, размеры и хеш SHA-256 сжатых данных, проверка типов и длин массивов при чтении:
##   битый или чужой файл удаляется, мир генерируется заново;
## - запись во временный файл и переименование: оборванная запись не оставляет полуфайла под настоящим именем.
## Какие миры хранить, решает меню (последние и избранные, GameContext.scope.settings.keep_seeds); остальное удаляет keep_only.
## Включает кэш только сама игра (Main): инструменты проверки по умолчанию генерируют честно.

const FORMAT := 3 # 12.2: файлы слоёв, записанные после частичной загрузки, могли быть неполными
const MAGIC := "WGC2"
const EXT := ".wgc"
## Повышать при несовместимом изменении полей ИЛИ результатов соответствующего этапа.
## Общая версия — контракт WorldData, численные правила и единицы, влияющие на все слои.
## Любая версия инвалидирует свой слой и следующие; UI/рендеринг не требуют смены GEO/TRAILS.
const SCHEMA_WORLD_VERSION := 1
const SCHEMA_GEO_VERSION := 1
const SCHEMA_TRAILS_VERSION := 8 # 8: bike park laid out without the path bed (StageTrailPlan.VERSION 6); 7: house turn checked by its footing (audit 29.10); 6: bike park (StageTrailPlan.VERSION 5); 5: length preference and shared regional kit definitions (StageTrailPlan.VERSION 4)
const SCHEMA_NATURE_VERSION := 4 # coherent rock deposits, bounded density and climate exclusions
const SCHEMA_VIEW_VERSION := 1
## Картинки мира: имя файла и исходники рисования
const VIEW := "view"
const VIEW_IMAGES := ["terrain", "map", "forest"]
const PREVIEW := ".preview.png"
const PREVIEW_SIZE := 256
## Байт на пиксель у форматов картинок мира (другой формат в файле — файл чужой)
const PIXEL_BYTES := {Image.FORMAT_L8: 1, Image.FORMAT_R8: 1, Image.FORMAT_RG8: 2, Image.FORMAT_RGB8: 3, Image.FORMAT_RGBA8: 4}
## Поля по клетке: длина ровно N
const PER_CELL := ["h", "filled", "elev", "ocean", "lake", "river", "river_area", "acc", "slope", "watershed",
	"down", "rain", "dist_ocean", "dist_water", "temp", "moist", "biome", "cost", "path_mask", "road_surface", "lake_id"]
const PER_OBJECT := ["obj_x", "obj_y", "obj_k", "obj_v", "obj_s"]

var enabled := false
var dir := "user://world_cache"
## 14.5: готовые миры автора в проекте (RecommendedSeeds): копируются в dir, если их там нет
const BUNDLED := "res://resources/world_cache"
var _writes: Array[int] = []
var _lock := Mutex.new()
var _layer_keys := PackedStringArray()
const Files := preload("res://scripts/core/cache_file.gd")
const SURFACE_VERSION := 2 # terrain and water chunks are immutable lazy blocks
const BASE_VERSION := 1
var io_timings := {}
var _io_lock := Mutex.new()
var _write_lock := Mutex.new()
var _enqueue_lock := Mutex.new()
const WRITE_QUEUE_BYTES := 96 * 1024 * 1024
const WRITE_QUEUE_JOBS := 4
var _jobs: Array[Dictionary] = []
var _writer_active := false
var _pending_bytes := 0
var _pending_jobs := 0
var _write_room := Semaphore.new()
var queue_stats := {wait_ms = 0.0, peak_bytes = 0, peak_jobs = 0, oversized_jobs = 0}
var cpu_budget: RefCounted
static var _file_pins := {}
static var _pin_lock := Mutex.new()
var _root_memo := {} # bounded validated manifest signatures -> referenced filenames, no physics arrays


## Ключи схем одинаковы в редакторе, PCK, Debug/Release и на всех платформах.
func layer_keys() -> PackedStringArray:
	_lock.lock()
	if _layer_keys.is_empty():
		_layer_keys = schema_keys(SCHEMA_WORLD_VERSION, PackedInt32Array([
			SCHEMA_GEO_VERSION, SCHEMA_TRAILS_VERSION, SCHEMA_NATURE_VERSION, SCHEMA_VIEW_VERSION]))
	var keys := _layer_keys.duplicate()
	_lock.unlock()
	return keys


## Чистая функция: только формат, размер плана, имена слоёв и явно переданные целочисленные версии.
static func schema_keys(world_version: int, versions: PackedInt32Array) -> PackedStringArray:
	assert(versions.size() == WorldGenerator.LAYERS.size() + 1)
	var keys := PackedStringArray()
	var prev := "WGC|%d|%d|%d" % [FORMAT, WorldGenerator.PLAN_SIZE, world_version]
	for k in versions.size():
		prev = ("%s|%s|%d" % [prev, _layer_name(k), versions[k]]).sha256_text()
		keys.append(prev.left(32))
	return keys


func _base(seed_text: String, size: int) -> String:
	return ("%s|%d|%d" % [seed_text, WorldGenerator.PLAN_SIZE, size]).md5_text()


## Имя слоя: слои генерации, за ними картинки (VIEW)
static func _layer_name(layer: int) -> String:
	return WorldGenerator.LAYERS[layer] if layer < WorldGenerator.LAYERS.size() else VIEW


func _key(seed_text: String, size: int, layer: int) -> String:
	return "%s|%d|%d|%s|%s" % [seed_text, WorldGenerator.PLAN_SIZE, size, _layer_name(layer), layer_keys()[layer]]


## Файл слоя layer мира (WorldGenerator.LAYERS.size() — картинки)
func path_for(seed_text: String, size: int, layer: int) -> String:
	return dir.path_join("%s.%s%s" % [_base(seed_text, size), _layer_name(layer), EXT])


## Файлы всех слоёв мира и картинок
func paths_for(seed_text: String, size: int = WorldGenerator.START_SIZE) -> Array[String]:
	var out: Array[String] = []
	for k in WorldGenerator.LAYERS.size() + 1:
		out.append(path_for(seed_text, size, k))
	return out


func artifact_path(seed_text: String, size: int, artifact: String) -> String:
	return dir.path_join("%s.%s%s" % [_base(seed_text, size), artifact, EXT])


func artifact_key(seed_text: String, size: int, artifact: String) -> String:
	var layer := 0 if artifact == "base" else 2
	var version := BASE_VERSION if artifact == "base" else SURFACE_VERSION
	return "%s|%s|%d|%d|%d|%d" % [_key(seed_text, size, layer), artifact, version, StageTrailPlan.VERSION if layer == 2 else 0, RoadRefinement.DIV, PlanTerrain.CELLS]


## Artifact passport without decompressing payloads. Sizes include the retained recovery generation.
func describe_artifacts(seed_text: String, size: int) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for k in WorldGenerator.LAYERS.size() + 1:
		out.append({id = _layer_name(k), owner = "WorldGenerator" if k < 3 else "MapBaker/ForestFloor",
			path = path_for(seed_text, size, k), key = _key(seed_text, size, k), stage = "canonical" if k < 3 else "view"})
	for artifact: String in ["base", "surface"]:
		out.append({id = artifact, owner = "WorldLoader/Heightfield", path = artifact_path(seed_text, size, artifact),
			key = artifact_key(seed_text, size, artifact), stage = artifact, version = BASE_VERSION if artifact == "base" else SURFACE_VERSION})
	for item: Dictionary in out:
		item.bytes = FileAccess.get_size(item.path) if FileAccess.file_exists(item.path) else 0
		item.backup_bytes = FileAccess.get_size(item.path + ".bak") if FileAccess.file_exists(item.path + ".bak") else 0
		item.header_matches = _cache_header_key(item.path) == item.key or _cache_header_key(item.path + ".bak") == item.key
	return out


func load_artifact(seed_text: String, size: int, artifact: String) -> Dictionary:
	var data: Variant = _read(artifact_path(seed_text, size, artifact), artifact_key(seed_text, size, artifact))
	return data if data is Dictionary else {}


func save_artifact(seed_text: String, size: int, artifact: String, data: Dictionary) -> void:
	_queue_write(artifact_path(seed_text, size, artifact), artifact_key(seed_text, size, artifact), data)


## Immutable chunk blocks first, the small surface manifest last. No monolithic terrain bytes.
func save_surface(seed_text: String, size: int, data: Dictionary, chunks: Dictionary, water_chunks: Array = [{}, {}]) -> Dictionary:
	var snapshot := data.duplicate(true)
	var pieces := chunks.duplicate(true)
	var key := artifact_key(seed_text, size, "surface")
	var path := artifact_path(seed_text, size, "surface")
	var generation := "%d_%d" % [Time.get_ticks_usec(), get_instance_id()]
	var water := water_chunks.duplicate(true)
	var ticket := {result = {}}
	var writing: Array[String] = []
	for group in 3:
		var source: Dictionary = pieces if group == 0 else water[group - 1]
		for at: Vector2i in source:
			writing.append(dir.path_join("%s.%s.%d.%d_%d.chunk%s" % [_base(seed_text, size), generation, group, at.x, at.y, EXT]))
	pin_files(writing)
	_queue_job(func() -> void:
		snapshot.chunks = {}
		snapshot.water_chunks = [{}, {}]
		for group in 3:
			var source: Dictionary = pieces if group == 0 else water[group - 1]
			var refs: Dictionary = snapshot.chunks if group == 0 else snapshot.water_chunks[group - 1]
			for at: Vector2i in source:
				var name := "%s.%s.%d.%d_%d.chunk%s" % [_base(seed_text, size), generation, group, at.x, at.y, EXT]
				var chunk_key := "%s|%d|%d|%d" % [key, group, at.x, at.y]
				if _write(dir.path_join(name), chunk_key, var_to_bytes({arrays = source[at]})) != OK:
					unpin_files(writing)
					return
				refs[at] = {file = name, key = chunk_key, bytes = preload("res://scripts/core/byte_lru.gd").size_of(source[at])}
		if _write(path, key, var_to_bytes(snapshot)) == OK:
			ticket.result = snapshot
			_pin_lock.lock()
			_memo_roots(_manifest_signature(path), snapshot)
			_pin_lock.unlock()
		unpin_files(writing)
		collect_chunks(seed_text, size),
		preload("res://scripts/core/byte_lru.gd").size_of([snapshot, pieces, water]))
	return ticket


static func _absolute(path: String) -> String:
	var result := ProjectSettings.globalize_path(path).simplify_path()
	return result.to_lower() if OS.get_name() == "Windows" else result

static func pin_files(paths: Array[String]) -> void:
	_pin_lock.lock()
	for path: String in paths:
		var key := _absolute(path)
		_file_pins[key] = _file_pins.get(key, 0) + 1
	_pin_lock.unlock()

static func unpin_files(paths: Array[String]) -> void:
	_pin_lock.lock()
	for path: String in paths:
		var key := _absolute(path)
		if not _file_pins.has(key): continue
		_file_pins[key] -= 1
		if _file_pins[key] <= 0: _file_pins.erase(key)
	_pin_lock.unlock()

func collect_chunks(seed_text: String, size: int) -> int:
	_pin_lock.lock()
	var keep := {}
	var path := artifact_path(seed_text, size, "surface")
	for suffix: String in ["", ".bak"]:
		var signature := _manifest_signature(path + suffix)
		if signature.is_empty(): continue
		if not _root_memo.has(signature):
			var data: Variant = _read_file(path + suffix, _cache_header_key(path + suffix))
			if not data is Dictionary: continue
			_memo_roots(signature, data)
		keep.merge(_root_memo[signature])
	var removed := 0
	var seen := {}
	for entry: String in DirAccess.get_files_at(dir):
		var file := entry.trim_suffix(".bak").trim_suffix(".tmp")
		if seen.has(file): continue
		seen[file] = true
		if not file.begins_with(_base(seed_text, size) + ".") or not file.ends_with(".chunk" + EXT): continue
		if keep.has(file) or _file_pins.has(_absolute(dir.path_join(file))): continue
		if Files.remove(dir.path_join(file)) == OK: removed += 1
	_pin_lock.unlock()
	return removed

func _manifest_signature(path: String) -> String:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null or file.get_length() < 64: return ""
	if file.get_buffer(4).get_string_from_ascii() != MAGIC or file.get_32() != FORMAT: return ""
	var key := file.get_pascal_string()
	var raw := file.get_64()
	var packed := file.get_64()
	return "%s|%d|%d|%s" % [key, raw, packed, file.get_buffer(32).hex_encode()]

func _memo_roots(signature: String, data: Dictionary) -> void:
	var names := {}
	for group: Variant in [data.get("chunks", {})] + data.get("water_chunks", []):
		if not group is Dictionary: continue
		for ref: Variant in group.values():
			if ref is Dictionary and ref.get("file") is String: names[ref.file] = true
	_root_memo[signature] = names
	while _root_memo.size() > 4: _root_memo.erase(_root_memo.keys()[0])

func request_collection(seed_text: String, size: int) -> void:
	_queue_job(func() -> void: collect_chunks(seed_text, size))


## Only dependencies downstream of the failed canonical layer. Player saves/regions are untouched.
func invalidate_from(seed_text: String, size: int, layer: int) -> void:
	wait_writes()
	for k in range(layer, WorldGenerator.LAYERS.size() + 1):
		Files.remove(path_for(seed_text, size, k))
	Files.remove(artifact_path(seed_text, size, "surface"))
	if layer == 0: Files.remove(artifact_path(seed_text, size, "base"))


func take_io_timings() -> Dictionary:
	_io_lock.lock()
	var result := io_timings.duplicate(true)
	io_timings.clear()
	_io_lock.unlock()
	return result


func _measure(name: String, since: int, bytes := 0) -> void:
	_io_lock.lock()
	io_timings[name + "_ms"] = io_timings.get(name + "_ms", 0.0) + (Time.get_ticks_usec() - since) / 1000.0
	io_timings[name + "_bytes"] = io_timings.get(name + "_bytes", 0) + bytes
	_io_lock.unlock()


## Превью карты мира для меню или null. Остаётся и после обновлений: мир от зерна почти не меняется.
func preview(seed_text: String) -> Image:
	var path := dir.path_join(_base(seed_text, WorldGenerator.START_SIZE) + PREVIEW)
	return Image.load_from_file(path) if FileAccess.file_exists(path) else null


## Сколько файлов мира подряд подходят к нынешнему коду: 0 — ничего, WorldGenerator.LAYERS.size() — мир
## без картинок, на 1 больше — всё (читаются только заголовки)
func ready_layers(seed_text: String, size: int = WorldGenerator.START_SIZE) -> int:
	for k in WorldGenerator.LAYERS.size() + 1:
		var path := path_for(seed_text, size, k)
		if _cache_header_key(path) != _key(seed_text, size, k) and _cache_header_key(path + ".bak") != _key(seed_text, size, k):
			return k
	return WorldGenerator.LAYERS.size() + 1


## Мир в кэше целиком и подходит к нынешнему коду
func has(seed_text: String, size: int = WorldGenerator.START_SIZE) -> bool:
	return ready_layers(seed_text, size) > WorldGenerator.LAYERS.size()


## Сколько миров в кэше и сколько байт на диске
func usage() -> Dictionary:
	var bases := {}
	var bytes := 0
	if DirAccess.dir_exists_absolute(dir):
		for f in DirAccess.get_files_at(dir):
			bases[f.get_slice(".", 0)] = true
			bytes += FileAccess.get_size(dir.path_join(f))
	return {worlds = bases.size(), bytes = bytes}


## Картинки мира из кэша: {terrain, map, forest} или пусто (нет, старые или битые — тогда файл удаляется)
func load_view(seed_text: String, size: int) -> Dictionary:
	var layer := WorldGenerator.LAYERS.size()
	var path := path_for(seed_text, size, layer)
	var data: Variant = _read(path, _key(seed_text, size, layer))
	var out := {}
	if data != null:
		for name: String in VIEW_IMAGES:
			var d: Variant = data.get(name)
			if not d is Dictionary or not d.get("data") is PackedByteArray or not d.get("w") is int \
					or not d.get("h") is int or not PIXEL_BYTES.has(d.get("f")) or d.w <= 0 or d.h <= 0 \
					or d.data.size() != d.w * d.h * PIXEL_BYTES[d.f]:
				out.clear()
				break
			out[name] = Image.create_from_data(d.w, d.h, false, d.f, d.data)
	return out


## Сохранить картинки мира ({terrain, map, forest}, сразу после загрузки, пока их никто не менял) и превью
func save_view(seed_text: String, size: int, images: Dictionary) -> void:
	var data := {}
	for name: String in VIEW_IMAGES:
		var img: Image = images[name]
		data[name] = {w = img.get_width(), h = img.get_height(), f = img.get_format(), data = img.get_data()}
	var layer := WorldGenerator.LAYERS.size()
	var path := path_for(seed_text, size, layer)
	var key := _key(seed_text, size, layer)
	var small: Image = (images.map as Image).duplicate()
	var preview_path := dir.path_join(_base(seed_text, WorldGenerator.START_SIZE) + PREVIEW)
	_queue_write(path, key, data, func() -> void:
		small.resize(PREVIEW_SIZE, PREVIEW_SIZE, Image.INTERPOLATE_BILINEAR)
		Files.replace(preview_path, small.save_png_to_buffer()))


## Мир с кэшем: подходящие слои читаются, с первого неподходящего генерация продолжается обычным путём,
## а новые слои пишутся в кэш в фоне (дождаться — wait_writes). layers — сколько слоёв взято из кэша.
func generate(seed_text: String, size: int, on_progress: Callable = Callable(),
		after_climate: Callable = Callable()) -> Dictionary:
	var got := _load(seed_text, size)
	var n: int = got.layers
	# Validate the plan before starting expensive preparation, even when schema keys match.
	if n >= 2 and StageTrailPlan.stale(got.world.trail_plan):
		invalidate_from(seed_text, size, 1)
		got = _load(seed_text, size)
		n = got.layers
	if n == WorldGenerator.LAYERS.size():
		return {world = got.world, layers = n}
	# Снимок для сравнения — отдельная копия: мир из кэша держит те же массивы и словари, и следующий слой,
	# меняя их на месте (тропы получают покрытие), менял бы и снимок. Тогда изменения не попадали в файл
	# слоя, и при следующем запуске дороги грузились без покрытия (исправлено в 12.2)
	var state := {prev = got.data.duplicate(true)}
	var prepare_base := func(cur: WorldData) -> void:
		if cur.base_heights != null:
			save_artifact(seed_text, size, "base", preload("res://scripts/game/surface_snapshot.gd").capture(cur.base_heights, "base"))
		if after_climate.is_valid(): after_climate.call(cur)
	var base: Heightfield = null
	if n > 0:
		base = preload("res://scripts/game/surface_snapshot.gd").restore(got.world, load_artifact(seed_text, size, "base"), "base")
		got.world.base_heights = base
	if n > 0: got.world.generation_profile = {} # report only stages actually generated on this load
	var w := WorldGenerator.generate_layers(seed_text, size, on_progress, prepare_base, got.world, n,
		func(cur: WorldData, k: int) -> void:
			state.prev = _save_layer(cur, size, k, state.prev))
	return {world = w, layers = n}


## Подходящие слои подряд с первого: {world — мир с ними или null, layers — сколько, data — их поля}
func _load(seed_text: String, size: int) -> Dictionary:
	var data := {}
	var n := 0
	var w: WorldData
	for k in WorldGenerator.LAYERS.size():
		var path := path_for(seed_text, size, k)
		var part: Variant = _read(path, _key(seed_text, size, k))
		if part == null:
			break
		var candidate := data.merged(part, true)
		var restored_at := Time.get_ticks_usec()
		var next := _restore(candidate, k == WorldGenerator.LAYERS.size() - 1)
		_measure("restore", restored_at)
		if next == null:
			var backup: Variant = _read_file(path + ".bak", _key(seed_text, size, k))
			if backup == null: break
			candidate = data.merged(backup, true)
			next = _restore(candidate, k == WorldGenerator.LAYERS.size() - 1)
			if next == null: break
		w = next
		data = candidate
		n = k + 1
	return {world = w, layers = n, data = data}


## Готовый мир только для чтения (сохранённые участки Trail Lab): без генерации и без удаления неподходящих
## файлов. {world, view — поля картинок или пусто, keys — ключи слоёв, files — пути слоёв} или {error}.
func read_only(seed_text: String, size: int = WorldGenerator.START_SIZE) -> Dictionary:
	var data := {}
	var files: Array[String] = []
	for k in WorldGenerator.LAYERS.size():
		var path := path_for(seed_text, size, k)
		files.append(path)
		var part: Variant = _read(path, _key(seed_text, size, k))
		if part == null:
			return {error = "нет подходящего нынешнему коду слоя «%s» мира «%s» в %s" % [_layer_name(k), seed_text, dir]}
		data.merge(part, true)
	var w := _restore(data, true)
	if w == null:
		return {error = "кэш мира «%s» в %s не читается" % [seed_text, dir]}
	var view_path := path_for(seed_text, size, WorldGenerator.LAYERS.size())
	var view: Variant = _read(view_path, _key(seed_text, size, WorldGenerator.LAYERS.size())) if FileAccess.file_exists(view_path) else null
	files.append(view_path)
	return {world = w, view = view if view is Dictionary else {}, keys = layer_keys(), files = files}


## Снимок слоя берётся сразу (пока следующий слой мир не тронул): в файл идут поля, которые слой поменял;
## сжатие и запись — в фоне. Возвращает снимок всех полей для сравнения со следующим слоем.
func _save_layer(w: WorldData, size: int, layer: int, prev: Dictionary) -> Dictionary:
	var started := Time.get_ticks_usec()
	var snap := prev.duplicate()
	var part := {}
	# Include nested mutations: settlement huts in places, trail surfaces in nature.
	var fields: Array = WorldData.CACHE_FIELDS
	if layer == 1:
		fields = WorldData.Civil.CACHE_FIELDS + ["peaks", "generation_profile"]
	elif layer == 2:
		fields = ["territory_center", "available_rect", "territory_revision", "generation_profile",
			"obj_x", "obj_y", "obj_k", "obj_v", "obj_s", "chunks", "CS", "CW", "CH", "obj_count",
			"lakes", "lake_id", "trails", "road_surface"]
	for name: String in fields:
		var v: Variant = EntityCodec.encode(w.get(name))
		# массивы и словари следующие слои меняют на месте; Packed*Array копируются при записи сами
		if v is Array or v is Dictionary:
			v = v.duplicate(true)
		snap[name] = v
		if not prev.has(name) or typeof(prev[name]) != typeof(v) or prev[name] != v:
			part[name] = v
	var path := path_for(w.seed_text, size, layer)
	var key := _key(w.seed_text, size, layer)
	_measure("snapshot", started)
	_queue_write(path, key, part)
	return snap


## FIFO writer; backpressure only when the byte/job budget is full, not at every submission.
func _queue_write(path: String, key: String, data: Dictionary, after := Callable()) -> void:
	var snapshot := data.duplicate(true)
	_queue_job(func() -> void:
		var started := Time.get_ticks_usec()
		var raw := var_to_bytes(snapshot)
		_measure("serialize", started, raw.size())
		_write(path, key, raw)
		if after.is_valid(): after.call(), preload("res://scripts/core/byte_lru.gd").size_of(snapshot))


func _queue_job(job: Callable, bytes := 0) -> void:
	_enqueue_lock.lock()
	var started := Time.get_ticks_usec()
	while true:
		_lock.lock()
		if _pending_jobs == 0 or (_pending_jobs < WRITE_QUEUE_JOBS and _pending_bytes + bytes <= WRITE_QUEUE_BYTES): break
		_lock.unlock()
		_write_room.wait()
	queue_stats.wait_ms += (Time.get_ticks_usec() - started) / 1000.0
	_pending_jobs += 1
	_pending_bytes += bytes
	queue_stats.peak_jobs = maxi(queue_stats.peak_jobs, _pending_jobs)
	queue_stats.peak_bytes = maxi(queue_stats.peak_bytes, _pending_bytes)
	queue_stats.oversized_jobs += int(bytes > WRITE_QUEUE_BYTES)
	if cpu_budget != null: cpu_budget.reserve(bytes)
	_jobs.append({call = job, bytes = bytes})
	if not _writer_active:
		_writer_active = true
		_writes.append(WorkerThreadPool.add_task(_drain_jobs, false, "Запись кэша"))
	_lock.unlock()
	_enqueue_lock.unlock()


func _drain_jobs() -> void:
	while true:
		_lock.lock()
		if _jobs.is_empty():
			_writer_active = false
			_lock.unlock()
			return
		var next: Dictionary = _jobs.pop_front()
		_lock.unlock()
		next.call.call()
		var bytes: int = next.bytes
		next.clear() # release immutable source containers before returning the reservation
		_lock.lock()
		_pending_jobs -= 1
		_pending_bytes -= bytes
		if cpu_budget != null: cpu_budget.release(bytes)
		_lock.unlock()
		_write_room.post()


func wait_writes() -> void:
	_enqueue_lock.lock()
	_join_writes()
	_enqueue_lock.unlock()


func _join_writes() -> void:
	_lock.lock()
	var tasks := _writes.duplicate()
	_writes.clear()
	_lock.unlock()
	for t in tasks:
		WorkerThreadPool.wait_for_task_completion(t)


## Удалить все файлы кэша, кроме миров из seeds (размера START_SIZE); пустой seeds — очистить всё
## 14.5: скопировать миры из проекта (BUNDLED) в кэш игрока, если там их ещё нет или они другие.
## Подходит ли файл к нынешнему коду, решает обычная проверка ключа при чтении: устаревший перегенерируется.
func install_bundled(source := BUNDLED) -> void:
	var manifest: Variant = JSON.parse_string(FileAccess.get_file_as_string(source.path_join("manifest.json"))) if FileAccess.file_exists(source.path_join("manifest.json")) else null
	if not manifest is Dictionary or manifest.get("format") != FORMAT: return
	for entry: Dictionary in manifest.get("files", []):
		var name: String = entry.get("name", "")
		if name != name.get_file() or name.is_empty(): continue
		var src := source.path_join(name)
		var to := dir.path_join(name)
		var layer := int(entry.get("layer", -1))
		if layer < 0 or layer > WorldGenerator.LAYERS.size(): continue
		var seed_text: String = entry.get("seed", "")
		var size := int(entry.get("size", 0))
		var key := _key(seed_text, size, layer)
		if entry.get("key") != key or name != path_for(seed_text, size, layer).get_file(): continue
		if _read(to, key) != null: continue
		var bytes := FileAccess.get_file_as_bytes(src)
		if Util.sha256(bytes).hex_encode() != entry.get("sha256", "") or _read(src, key) == null: continue
		Files.replace(to, bytes)
	# Derived surfaces are optional. Publish their manifest only after every referenced block is valid.
	for entry: Dictionary in manifest.get("artifacts", []):
		var artifact: String = entry.get("artifact", "")
		if artifact not in ["base", "surface"]: continue
		var seed_text: String = entry.get("seed", "")
		var size := int(entry.get("size", 0))
		var path := artifact_path(seed_text, size, artifact)
		var key := artifact_key(seed_text, size, artifact)
		if entry.get("key") != key or entry.get("name") != path.get_file() or _read(path, key) != null: continue
		var src := source.path_join(path.get_file())
		var bytes := FileAccess.get_file_as_bytes(src)
		if Util.sha256(bytes).hex_encode() != entry.get("sha256"): continue
		var data: Variant = _read(src, key)
		if data == null: continue
		if artifact == "surface" and not _install_chunks(source, data, key): continue
		Files.replace(path, bytes)
	# Previews have their own digest, and never replace a valid user preview.
	for entry: Dictionary in manifest.get("previews", []):
		var name: String = entry.get("name", "")
		if name != name.get_file() or not name.ends_with(".preview"): continue
		var to := dir.path_join(name + ".png")
		if not preview_file(to).is_empty(): continue
		var bytes := FileAccess.get_file_as_bytes(source.path_join(name))
		if Util.sha256(bytes).hex_encode() == entry.get("sha256", "") and not preview_file(source.path_join(name)).is_empty():
			Files.replace(to, bytes)


func _install_chunks(source: String, data: Dictionary, key: String) -> bool:
	if not data.get("chunks") is Dictionary or not data.get("water_chunks") is Array or data.water_chunks.size() != 2: return false
	var groups: Array = [data.chunks] + data.water_chunks
	for group in groups.size():
		if not groups[group] is Dictionary: return false
		for at: Variant in groups[group]:
			var ref: Variant = groups[group][at]
			if not at is Vector2i or not ref is Dictionary or not ref.get("file") is String: return false
			var chunk_key := "%s|%d|%d|%d" % [key, group, at.x, at.y]
			if ref.get("key") != chunk_key or ref.file != ref.file.get_file(): return false
			var to := dir.path_join(ref.file)
			if _read(to, chunk_key) != null: continue
			var path := source.path_join(ref.file)
			if _read(path, chunk_key) == null: return false
			if Files.replace(to, FileAccess.get_file_as_bytes(path)) != OK: return false
	return true


func preview_file(path: String) -> PackedByteArray:
	if not FileAccess.file_exists(path): return PackedByteArray()
	var bytes := FileAccess.get_file_as_bytes(path)
	var img := Image.new()
	return bytes if img.load_png_from_buffer(bytes) == OK and img.get_width() == PREVIEW_SIZE and img.get_height() == PREVIEW_SIZE else PackedByteArray()


func _cache_header_key(path: String) -> String:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null or f.get_length() < 64 or f.get_buffer(4).get_string_from_ascii() != MAGIC or f.get_32() != FORMAT:
		return ""
	return f.get_pascal_string()


func keep_only(seeds: Array) -> void:
	wait_writes()
	var keep := {}
	for s: String in seeds:
		keep[_base(s, WorldGenerator.START_SIZE)] = true
	if not DirAccess.dir_exists_absolute(dir):
		return
	for f in DirAccess.get_files_at(dir):
		if not keep.has(f.get_slice(".", 0)):
			DirAccess.remove_absolute(dir.path_join(f))


## Удалить все слои одного мира, включая устаревшие версии.
func remove_seed(seed_text: String) -> Error:
	wait_writes()
	if not DirAccess.dir_exists_absolute(dir):
		return OK
	var prefix := _base(seed_text, WorldGenerator.START_SIZE) + "."
	for file: String in DirAccess.get_files_at(dir):
		if file.begins_with(prefix):
			var err := DirAccess.remove_absolute(dir.path_join(file))
			if err != OK:
				return err
	return OK


func _write(path: String, key: String, raw: PackedByteArray) -> Error:
	var started := Time.get_ticks_usec()
	var packed := raw.compress(FileAccess.COMPRESSION_ZSTD)
	_measure("compress", started, packed.size())
	var stream := StreamPeerBuffer.new()
	stream.put_data(MAGIC.to_ascii_buffer())
	stream.put_u32(FORMAT)
	stream.put_utf8_string(key)
	stream.put_u64(raw.size())
	stream.put_u64(packed.size())
	stream.put_data(Util.sha256(packed))
	stream.put_data(packed)
	started = Time.get_ticks_usec()
	var preserve := FileAccess.file_exists(path) and _read_file(path, key) == null
	var err := Files.replace(path, stream.data_array, preserve)
	_measure("write", started, stream.data_array.size())
	if err != OK: push_warning("Кэш мира не записан: %s (%s)" % [path, error_string(err)])
	return err


## Поля слоя из файла или null
func _read(path: String, key: String) -> Variant:
	for suffix in ["", ".bak"]:
		var result: Variant = _read_file(path + suffix, key)
		if result != null: return result
	return null


func _read_file(path: String, key: String) -> Variant:
	var started := Time.get_ticks_usec()
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null or f.get_length() < 64:
		return null
	if f.get_buffer(4).get_string_from_ascii() != MAGIC or f.get_32() != FORMAT or f.get_pascal_string() != key:
		return null
	var raw_size := f.get_64()
	var packed_size := f.get_64()
	var expected := f.get_buffer(32)
	if packed_size <= 0 or packed_size != f.get_length() - f.get_position() or raw_size <= 0 or raw_size > (1 << 31):
		return null
	var packed := f.get_buffer(packed_size)
	f.close()
	_measure("read", started, packed.size())
	if packed.size() != packed_size or Util.sha256(packed) != expected:
		return null
	started = Time.get_ticks_usec()
	var raw := packed.decompress(raw_size, FileAccess.COMPRESSION_ZSTD)
	_measure("decompress", started, raw.size())
	if raw.size() != raw_size:
		return null
	started = Time.get_ticks_usec()
	var data: Variant = bytes_to_var(raw)
	_measure("decode", started)
	return data if data is Dictionary else null


## Мир из словаря полей; null, если поля не хватает, тип или длина не те.
## complete — все слои: иначе поля следующих слоёв ещё пустые.
func _restore(data: Dictionary, complete: bool) -> WorldData:
	var w := WorldData.new()
	for name: String in WorldData.CACHE_FIELDS:
		var cur: Variant = w.get(name)
		if not data.has(name) or typeof(data[name]) != typeof(cur):
			return null
		if name in ["settlements", "sites", "lakes", "bridges", "tunnels"]:
			w.set(name, data[name])
		elif cur is Array and (cur as Array).is_typed():
			(cur as Array).assign(data[name])
		else:
			w.set(name, data[name])
	if w.W != WorldGenerator.PLAN_SIZE or w.H != WorldGenerator.PLAN_SIZE or w.N != w.W * w.H:
		return null
	for name: String in PER_CELL:
		var n: int = w.get(name).size()
		if n != w.N and not (n == 0 and (not complete or name in ["river_area", "road_surface", "lake_id"])):
			return null
	for name: String in PER_OBJECT:
		if w.get(name).size() != w.obj_count:
			return null
	if complete and w.chunks.size() != w.CW * w.CH or w.seed_num != WGRandom.hash_string(w.seed_text):
		return null
	for name: String in WorldGenerator.NOISE_SLOTS:
		w.noise[name] = Simplex.new(WorldGenerator.noise_rng(w.seed_num, name))
	return w


## Reset only while this context is idle; join pending writes before changing paths.
func reset() -> void:
	wait_writes()
	enabled = false
	dir = "user://world_cache"
	_layer_keys.clear()
	take_io_timings()
