extends SceneTree
## Небольшой географический стенд: смешанный прямоугольник у края и плоский водосбор.
const SelfTest := preload("res://tools/selftest.gd")
var fails := 0


func check(ok: bool, label: String) -> void:
	if not ok:
		fails += 1
		printerr(label)


func _init() -> void:
	preload("res://tools/watchdog.gd").arm(self, 60)
	Grid.allow_fast = not OS.get_cmdline_user_args().has("--gdscript")
	# Частный размер допустим только у этого стенда, не для соседних игровых областей.
	var w := WorldGenerator._geography("Север-1234", 96)
	var r := Rect2i(-7, 18, 25, 31)
	var a := OuterLand.compute(w, r.position.x, r.position.y, r.size.x, r.size.y)
	var large := r.grow(13)
	var b := OuterLand.compute(w, large.position.x, large.position.y, large.size.x, large.size.y)
	for name: String in a:
		var differences := 0
		for y in r.size.y:
			for x in r.size.x:
				var i := y * r.size.x + x
				var j := (y + 13) * large.size.x + x + 13
				if a[name][i] != b[name][j]: differences += 1
		check(differences == 0, "У края результат зависит от размера запроса: " + name)
	for y in r.size.y:
		for x in range(7, r.size.x):
			var i := y * r.size.x + x
			var j := (y + r.position.y) * w.W + x + r.position.x
			check(a.h[i] == w.h[j] and a.dw[i] == w.dist_water[j] and a.river[i] == w.river_cells()[j],
				"Смешанный прямоугольник потерял готовую долину или воду")
	var fingerprints := {down = SelfTest.fnv(w.down.to_byte_array()), watershed = SelfTest.fnv(w.watershed.to_byte_array()),
		edge = SelfTest.fnv(var_to_bytes(a))}
	# Равные высоты проверяют одинаковое разрешение ничьих flood в двух реализациях.
	w.h.fill(0.1)
	w.ocean.fill(0)
	StageHydrology.run(w)
	var bad := 0
	for i in w.N:
		if w.watershed[i] < 0 or w.down[w.watershed[i]] >= 0 or w.down[i] >= 0 and w.watershed[w.down[i]] != w.watershed[i]:
			bad += 1
	check(bad == 0, "Разорван плоский водосбор")
	fingerprints.flat_down = SelfTest.fnv(w.down.to_byte_array())
	fingerprints.flat_watershed = SelfTest.fnv(w.watershed.to_byte_array())
	w.clear_noise_fields()
	print("BACKEND_FINGERPRINT=" + JSON.stringify(fingerprints))
	print("region_edge_test: " + ("OK" if fails == 0 else "ошибок %d" % fails))
	quit(1 if fails > 0 else 0)
