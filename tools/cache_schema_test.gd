extends SceneTree
var fails := 0


func check(ok: bool, label: String) -> void:
	print(("OK " if ok else "FAIL ") + label)
	fails += int(not ok)


func _initialize() -> void:
	var versions := PackedInt32Array([WorldCache.SCHEMA_GEO_VERSION, WorldCache.SCHEMA_TRAILS_VERSION,
		WorldCache.SCHEMA_NATURE_VERSION, WorldCache.SCHEMA_VIEW_VERSION])
	var base := WorldCache.schema_keys(WorldCache.SCHEMA_WORLD_VERSION, versions)
	check(base == WorldCache.layer_keys(), "производственные ключи равны явным версиям схем")
	for changed in versions.size():
		var next := versions.duplicate()
		next[changed] += 1
		var keys := WorldCache.schema_keys(WorldCache.SCHEMA_WORLD_VERSION, next)
		var valid := true
		for k in keys.size():
			valid = valid and (keys[k] == base[k] if k < changed else keys[k] != base[k])
		check(valid, "изменение версии слоя %d сохраняет предыдущие и инвалидирует следующие" % changed)
	var common := WorldCache.schema_keys(WorldCache.SCHEMA_WORLD_VERSION + 1, versions)
	check(range(common.size()).all(func(k: int) -> bool: return common[k] != base[k]), "общая версия инвалидирует все слои")
	var old_version: Variant = ProjectSettings.get_setting("application/config/version")
	ProjectSettings.set_setting("application/config/version", "release-test-999")
	WorldCache._layer_keys.clear()
	check(WorldCache.layer_keys() == base, "версия приложения не влияет на ключи")
	ProjectSettings.set_setting("application/config/version", old_version)
	var copy := WorldCache.layer_keys()
	copy[0] = "changed-by-caller"
	check(WorldCache.layer_keys() == base, "потребитель не может изменить опубликованные ключи")
	var result := {keys = base}
	var args := OS.get_cmdline_user_args()
	if args.has("--packed"):
		check(not FileAccess.file_exists("res://scripts/world/world_cache.gd")
			and not FileAccess.file_exists("res://scripts/core/FastGrid.cs"),
			"в PCK исходники недоступны по обычным путям")
	if args.has("--out"):
		var f := FileAccess.open(args[args.find("--out") + 1], FileAccess.WRITE)
		f.store_string(JSON.stringify(result))
	print(JSON.stringify(result))
	quit(1 if fails else 0)
