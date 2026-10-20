extends SceneTree
## Выделения FastGrid и равенство последовательного/параллельного рельефа, включая фоновые куски.

var fails := 0


func _initialize() -> void:
	var probe: Object = load("res://tools/ComputeProbe.cs").new()
	print("FastGrid constructor: %d managed bytes" % probe.ConstructorBytes(100))
	for size in [256, 512, 768]:
		var allocated: PackedInt64Array = probe.CorridorBytes(size, 3)
		print("Corridor %d managed bytes: %s" % [size, allocated])
		_check(allocated[1] == 0 and allocated[2] == 0, "повторная ширина прохода без новых буферов %d" % size)
	if OS.get_cmdline_user_args().has("--alloc-only"):
		quit(0 if fails == 0 else 1)
		return
	# На одном finder меняем и ширину, и поверхность. Кэш прежнего прохода не должен выжить.
	var flat := PackedFloat32Array()
	flat.resize(12 * 12)
	var water := flat.duplicate()
	water.fill(-INF)
	var wet := PackedByteArray()
	wet.resize(flat.size())
	var costs := flat.duplicate()
	costs.fill(1.0)
	var finder := Pathfinder.new(12, 12, flat)
	for phase in 3:
		var ground := flat.duplicate()
		if phase == 1:
			for y in 12:
				for x in range(6, 12):
					ground[y * 12 + x] = 10.0
		finder.set_corridor(ground, water, wet, 0.45 - phase * 0.05)
		var route := finder.find_path(costs, 5 * 12 + 1, 5 * 12 + 10, 32.0, 0.35)
		_check(route.is_empty() == (phase == 1), "сброс кэша прохода при смене поверхности %d" % phase)
	var w := WorldData.new()
	w.rng = WGRandom.new(1234)
	for name in ["warpX", "warpY", "cont", "mask", "ridge", "hill"]:
		w.noise[name] = Simplex.new(w.rng)
	var fast := Grid.fast_grid()
	for rect: Rect2i in [Rect2i(-67, -129, 69, 69), Rect2i(511, 511, 19, 7), Rect2i(0, 0, 1, 33)]:
		var a := StageRelief.raw_rect(w, rect.position.x, rect.position.y, rect.size.x, rect.size.y, false)
		var b := StageRelief.raw_rect(w, rect.position.x, rect.position.y, rect.size.x, rect.size.y, true)
		_check(a == b, "последовательный и параллельный рельеф %s" % rect)
		var pm: PackedInt32Array = w.noise.cont.perm
		var c: PackedFloat64Array = fast.FbmRect(pm, rect.position.x, rect.position.y, rect.size.x, rect.size.y, 170.0, 4, 0.0, 0.0, false)
		var d: PackedFloat64Array = fast.FbmRect(pm, rect.position.x, rect.position.y, rect.size.x, rect.size.y, 170.0, 4, 0.0, 0.0, true)
		_check(c == d, "последовательный и параллельный fbm %s" % rect)
	# Одновременные внешние задачи используют независимые объекты C#, результат тот же.
	var expected := StageRelief.raw_rect(w, -65, 511, 69, 69, false)
	var results := Parallel.bands(3, func(_a: int, _b: int) -> PackedFloat32Array:
		return StageRelief.raw_rect(w, -65, 511, 69, 69, false), 1)
	for result in results:
		_check(result == expected, "одновременный фоновый расчёт")
	quit(0 if fails == 0 else 1)


func _check(ok: bool, label: String) -> void:
	if not ok:
		fails += 1
		printerr("FAIL: " + label)
	else:
		print("OK: " + label)
