extends SceneTree
## Единая проверка (8.0): мир генерируется один раз, и в нём же снимаются виды и меряется FPS, потом
## прогон сравнивается с прошлой версией. Заменяет связку shots.gd → perf.gd → compare.gd, где каждый шаг
## заново генерировал мир. Нужно окно (не headless). Запуск из папки проекта:
##   godot --path . --script res://tools/control/check.gd -- [ключи]
## Быстрая (по умолчанию): один мир (Север-1234@512), все виды, FPS. Ключи:
##   --world <сид> --size <N>     другой мир
##   --views all|none|spawn,road  что снимать: spawn, peak, valley, road, settlement, map (all — всё)
##   --fps on|off                 мерить ли FPS (по умолчанию on)
##   --hours 7.5,19.1             снять виды ещё и в эти часы (по умолчанию только полдень, 12)
##   --look S --road S            длительность осмотра и пролёта, с (по умолчанию из seeds.json)
## Глубокая: godot --headless --path . --script res://tools/control/check.gd -- --deep — все миры из seeds.json (виды) и все размеры замера (FPS), по процессу на мир;
##   Север-1234@512 снимается и меряется за одну генерацию.
## Общие: --out <папка> (по умолчанию runs/<версия>), --base <папка> (по умолчанию прошлая версия в runs),
##   --again (снять заново, даже если этот коммит уже снят), --shadows on|off, --scale 0.25..1.
## Кэш: в папке прогона лежит check.json; если тот же коммит без правок уже снят с теми же видами и FPS,
## мир не генерируется повторно. Поэтому «было» снимается один раз до правок и дальше берётся из кэша.

const Dev := preload("res://tools/control/control.gd")
const Perf := preload("res://tools/control/perf.gd")
const ALL_VIEWS := ["map", "spawn", "peak", "valley", "road", "settlement"]
const NOON := 12.0
const SETTLE_FRAMES := 12   # кадров после переноса камеры до снимка
const WARMUP_S := 1.5       # первые кадры компилируют шейдеры, их не считаем
const ROAD_SPEED := GameConfig.BIKE_SPEED

var main: Node
var out := ""
var cfg: Dictionary
var seed_text := ""
var size := 0
var want_views: Array = []
var want_fps := true
var hours: Array = []      # [час, суффикс имени]
var look_s := 8.0
var road_s := 10.0
var t_start := 0
var timing := {}           # секунды по этапам
var load_ms := {}          # из чего сложилась загрузка: WorldLoader.timings и шаги GameWorld.start, мс

var phase := "menu"
var frames := 0
var started := 0
var wait := 0
var shots: Array = []      # {name, pos, target, hour, suffix}
var shot := 0
var spawn := Transform3D()
var t := 0.0
var last_us := 0
var yaw0 := 0.0
var road: PackedVector3Array = []
var road_len: PackedFloat32Array = []
var look_ms := PackedFloat32Array()
var road_ms := PackedFloat32Array()
var draw_calls := 0.0
var primitives := 0.0
var counted := 0
var result := {}
var failed := false
var done := false


func _initialize() -> void:
	t_start = Time.get_ticks_msec()
	out = Dev.out_dir()
	cfg = Dev.seeds().perf
	look_s = float(Dev.arg("look", str(cfg.look_s)))
	road_s = float(Dev.arg("road", str(cfg.road_s)))
	if "--deep" in OS.get_cmdline_user_args():
		_run_deep()
		return
	seed_text = Dev.arg("world", cfg.seed)
	size = int(Dev.arg("size", "512"))
	var v := Dev.arg("views", "all")
	want_views = ALL_VIEWS.duplicate() if v == "all" else ([] if v == "none" else Array(v.split(",", false)))
	want_fps = Dev.arg("fps", "on") != "off"
	hours = [[NOON, ""]]
	for h in Dev.arg("hours", "").split(",", false):
		hours.append([float(h), "_h" + h])
	if _cached(Dev.world_id(seed_text, size), want_views, want_fps):
		print("%s уже снят на этом коммите (--again — снять заново)" % Dev.world_id(seed_text, size))
		_after_run()
		return
	main = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)


# --- Кэш: check.json в папке прогона ---

## Коммит, если в отслеживаемых файлах нет правок; иначе пусто (такой прогон не кэшируется)
static func _clean_commit() -> String:
	var o := []
	var dir := ProjectSettings.globalize_path("res://")
	if OS.execute("git", ["-C", dir, "status", "--porcelain", "--untracked-files=no"], o) != 0 or str(o[0]).strip_edges() != "":
		return ""
	o.clear()
	OS.execute("git", ["-C", dir, "rev-parse", "HEAD"], o)
	return str(o[0]).strip_edges() if o.size() > 0 else ""


