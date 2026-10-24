extends SceneTree
## Владение контекстами, координатный доступ и совместимость packed API/слоёв кэша.
var fails := 0


func check(ok: bool, label: String) -> void:
	print(("OK " if ok else "FAIL ") + label)
	fails += int(not ok)


func _initialize() -> void:
	var w := WorldData.new()
	w.W = 3
	w.H = 2
	w.N = 6
	w.geology.h.resize()
	w.geology.h.set_cell(1, 1, 0.75)
	check(w.h[4] == 0.75 and w.grid.cell(4) == Vector2i(1, 1), "2D-адресация совпадает с контрактом плоского буфера")
	w.h[2] = 0.5
	check(w.geology.h.get_cell(2, 0) == 0.5, "поэлементная запись фасада видна контексту")
	w.h = PackedFloat32Array([1, 2, 3, 4, 5, 6])
	check(w.geology.h.get_cell(0, 1) == 4.0, "замена packed-буфера не оставляет старую ссылку в контексте")
	w.climate.biome.resize()
	w.climate.biome.set_cell(2, 1, Biomes.GRASS)
	check(w.biome[5] == Biomes.GRASS, "биомы принадлежат климатическому контексту")
	w.civil.path_mask.resize()
	w.civil.path_mask.set_cell(0, 1, 3)
	check(w.path_mask[3] == 3, "дороги принадлежат инфраструктурному контексту")
	w.geology.lake_id.resize()
	w.lake_id.fill(-1)
	w.geology.lake_id.set_cell(2, 0, 7)
	check(w.lake_near(1, 0, 1) == 7 and w.lake_within(1, 0, 1, 7), "поиск озёр использует координатный буфер")
	w.obj_x.append(12.5)
	w.settlements.append(SettlementData.from_dict({name = "Тест"}))
	check(w.climate.obj_x[0] == 12.5 and w.civil.settlements[0].name == "Тест", "столбцы объектов и списки доступны через фасад")
	var another := WorldData.new()
	check(another.h.is_empty() and another.settlements.is_empty() and another.grid.width == 0,
		"миры не разделяют изменяемые контексты по умолчанию")
	check(not w.grid.contains(-1, 0) and not w.grid.contains(3, 1) and w.grid.contains(2, 1), "границы прямоугольной сетки")
	var refs := context_refs(w)
	w = null
	check(refs.all(func(r: WeakRef) -> bool: return r.get_ref() == null), "контексты и буферы освобождаются вместе с фасадом")
	check(noise_disposed(), "незавершённое временное поле не удерживает мир и состояние генерации")
	cache_roundtrip()
	bundled_headers()
	print("world_context_test: %d failures" % fails)
	quit(1 if fails else 0)


func context_refs(w: WorldData) -> Array[WeakRef]:
	var refs: Array[WeakRef] = []
	for value: Object in [w, w.grid, w.geology, w.climate, w.civil, w.generation, w.streaming, w.geology.h]:
		refs.append(weakref(value))
	return refs


func noise_disposed() -> bool:
	var w := WorldData.new()
	w.W = 8
	w.H = 6
	w.N = w.W * w.H
	for name: String in WorldData.NOISE_FIELDS:
		w.noise[name] = Simplex.new(WGRandom.new(123))
	w.start_noise_fields()
	var owner: WeakRef = weakref(w)
	var state: WeakRef = weakref(w.generation)
	w = null
	return owner.get_ref() == null and state.get_ref() == null


func cache_roundtrip() -> void:
	var w := WorldData.new()
	w.W = WorldGenerator.PLAN_SIZE
	w.H = w.W
	w.N = w.W * w.H
	w.seed_text = "context-roundtrip"
	w.seed_num = WGRandom.hash_string(w.seed_text)
	w.geology.h.resize()
	w.geology.h.set_cell(2, 1, 0.125)
	w.climate.biome.resize()
	w.climate.biome.set_cell(2, 1, Biomes.GRASS)
	w.obj_count = 1
	w.obj_x = PackedFloat64Array([2.5])
	w.obj_y = PackedFloat64Array([1.5])
	w.obj_k = PackedInt32Array([0])
	w.obj_v = PackedInt32Array([0])
	w.obj_s = PackedFloat64Array([1.0])
	w.chunks = [PackedInt32Array([0])]
	var old_dir := GameContext.scope.cache.dir
	GameContext.scope.cache.dir = "res://.godot/context_cache_%d" % OS.get_process_id()
	var snapshot := GameContext.scope.cache._save_layer(w, 64, 0, {})
	GameContext.scope.cache.wait_writes()
	check(snapshot.size() == WorldData.CACHE_FIELDS.size() and not snapshot.has("_region_index")
		and not snapshot.has("generation"), "сериализация сохраняет только явную схему данных")
	var loaded := GameContext.scope.cache._load(w.seed_text, 64)
	var restored: WorldData = loaded.world
	check(loaded.layers == 1 and restored != null, "слой кэша восстановлен через фасад контекстов")
	if restored != null:
		check(restored.geology.h.data.to_byte_array() == w.h.to_byte_array()
			and restored.climate.biome.data == w.biome and restored.chunks == w.chunks,
			"побайтовый roundtrip и типизированные чанки")
		check(restored.geology.h.get_cell(2, 1) == 0.125 and restored.geology.h.layout.width == w.W,
			"размеры 2D-буферов восстановлены вместе с данными")
	var invalid := snapshot.duplicate(true)
	invalid.erase("h")
	check(GameContext.scope.cache._restore(invalid, false) == null, "отсутствующее обязательное поле отклоняется")
	invalid = snapshot.duplicate(true)
	invalid.h = PackedFloat32Array([1.0])
	check(GameContext.scope.cache._restore(invalid, false) == null, "неверная длина буфера отклоняется")
	for path: String in GameContext.scope.cache.paths_for(w.seed_text, 64):
		if FileAccess.file_exists(path):
			DirAccess.remove_absolute(path)
	DirAccess.remove_absolute(GameContext.scope.cache.dir)
	GameContext.scope.cache.dir = old_dir


func bundled_headers() -> void:
	var old_dir := GameContext.scope.cache.dir
	GameContext.scope.cache.dir = "res://.godot/bundled_header_test_%d" % OS.get_process_id()
	GameContext.scope.cache.install_bundled()
	var seed_text: String = RecommendedSeeds.SEEDS[0].seed
	var path := GameContext.scope.cache.path_for(seed_text, WorldGenerator.START_SIZE, 0)
	var key := GameContext.scope.cache._cache_header_key(path)
	var size := FileAccess.get_size(path)
	var f := FileAccess.open(path, FileAccess.READ_WRITE)
	f.seek(8)
	var wrong := key.left(key.length() - 1) + ("0" if not key.ends_with("0") else "1")
	f.store_pascal_string(wrong)
	f.close()
	GameContext.scope.cache.install_bundled()
	check(GameContext.scope.cache._cache_header_key(path) == key and FileAccess.get_size(path) == size,
		"встроенный кэш обновляется при новом ключе даже без изменения размера файла")
	for name: String in DirAccess.get_files_at(GameContext.scope.cache.dir):
		DirAccess.remove_absolute(GameContext.scope.cache.dir.path_join(name))
	DirAccess.remove_absolute(GameContext.scope.cache.dir)
	GameContext.scope.cache.dir = old_dir
