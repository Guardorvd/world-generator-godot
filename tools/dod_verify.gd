extends SceneTree
## Сверка переносов в C# (DOD): старый путь GDScript и новый путь C# на одних и тех же данных в одном процессе,
## побайтно, и время обоих. Мир не генерируется: берётся готовая сохранённая географическая основа
## («network_game_cache», слои мира и базовый рельеф), если её нет — тест выходит с пояснением.
##   godot --headless --path . --script res://tools/dod_verify.gd -- [--only bed,refine] [--dir <папка кэша>]
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
	var cache := WorldCache.new()
	cache.dir = _arg("--dir", "res://tools/control/runs/network_game_cache")
	var size := WorldGenerator.START_SIZE
	var got := cache.read_only(SEED, size)
	if got.has("error"):
		print("НЕТ ФИКСТУРЫ: ", got.error)
		quit(1)
		return
	var w: WorldData = got.world
	var base := preload("res://scripts/game/surface_snapshot.gd").restore(w, cache.load_artifact(SEED, size, "base"), "base")
	if base == null:
		print("НЕТ БАЗОВОГО РЕЛЬЕФА в ", cache.dir)
		quit(1)
		return
	w.base_heights = base
	print("мир ", w.W, "x", w.H, ", путей ", w.trails.size(), ", мостов ", w.bridges.size(), ", туннелей ", w.tunnels.size())
	if wanted("bed"):
		verify_bed(base)
	if wanted("rivers"):
		verify_rivers(w)
	var refine_base: Heightfield = null
	if wanted("refine") or wanted("mesh"):
		refine_base = prepared_for_refinement(base)
	if wanted("refine"):
		verify_refinement(refine_base)
	if wanted("mesh"):
		verify_mesh(refine_base)
	print("DOD RESULT ", failures, " failures")
	quit(1 if failures else 0)


## Рельеф с полотном путей (RoadBed) и сооружениями, как перед RoadRefinement.build в finish_paths
func prepared_for_refinement(base: Heightfield) -> Heightfield:
	var h := base.copy()
	h.structures = base.structures
	RoadBed.allow_fast = false
	RoadBed.refine(h)
	RoadBed.allow_fast = true
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


func verify_bed(base: Heightfield) -> void:
	var slow := base.copy()
	var fast := base.copy()
	var t := Time.get_ticks_usec()
	RoadBed.allow_fast = false
	var slow_changed := RoadBed.refine(slow)
	var slow_ms := (Time.get_ticks_usec() - t) / 1000.0
	t = Time.get_ticks_usec()
	RoadBed.allow_fast = true
	var fast_changed := RoadBed.refine(fast)
	var fast_ms := (Time.get_ticks_usec() - t) / 1000.0
	print("RoadBed.refine: GDScript %.0f мс, C# %.0f мс, изменено клеток %d" % [slow_ms, fast_ms, slow_changed.size()])
	check(slow_changed == fast_changed, "RoadBed: списки изменённых клеток равны")
	check(slow.hv.to_byte_array() == fast.hv.to_byte_array(), "RoadBed: рельеф hv совпадает побайтно")


func verify_refinement(h: Heightfield) -> void:
	var slow := time_build(h, false)
	var fast := time_build(h, true)
	print("RoadRefinement.build: GDScript %.0f мс, C# %.0f мс, патчей %d" % [slow.ms, fast.ms, slow.r.patches.size()])
	print("  GDScript: ", JSON.stringify(slow.r.build_timings))
	print("  C#:       ", JSON.stringify(fast.r.build_timings))
	var a: RoadRefinement = slow.r
	var b: RoadRefinement = fast.r
	check(a.patches.keys() == b.patches.keys(), "RoadRefinement: те же патчи в том же порядке")
	var same := var_to_bytes(a.patches) == var_to_bytes(b.patches)
	check(same, "RoadRefinement: патчи совпадают побайтно")
	if not same:
		report_patch_diff(a.patches, b.patches)
	check(var_to_bytes(a.fit_routes) == var_to_bytes(b.fit_routes), "RoadRefinement: подгонка профиля совпадает побайтно")


## Где именно патчи разошлись: по каналам число различных клеток и первые три примера
func report_patch_diff(a: Dictionary, b: Dictionary) -> void:
	var diffs := {}
	var samples := {}
	for key: int in a:
		if not b.has(key):
			print("  нет патча ", key)
			continue
		for channel: String in ["h", "color", "uv", "surface", "road"]:
			var pa = a[key][channel]
			var pb = b[key][channel]
			if var_to_bytes(pa) == var_to_bytes(pb):
				continue
			diffs[channel] = diffs.get(channel, 0) + 1
			if not samples.has(channel): samples[channel] = []
			if samples[channel].size() < 3:
				for i in pa.size():
					if var_to_bytes(pa[i]) != var_to_bytes(pb[i]):
						samples[channel].append("клетка %d (x %d, z %d) вершина %d: было %s стало %s" % [key, key % 768, key / 768, i, str(pa[i]), str(pb[i])])
						break
	print("  расхождения по каналам: ", diffs)
	var k0: int = a.keys()[0]
	print("  первый патч: ключ ", typeof(k0), "/", typeof(b.keys()[0]), ", поля ", a[k0].keys(), " / ", b[k0].keys(),
		", типы ", typeof(a[k0].h), typeof(b[k0].h), typeof(a[k0].color), typeof(b[k0].color), typeof(a[k0].uv), typeof(b[k0].uv),
		typeof(a[k0].surface), typeof(b[k0].surface), typeof(a[k0].road), typeof(b[k0].road))
	print("  словарь патча равен: ", var_to_bytes(a[k0]) == var_to_bytes(b[k0]), ", размеры ", var_to_bytes(a[k0]).size(), "/", var_to_bytes(b[k0]).size())
	for channel: String in samples:
		for line: String in samples[channel]:
			print("  ", channel, ": ", line)


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


func time_build(h: Heightfield, fast: bool) -> Dictionary:
	RoadRefinement.allow_fast_index = fast
	RoadRefinement.allow_fast_patches = fast
	var t := Time.get_ticks_usec()
	var r := RoadRefinement.build(h)
	return {r = r, ms = (Time.get_ticks_usec() - t) / 1000.0}
