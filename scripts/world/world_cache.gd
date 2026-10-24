class_name WorldCache
extends RefCounted
## Кэш готовых миров (с 10.0): данные генерации (WorldData) в файлах на диске игрока.
## Генерация — самая долгая часть загрузки (46 из 62 с у мира 768), а остальное — рельеф, меш, текстуры —
## считается из готовых данных за секунды и в кэш не кладётся: так файл в несколько раз меньше.
## Мир не меняется: в файле ровно то, что вернул генератор, а шумы пересоздаются из сида.
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
const SCHEMA_GEO_VERSION := 3
const SCHEMA_TRAILS_VERSION := 1
const SCHEMA_NATURE_VERSION := 3 # 15.5: soft forest character and distinct giant tree species
const SCHEMA_VIEW_VERSION := 1
## Картинки мира: имя файла и исходники рисования
const VIEW := "view"
const VIEW_IMAGES := ["terrain", "map", "forest"]
const PREVIEW := ".preview.png"
const PREVIEW_SIZE := 256
## Байт на пиксель у форматов картинок мира (другой формат в файле — файл чужой)
const PIXEL_BYTES := {Image.FORMAT_L8: 1, Image.FORMAT_R8: 1, Image.FORMAT_RG8: 2, Image.FORMAT_RGB8: 3, Image.FORMAT_RGBA8: 4}
## Поля по клетке: длина ровно N
const PER_CELL := ["h", "filled", "elev", "ocean", "lake", "river", "river_area", "wetland", "acc", "slope", "watershed",
	"down", "rain", "dist_ocean", "dist_water", "temp", "moist", "biome", "cost", "path_mask", "road_surface", "lake_id"]
const PER_OBJECT := ["obj_x", "obj_y", "obj_k", "obj_v", "obj_s"]

var enabled := false
var dir := "user://world_cache"
## 14.5: готовые миры автора в проекте (RecommendedSeeds): копируются в dir, если их там нет
const BUNDLED := "res://resources/world_cache"
var _writes: Array[int] = []
var _lock := Mutex.new()
var _layer_keys := PackedStringArray()


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


## Превью карты мира для меню или null. Остаётся и после обновлений: мир от зерна почти не меняется.
func preview(seed_text: String) -> Image:
	var path := dir.path_join(_base(seed_text, WorldGenerator.START_SIZE) + PREVIEW)
	return Image.load_from_file(path) if FileAccess.file_exists(path) else null


## Сколько файлов мира подряд подходят к нынешнему коду: 0 — ничего, WorldGenerator.LAYERS.size() — мир
## без картинок, на 1 больше — всё (читаются только заголовки)
func ready_layers(seed_text: String, size: int = WorldGenerator.START_SIZE) -> int:
	for k in WorldGenerator.LAYERS.size() + 1:
		var f := FileAccess.open(path_for(seed_text, size, k), FileAccess.READ)
		if f == null or f.get_length() < 64 or f.get_buffer(4).get_string_from_ascii() != MAGIC or f.get_32() != FORMAT \
				or f.get_pascal_string() != _key(seed_text, size, k):
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
	if not FileAccess.file_exists(path):
		return {}
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
	if out.is_empty():
		DirAccess.remove_absolute(path)
	return out


## Сохранить картинки мира ({terrain, map, forest}, сразу после загрузки, пока их никто не менял) и превью
func save_view(seed_text: String, size: int, images: Dictionary) -> void:
	var data := {}
	for name: String in VIEW_IMAGES:
		var img: Image = images[name]
		data[name] = {w = img.get_width(), h = img.get_height(), f = img.get_format(), data = img.get_data()}
	var raw := var_to_bytes(data)
	var layer := WorldGenerator.LAYERS.size()
	var path := path_for(seed_text, size, layer)
	var key := _key(seed_text, size, layer)
	var small: Image = (images.map as Image).duplicate()
	var preview_path := dir.path_join(_base(seed_text, WorldGenerator.START_SIZE) + PREVIEW)
	var job := func() -> void:
		_write(path, key, raw)
		small.resize(PREVIEW_SIZE, PREVIEW_SIZE, Image.INTERPOLATE_BILINEAR)
		small.save_png(preview_path)
	var task := WorkerThreadPool.add_task(job, false, "Кэш мира")
	_lock.lock()
	_writes.append(task)
	_lock.unlock()


## Мир с кэшем: подходящие слои читаются, с первого неподходящего генерация продолжается обычным путём,
## а новые слои пишутся в кэш в фоне (дождаться — wait_writes). layers — сколько слоёв взято из кэша.
func generate(seed_text: String, size: int, on_progress: Callable = Callable(),
		after_climate: Callable = Callable()) -> Dictionary:
	var got := _load(seed_text, size)
	var n: int = got.layers
	if n == WorldGenerator.LAYERS.size():
		return {world = got.world, layers = n}
	# Снимок для сравнения — отдельная копия: мир из кэша держит те же массивы и словари, и следующий слой,
	# меняя их на месте (тропы получают покрытие), менял бы и снимок. Тогда изменения не попадали в файл
	# слоя, и при следующем запуске дороги грузились без покрытия (исправлено в 12.2)
	var state := {prev = got.data.duplicate(true)}
	var w := WorldGenerator.generate_layers(seed_text, size, on_progress, after_climate, got.world, n,
		func(cur: WorldData, k: int) -> void:
			state.prev = _save_layer(cur, size, k, state.prev))
	return {world = w, layers = n}


