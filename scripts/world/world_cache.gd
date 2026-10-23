class_name WorldCache
extends RefCounted
## Кэш готовых миров (с 10.0): данные генерации (WorldData) в файлах на диске игрока.
## Генерация — самая долгая часть загрузки (46 из 62 с у мира 768), а остальное — рельеф, меш, текстуры —
## считается из готовых данных за секунды и в кэш не кладётся: так файл в несколько раз меньше.
## Мир не меняется: в файле ровно то, что вернул генератор, а шумы пересоздаются из сида.
##
## С 10.2 кэш по слоям генерации (WorldGenerator.LAYERS): география, места и пути, природа — по файлу на слой.
## Ключ слоя — хеш исходников его этапов, общих скриптов генерации и ключа прошлого слоя, а не версия игры:
## после патча, который не трогал генерацию, мир берётся из кэша целиком; если поменялись только этапы мест
## и путей, география берётся из кэша, а генерация продолжается с мест. Первый слой хранит все поля мира,
## следующие — только поля, которые этот слой поменял.
##
## Защиты:
## - ключ файла — формат кэша, сид, размеры и хеш исходников: старый файл не подходит и перезаписывается;
## - заголовок, размеры и хеш SHA-256 сжатых данных, проверка типов и длин массивов при чтении:
##   битый или чужой файл удаляется, мир генерируется заново;
## - запись во временный файл и переименование: оборванная запись не оставляет полуфайла под настоящим именем.
## Какие миры хранить, решает меню (последние и избранные, GameSettings.keep_seeds); остальное удаляет keep_only.
## Включает кэш только сама игра (Main): инструменты проверки по умолчанию генерируют честно.

const FORMAT := 2
const MAGIC := "WGC2"
const EXT := ".wgc"
## Исходники, от которых зависят все слои: общий код генерации, данные, рельеф с водой (Heightfield).
## Папка — все .gd и .cs в ней. Поменялся файл — кэш всех слоёв не подходит.
const COMMON := ["res://scripts/core/", "res://scripts/data/biomes.gd", "res://scripts/data/names.gd",
	"res://scripts/world/world_data.gd", "res://scripts/world/world_generator.gd", "res://scripts/game/heightfield.gd",
	"res://scripts/game/game_config.gd", "res://scripts/render/water_builder.gd"]
## Свои исходники слоёв WorldGenerator.LAYERS по порядку. Поменялся файл слоя — этот слой и следующие
## генерируются заново, прошлые берутся из кэша. Новый этап или скрипт, который читает генерация, — дописать сюда.
const LAYER_SOURCES := [
	["res://scripts/world/stages/stage_relief.gd", "res://scripts/world/stages/stage_ocean.gd",
		"res://scripts/world/stages/stage_hydrology.gd", "res://scripts/world/stages/stage_rivers.gd",
		"res://scripts/world/stages/stage_geography.gd", "res://scripts/world/stages/stage_climate.gd"],
	["res://scripts/world/stages/stage_landmarks.gd", "res://scripts/world/stages/stage_trails.gd",
		"res://scripts/world/stages/stage_sites.gd"],
	["res://scripts/world/stages/stage_vegetation.gd", "res://scripts/world/stages/stage_lakes.gd",
		"res://scripts/world/road_surface.gd", "res://scripts/game/player_state.gd"],
]
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
static var _layer_keys := PackedStringArray()


## Ключи слоёв по исходникам (считаются один раз)
static func layer_keys() -> PackedStringArray:
	_lock.lock()
	if _layer_keys.is_empty():
		var prev := _hash(("%d|%d" % [FORMAT, WorldGenerator.PLAN_SIZE]).to_utf8_buffer() + _sources(COMMON))
		for sources: Array in LAYER_SOURCES:
			prev = _hash(prev + _sources(sources))
			_layer_keys.append(prev.hex_encode().left(32))
	var keys := _layer_keys
	_lock.unlock()
	return keys


## Содержимое исходников подряд. В экспортированной игре .gd может не быть (.gdc, C# в сборке):
## тогда вместо файла — версия игры, и после обновления такой слой генерируется заново, как в 10.0.
static func _sources(paths: Array) -> PackedByteArray:
	var out := PackedByteArray()
	for path: String in paths:
		var files: Array[String] = [path]
		if path.ends_with("/"):
			files.clear()
			for f in DirAccess.get_files_at(path):
				f = f.trim_suffix(".remap")
				if f.get_extension() in ["gd", "cs"] and not path.path_join(f) in files:
					files.append(path.path_join(f))
			files.sort()
		for f in files:
			var bytes := FileAccess.get_file_as_bytes(f)
			if bytes.is_empty():
				bytes = FileAccess.get_file_as_bytes(f.get_basename() + ".gdc")
			if bytes.is_empty():
				bytes = (f + "|" + str(ProjectSettings.get_setting("application/config/version", "?"))).to_utf8_buffer()
			out.append_array(f.to_utf8_buffer())
			out.append_array(_hash(bytes))
	return out


