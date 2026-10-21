extends SceneTree
## 5.8: сток, слияния, короткие ручьи, долины и выходы из окна мира.
## godot --headless --path . --script res://tools/hydrology_test.gd [-- --gdscript]

var fails := 0

func check(ok: bool, label: String) -> void:
	if not ok:
		fails += 1
		printerr(label)

func inspect(w: WorldData, before: PackedFloat32Array) -> void:
	var rank := PackedInt32Array()
	rank.resize(w.N)
	for k in w.order_n:
		rank[w.order[k]] = k
	var bad_flow := 0
	var raised := 0
	var cuts := 0
	for i in w.N:
		# Речная поверхность у моря ограничена нулём; исходная сухая впадина
		# иногда на несколько сантиметров ниже него. Боковой срез ничего не насыпает.
		if w.h[i] > maxf(0.0, before[i]) + 1e-6:
			raised += 1
		if w.river[i] == 0 and w.h[i] < before[i] - 1e-6:
			cuts += 1
		if w.ocean[i] != 0 or w.lake[i] != 0:
			check(w.h[i] == before[i], "Не менять море и дно озёр")
		var d := w.down[i]
		if d >= 0 and (rank[d] >= rank[i] or w.acc[d] + 0.001 < w.acc[i]):
			bad_flow += 1
		if w.river[i] != 0 and d >= 0:
			check(w.h[i] >= 0.0, "Речной профиль не ниже уровня моря")
			if w.filled[d] > w.filled[i] + 1e-6:
				bad_flow += 1
			if w.ocean[d] == 0 and w.lake[d] == 0 and w.river[d] == 0:
				bad_flow += 1
	check(bad_flow == 0, "%s: циклы, потеря стока или разрыв реки (%d)" % [w.seed_text, bad_flow])
	check(raised == 0, "Долины только срезают рельеф, устье не ниже моря")
	check(cuts > 0, "%s: реки формируют соседние склоны" % w.seed_text)
	var ends := {}
	for r: Array in w.rivers:
		check(r.size() >= 2, "Сохранять короткие ручьи")
		for k in range(1, r.size()):
			check(r[k].e <= r[k - 1].e + 1e-6, "Вода не поднимается после сглаживания")
		for p: Dictionary in [r[0], r[-1]]:
			var key := Vector2(p.x, p.y)
			var cell := clampi(floori(p.y), 0, w.H - 1) * w.W + clampi(floori(p.x), 0, w.W - 1)
			if ends.has(key) and w.river[cell] != 0:
				check(absf(ends[key].e - p.e) < 1e-6 and absf(ends[key].w - p.w) < 1e-6, "Общие высота и ширина слияния")
			ends[key] = p
	for p: Dictionary in w.river_exits:
		check(p.x == 0.0 or p.y == 0.0 or p.x == w.W or p.y == w.H, "Выход лежит на границе окна")
		check(ends.has(Vector2(p.x, p.y)), "Лента доходит до выхода")
		check(p.acc >= WorldData.STREAM_ACC, "Выход сохраняет расход")
	var heights := Heightfield.new(w, false)
	for ribbon: Array in heights.ribbons:
		for k in range(1, ribbon.size()):
			check(ribbon[k].y <= ribbon[k - 1].y + 1e-5, "Игровая вода течёт вниз")
	print("%s@%d: клеток рек %d, участков %d, выходов %d, склонов долин %d" % [w.seed_text, w.W, w.river.count(1), w.rivers.size(), w.river_exits.size(), cuts])

func short_junction() -> void:
	var w := WorldData.new()
	w.W = 5
	w.H = 5
	w.N = 25
	w.h.resize(25)
	w.h.fill(0.1)
	w.filled = w.h.duplicate()
	w.ocean.resize(25)
	w.lake.resize(25)
	w.river.resize(25)
	w.acc.resize(25)
	w.down.resize(25)
	w.down.fill(-1)
	# Два коротких притока сходятся в 12; сразу за ним озеро.
	for i in [6, 8, 12]:
		w.river[i] = 1
		w.acc[i] = 100.0 if i != 12 else 200.0
	w.down[6] = 12
	w.down[8] = 12
	w.down[12] = 17
	w.lake[17] = 1
	StageRivers.run(w)
	check(w.rivers.size() == 3, "Не терять притоки длиной в одно ребро и короткий выход слияния")
	var joins := 0
	for r: Array in w.rivers:
		for p: Dictionary in [r[0], r[-1]]:
			if p.x == 2.5 and p.y == 2.5:
				joins += 1
	check(joins == 3, "Все три участка сходятся в одной точке")

func _init() -> void:
	Grid.allow_fast = not OS.get_cmdline_user_args().has("--gdscript")
	short_junction()
	for seed_text in ["Север-1234", "Туман-4821", "Ущелье", "Янтарь-5150"]:
		var w := WorldData.new()
		w.W = 256
		w.H = 256
		w.N = w.W * w.H
		w.scale = float(w.N) / (512 * 512)
		w.seed_text = seed_text
		w.seed_num = WGRandom.hash_string(seed_text)
		w.rng = WGRandom.new(w.seed_num)
		for key in ["warpX", "warpY", "cont", "mask", "ridge", "hill", "moist", "temp", "forest", "cost", "micro"]:
			w.noise[key] = Simplex.new(w.rng)
		StageRelief.run(w)
		StageOcean.run(w)
		StageHydrology.run(w)
		var before := w.h.duplicate()
		StageRivers.run(w)
		inspect(w, before)
		w.clear_noise_fields()
	print("Ошибок гидрологии: %d" % fails)
	quit(1 if fails > 0 else 0)
