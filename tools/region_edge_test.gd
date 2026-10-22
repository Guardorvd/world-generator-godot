extends SceneTree
## Небольшой географический стенд: смешанный прямоугольник у края и плоский водосбор.
const SelfTest := preload("res://tools/selftest.gd")
var fails := 0


func check(ok: bool, label: String) -> void:
	if not ok:
		fails += 1
		printerr(label)


func _init() -> void:
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
	# Через одну границу: река, сухой подход к истоку, выход из озера и устье в озеро.
	w.river.fill(0)
	w.lake.fill(0)
	w.down.fill(-1)
	w.acc.fill(0)
	w.filled.fill(0.1)
	for n in 4:
		var i := (10 + n * 2) * w.W + 47
		var d := i + 1
		w.down[i] = d
		w.river[i] = 0 if n in [1, 2] else 1
		w.river[d] = 0 if n == 3 else 1
		w.lake[i] = 1 if n == 2 else 0
		w.lake[d] = 1 if n == 3 else 0
		w.acc[i] = 10.0 if n == 1 else 100.0
		w.acc[d] = 200.0
		w.filled[i] = 0.12
		w.watershed[i] = d
		w.watershed[d] = d
	var left := WorldRegion.river_links(w, Rect2i(0, 0, 48, 96))
	var right := WorldRegion.river_links(w, Rect2i(48, 0, 48, 96))
	check(left == right and left.size() == 3, "Сухой подход выдан как река или соседи не согласовали связи")
	for link: Dictionary in left:
		if link.from_lake: check(link.width == link.next_width, "Выход из озера не согласован с началом русла")
		if link.to.y == 16: check(link.next_width > link.width, "Устье не расширяется к озеру")
	w.clear_noise_fields()
	print("BACKEND_FINGERPRINT=" + JSON.stringify(fingerprints))
	print("region_edge_test: " + ("OK" if fails == 0 else "ошибок %d" % fails))
	quit(1 if fails > 0 else 0)
