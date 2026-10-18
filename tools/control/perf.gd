extends SceneTree
## Замер производительности для каждого размера мира из tools/control/seeds.json (perf): время загрузки
## (от «Начать» до готового мира), FPS и память. Каждый размер меряется в отдельном процессе с окном 1280×720,
## без вертикальной синхронизации: сначала камера осматривается на месте появления (look_s секунд), потом
## летит на высоте глаз вдоль самой длинной дороги со скоростью велосипеда (road_s секунд), растительность
## подгружается, как в игре. Итог — perf.json и таблица в консоли. Запуск из папки проекта:
##   godot --headless --path . --script res://tools/control/perf.gd -- [--out <папка>]
## Один размер (так скрипт запускает сам себя для каждого размера; нужно окно):
##   godot --path . --script res://tools/control/perf.gd -- --size 512 [--out <папка>]

const Dev := preload("res://tools/control/control.gd")
const LOAD_TIMEOUT_MS := 300000
const WARMUP_S := 1.5   # первые кадры компилируют шейдеры, их не считаем
const ROAD_SPEED := 11.0

var main: Node
var out := ""
var cfg: Dictionary
var size := 0
var phase := "menu"
var frames := 0
var started := 0
var t := 0.0
var last_us := 0
var yaw0 := 0.0
var spawn := Vector3.ZERO
var road: PackedVector3Array = []
var road_len: PackedFloat32Array = []
var look_ms := PackedFloat32Array()   # время кадров осмотра, мс
var road_ms := PackedFloat32Array()   # время кадров пролёта по дороге, мс
var draw_calls := 0.0
var primitives := 0.0
var counted := 0
var result := {}
var done := false


func _initialize() -> void:
	out = Dev.out_dir()
	cfg = Dev.seeds().perf
	size = int(Dev.arg("size", "0"))
	if size == 0:
		_run_all()
		return
	main = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)


## Запускает себя для каждого размера по очереди и собирает итог
func _run_all() -> void:
	var all := {version = Dev.version(), seed = cfg.seed, sizes = {}}
	for s in cfg.sizes:
		print("Размер %d…" % s)
		var log := []
		var code := OS.execute(OS.get_executable_path(), ["--path", ProjectSettings.globalize_path("res://"),
			"--script", "res://tools/control/perf.gd", "--", "--size", str(s), "--out", out], log, true)
		var part: Variant = Dev.load_json(out.path_join("perf_%d.json" % s))
		if code != 0 or part == null:
			printerr("Замер размера %d не удался (код %d):\n%s" % [s, code, "".join(log)])
			continue
		all.machine = part.machine
		all.sizes[str(int(s))] = part.result
		DirAccess.remove_absolute(out.path_join("perf_%d.json" % s))
	Dev.save_json(out.path_join("perf.json"), all)
	print_table(all)
	print("Итог: ", out.path_join("perf.json"))
	done = true
	quit(0 if all.sizes.size() == cfg.sizes.size() else 1)


static func print_table(all: Dictionary) -> void:
	print("Версия %s, мир %s, %s" % [all.version, all.seed, all.get("machine", {}).get("gpu", "")])
	print("  %-6s %9s %8s %9s %8s %9s %9s %9s" % ["Размер", "Загрузка", "FPS", "1% худш.", "FPS", "1% худш.", "Память", "Видео"])
	print("  %-6s %9s %8s %9s %8s %9s %9s %9s" % ["", "с", "осмотр", "осмотр", "дорога", "дорога", "МБ", "МБ"])
	for s in all.sizes:
		var r: Dictionary = all.sizes[s]
		print("  %-6s %9.1f %8.0f %9.0f %8.0f %9.0f %9.0f %9.0f" % [s, r.load_s, r.look.fps, r.look.low1, r.road.fps, r.road.low1,
			r.memory.rss_mb, r.memory.video_mb])


func _ready_road(game: GameWorld) -> void:
	var w := game.world
	var best: Array = []
	var best_n := 0.0
	for tr in w.trails:
		if tr.kind == "road" and Dev._length(tr.pts) > best_n:
			best_n = Dev._length(tr.pts)
			best = tr.pts
	if best.size() < 2:
		# дорог нет: летим на север от точки появления
		best = [{x = spawn.x / Dev.TILE, y = spawn.z / Dev.TILE}, {x = spawn.x / Dev.TILE, y = spawn.z / Dev.TILE - 200.0}]
	var acc := 0.0
	for k in best.size():
		var p := Vector3((best[k].x + 0.5) * Dev.TILE, 0.0, (best[k].y + 0.5) * Dev.TILE)
		if k > 0:
			acc += Vector2(p.x - road[k - 1].x, p.z - road[k - 1].z).length()
		road.append(p)
		road_len.append(acc)


## Точка дороги в s метрах от начала (по кругу туда и обратно, если дорога короче пролёта)
func _road_at(s: float) -> Vector3:
	var total := road_len[road_len.size() - 1]
	s = fmod(s, 2.0 * total)
	if s > total:
		s = 2.0 * total - s
	var k := 1
	while k < road_len.size() - 1 and road_len[k] < s:
		k += 1
	var seg := maxf(0.001, road_len[k] - road_len[k - 1])
	return road[k - 1].lerp(road[k], clampf((s - road_len[k - 1]) / seg, 0.0, 1.0))


