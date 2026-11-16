extends SceneTree
var fails := 0


func check(ok: bool, label: String) -> void:
	print(("OK " if ok else "FAIL ") + label)
	fails += int(not ok)


func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 60)
	var versions := PackedInt32Array([WorldCache.SCHEMA_GEO_VERSION, WorldCache.SCHEMA_TRAILS_VERSION,
		WorldCache.SCHEMA_NATURE_VERSION, WorldCache.SCHEMA_VIEW_VERSION])
	var suffixes := WorldCache._road_layer_suffixes(RoadTuning.current(), QuickTrails.network())
	var base := WorldCache.schema_keys(WorldCache.SCHEMA_WORLD_VERSION, versions, suffixes)
	check(base == GameContext.scope.cache.layer_keys(), "производственные ключи соответствуют версиям и входам слоёв")
	for changed in versions.size():
		var next := versions.duplicate()
		next[changed] += 1
		var keys := WorldCache.schema_keys(WorldCache.SCHEMA_WORLD_VERSION, next, suffixes)
		var valid := true
		for k in keys.size():
			valid = valid and (keys[k] == base[k] if k < changed else keys[k] != base[k])
		check(valid, "изменение версии слоя %d сохраняет предыдущие и инвалидирует следующие" % changed)
	var common := WorldCache.schema_keys(WorldCache.SCHEMA_WORLD_VERSION + 1, versions, suffixes)
	check(range(common.size()).all(func(k: int) -> bool: return common[k] != base[k]), "общая версия инвалидирует все слои")
	var old_version: Variant = ProjectSettings.get_setting("application/config/version")
	ProjectSettings.set_setting("application/config/version", "release-test-999")
	GameContext.scope.cache._layer_keys.clear()
	check(GameContext.scope.cache.layer_keys() == base, "версия приложения не влияет на ключи")
	ProjectSettings.set_setting("application/config/version", old_version)
	var copy := GameContext.scope.cache.layer_keys()
	copy[0] = "changed-by-caller"
	check(GameContext.scope.cache.layer_keys() == base, "потребитель не может изменить опубликованные ключи")
	_road_dependencies(versions)
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


func _road_dependencies(versions: PackedInt32Array) -> void:
	var tuning := RoadTuning.current()
	var network := QuickTrails.network()
	var baseline := _key_snapshot()
	var turn: float = tuning.routing.turn_costs.road
	tuning.routing.turn_costs.road = turn + 1.25
	_check_road_keys(baseline, _key_snapshot(), 1, true, true, "штраф поворота")
	tuning.routing.turn_costs.road = turn
	var roll := tuning.road.roll
	var normal := WorldCache._road_layer_suffixes(tuning, false)
	var prepared := WorldCache._road_layer_suffixes(tuning, true)
	tuning.road.roll = roll + 0.125
	_check_road_keys(baseline, _key_snapshot(), 1 if network else 2, true, network, "форма полотна")
	check(WorldCache._road_layer_suffixes(tuning, false).places == normal.places
		and WorldCache.schema_keys(WorldCache.SCHEMA_WORLD_VERSION, versions, WorldCache._road_layer_suffixes(tuning, true))[1]
		!= WorldCache.schema_keys(WorldCache.SCHEMA_WORLD_VERSION, versions, prepared)[1],
		"форма полотна меняет слой путей только при подготовке сети трасс")
	tuning.road.roll = roll
	var section := tuning.section
	var initial_width: float = section.widths.trail
	section.widths.trail = initial_width + 0.05
	_check_road_keys(baseline, _key_snapshot(), 1, true, true, "рабочая ширина")
	section.widths.trail = initial_width
	var initial_clearance: float = section.clearance.trail
	section.clearance.trail = initial_clearance + 0.25
	_check_road_keys(baseline, _key_snapshot(), 2, true, true, "лесной просвет")
	section.clearance.trail = initial_clearance
	var initial_edge := section.edge
	section.edge = initial_edge - 0.05
	_check_road_keys(baseline, _key_snapshot(), 1 if network else versions.size(), true, network, "маска кромки")
	check(WorldCache._road_layer_suffixes(tuning, true).places != prepared.places, "маска кромки влияет на подготовленную сеть")
	section.edge = initial_edge
	var root_chance := tuning.obstacles.root_chance
	tuning.obstacles.root_chance = root_chance * 0.5
	check(baseline == _key_snapshot() and WorldCache._road_layer_suffixes(tuning, true) == prepared,
		"настройки препятствий не меняют дисковые ключи мира")
	tuning.obstacles.root_chance = root_chance
	var overrides := StageTrails.routing_overrides
	StageTrails.routing_overrides = {turn_costs = {road = 0.0, trail = 0.0, mountain = 0.0},
		bend_costs = {road = 0.0, trail = 0.0, mountain = 0.0}}
	check(baseline == _key_snapshot(), "временные настройки поиска не попадают в кэш игры")
	StageTrails.routing_overrides = overrides


func _key_snapshot() -> Dictionary:
	var cache := WorldCache.new()
	var world := WorldData.new()
	world.seed_text = "road tuning key fixture"
	world.W = 2
	world.H = 2
	world.h = PackedFloat32Array([0.1, 0.2, 0.3, 0.4])
	world.path_mask = PackedByteArray([0, 1, 2, 3])
	return {layers = cache.layer_keys(), base = cache.artifact_key(world.seed_text, 512, "base"),
		surface = cache.artifact_key(world.seed_text, 512, "surface"), region = RegionStream.store_dir(world)}


func _check_road_keys(before: Dictionary, after: Dictionary, first_layer: int, surface: bool, region: bool, label: String) -> void:
	var layers := true
	for k in before.layers.size():
		layers = layers and ((before.layers[k] == after.layers[k]) == (k < first_layer))
	check(layers and before.base == after.base and ((before.surface != after.surface) == surface)
		and ((before.region != after.region) == region), label)