func _cached(id: String, views: Array, fps: bool) -> bool:
	if "--again" in OS.get_cmdline_user_args():
		return false
	var c: Variant = Dev.load_json(out.path_join("check.json"))
	var commit := _clean_commit()
	if c == null or commit == "" or not c.get("worlds", {}).has(id):
		return false
	var e: Dictionary = c.worlds[id]
	if e.get("commit", "") != commit or (fps and not e.get("fps", false)):
		return false
	for name in views:
		if not name in e.get("views", []):
			return false
	return Array(e.get("hours", [])) == hours.map(func(h): return h[0])


func _remember(id: String) -> void:
	var path := out.path_join("check.json")
	var c: Variant = Dev.load_json(path)
	if c == null:
		c = {version = Dev.version(), worlds = {}}
	var views: Array = []
	for s in shots:
		if not s.name in views:
			views.append(s.name)
	if "map" in want_views:
		views.append("map")
	c.worlds[id] = {commit = _clean_commit(), views = views, fps = want_fps, hours = hours.map(func(h): return h[0]),
		seconds = timing, load_ms = load_ms}
	Dev.save_json(path, c)


# --- Глубокая: по процессу на мир ---

func _run_deep() -> void:
	if DisplayServer.get_name() != "headless":
		print("Глубокую проверку запускайте с --headless: окна откроют сами миры")
	var views: Dictionary = {}   # id -> [сид, размер, виды, fps]
	for w in Dev.seeds().views:
		views[Dev.world_id(w[0], int(w[1]))] = [w[0], int(w[1]), "all", "off"]
	for s in cfg.sizes:
		var id := Dev.world_id(cfg.seed, int(s))
		if views.has(id):
			views[id][3] = "on"
		else:
			views[id] = [cfg.seed, int(s), "none", "on"]
	var pass_args: PackedStringArray = ["--out", out, "--look", str(look_s), "--road", str(road_s),
		"--shadows", Dev.arg("shadows", "on"), "--scale", Dev.arg("scale", "1"), "--child", "1"]
	if Dev.arg("hours") != "":
		pass_args.append_array(["--hours", Dev.arg("hours")])
	if "--again" in OS.get_cmdline_user_args():
		pass_args.append("--again")
	for id in views:
		var w: Array = views[id]
		print("Мир %s: виды %s, FPS %s" % [id, w[2], w[3]])
		var log := []
		var args: PackedStringArray = ["--path", ProjectSettings.globalize_path("res://"), "--script",
			"res://tools/control/check.gd", "--", "--world", w[0], "--size", str(w[1]), "--views", w[2], "--fps", w[3]]
		var code := OS.execute(OS.get_executable_path(), args + pass_args, log, true)
		if code != 0:
			failed = true
			printerr("Мир %s не проверен (код %d):\n%s" % [id, code, "".join(log)])
	_after_run()


# --- После прогона: время и сравнение с прошлой версией ---

func _after_run() -> void:
	done = true
	if Dev.arg("child") != "":
		quit(1 if failed else 0)
		return
	var base := Dev.abs_dir(Dev.arg("base", _prev_run()))
	var total := (Time.get_ticks_msec() - t_start) / 1000.0
	if base == "" or not DirAccess.dir_exists_absolute(base):
		print("Базы для сравнения нет: прошлая версия в runs не снята. Прогон: %s, %.0f с" % [out, total])
		quit(1 if failed else 0)
		return
	var log := []
	OS.execute(OS.get_executable_path(), ["--headless", "--path", ProjectSettings.globalize_path("res://"), "--script",
		"res://tools/control/compare.gd", "--", "--base", base, "--new", out], log, true)
	print("".join(log))
	print("Проверка заняла %.0f с (с запуском сравнения). Прогон: %s" % [total, out])
	quit(1 if failed else 0)


## Самая свежая папка runs/<версия> младше текущей версии, в которой есть check.json
static func _prev_run() -> String:
	var runs := ProjectSettings.globalize_path(Dev.RUNS)
	var cur := Dev.version()
	var best := ""
	var re := RegEx.create_from_string("^\\d+(\\.\\d+)*$")
	for d in DirAccess.get_directories_at(runs):
		if re.search(d) == null or not Dev._version_less(d, cur) or not FileAccess.file_exists(runs.path_join(d).path_join("check.json")):
			continue
		if best == "" or Dev._version_less(best, d):
			best = d
	return runs.path_join(best) if best != "" else ""


# --- Один мир ---