static func _base(seed_text: String, size: int) -> String:
	return ("%s|%d|%d" % [seed_text, WorldGenerator.PLAN_SIZE, size]).md5_text()


static func _key(seed_text: String, size: int, layer: int) -> String:
	return "%s|%d|%d|%s|%s" % [seed_text, WorldGenerator.PLAN_SIZE, size, WorldGenerator.LAYERS[layer], layer_keys()[layer]]


## Файл слоя layer мира
static func path_for(seed_text: String, size: int, layer: int) -> String:
	return dir.path_join("%s.%s%s" % [_base(seed_text, size), WorldGenerator.LAYERS[layer], EXT])


## Файлы всех слоёв мира
static func paths_for(seed_text: String, size: int = WorldGenerator.START_SIZE) -> Array[String]:
	var out: Array[String] = []
	for k in WorldGenerator.LAYERS.size():
		out.append(path_for(seed_text, size, k))
	return out


## Все слои мира в кэше и подходят к нынешнему коду (читается только заголовок)
static func has(seed_text: String, size: int = WorldGenerator.START_SIZE) -> bool:
	for k in WorldGenerator.LAYERS.size():
		var f := FileAccess.open(path_for(seed_text, size, k), FileAccess.READ)
		if f == null or f.get_length() < 64 or f.get_buffer(4).get_string_from_ascii() != MAGIC or f.get_32() != FORMAT \
				or f.get_pascal_string() != _key(seed_text, size, k):
			return false
	return true


## Мир с кэшем: подходящие слои читаются, с первого неподходящего генерация продолжается обычным путём,
## а новые слои пишутся в кэш в фоне (дождаться — wait_writes). layers — сколько слоёв взято из кэша.
static func generate(seed_text: String, size: int, on_progress: Callable = Callable(),
		after_climate: Callable = Callable()) -> Dictionary:
	var got := _load(seed_text, size)
	var n: int = got.layers
	if n == WorldGenerator.LAYERS.size():
		return {world = got.world, layers = n}
	var state := {prev = got.data}
	var w := WorldGenerator.generate_layers(seed_text, size, on_progress, after_climate, got.world, n,
		func(cur: WorldData, k: int) -> void:
			state.prev = _save_layer(cur, size, k, state.prev))
	return {world = w, layers = n}


## Подходящие слои подряд с первого: {world — мир с ними или null, layers — сколько, data — их поля}
static func _load(seed_text: String, size: int) -> Dictionary:
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
static func _save_layer(w: WorldData, size: int, layer: int, prev: Dictionary) -> Dictionary:
	var snap := {}
	var part := {}
	for p: Dictionary in w.get_property_list():
		if not (p.usage & PROPERTY_USAGE_SCRIPT_VARIABLE) or p.name in SKIP:
			continue
		var v: Variant = w.get(p.name)
		if typeof(v) == TYPE_OBJECT:
			continue
		# массивы и словари следующие слои меняют на месте; Packed*Array копируются при записи сами
		if v is Array or v is Dictionary:
			v = v.duplicate(true)
		snap[p.name] = v
		if not prev.has(p.name) or typeof(prev[p.name]) != typeof(v) or prev[p.name] != v:
			part[p.name] = v
	var raw := var_to_bytes(part)
	var path := path_for(w.seed_text, size, layer)
	var key := _key(w.seed_text, size, layer)
	var task := WorkerThreadPool.add_task(func() -> void: _write(path, key, raw), false, "Кэш мира")
	_lock.lock()
	_writes.append(task)
	_lock.unlock()
	return snap


static func wait_writes() -> void:
	_lock.lock()
	var tasks := _writes.duplicate()
	_writes.clear()
	_lock.unlock()
	for t in tasks:
		WorkerThreadPool.wait_for_task_completion(t)


## Удалить все файлы кэша, кроме миров из seeds (размера START_SIZE)
static func keep_only(seeds: Array) -> void:
	wait_writes()
	var keep := {}
	for s: String in seeds:
		keep[_base(s, WorldGenerator.START_SIZE)] = true
	if not DirAccess.dir_exists_absolute(dir):
		return
	for f in DirAccess.get_files_at(dir):
		if not keep.has(f.get_slice(".", 0)):
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


## Поля слоя из файла или null
static func _read(path: String, key: String) -> Variant:
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
static func _restore(data: Dictionary, complete: bool) -> WorldData:
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
