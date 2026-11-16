extends SceneTree
## Снимок-эталон дорожных вычислений (16.11.2026): хеши результата RoadBed и RoadRefinement на синтетическом стенде
## road_relief_fixture (мир не генерируется, секунды): полная сборка и частичная ({0: true}, как у Trail Lab).
## Нужен, чтобы переносить дорожный код на C# и перестраивать его, не меняя результат: любая правка, после которой хеши
## расходятся, меняет мир. Эталон пишется один раз на проверенном коде; пересъёмка — только осознанно (поведение изменили).
##   godot --headless --path . --script res://tools/road_golden.gd -- [--save]
## Без ключа сверяет с tools/control/golden/roads.txt и печатает «ROAD GOLDEN RESULT n failures»; код 1 при расхождении.
## Лимит 60 с (watchdog).
const Fixture := preload("res://tools/road_relief_fixture.gd")
const FILE := "res://tools/control/golden/roads.txt"
var lines := {}


func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 60)
	run.call_deferred()


func run() -> void:
	var save := "--save" in OS.get_cmdline_user_args()
	if Grid.fast_grid() == null:
		print("ROAD GOLDEN: нужен C# (dotnet build), без него эталон не снять и не сверить")
		quit(1)
		return
	var w := Fixture.world()
	var h := Heightfield.new(w, false)
	h.road_refinement = null
	RoadBed.refine(h)
	h.build_structures()
	lines["whole.bed_hv"] = _hash(h.hv)
	var whole := RoadRefinement.build(h)
	_refinement("whole", whole)
	h.road_refinement = whole
	# Частичная пересборка нового пути на готовой сетке: полотно и сетка только вокруг пути 0
	var part := Heightfield.new(w, false)
	RoadBed.refine(part)
	part.build_structures()
	part.road_refinement = whole
	var frozen := PackedByteArray()
	frozen.resize(w.N)
	for i in w.N:
		frozen[i] = 1 if i % 97 < 9 else 0
	RoadBed.refine(part, {0: true}, frozen)
	lines["part.bed_hv"] = _hash(part.hv)
	_refinement("part", RoadRefinement.build(part, true, {0: true}))
	if save:
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(FILE.get_base_dir()))
		var file := FileAccess.open(FILE, FileAccess.WRITE)
		for key: String in _sorted(lines.keys()):
			file.store_line("%s %s" % [key, lines[key]])
		file.close()
		print("ROAD GOLDEN: записано %d хешей в %s" % [lines.size(), FILE])
		quit(0)
		return
	var saved := {}
	if FileAccess.file_exists(FILE):
		for row in FileAccess.get_file_as_string(FILE).split("\n", false):
			var pair := row.split(" ")
			if pair.size() == 2: saved[pair[0]] = pair[1]
	var failures := 0
	if saved.is_empty():
		print("FAIL эталона нет: %s (снять: -- --save)" % FILE)
		failures += 1
	for key: String in _sorted(lines.keys()):
		var same: bool = saved.get(key, "") == lines[key]
		print("PASS " if same else "FAIL ", key)
		failures += int(not same)
	for key: String in saved:
		if not lines.has(key):
			print("FAIL в эталоне лишний ключ ", key)
			failures += 1
	print("ROAD GOLDEN RESULT %d failures" % failures)
	quit(1 if failures else 0)


## Профиль подгонки, формы коридора и метровые патчи — по отдельному хешу: видно, что именно разошлось
func _refinement(label: String, r: RoadRefinement) -> void:
	var fit := HashingContext.new()
	fit.start(HashingContext.HASH_SHA256)
	for route: int in _sorted(r.fit_routes.keys()):
		var f: Dictionary = r.fit_routes[route]
		for field: String in ["points", "profile", "strength", "limit"]:
			fit.update(var_to_bytes(f[field]))
		fit.update(var_to_bytes(route))
	lines[label + ".fit"] = fit.finish().hex_encode()
	var corridor := HashingContext.new()
	corridor.start(HashingContext.HASH_SHA256)
	corridor.update(var_to_bytes(r.corridor))
	for route: int in _sorted(r.corridor_routes.keys()):
		corridor.update(var_to_bytes([route, r.corridor_routes[route]]))
	lines[label + ".corridor"] = corridor.finish().hex_encode()
	var patches := HashingContext.new()
	patches.start(HashingContext.HASH_SHA256)
	for key: int in _sorted(r.patches.keys()):
		patches.update(var_to_bytes(key))
		var patch: Dictionary = r.patches[key]
		for field: String in _sorted(patch.keys()):
			patches.update(var_to_bytes(patch[field]))
	lines[label + ".patches"] = patches.finish().hex_encode()
	lines[label + ".patch_count"] = str(r.patches.size())


func _hash(value: Variant) -> String:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(var_to_bytes(value))
	return ctx.finish().hex_encode()


func _sorted(values: Array) -> Array:
	var copy := values.duplicate()
	copy.sort()
	return copy