func _process(delta: float) -> bool:
	if done or main == null:
		return false
	frames += 1
	var game: GameWorld = main.game
	match phase:
		"menu":
			if frames == 1:
				DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
				DisplayServer.window_set_size(Dev.WINDOW_SIZE)
				DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
				Engine.max_fps = 0
				GameSettings.shadows = Dev.arg("shadows", "on") != "off"
				root.scaling_3d_scale = clampf(float(Dev.arg("scale", "1")), 0.25, 1.0)
				result.render = {method = RenderingServer.get_current_rendering_method(), viewport = str(root.size),
					scale = root.scaling_3d_scale, shadows = GameSettings.shadows, msaa = root.msaa_3d}
			if frames == 30:
				result.menu_memory = _memory()
				print("Мир %s@%d" % [seed_text, size])
				started = Time.get_ticks_msec()
				main.start_game(seed_text, size)
				phase = "loading"
		"loading":
			if game == null or game.player == null:
				if Time.get_ticks_msec() - started > Dev.LOAD_TIMEOUT_MS:
					printerr("Мир не загрузился за %d с" % (Dev.LOAD_TIMEOUT_MS / 1000))
					failed = true
					return _finish()
				return false
			result.load_s = snappedf((Time.get_ticks_msec() - started) / 1000.0, 0.01)
			timing.load = result.load_s
			load_ms = game.load_timings.duplicate()
			game.paused = true
			main.hud.visible = false
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
			game.camera.fov = 70.0
			spawn = game.camera.global_transform
			yaw0 = game.yaw
			result.loaded_memory = _memory()
			var id := Dev.world_id(seed_text, size)
			Dev.save_json(out.path_join("stats_%s.json" % id), Dev.world_stats(game.world))
			if "map" in want_views:
				_save(main.hud.map_tex.get_image(), "%s_map" % id, true)
			for v: Dictionary in Dev.views(game):
				if v.name in want_views:
					for h in hours:
						shots.append({name = v.name, pos = v.pos, target = v.target, hour = h[0], suffix = h[1]})
			started = Time.get_ticks_msec()
			phase = "shots"
			shot = 0
			wait = 0
			if not shots.is_empty():
				_place(game, shots[0])
		"shots":
			if shot < shots.size():
				wait += 1
				if wait < SETTLE_FRAMES:
					return false
				var s: Dictionary = shots[shot]
				_save(root.get_texture().get_image(), "%s_%s%s" % [Dev.world_id(seed_text, size), s.name, s.suffix], false)
				shot += 1
				wait = 0
				if shot < shots.size():
					_place(game, shots[shot])
				return false
			timing.shots = snappedf((Time.get_ticks_msec() - started) / 1000.0, 0.1)
			if not want_fps:
				return _finish()
			# назад на точку появления: растительность и край карты вокруг неё, как сразу после загрузки
			game.camera.global_transform = spawn
			game.vegetation.update(spawn.origin.x, spawn.origin.z, true)
			game.terrain_stream.update(spawn.origin.x, spawn.origin.z, true)
			if game.world.outer != null:
				game.outer.preload_around(spawn.origin.x, spawn.origin.z)
			_set_hour(game, NOON)
			_load_road(game)
			started = Time.get_ticks_msec()
			phase = "warmup"
			t = 0.0
		"warmup", "look":
			t += delta
			_advance_day(game, delta)
			game.camera.rotation = Vector3(-0.05, yaw0 + TAU * t / look_s, 0.0)
			game.camera.position = spawn.origin
			if phase == "warmup" and t >= WARMUP_S:
				phase = "look"
				t = 0.0
				last_us = Time.get_ticks_usec()
			elif phase == "look":
				_count(look_ms)
				if t >= look_s:
					phase = "road"
					t = 0.0
		"road":
			t += delta
			_advance_day(game, delta)
			var p := _road_at(t * ROAD_SPEED)
			var ahead := _road_at(t * ROAD_SPEED + 15.0)
			var hf := game.heights
			p.y = maxf(hf.surface_at(p.x, p.z, INF), hf.ground_at(p.x, p.z) + hf.depth_at(p.x, p.z)) + GameConfig.EYE
			ahead.y = hf.ground_at(ahead.x, ahead.z) + GameConfig.EYE
			if p.distance_to(ahead) > 0.5:
				game.camera.look_at_from_position(p, ahead, Vector3.UP)
			var uploaded := game.vegetation.update(p.x, p.z, false)
			uploaded = game.terrain_stream.update(p.x, p.z, false, not uploaded) or uploaded
			if game.world.outer != null:
				game.outer.update(p.x, p.z, not uploaded)
			_count(road_ms)
			if t >= road_s:
				timing.fps = snappedf((Time.get_ticks_msec() - started) / 1000.0, 0.1)
				_save_perf()
				return _finish()
	return false


