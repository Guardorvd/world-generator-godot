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
	for r: Dictionary in RecommendedSeeds.SEEDS:
		var started := Time.get_ticks_msec()
		var loaded := WorldLoader.load_world(r.seed, WorldGenerator.START_SIZE)
		GameContext.scope.cache.wait_writes()
		print("%s: %s, %d мс" % [r.seed, "из кэша" if loaded.from_cache else "сгенерирован", Time.get_ticks_msec() - started])
	# превью без расширения .png: иначе Godot импортирует его как текстуру
	var bytes := 0
	for f in DirAccess.get_files_at(out):
		if f.ends_with(WorldCache.PREVIEW):
			DirAccess.rename_absolute(out.path_join(f), out.path_join(f.trim_suffix(".png")))
	for f in DirAccess.get_files_at(out):
		bytes += FileAccess.get_size(out.path_join(f))
		print("  ", f)
	print("Файлов в %s: %d, %.1f МБ" % [out, DirAccess.get_files_at(out).size(), bytes / 1048576.0])
	quit()
