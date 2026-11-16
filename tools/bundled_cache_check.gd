extends SceneTree
## Подходят ли готовые миры из resources/world_cache к нынешнему коду (читаются только заголовки, секунды, без генерации).
##   godot --headless --path . --script res://tools/bundled_cache_check.gd

func _init() -> void:
	preload("res://tools/watchdog.gd").arm(self, 30)
	var cache := WorldCache.new()
	var stale := 0
	for r: Dictionary in RecommendedSeeds.SEEDS:
		var ok := cache.has_bundled(r.seed)
		stale += int(not ok)
		print("%s: %s" % [r.seed, "подходит" if ok else "УСТАРЕЛ"])
		for layer in WorldGenerator.LAYERS.size() + 1:
			var f := WorldCache.BUNDLED.path_join(cache.path_for(r.seed, WorldGenerator.START_SIZE, layer).get_file())
			print("  слой %d: %s" % [layer, "подходит" if cache._cache_header_key(f) == cache._key(r.seed, WorldGenerator.START_SIZE, layer) else "не подходит"])
	print("устарело миров: %d из %d" % [stale, RecommendedSeeds.SEEDS.size()])
	quit()