func _finish() -> bool:
	if not failed:
		_remember(Dev.world_id(seed_text, size))
	print("%s: загрузка %.1f с, снимки %.1f с, FPS %.1f с" % [Dev.world_id(seed_text, size), timing.get("load", 0.0),
		timing.get("shots", 0.0), timing.get("fps", 0.0)])
	_after_run()
	return false


func _save(img: Image, name: String, png: bool) -> void:
	var path := out.path_join(name + (".png" if png else ".jpg"))
	var err := img.save_png(path) if png else img.save_jpg(path, 0.9)
	if err != OK:
		printerr("Не удалось сохранить %s (ошибка %d)" % [path, err])
		failed = true


## Камера на вид, растительность и край карты вокруг неё сразу целиком, час суток
func _place(game: GameWorld, v: Dictionary) -> void:
	game.camera.fov = 70.0
	game.camera.look_at_from_position(v.pos, v.target, Vector3.UP)
	game.vegetation.update(v.pos.x, v.pos.z, true)
	game.terrain_stream.update(v.pos.x, v.pos.z, true)
	if game.world.outer != null:
		game.outer.preload_around(v.pos.x, v.pos.z)
	for l: Label3D in game.labels:
		var d := Vector2(l.position.x - v.pos.x, l.position.z - v.pos.z).length()
		l.visible = d > 25.0 and d < 900.0
	_set_hour(game, v.hour)


## Час суток; облака стоят на одном месте (время 100 с), чтобы снимки повторялись
func _set_hour(game: Node, h: float) -> void:
	if game.get("day") != null:
		game.hour = h
		game.day.apply(h, 100.0)


## На замере игра стоит, а сутки идут (полчаса в секунду), как в perf.gd
func _advance_day(game: Node, delta: float) -> void:
	if game.get("day") != null:
		game.hour = fposmod(game.hour + delta * 0.5, 24.0)
		game.day.apply(game.hour, Time.get_ticks_msec() / 1000.0)


func _count(ms: PackedFloat32Array) -> void:
	var now := Time.get_ticks_usec()
	ms.append((now - last_us) / 1000.0)
	last_us = now
	draw_calls += Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)
	primitives += Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME)
	counted += 1


func _memory() -> Dictionary:
	var pm := Dev.process_memory()
	return {
		rss_mb = Perf._mb(pm.rss), peak_rss_mb = Perf._mb(pm.peak),
		video_mb = Perf._mb(Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED)),
		objects = int(Performance.get_monitor(Performance.OBJECT_COUNT)),
		nodes = int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT)),
	}


## Дописывает замер в perf.json папки прогона (формат perf.gd); мир не из замера — под ключом <сид>_<размер>
func _save_perf() -> void:
	result.look = Perf._frame_stats(look_ms)
	result.road = Perf._frame_stats(road_ms)
	result.draw_calls = roundi(draw_calls / maxi(1, counted))
	result.primitives = roundi(primitives / maxi(1, counted))
	result.memory = _memory()
	var path := out.path_join("perf.json")
	var all: Variant = Dev.load_json(path)
	if all == null:
		all = {version = Dev.version(), seed = cfg.seed, sizes = {}}
	all.machine = {gpu = RenderingServer.get_video_adapter_name(), cpu = OS.get_processor_name(),
		threads = OS.get_processor_count(), os = OS.get_name(), dotnet = Grid.fast_grid() != null}
	var key := str(size) if seed_text == cfg.seed else Dev.world_id(seed_text, size)
	all.sizes[key] = result
	Dev.save_json(path, all)
	print("FPS %s: осмотр %.0f (1%% %.0f), дорога %.0f (1%% %.0f), загрузка %.1f с" % [key, result.look.fps,
		result.look.low1, result.road.fps, result.road.low1, result.load_s])


## Ломаная самой длинной дороги в метрах; если дорог нет — прямая на север от точки появления
func _load_road(game: GameWorld) -> void:
	var best: Array = []
	var best_n := 0.0
	for tr in game.world.trails:
		if tr.kind == "road" and Dev.path_length(tr.pts) > best_n:
			best_n = Dev.path_length(tr.pts)
			best = tr.pts
	var o := spawn.origin
	if best.size() < 2:
		best = [{x = o.x / Dev.TILE, y = o.z / Dev.TILE}, {x = o.x / Dev.TILE, y = o.z / Dev.TILE - 200.0}]
	var acc := 0.0
	for k in best.size():
		var p := Vector3((best[k].x + 0.5) * Dev.TILE, 0.0, (best[k].y + 0.5) * Dev.TILE)
		if k > 0:
			acc += Vector2(p.x - road[k - 1].x, p.z - road[k - 1].z).length()
		road.append(p)
		road_len.append(acc)


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
