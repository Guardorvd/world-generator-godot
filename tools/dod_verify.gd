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
	var refine_base: Heightfield = null
	if wanted("refine") or wanted("fit"):
		refine_base = prepared_for_refinement(base)
	if wanted("refine"):
		verify_refinement(refine_base)
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
	check(var_to_bytes(a.patches) == var_to_bytes(b.patches), "RoadRefinement: патчи совпадают побайтно")
	check(var_to_bytes(a.fit_routes) == var_to_bytes(b.fit_routes), "RoadRefinement: подгонка профиля совпадает побайтно")


func time_build(h: Heightfield, fast: bool) -> Dictionary:
	RoadRefinement.allow_fast_index = fast
	RoadRefinement.allow_fast_patches = fast
	var t := Time.get_ticks_usec()
	var r := RoadRefinement.build(h)
	return {r = r, ms = (Time.get_ticks_usec() - t) / 1000.0}
