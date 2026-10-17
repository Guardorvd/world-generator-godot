extends SceneTree
## Самопроверка генератора: тот же сид должен давать тот же мир, что и в JS-версии 1.2.
## Хеши массивов мира (FNV-1a по байтам, как в tools/selftest.js JS-версии) сравниваются с эталоном
## tools/selftest_reference.json, снятым с JS-версии. Запуск из папки проекта:
##   godot --headless --script res://tools/selftest.gd
## С ключом -- --print печатает свежие хеши вместо сравнения (так обновляется эталон).
## С ключом -- --gdscript проверяет генерацию без C# (FastGrid.cs), как в обычной сборке Godot.

const CASES := [["Север-1234", 256], ["Туман-4821", 192], ["abc", 128]]


static func fnv(bytes: PackedByteArray) -> int:
	var h := 2166136261
	for b in bytes:
		h = WGRandom.imul(h ^ b, 16777619)
	return h


static func fingerprint(w: WorldData) -> Dictionary:
	var r := {}
	for key in ["h", "filled", "elev", "acc", "slope", "temp", "moist", "dist_ocean", "dist_water"]:
		r[key] = fnv((w.get(key) as PackedFloat32Array).to_byte_array())
	for key in ["ocean", "lake", "river", "biome", "path_mask"]:
		r[key] = fnv(w.get(key))
	r.seed_num = w.seed_num
	r.obj_count = w.obj_count
	r.rivers = w.rivers.size()
	r.trails = w.trails.size()
	var names := PackedStringArray()
	for s in w.settlements:
		names.append(s.name)
	for p in w.peaks:
		names.append(p.name)
	r.names = ",".join(names)
	return r


func _init() -> void:
	var print_only := OS.get_cmdline_user_args().has("--print")
	Grid.allow_fast = not OS.get_cmdline_user_args().has("--gdscript")
	var ref := {}
	if not print_only:
		ref = JSON.parse_string(FileAccess.get_file_as_string("res://tools/selftest_reference.json"))
	var fresh := {}
	var fails := 0
	for c in CASES:
		var key := "%s@%d" % [c[0], c[1]]
		var t0 := Time.get_ticks_msec()
		var fp := fingerprint(WorldGenerator.generate(c[0], c[1]))
		fresh[key] = fp
		if print_only:
			continue
		var exp: Dictionary = ref.get(key, {})
		var bad := PackedStringArray()
		for k in fp:
			if not exp.has(k) or (str(exp[k]) != str(fp[k]) if fp[k] is String else int(exp[k]) != int(fp[k])):
				bad.append(k)
		if bad.size() > 0:
			fails += 1
		print("%s %s (%d мс)%s" % ["✗" if bad.size() > 0 else "✓", key, Time.get_ticks_msec() - t0, (" — отличается: " + ", ".join(bad)) if bad.size() > 0 else ""])
	if print_only:
		print(JSON.stringify(fresh, " "))
	else:
		print("Не совпало случаев: %d" % fails if fails > 0 else "Все миры совпали с эталоном.")
	quit(1 if fails > 0 else 0)
