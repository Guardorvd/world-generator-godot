extends SceneTree
## Регрессия недоступных островов и проверка оптимизаций 5.3+.
## -- --worlds проверяет проблемный большой мир и несколько других сидов.

const SelfTest := preload("res://tools/selftest.gd")
var fails := 0


func _check(ok: bool, label: String) -> void:
	print(("✓ " if ok else "✗ ") + label)
	if not ok: fails += 1


func _regions() -> void:
	const W := 160
	const H := 32
	var wet := PackedByteArray()
	wet.resize(W * H)
	var all_land := Grid.bridge_region(W, H, wet, StageTrails.SPAN)
	_check(all_land.count(1) == W * H, "сплошная суша полностью доступна")
	wet.fill(1)
	_check(Grid.bridge_region(W, H, wet, StageTrails.SPAN).count(1) == 0, "чистый океан не создаёт область поселений")
	for y in H:
		for x in range(0, 60): wet[y * W + x] = 0
		for x in range(135, W): wet[y * W + x] = 0
	var separate := Grid.bridge_region(W, H, wet, StageTrails.SPAN)
	_check(separate[16 * W + 20] == 1 and separate[16 * W + 150] == 0,
		"остров за проливом шире любого моста исключается")
	# Промежуточный остров позволяет цепочку коротких переправ.
	for y in H:
		for x in range(95, 105): wet[y * W + x] = 0
	var chain := Grid.bridge_region(W, H, wet, StageTrails.SPAN)
	_check(chain[16 * W + 150] == 1, "цепочка доступных островов сохраняется")
	_check(Grid.bridge_region(0, 0, PackedByteArray(), StageTrails.SPAN).is_empty(), "пустая сетка безопасна")


func _nearest_water() -> void:
	var fast := Grid.fast_grid()
	if fast == null:
		_check(false, "для проверки C# требуется собранный модуль")
		return
	const W := 17
	const H := 11
	var cost := PackedFloat32Array()
	var water := PackedFloat32Array()
	cost.resize(W * H)
	water.resize(W * H)
	for i in W * H:
		cost[i] = INF if i % 7 == 0 else 1.0
		water[i] = float(i % 5) * 0.5
	var same := true
	for sy in H:
		for sx in W:
			for radius in [1, 4, 40]:
				var best := -1
				var distance := INF
				for y in range(maxi(0, sy - radius), mini(H, sy + radius)):
					for x in range(maxi(0, sx - radius), mini(W, sx + radius)):
						var i := y * W + x
						if cost[i] == INF or water[i] > 1.5: continue
						var d := (x - sx) * (x - sx) + (y - sy) * (y - sy)
						if d < distance:
							distance = d
							best = i
				same = same and best == fast.FindNearestWater(cost, water, W, H, sx, sy, radius)
	_check(same, "FindNearestWater совпадает с прежним циклом: границы, равные расстояния, запретные клетки")


func _settlements() -> void:
	var w := WorldData.new()
	w.W = 160
	w.H = 96
	w.N = w.W * w.H
	w.scale = float(w.N) / (512 * 512)
	w.rng = WGRandom.new(53)
	w.biome.resize(w.N)
	w.biome.fill(Biomes.OCEAN)
	w.ocean.resize(w.N)
	w.ocean.fill(1)
	w.lake.resize(w.N)
	w.river.resize(w.N)
	w.slope.resize(w.N)
	w.acc.resize(w.N)
	w.dist_water.resize(w.N)
	w.dist_water.fill(2.0)
	for y in w.H:
		for x in w.W:
			if x < 60 or x >= 135:
				var i := y * w.W + x
				w.biome[i] = Biomes.GRASS
				w.ocean[i] = 0
				# Недоступный остров привлекательнее всех кандидатов на материке.
				w.slope[i] = 0.59 if x < 60 else 0.0
	StageLandmarks._place_settlements(w)
	var mainland := true
	for s in w.settlements: mainland = mainland and s.x < 60.0
	_check(w.settlements.size() == 4 and mainland,
		"недоступный привлекательный остров заменяется кандидатами на материке, число поселений сохраняется")


func _init() -> void:
	_regions()
	_settlements()
	_nearest_water()
	if OS.get_cmdline_user_args().has("--worlds"):
		Pathfinder.profile_searches = true
		for c in [["Заря-4787", 768], ["Север-1234", 768], ["Туман-4821", 768], ["Янтарь-5150", 512]]:
			var start := Time.get_ticks_msec()
			var w := WorldGenerator.generate(c[0], c[1])
			_check(SelfTest.settlements_connected(w), "%s@%d: все %d поселений связаны" % [c[0], c[1], w.settlements.size()])
			print("PROFILE ", JSON.stringify({seed = c[0], size = c[1], ms = Time.get_ticks_msec() - start, roads = w.generation_profile}))
	print("Регрессия генерации: ошибок %d" % fails)
	quit(1 if fails else 0)
