extends SceneTree
## Быстрый замер формы гор без генерации мира: только StageRelief на трёх сидах (768×768).
## Показывает, что видит обзорная сетка 32 м: доли склонов, седловины и длину непрерывных спусков.
## Запуск: godot --headless --path . --script res://tools/mountain_shape_probe.gd [-- --out файл.json]
## Для «было/стало» сохраняется JSON; старый файл подставляется через --base.
const STEP := 8 # клеток обзора: 8 × 4 м = 32 м
const SEEDS := ["Север-1234", "Ущелье", "Туман-4821"]


func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 90)
	var args := OS.get_cmdline_user_args()
	var rows := {}
	for seed_text: String in SEEDS:
		var w := WorldData.new()
		w.W = 768; w.H = 768; w.N = 768 * 768
		w.seed_text = seed_text
		w.seed_num = WGRandom.hash_string(seed_text)
		for key: String in WorldGenerator.NOISE_SLOTS:
			w.noise[key] = Simplex.new(WorldGenerator.noise_rng(w.seed_num, key))
		var t := Time.get_ticks_msec()
		StageRelief.run(w)
		var ms := Time.get_ticks_msec() - t
		var row := measure(w)
		row["relief_ms"] = ms
		rows[seed_text] = row
		print(seed_text, " ", JSON.stringify(row))
	var base_i := args.find("--base")
	if base_i >= 0 and base_i + 1 < args.size():
		var base: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(args[base_i + 1]))
		for s: String in SEEDS:
			var line := s + " было→стало:"
			for k: String in rows[s]:
				if k == "relief_ms":
					continue
				line += " %s %s→%s;" % [k, str(base[s].get(k, "?")), str(rows[s][k])]
			print(line)
	var out_i := args.find("--out")
	if out_i >= 0 and out_i + 1 < args.size():
		var f := FileAccess.open(args[out_i + 1], FileAccess.WRITE)
		f.store_string(JSON.stringify(rows))
	quit(0)


func measure(w: WorldData) -> Dictionary:
	var n := w.W
	var m := n / STEP
	var hs := PackedFloat32Array()
	hs.resize(m * m)
	for y in m:
		for x in m:
			hs[y * m + x] = w.h[(y * STEP + STEP / 2) * n + x * STEP + STEP / 2] * GameConfig.HS
	var span := STEP * GameConfig.TILE
	var mount := 0
	var flat := 0
	var ride := 0
	var steep := 0
	var saddles := 0
	var peaks := []
	for y in range(1, m - 1):
		for x in range(1, m - 1):
			var i := y * m + x
			if hs[i] < 0.2 * GameConfig.HS:
				continue
			mount += 1
			var g := Vector2(hs[i + 1] - hs[i - 1], hs[i + m] - hs[i - m]).length() / (2.0 * span)
			if g < 0.06: flat += 1
			elif g <= 0.20: ride += 1
			elif g > 0.45: steep += 1
			# Седловина: кольцо из 8 соседей меняет знак (выше/ниже) ровно четыре раза
			var ring := [hs[i - m - 1], hs[i - m], hs[i - m + 1], hs[i + 1], hs[i + m + 1], hs[i + m], hs[i + m - 1], hs[i - 1]]
			var changes := 0
			for k in 8:
				if (ring[k] > hs[i]) != (ring[(k + 1) % 8] > hs[i]):
					changes += 1
			if changes == 4:
				saddles += 1
			var top := true
			for v: float in ring:
				if v >= hs[i]:
					top = false
					break
			if top and hs[i] > 0.3 * GameConfig.HS:
				peaks.append(i)
	# Непрерывный спуск от вершины по самому крутому соседу, пока шаг не круче 25%: так видна протяжённость
	var runs := []
	for p: int in peaks:
		var i: int = p
		var length := 0.0
		for _s in 200:
			var x := i % m
			var y := i / m
			if x < 1 or y < 1 or x >= m - 1 or y >= m - 1:
				break
			var best := -1
			var best_g := 0.0
			for d: Vector2i in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1), Vector2i(1, 1), Vector2i(-1, -1), Vector2i(1, -1), Vector2i(-1, 1)]:
				var j: int = (y + d.y) * m + x + d.x
				var gr: float = (hs[i] - hs[j]) / (span * Vector2(d).length())
				# самый крутой из допустимых шагов: 4–25%
				if gr >= 0.04 and gr <= 0.25 and gr > best_g:
					best = j
					best_g = gr
			if best < 0:
				break
			var dd := Vector2i(best % m - x, best / m - y)
			var step_len := span * Vector2(dd).length()
			length += step_len
			i = best
		runs.append(length)
	runs.sort()
	var long_runs := 0
	for r: float in runs:
		long_runs += int(r >= 400.0)
	return {
		peaks = peaks.size(), saddles = saddles,
		flat_pct = snappedf(100.0 * flat / maxi(mount, 1), 0.1),
		ride_pct = snappedf(100.0 * ride / maxi(mount, 1), 0.1),
		steep_pct = snappedf(100.0 * steep / maxi(mount, 1), 0.1),
		descents_400m = long_runs,
		descent_p75_m = runs[int(runs.size() * 0.75)] if runs.size() > 0 else 0.0,
	}
