extends SceneTree
## Сверка переносов в C# (DOD): старый путь GDScript и новый путь C# на одних и тех же данных в одном процессе,
## побайтно, и время обоих. fields использует синтетические поля; rivers и mesh читают сохранённую
## географическую основу («network_game_cache», слои мира и базовый рельеф).
## Русла рек (rivers) и меш с метровой сеткой (mesh) — пока есть оба пути. Дорожное полотно RoadBed и метровая сетка
## RoadRefinement с 16.11.2026 только на C#: их проверяет tools/road_golden.gd (хеши), здесь они лишь готовят рельеф для mesh.
## Выбор стартовой области и океан с сухими ложбинами (relief) — на настоящем рельефе плана 768 нескольких сидов
## (только этапы relief и ocean, без остальной генерации), --seeds a,b,c — свои сиды.
## Стоимости природных маршрутов (rides, RideRoutes.cost_fields) — на синтетических полях.
##   godot --headless --path . --script res://tools/dod_verify.gd -- [--only fields,relief,rides,rivers,mesh] [--dir <папка кэша>]
## Лимит 240 с (watchdog). Код 1 при любом расхождении.

const SEED := "Север-1234"
var failures := 0
var _only := PackedStringArray()


func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 240)
	run.call_deferred()


func check(ok: bool, message: String) -> void:
	print("PASS " if ok else "FAIL ", message)
	failures += int(not ok)


func wanted(name: String) -> bool:
	return _only.is_empty() or name in _only


func _arg(name: String, fallback: String) -> String:
	var args := OS.get_cmdline_user_args()
	var at := args.find(name)
	return args[at + 1] if at >= 0 and at + 1 < args.size() else fallback


func run() -> void:
	var args := OS.get_cmdline_user_args()
	if "--only" in args:
		_only = _arg("--only", "").split(",")
	if Grid.fast_grid() == null:
		print("FAIL C# (FastGrid) недоступен: сначала dotnet build; сверка C# с самим собой ничего не доказывает")
		quit(1)
		return
	if wanted("fields"):
		verify_fields()
	if wanted("relief"):
		verify_relief()
	if wanted("rides"):
		verify_rides()
	if (wanted("rivers") or wanted("mesh")) and not verify_saved_world():
		quit(1)
		return
	print("DOD RESULT ", failures, " failures")
	quit(1 if failures else 0)


func verify_saved_world() -> bool:
	var cache := WorldCache.new()
	cache.dir = _arg("--dir", "res://tools/control/runs/network_game_cache")
	var size := WorldGenerator.START_SIZE
	var got := cache.read_only(SEED, size)
	if got.has("error"):
		print("НЕТ ФИКСТУРЫ: ", got.error)
		return false
	var w: WorldData = got.world
	var base := preload("res://scripts/game/surface_snapshot.gd").restore(w, cache.load_artifact(SEED, size, "base"), "base")
	if base == null:
		print("НЕТ БАЗОВОГО РЕЛЬЕФА в ", cache.dir)
		return false
	w.base_heights = base
	print("мир ", w.W, "x", w.H, ", путей ", w.trails.size(), ", мостов ", w.bridges.size(), ", туннелей ", w.tunnels.size())
	if wanted("rivers"):
		verify_rivers(w)
	if wanted("mesh"):
		verify_mesh(prepared_for_refinement(base))
	return true


func verify_fields() -> void:
	for size: Vector2i in [Vector2i(1, 1), Vector2i(1, 53), Vector2i(289, 231)]:
		var w := WorldData.new()
		w.W = size.x
		w.H = size.y
		w.N = w.W * w.H
		w.seed_num = 2718
		w.noise.moist = Simplex.new(WorldGenerator.noise_rng(w.seed_num, "moist"))
		w.h.resize(w.N)
		w.ocean.resize(w.N)
		var proposal := StageHydrology.lake_candidate(w.seed_num, w.W, w.H, 0)
		for i in w.N:
			var x := i % w.W
			var y := i / w.W
			w.ocean[i] = int(w.W > 48 and x < 5)
			if w.ocean[i] != 0:
				w.h[i] = -0.05
			elif absi(x - int(proposal.x)) <= 3 and absi(y - int(proposal.y)) <= 3:
				w.h[i] = 0.075
			else:
				w.h[i] = 0.15 + WGRandom.hash2(x, y, w.seed_num) * 0.35
		if w.W == 1:
			w.h[0] = -0.0
		w.noise_field("moist")
		Grid.allow_fast = false
		var position := StageHydrology.position_field(w.h, w.W, w.H).to_byte_array()
		Grid.allow_fast = true
		check(position == StageHydrology.position_field(w.h, w.W, w.H, true).to_byte_array(), "%s: поле положения побайтно" % size)
		for regional: bool in [true, false]:
			StageHydrology.regional = regional
			Grid.allow_fast = false
			StageHydrology.run(w, 2)
			StageGeography.run(w)
			var reference := field_bytes(w)
			Grid.allow_fast = true
			StageHydrology.run(w, 2)
			StageGeography.run(w)
			check(reference == field_bytes(w), "%s: осадки, вода, высоты и уклоны побайтно (regional=%s)" % [size, regional])
			if w.W > 48:
				check(w.lake.count(1) >= StageHydrology.LAKE_MIN, "%s: синтетическая замкнутая котловина заполнилась" % size)
	StageHydrology.regional = true