static func _frame_stats(ms: PackedFloat32Array) -> Dictionary:
	if ms.is_empty():
		return {fps = 0, low1 = 0, max_ms = 0, frames = 0}
	var sum := 0.0
	for v in ms:
		sum += v
	var sorted := ms.duplicate()
	sorted.sort()
	var p99 := sorted[mini(sorted.size() - 1, int(sorted.size() * 0.99))]
	return {fps = snappedf(1000.0 * ms.size() / sum, 0.1), low1 = snappedf(1000.0 / p99, 0.1),
		max_ms = snappedf(sorted[sorted.size() - 1], 0.1), frames = ms.size()}


static func _mb(bytes: float) -> float:
	return snappedf(bytes / 1048576.0, 0.1)


func _memory() -> Dictionary:
	var pm := Dev.process_memory()
	return {
		rss_mb = _mb(pm.rss), peak_rss_mb = _mb(pm.peak),
		static_mb = _mb(Performance.get_monitor(Performance.MEMORY_STATIC)),
		video_mb = _mb(Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED)),
		texture_mb = _mb(Performance.get_monitor(Performance.RENDER_TEXTURE_MEM_USED)),
		buffer_mb = _mb(Performance.get_monitor(Performance.RENDER_BUFFER_MEM_USED)),
		objects = int(Performance.get_monitor(Performance.OBJECT_COUNT)),
		nodes = int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT)),
	}


func _finish(ok: bool) -> bool:
	done = true
	if ok:
		result.look = _frame_stats(look_ms)
		result.road = _frame_stats(road_ms)
		result.draw_calls = roundi(draw_calls / maxi(1, counted))
		result.primitives = roundi(primitives / maxi(1, counted))
		result.memory = _memory()
		var machine := {gpu = RenderingServer.get_video_adapter_name(), cpu = OS.get_processor_name(),
			threads = OS.get_processor_count(), os = OS.get_name(), dotnet = Grid.fast_grid() != null}
		Dev.save_json(out.path_join("perf_%d.json" % size), {machine = machine, result = result})
		print("Размер %d: загрузка %.1f с, FPS %.0f / %.0f" % [size, result.load_s, result.look.fps, result.road.fps])
	quit(0 if ok else 1)
	return false


func _process(delta: float) -> bool:
	if done or size == 0:
		return false
	frames += 1
	var game: GameWorld = main.game
	match phase:
		"menu":
			if frames == 1:
				DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
				DisplayServer.window_set_size(Vector2i(1280, 720))
				DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
				Engine.max_fps = 0
			if frames == 30:
				result.menu_memory = _memory()
				started = Time.get_ticks_msec()
				main.start_game(cfg.seed, size)
				phase = "loading"
		"loading":
			if game == null or game.player == null:
				if Time.get_ticks_msec() - started > LOAD_TIMEOUT_MS:
					printerr("Мир не загрузился за %d с" % (LOAD_TIMEOUT_MS / 1000))
					return _finish(false)
				return false
			result.load_s = snappedf((Time.get_ticks_msec() - started) / 1000.0, 0.01)
			game.paused = true
			main.hud.visible = false
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
			game.camera.fov = 70.0
			spawn = game.camera.global_position
			yaw0 = game.yaw
			_ready_road(game)
			result.loaded_memory = _memory()
			phase = "warmup"
			t = 0.0
		"warmup", "look":
			t += delta
			game.camera.rotation = Vector3(-0.05, yaw0 + TAU * t / float(cfg.look_s), 0.0)
			game.camera.position = spawn
			if phase == "warmup" and t >= WARMUP_S:
				phase = "look"
				t = 0.0
				last_us = Time.get_ticks_usec()
			elif phase == "look":
				_count("look")
				if t >= float(cfg.look_s):
					phase = "road"
					t = 0.0
		"road":
			t += delta
			var p := _road_at(t * ROAD_SPEED)
			var ahead := _road_at(t * ROAD_SPEED + 15.0)
			# на настиле моста, над водой брода, на полу туннеля
			var hf := game.heights
			p.y = maxf(hf.surface_at(p.x, p.z, INF), hf.ground_at(p.x, p.z) + hf.depth_at(p.x, p.z)) + GameConfig.EYE
			ahead.y = game.heights.ground_at(ahead.x, ahead.z) + GameConfig.EYE
			if p.distance_to(ahead) > 0.5:
				game.camera.look_at_from_position(p, ahead, Vector3.UP)
			game.vegetation.update(p.x, p.z, false)
			_count("road")
			if t >= float(cfg.road_s):
				return _finish(true)
	return false


## Время кадра (по часам, а не delta: delta сглаживается движком) и число вызовов отрисовки
func _count(key: String) -> void:
	var now := Time.get_ticks_usec()
	if key == "look":
		look_ms.append((now - last_us) / 1000.0)
	else:
		road_ms.append((now - last_us) / 1000.0)
	last_us = now
	draw_calls += Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)
	primitives += Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME)
	counted += 1