## Подходящие слои подряд с первого: {world — мир с ними или null, layers — сколько, data — их поля}
func _load(seed_text: String, size: int) -> Dictionary:
	var data := {}
	var n := 0
	for k in WorldGenerator.LAYERS.size():
		var path := path_for(seed_text, size, k)
		if not FileAccess.file_exists(path):
			break
		var part: Variant = _read(path, _key(seed_text, size, k))
		if part == null:
			# старый (другой код этапов) или битый файл: слой и следующие будут перезаписаны
			DirAccess.remove_absolute(path)
			break
		data.merge(part, true)
		n = k + 1
	var w := _restore(data, n == WorldGenerator.LAYERS.size()) if n > 0 else null
	if n > 0 and w == null:
		push_warning("Кэш мира %s не подошёл, мир будет создан заново" % seed_text)
		for path in paths_for(seed_text, size):
			DirAccess.remove_absolute(path)
		return {world = null, layers = 0, data = {}}
	return {world = w, layers = n, data = data}


## Снимок слоя берётся сразу (пока следующий слой мир не тронул): в файл идут поля, которые слой поменял;
## сжатие и запись — в фоне. Возвращает снимок всех полей для сравнения со следующим слоем.
func _save_layer(w: WorldData, size: int, layer: int, prev: Dictionary) -> Dictionary:
	var snap := {}
	var part := {}
	for name: String in WorldData.CACHE_FIELDS:
		var v: Variant = EntityCodec.encode(w.get(name))
		# массивы и словари следующие слои меняют на месте; Packed*Array копируются при записи сами
		if v is Array or v is Dictionary:
			v = v.duplicate(true)
		snap[name] = v
		if not prev.has(name) or typeof(prev[name]) != typeof(v) or prev[name] != v:
			part[name] = v
	var raw := var_to_bytes(part)
	var path := path_for(w.seed_text, size, layer)
	var key := _key(w.seed_text, size, layer)
	var task := WorkerThreadPool.add_task(func() -> void: _write(path, key, raw), false, "Кэш мира")
	_lock.lock()
	_writes.append(task)
	_lock.unlock()
	return snap


func wait_writes() -> void:
	_lock.lock()
	var tasks := _writes.duplicate()
	_writes.clear()
	_lock.unlock()
	for t in tasks:
		WorkerThreadPool.wait_for_task_completion(t)


## Удалить все файлы кэша, кроме миров из seeds (размера START_SIZE); пустой seeds — очистить всё
## 14.5: скопировать миры из проекта (BUNDLED) в кэш игрока, если там их ещё нет или они другие.
## Подходит ли файл к нынешнему коду, решает обычная проверка ключа при чтении: устаревший перегенерируется.
func install_bundled() -> void:
	if not DirAccess.dir_exists_absolute(BUNDLED):
		return
	DirAccess.make_dir_recursive_absolute(dir)
	for f in DirAccess.get_files_at(BUNDLED):
		if not f.ends_with(EXT) and not f.ends_with(".preview"):
			continue
		var to := dir.path_join(f.trim_suffix(".preview") + PREVIEW if f.ends_with(".preview") else f)
		var src := BUNDLED.path_join(f)
		if FileAccess.file_exists(to):
			if f.ends_with(EXT):
				# Новые ключи имеют ту же длину: совпадение размера не означает ту же схему.
				var bundled_key := _cache_header_key(src)
				if not bundled_key.is_empty() and _cache_header_key(to) == bundled_key:
					continue
			elif FileAccess.get_size(to) == FileAccess.get_size(src):
				continue
		var bytes := FileAccess.get_file_as_bytes(src)
		var out := FileAccess.open(to, FileAccess.WRITE)
		if out != null and not bytes.is_empty():
			out.store_buffer(bytes)


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


func _write(path: String, key: String, raw: PackedByteArray) -> void:
	DirAccess.make_dir_recursive_absolute(dir)
	var packed := raw.compress(FileAccess.COMPRESSION_ZSTD)
	var tmp := path + ".tmp"
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		return
	f.store_buffer(MAGIC.to_ascii_buffer())
	f.store_32(FORMAT)
	f.store_pascal_string(key)
	f.store_64(raw.size())
	f.store_64(packed.size())
	f.store_buffer(_hash(packed))
	f.store_buffer(packed)
	var ok := f.get_error() == OK
	f.close()
	if ok and FileAccess.get_size(tmp) > 0:
		if FileAccess.file_exists(path):
			DirAccess.remove_absolute(path)
		ok = DirAccess.rename_absolute(tmp, path) == OK
	if not ok:
		DirAccess.remove_absolute(tmp)


func _hash(bytes: PackedByteArray) -> PackedByteArray:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(bytes)
	return ctx.finish()


## Поля слоя из файла или null
func _read(path: String, key: String) -> Variant:
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
	if packed.size() != packed_size or _hash(packed) != expected:
		return null
	var raw := packed.decompress(raw_size, FileAccess.COMPRESSION_ZSTD)
	if raw.size() != raw_size:
		return null
	var data: Variant = bytes_to_var(raw)
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
