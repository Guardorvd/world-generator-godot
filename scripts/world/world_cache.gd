class_name WorldCache
extends RefCounted
## Кэш готовых миров (с 10.0): данные генерации (WorldData после всех этапов) в файле на диске игрока.
## Генерация — самая долгая часть загрузки (46 из 62 с у мира 768), а остальное — рельеф, меш, текстуры —
## считается из готовых данных за секунды и в кэш не кладётся: так файл в несколько раз меньше.
## Мир не меняется: в файле ровно то, что вернул генератор, а шумы пересоздаются из сида.
##
## Защиты:
## - ключ файла — версия игры, формат кэша, сид и размеры: после патча старый файл не подходит и удаляется;
## - заголовок, размеры и хеш SHA-256 сжатых данных, проверка типов и длин массивов при чтении:
##   битый или чужой файл удаляется, мир генерируется заново;
## - запись во временный файл и переименование: оборванная запись не оставляет полуфайла под настоящим именем.
## Какие миры хранить, решает меню (последние и избранные, GameSettings.keep_seeds); остальное удаляет keep_only.
## Включает кэш только сама игра (Main): инструменты проверки по умолчанию генерируют честно.

const FORMAT := 1
const MAGIC := "WGC1"
const EXT := ".wgc"
## Поля мира, которые не сохраняются: объекты и временное состояние генерации
const SKIP := ["rng", "noise", "outer", "base_heights", "_fields_thread", "_fields", "_index"]
## Поля по клетке: длина ровно N
const PER_CELL := ["h", "filled", "elev", "ocean", "lake", "river", "river_area", "acc", "slope", "watershed",
	"down", "rain", "dist_ocean", "dist_water", "temp", "moist", "biome", "cost", "path_mask", "road_surface", "lake_id"]
const PER_OBJECT := ["obj_x", "obj_y", "obj_k", "obj_v", "obj_s"]

static var enabled := false
static var dir := "user://world_cache"
static var _writes: Array[int] = []
static var _lock := Mutex.new()


static func _key(seed_text: String, size: int) -> String:
	return "%s|%d|%s|%d|%d" % [ProjectSettings.get_setting("application/config/version", "?"), FORMAT, seed_text,
		WorldGenerator.PLAN_SIZE, size]


static func path_for(seed_text: String, size: int = WorldGenerator.START_SIZE) -> String:
	return dir.path_join(_key(seed_text, size).md5_text() + EXT)


static func has(seed_text: String, size: int = WorldGenerator.START_SIZE) -> bool:
	return FileAccess.file_exists(path_for(seed_text, size))


## Готовый мир из кэша или null (нет файла, другая версия, битый файл — тогда он удаляется)
static func load_world(seed_text: String, size: int) -> WorldData:
	var path := path_for(seed_text, size)
	if not FileAccess.file_exists(path):
		return null
	var w := _read(path, _key(seed_text, size))
	if w == null:
		push_warning("Кэш мира %s не подошёл, мир будет создан заново" % seed_text)
		DirAccess.remove_absolute(path)
	return w


## Снимок мира берётся сразу (вызывать сразу после генерации, пока мир никто не менял),
## сжатие и запись идут в фоне. Дождаться — wait_writes.
static func save_world(w: WorldData, size: int) -> void:
	var data := {}
	for p: Dictionary in w.get_property_list():
		if not (p.usage & PROPERTY_USAGE_SCRIPT_VARIABLE) or p.name in SKIP:
			continue
		var v: Variant = w.get(p.name)
		if typeof(v) != TYPE_OBJECT:
			data[p.name] = v
	var raw := var_to_bytes(data)
	var key := _key(w.seed_text, size)
	var path := path_for(w.seed_text, size)
	var task := WorkerThreadPool.add_task(func() -> void: _write(path, key, raw), false, "Кэш мира")
	_lock.lock()
	_writes.append(task)
	_lock.unlock()


static func wait_writes() -> void:
	_lock.lock()
	var tasks := _writes.duplicate()
	_writes.clear()
	_lock.unlock()
	for t in tasks:
		WorkerThreadPool.wait_for_task_completion(t)


## Удалить все файлы кэша, кроме миров из seeds (текущей версии и размера START_SIZE).
static func keep_only(seeds: Array) -> void:
	wait_writes()
	var keep := {}
	for s: String in seeds:
		keep[path_for(s).get_file()] = true
	if not DirAccess.dir_exists_absolute(dir):
		return
	for f in DirAccess.get_files_at(dir):
		if not keep.has(f):
			DirAccess.remove_absolute(dir.path_join(f))


static func _write(path: String, key: String, raw: PackedByteArray) -> void:
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


static func _hash(bytes: PackedByteArray) -> PackedByteArray:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(bytes)
	return ctx.finish()


static func _read(path: String, key: String) -> WorldData:
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
	return _restore(data) if data is Dictionary else null


## Мир из словаря полей; null, если поля не хватает, тип или длина не те
static func _restore(data: Dictionary) -> WorldData:
	var w := WorldData.new()
	for p: Dictionary in w.get_property_list():
		if not (p.usage & PROPERTY_USAGE_SCRIPT_VARIABLE) or p.name in SKIP:
			continue
		var cur: Variant = w.get(p.name)
		if typeof(cur) == TYPE_OBJECT:
			continue
		if not data.has(p.name) or typeof(data[p.name]) != typeof(cur):
			return null
		if cur is Array and (cur as Array).is_typed():
			(cur as Array).assign(data[p.name])
		else:
			w.set(p.name, data[p.name])
	if w.W != WorldGenerator.PLAN_SIZE or w.H != WorldGenerator.PLAN_SIZE or w.N != w.W * w.H:
		return null
	for name: String in PER_CELL:
		var n: int = w.get(name).size()
		if n != w.N and not (n == 0 and name in ["river_area", "road_surface", "lake_id"]):
			return null
	for name: String in PER_OBJECT:
		if w.get(name).size() != w.obj_count:
			return null
	if w.chunks.size() != w.CW * w.CH or w.seed_num != WGRandom.hash_string(w.seed_text):
		return null
	for name: String in WorldGenerator.NOISE_SLOTS:
		w.noise[name] = Simplex.new(WorldGenerator.noise_rng(w.seed_num, name))
	return w