func field_bytes(w: WorldData) -> Array:
	return [w.filled.to_byte_array(), w.lake, w.rain.to_byte_array(), w.dist_ocean.to_byte_array(),
		w.dist_water.to_byte_array(), w.elev.to_byte_array(), w.slope.to_byte_array()]


## Рельеф с полотном путей (RoadBed) и сооружениями, как перед RoadRefinement.build в finish_paths
func prepared_for_refinement(base: Heightfield) -> Heightfield:
	var h := base.copy()
	h.structures = base.structures
	RoadBed.refine(h)
	h.build_structures()
	return h


## Реки (StageRivers): долины и рельеф с руслами. Любое согласованное состояние мира годится: сверяются два пути
## на одних данных, а не «до» и «после» этапа.
func verify_rivers(w: WorldData) -> void:
	var h0 := w.h.duplicate()
	var f0 := w.filled.duplicate()
	var t := Time.get_ticks_usec()
	StageRivers.allow_fast = false
	StageRivers._shape_valleys(w)
	var slow_ms := (Time.get_ticks_usec() - t) / 1000.0
	var slow_h := w.h.duplicate()
	var slow_f := w.filled.duplicate()
	w.h = h0.duplicate()
	w.filled = f0.duplicate()
	t = Time.get_ticks_usec()
	StageRivers.allow_fast = true
	StageRivers._shape_valleys(w)
	var fast_ms := (Time.get_ticks_usec() - t) / 1000.0
	print("долины рек: GDScript %.0f мс, C# %.0f мс" % [slow_ms, fast_ms])
	check(slow_h.to_byte_array() == w.h.to_byte_array(), "долины рек: h совпадает побайтно")
	check(slow_f.to_byte_array() == w.filled.to_byte_array(), "долины рек: filled совпадает побайтно")
	w.h = h0
	w.filled = f0
	t = Time.get_ticks_usec()
	Heightfield.allow_fast_river_surface = false
	var slow_surface := Heightfield.new(w, false, true)
	slow_surface.complete_water()
	var slow_surface_ms := (Time.get_ticks_usec() - t) / 1000.0
	t = Time.get_ticks_usec()
	Heightfield.allow_fast_river_surface = true
	var fast_surface := Heightfield.new(w, false, true)
	fast_surface.complete_water()
	var fast_surface_ms := (Time.get_ticks_usec() - t) / 1000.0
	print("поверхность рек (рельеф с руслами + вода): GDScript %.0f мс, C# %.0f мс" % [slow_surface_ms, fast_surface_ms])
	print("  GDScript: ", JSON.stringify(slow_surface.path_timings))
	print("  C#:       ", JSON.stringify(fast_surface.path_timings))
	check(slow_surface.hv_raw.to_byte_array() == fast_surface.hv_raw.to_byte_array(), "поверхность рек: hv_raw совпадает побайтно")
	check(slow_surface.hv.to_byte_array() == fast_surface.hv.to_byte_array(), "поверхность рек: hv совпадает побайтно")
	check(var_to_bytes(slow_surface.ribbons) == var_to_bytes(fast_surface.ribbons), "поверхность рек: ленты (с берегами) совпадают побайтно")
	check(slow_surface._seg_pts.to_byte_array() == fast_surface._seg_pts.to_byte_array()
		and slow_surface._pair_cells == fast_surface._pair_cells and slow_surface._pair_segs == fast_surface._pair_segs,
		"поверхность рек: индекс лент совпадает")
	check(slow_surface.water_level.to_byte_array() == fast_surface.water_level.to_byte_array(), "поверхность рек: water_level совпадает побайтно")


