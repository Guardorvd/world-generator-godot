extends SceneTree
## 14.5: готовые файлы миров автора (RecommendedSeeds) в проект — resources/world_cache. Игра при запуске
## копирует их в кэш игрока (GameContext.scope.cache.install_bundled), и такой мир открывается без генерации.
## Пересобирать после правок генерации: иначе файлы не подойдут к коду и мир сгенерируется как обычно.
##   godot --headless --path . --script res://tools/bundle_cache.gd

func _init() -> void:
	preload("res://tools/watchdog.gd").arm(self, 600)
	var out := WorldCache.BUNDLED
	DirAccess.make_dir_recursive_absolute(out)
	for f in DirAccess.get_files_at(out):
		DirAccess.remove_absolute(out.path_join(f))
	GameContext.scope.cache.enabled = true
	GameContext.scope.cache.dir = out
	var manifest := {format = WorldCache.FORMAT, files = [], artifacts = [], previews = []}
	for r: Dictionary in RecommendedSeeds.SEEDS:
		var started := Time.get_ticks_msec()
		var loaded := WorldLoader.load_world(r.seed, WorldGenerator.START_SIZE)
		GameContext.scope.cache.wait_writes()
		for layer in WorldGenerator.LAYERS.size() + 1:
			var path := GameContext.scope.cache.path_for(r.seed, WorldGenerator.START_SIZE, layer)
			manifest.files.append({name = path.get_file(), seed = r.seed, size = WorldGenerator.START_SIZE,
				layer = layer, key = GameContext.scope.cache._key(r.seed, WorldGenerator.START_SIZE, layer),
				sha256 = Util.sha256(FileAccess.get_file_as_bytes(path)).hex_encode()})
		for artifact: String in ["base", "surface"]:
			var path := GameContext.scope.cache.artifact_path(r.seed, WorldGenerator.START_SIZE, artifact)
			if not FileAccess.file_exists(path): continue
			manifest.artifacts.append({name = path.get_file(), seed = r.seed, size = WorldGenerator.START_SIZE, artifact = artifact,
				key = GameContext.scope.cache.artifact_key(r.seed, WorldGenerator.START_SIZE, artifact),
				sha256 = Util.sha256(FileAccess.get_file_as_bytes(path)).hex_encode()})
		print("%s: %s, %d мс" % [r.seed, "из кэша" if loaded.from_cache else "сгенерирован", Time.get_ticks_msec() - started])
	# превью без расширения .png: иначе Godot импортирует его как текстуру
	var bytes := 0
	for f in DirAccess.get_files_at(out):
		if f.ends_with(WorldCache.PREVIEW):
			DirAccess.rename_absolute(out.path_join(f), out.path_join(f.trim_suffix(".png")))
			manifest.previews.append({name = f.trim_suffix(".png"), sha256 = Util.sha256(FileAccess.get_file_as_bytes(out.path_join(f.trim_suffix(".png")))).hex_encode()})
	var manifest_file := FileAccess.open(out.path_join("manifest.json"), FileAccess.WRITE)
	manifest_file.store_string(JSON.stringify(manifest, "\t"))
	manifest_file.close()
	for f in DirAccess.get_files_at(out):
		bytes += FileAccess.get_size(out.path_join(f))
		print("  ", f)
	print("Файлов в %s: %d, %.1f МБ" % [out, DirAccess.get_files_at(out).size(), bytes / 1048576.0])
	quit()
