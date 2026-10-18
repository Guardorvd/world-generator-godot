extends SceneTree
## Самопроверка генератора: тот же сид должен давать тот же мир.
## Хеши массивов мира (FNV-1a по байтам, как в JS-версии) сравниваются с эталоном
## tools/selftest_reference.json. До версии 1.7 эталон был снят с JS-версии 1.2; с 1.8 генерация
## намеренно другая (дороги, мосты, туннели), эталон снят с неё. Ещё проверяется, что по дорогам
## и тропам из любого поселения можно дойти до любого другого. Запуск из папки проекта:
##   godot --headless --script res://tools/selftest.gd
## С ключом -- --print печатает свежие хеши вместо сравнения (так обновляется эталон).
## С ключом -- --gdscript проверяет генерацию без C# (FastGrid.cs), как в обычной сборке Godot.

const CASES := [["Север-1234", 256], ["Туман-4821", 192], ["abc", 128], ["Ущелье", 512]]   # в «Ущелье» дорога обходит гору (с 1.9.2)


static func fnv(bytes: PackedByteArray) -> int:
	var h := 2166136261
	for b in bytes:
		h = WGRandom.imul(h ^ b, 16777619)
	return h


## Связаны ли все поселения путями людей (клетки path_mask 2 и 3, по восьми соседям; мосты в них входят)
static func settlements_connected(w: WorldData) -> bool:
	if w.settlements.is_empty():
		return true
	var seen := PackedByteArray()
	seen.resize(w.N)
	var queue := PackedInt32Array([w.settlements[0].i])
	seen[queue[0]] = 1
	var head := 0
	while head < queue.size():
		var c := queue[head]
		head += 1
		var cx := c % w.W
		var cy := c / w.W
		for k in 8:
			var nx: int = cx + Grid.DX[k]
			var ny: int = cy + Grid.DY[k]
			if nx < 0 or ny < 0 or nx >= w.W or ny >= w.H:
				continue
			var n := ny * w.W + nx
			if seen[n] == 0 and w.path_mask[n] >= 2:
				seen[n] = 1
				queue.append(n)
	for s in w.settlements:
		if seen[s.i] == 0:
			return false
	return true


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
	r.bridges = w.bridges.size()
	r.tunnels = w.tunnels.size()
	var names := PackedStringArray()
	for s in w.settlements:
		names.append(s.name)
	for p in w.peaks:
		names.append(p.name)
	r.names = ",".join(names)
	# озёра с названиями (с 2.9): имя, клеток, середина
	var lakes := PackedStringArray()
	for lk in w.lakes:
		lakes.append("%s %d %d,%d" % [lk.name, lk.cells, lk.x, lk.y])
	r.lakes = "; ".join(lakes)
	return r


func _init() -> void:
	var print_only := OS.get_cmdline_user_args().has("--print")
	Grid.allow_fast = not OS.get_cmdline_user_args().has("--gdscript")
	var ref: Variant = {}
	if not print_only:
		ref = JSON.parse_string(FileAccess.get_file_as_string("res://tools/selftest_reference.json"))
		if not (ref is Dictionary):
			printerr("Эталон tools/selftest_reference.json не прочитан: нет файла или он повреждён")
			quit(1)
			return
	var fresh := {}
	var fails := 0
	for c in CASES:
		var key := "%s@%d" % [c[0], c[1]]
		var t0 := Time.get_ticks_msec()
		var w := WorldGenerator.generate(c[0], c[1])
		var fp := fingerprint(w)
		fresh[key] = fp
		if print_only:
			continue
		var want: Dictionary = ref.get(key, {})
		var bad := PackedStringArray()
		if not settlements_connected(w):
			bad.append("связь поселений по дорогам и тропам")
		if want.is_empty():
			bad.append("нет случая в эталоне (запустите с -- --print)")
		else:
			for k in fp:
				if not want.has(k) or (str(want[k]) != str(fp[k]) if fp[k] is String else int(want[k]) != int(fp[k])):
					bad.append(k)
		if bad.size() > 0:
			fails += 1
		print("%s %s (%d мс)%s" % ["✗" if bad.size() > 0 else "✓", key, Time.get_ticks_msec() - t0, (" — отличается: " + ", ".join(bad)) if bad.size() > 0 else ""])
	if print_only:
		print(JSON.stringify(fresh, " "))
	else:
		print("Не совпало случаев: %d" % fails if fails > 0 else "Все миры совпали с эталоном.")
	quit(1 if fails > 0 else 0)