## Меш рельефа с метровой сеткой у путей (TerrainBuilder.refine_arrays): общий исходный меш, два пути
func verify_mesh(h: Heightfield) -> void:
	h.road_refinement = null
	var source := TerrainBuilder.build_arrays(h.world, h)
	h.road_refinement = RoadRefinement.build(h)
	var slow := clone_arrays(source)
	var fast := clone_arrays(source)
	var t := Time.get_ticks_usec()
	TerrainBuilder.allow_fast_refine = false
	TerrainBuilder.refine_arrays(slow, h.world, h)
	var slow_ms := (Time.get_ticks_usec() - t) / 1000.0
	t = Time.get_ticks_usec()
	TerrainBuilder.allow_fast_refine = true
	TerrainBuilder.refine_arrays(fast, h.world, h)
	var fast_ms := (Time.get_ticks_usec() - t) / 1000.0
	print("refine_arrays: GDScript %.0f мс, C# %.0f мс, вершин %d" % [slow_ms, fast_ms, slow[Mesh.ARRAY_VERTEX].size()])
	var names := {Mesh.ARRAY_VERTEX: "вершины", Mesh.ARRAY_NORMAL: "нормали", Mesh.ARRAY_TEX_UV: "UV", Mesh.ARRAY_TEX_UV2: "UV2",
		Mesh.ARRAY_COLOR: "цвета", Mesh.ARRAY_INDEX: "индексы"}
	for channel: int in names:
		check(var_to_bytes(slow[channel]) == var_to_bytes(fast[channel]), "меш рельефа: %s совпадают побайтно" % names[channel])


func clone_arrays(source: Array) -> Array:
	var copy := []
	for item: Variant in source:
		copy.append(item.duplicate() if item != null else null)
	return copy


## Выбор старта (StageRelief._pick_start) и океан (StageOcean.run): GDScript и C# на одном рельефе плана, побайтно
func verify_relief() -> void:
	var seeds := _arg("--seeds", "Север-1234,Ущелье,Туман-4821,Янтарь-5150,a1,b2,c3,d4").split(",", false)
	var slow_pick := 0.0
	var fast_pick := 0.0
	var slow_ocean := 0.0
	var fast_ocean := 0.0
	for seed_text: String in seeds:
		var w := WorldData.new()
		w.W = WorldGenerator.PLAN_SIZE
		w.H = w.W
		w.N = w.W * w.H
		w.seed_text = seed_text
		w.seed_num = WGRandom.hash_string(seed_text)
		for name: String in WorldGenerator.NOISE_SLOTS:
			w.noise[name] = Simplex.new(WorldGenerator.noise_rng(w.seed_num, name))
		w.scale = float(w.N) / (512 * 512)
		StageRelief.configure(w)
		var t := Time.get_ticks_usec()
		StageRelief.allow_fast_pick = false
		StageRelief._pick_start(w)
		slow_pick += (Time.get_ticks_usec() - t) / 1000.0
		var slow_xy := Vector2(w.macro_x, w.macro_y)
		w.macro_x = 0
		w.macro_y = 0
		t = Time.get_ticks_usec()
		StageRelief.allow_fast_pick = true
		StageRelief._pick_start(w)
		fast_pick += (Time.get_ticks_usec() - t) / 1000.0
		check(slow_xy == Vector2(w.macro_x, w.macro_y), "%s: старт %s (GDScript %s)" % [seed_text, Vector2(w.macro_x, w.macro_y), slow_xy])
		# Сами высоты оценки, а не только выбранный сдвиг: выбранный и нулевой сдвиг
		var probe := [[0.0, 0, w.macro_x, w.macro_y], [0.0, 1, 0.0, 0.0]]
		check(var_to_bytes(StageRelief._start_raws(w, probe, null)) == var_to_bytes(StageRelief._start_raws(w, probe, Grid.fast_grid())),
			"%s: сырые высоты оценки старта побайтно" % seed_text)
		var h0 := StageRelief.height_rect(w, 0, 0, w.W, w.H, true)
		# Поле рельефа C# (ReliefField, общий с оценкой старта расчёт клетки) против GDScript на куске плана с горами
		var at := _relief_probe(h0, w.W)
		Grid.allow_fast = false
		var slow_rect := StageRelief.height_rect(w, at.x, at.y, 48, 48, true)
		Grid.allow_fast = true
		var fast_rect := StageRelief.height_rect(w, at.x, at.y, 48, 48, true)
		check(slow_rect.to_byte_array() == fast_rect.to_byte_array() and fast_rect == _crop(h0, w.W, at, 48),
			"%s: рельеф 48×48 у %s: C# == GDScript побайтно" % [seed_text, at])
		w.h = h0.duplicate()
		t = Time.get_ticks_usec()
		StageOcean.allow_fast = false
		StageOcean.run(w)
		slow_ocean += (Time.get_ticks_usec() - t) / 1000.0
		var slow_h := w.h.to_byte_array()
		var slow_sea := w.ocean
		var slow_dried: int = w.generation_profile.dried_pocket_cells
		w.h = h0.duplicate()
		t = Time.get_ticks_usec()
		StageOcean.allow_fast = true
		StageOcean.run(w)
		fast_ocean += (Time.get_ticks_usec() - t) / 1000.0
		check(slow_h == w.h.to_byte_array() and slow_sea == w.ocean and slow_dried == w.generation_profile.dried_pocket_cells,
			"%s: океан и высоты побайтно (осушено %d клеток, океан %d)" % [seed_text, slow_dried, slow_sea.count(1)])
	StageRelief.allow_fast_pick = true
	StageOcean.allow_fast = true
	var n := float(seeds.size())
	print("выбор старта: GDScript %.0f мс, C# %.1f мс на сид" % [slow_pick / n, fast_pick / n])
	print("океан: GDScript %.0f мс, C# %.1f мс на сид" % [slow_ocean / n, fast_ocean / n])


## Угол куска 48×48 с самой высокой клеткой плана (горы со слоем склонов), не у края
func _relief_probe(h: PackedFloat32Array, W: int) -> Vector2i:
	var top := 0
	for i in h.size():
		if h[i] > h[top]:
			top = i
	return Vector2i(clampi(top % W - 24, 0, W - 48), clampi(top / W - 24, 0, W - 48))


func _crop(h: PackedFloat32Array, W: int, at: Vector2i, side: int) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	for y in side:
		out.append_array(h.slice((at.y + y) * W + at.x, (at.y + y) * W + at.x + side))
	return out


## Стоимости природных маршрутов (RideRoutes.cost_fields): GDScript и C# на синтетических полях с INF, сетью,
## реками, лесом и равными высотами в блоке (при равенстве остаётся первая клетка), побайтно
func verify_rides() -> void:
	for size: Vector2i in [Vector2i(1, 1), Vector2i(37, 53), Vector2i(301, 247)]:
		var w := WorldData.new()
		w.W = size.x
		w.H = size.y
		w.N = w.W * w.H
		w.seed_num = 4242
		w.cost.resize(w.N)
		w.biome.resize(w.N)
		w.slope.resize(w.N)
		var river := PackedByteArray()
		river.resize(w.N)
		var mask := PackedByteArray()
		mask.resize(w.N)
		var hv := PackedFloat32Array()
		hv.resize(w.N)
		for i in w.N:
			var r := WGRandom.hash2(i % w.W, i / w.W, w.seed_num)
			w.cost[i] = INF if r < 0.05 else 0.3 + r * 9.0
			w.biome[i] = int(r * 997.0) % Biomes.LIST.size()
			w.slope[i] = fmod(r * 13.0, 0.3)
			mask[i] = int(r * 57.0) % 4
			hv[i] = floorf(r * 8.0) * 5.0 # много равных высот
			river[i] = int(fmod(r * 31.0, 1.0) < 0.1)
		w.river = river
		var net := RideRoutes._net_mask(mask)
		check(net == Grid.fast_grid().BytesAtLeast(mask, 2), "%s: маска сети побайтно" % size)
		var dist := Grid.distance_field(w.W, w.H, net)
		var slow := RideRoutes.cost_fields(w, hv, net, dist, null)
		var fast := RideRoutes.cost_fields(w, hv, net, dist, Grid.fast_grid())
		check(slow.cost.to_byte_array() == PackedFloat32Array(fast.cost).to_byte_array()
			and slow.wood.to_byte_array() == PackedFloat32Array(fast.wood).to_byte_array()
			and slow.block == PackedInt32Array(fast.block), "%s: стоимости маршрутов и вершины блоков побайтно" % size)
