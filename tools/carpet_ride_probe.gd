extends SceneTree
## 19.11.2026: ковёр травы и трава в настоящем мире на скорости. Мир — из кэша стресс-теста (Север-1234@START_SIZE,
## tools/control/runs/stress/world_cache; без генерации, если кэш есть), настройки по умолчанию, 60 кадров/с как в игре.
## Камера едет по самой длинной дороге с заданной скоростью, подгрузка — тем же WorldStreamCoordinator, что в игре.
## Каждые 0,2 с: сколько куртинок ковра стоит (с учётом проявления) против полного ковра в тех же плитках —
## по полосам впереди (вдоль взгляда, ±12 м вбок) и на обочинах рядом. Печатает минимум и среднее по полосам,
## расстояние, на котором ковёр появлялся (проявление начиналось), очередь и время склейки. Снимки вперёд.
##   godot --path . --script res://tools/carpet_ride_probe.gd -- [--speeds 8,14,22] [--seconds 10] [--fps 60] [--out <папка>]
## Нужно окно. Лимит 300 с.
const Dev := preload("res://tools/control/control.gd")
const Snapshots := preload("res://scripts/render/vegetation_snapshots.gd")
const BANDS := [0.0, 8.0, 16.0, 24.0, 32.0, 44.0]

var args := OS.get_cmdline_user_args()
var out := ""
var main: Node
var game: GameWorld
var road: PackedVector3Array = []
var road_len: PackedFloat32Array = []
var ideal := {}
var failures := 0


func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 300)
	_run.call_deferred()


func _arg(name: String, fallback: String) -> String:
	var i := args.find("--" + name)
	return args[i + 1] if i >= 0 and i + 1 < args.size() else fallback


func _run() -> void:
	out = _arg("out", ProjectSettings.globalize_path("res://tools/control/runs/carpet_ride"))
	DirAccess.make_dir_recursive_absolute(out)
	var seed_text := "Север-1234"
	var size := WorldGenerator.START_SIZE
	var settings := GameContext.scope.settings
	settings.settings_path = out.path_join("settings.cfg")
	preload("res://scripts/game/opening_route.gd").fixed_seed = 1
	main = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	for i in 3: await process_frame
	DisplayServer.window_set_size(Dev.WINDOW_SIZE)
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = int(_arg("fps", "60"))
	var cache := GameContext.scope.cache
	cache.dir = ProjectSettings.globalize_path("res://tools/control/runs/stress/world_cache")
	cache.enabled = true
	settings.recent_seeds.assign([seed_text])
	print("Мир %s@%d: %s" % [seed_text, size, "из кэша" if cache.has(seed_text, size) else "генерация"])
	var t0 := Time.get_ticks_msec()
	main.start_game(seed_text, size)
	while main.game == null or main.game.player == null or main.busy:
		await process_frame
		if Time.get_ticks_msec() - t0 > 200000:
			print("FAIL мир не загрузился")
			quit(1)
			return
	game = main.game
	game.paused = true
	if game.pause_requested.is_connected(main._toggle_pause):
		game.pause_requested.disconnect(main._toggle_pause)
	if game._opening:
		game._finish_opening()
	game.camera.fov = 70.0
	var carpet: GroundCarpet = game.vegetation.carpet
	print("ковёр: дальность %.0f м, по взгляду %s, густота %.2f" % [carpet.reach(), carpet.directional, carpet.density])
	_load_road()
	if "--bench" in args:
		_bench(carpet)
		quit(0)
		return
	var speeds := _arg("speeds", "8,14,22").split(",")
	var seconds := float(_arg("seconds", "10"))
	var start := 200.0
	for speed_text in speeds:
		var speed := float(speed_text)
		await _ride(speed, seconds, start)
		start += speed * seconds + 150.0
	print("carpet_ride_probe: снимки в %s" % out)
	quit(0)


func _ride(speed: float, seconds: float, s0: float) -> void:
	var carpet: GroundCarpet = game.vegetation.carpet
	var eye := _road_eye(s0)
	game.camera.look_at_from_position(eye, _road_eye(s0 + 15.0), Vector3.UP)
	game.vegetation.update(eye.x, eye.z, true)
	game.terrain_stream.update(eye.x, eye.z, true)
	# 1 с стоим: штатная догрузка вокруг, как после появления
	var t := 0.0
	var last := Time.get_ticks_usec()
	while t < 1.0:
		await process_frame
		var now := Time.get_ticks_usec()
		t += (now - last) / 1000000.0
		last = now
		game.stream_coordinator.update(eye)
	var samples: Array = []
	var appear: Array = [] # расстояния, на которых ковёр начинал проявляться впереди
	var seen := {}
	t = 0.0
	var next_sample := 0.0
	var frames := 0
	var worst_frame := 0.0
	var shot_done := false
	var max_backlog := 0
	var last_job := {}
	var veg_stats := {}
	while t < seconds:
		await process_frame
		var now := Time.get_ticks_usec()
		var dt := (now - last) / 1000000.0
		last = now
		t += dt
		frames += 1
		var s := s0 + t * speed
		var pos := _road_eye(s)
		game.camera.look_at_from_position(pos, _road_eye(s + 15.0), Vector3.UP)
		var began := Time.get_ticks_usec()
		game.stream_coordinator.update(pos)
		worst_frame = maxf(worst_frame, (Time.get_ticks_usec() - began) / 1000.0)
		max_backlog = maxi(max_backlog, carpet._out.size())
		var veg := game.vegetation
		veg_stats.detail_s = maxf(veg_stats.get("detail_s", 0.0), veg._detail_seconds)
		veg_stats.latency_s = maxf(veg_stats.get("latency_s", 0.0), veg.stream.latency)
		veg_stats.pending = maxi(veg_stats.get("pending", 0), veg._pending.size())
		veg_stats.lead_m = maxf(veg_stats.get("lead_m", 0.0), veg.stream.lead().length())
		if not veg._present.is_empty(): veg_stats.present_frames = veg_stats.get("present_frames", 0) + 1
		var nearest_pending := INF
		for built: Dictionary in veg._pending:
			nearest_pending = minf(nearest_pending, veg._distance(built.chunk, Vector2(pos.x, pos.z)))
		veg_stats.tree_pending_nearest_m = minf(veg_stats.get("tree_pending_nearest_m", INF), nearest_pending)
		# трава: насколько далеко впереди уже лежит опубликованный снимок (центр снимка + радиус травы − игрок)
		# впереди по ходу: точка в 0,6 радиуса травы перед игроком должна лежать внутри принятого снимка
		# край принятого снимка травы впереди по ходу, м (должен быть не ближе радиуса травы)
		var dir := Vector2(_road_eye(s + 3.0).x - pos.x, _road_eye(s + 3.0).z - pos.z).normalized()
		var edge := 0.0
		while edge < veg.grass_r * 1.5 and veg.grass_at.is_finite() and VegetationLayer.StreamPolicy.distance_to_coverage(Vector2(pos.x, pos.z) + dir * (edge + 5.0), veg.grass_at, veg.grass_lead) <= veg.grass_r:
			edge += 5.0
		var grass_edge: float = edge
		if t > minf(10.0, seconds * 0.5): # после разгона: первый снимок травы считался на месте
			veg_stats.grass_margin_min = minf(veg_stats.get("grass_margin_min", INF), grass_edge)
		if "--timeline" in args and not carpet.job_parts.is_empty() and carpet.job_parts != last_job:
			last_job = carpet.job_parts
			print("  t=%.2f склейка плиток %d (из %d) %.0f мс, пар %d, публикация %.0f мс; очередь до неё %d" % [t, last_job.tiles, last_job.need, last_job.build, last_job.pairs, last_job.publish, carpet._out.size()])
		if t >= next_sample and t > 1.0:
			next_sample = t + 0.2
			var forward := Vector2(_road_eye(s + 3.0).x - pos.x, _road_eye(s + 3.0).z - pos.z).normalized()
			var shown := _shown(carpet)
			samples.append({p = Vector2(pos.x, pos.z), f = forward, shown = shown})
			for key: Vector2i in shown:
				if not seen.has(key):
					seen[key] = true
					var c := (Vector2(key) + Vector2.ONE * 0.5) * GameConfig.TILE - Vector2(pos.x, pos.z)
					if c.dot(forward) > 0.0 and absf(forward.cross(c)) < 12.0:
						appear.append(c.dot(forward))
		if not shot_done and t > seconds * 0.6:
			shot_done = true
			await RenderingServer.frame_post_draw
			root.get_texture().get_image().save_jpg(out.path_join("ride_%d.jpg" % roundi(speed)), 0.85)
		if t <= 1.0:
			for key: Vector2i in _shown(carpet):
				seen[key] = true
	_report(speed, samples, appear, frames / maxf(t, 0.001), worst_frame, max_backlog, carpet)
	print("  деревья: дальность %.0f м, ближайший ещё не выложенный чанк %.0f м" % [game.vegetation.tree_r, veg_stats.get("tree_pending_nearest_m", INF)])
	print("  трава и подлесок: радиус травы %.0f м, край снимка травы впереди не ближе %.0f м; %s" % [game.vegetation.grass_r, veg_stats.get("grass_margin_min", 0.0), str(veg_stats)])


## Куртинки на экране по плиткам 4 м, с учётом проявления (0..1)
func _shown(carpet: GroundCarpet) -> Dictionary:
	var by_tile := {}
	var now: float = game.vegetation.stream.clock
	for entry: Dictionary in carpet.layers:
		for key: Vector2i in entry.nodes:
			var mm: MultiMesh = entry.nodes[key].mm
			var live: PackedFloat32Array = mm.buffer
			for n: int in mm.visible_instance_count:
				var o := n * GroundCarpet.STRIDE
				var tile := Vector2i(floori(live[o + 3] / GameConfig.TILE), floori(live[o + 11] / GameConfig.TILE))
				by_tile[tile] = by_tile.get(tile, 0.0) + Snapshots.opacity(live[o + 19], now)
	return by_tile


func _ideal(carpet: GroundCarpet, key: Vector2i) -> float:
	if not ideal.has(key):
		var total := 0
		for part: PackedFloat32Array in carpet._build_tile(key.x, key.y).parts:
			total += part.size() / GroundCarpet.STRIDE
		ideal[key] = float(total)
	return ideal[key]


func _report(speed: float, samples: Array, appear: Array, fps: float, worst_frame: float, max_backlog: int, carpet: GroundCarpet) -> void:
	var bands := BANDS.size() - 1
	var minimum: Array = []
	var mean: Array = []
	for b in bands:
		minimum.append(1.0)
		mean.append(0.0)
	var side_min := 1.0
	for sample: Dictionary in samples:
		var have := []
		var want := []
		have.resize(bands)
		want.resize(bands)
		have.fill(0.0)
		want.fill(0.0)
		var side_have := 0.0
		var side_want := 0.0
		var p: Vector2 = sample.p
		var f: Vector2 = sample.f
		var r := ceili(BANDS[-1] / GameConfig.TILE) + 1
		var c0 := Vector2i((p / GameConfig.TILE).floor())
		for j in range(-r, r + 1):
			for i in range(-r, r + 1):
				var key := c0 + Vector2i(i, j)
				var c := (Vector2(key) + Vector2.ONE * 0.5) * GameConfig.TILE - p
				var along := c.dot(f)
				var across := absf(f.cross(c))
				if across > 12.0 or along < -6.0 or along >= BANDS[-1]:
					continue
				var w := _ideal(carpet, key)
				if w <= 0.0:
					continue
				var got := minf(float(sample.shown.get(key, 0.0)), w)
				if along < 6.0:
					side_have += got
					side_want += w
				if along < 0.0:
					continue
				for b in bands:
					if along >= BANDS[b] and along < BANDS[b + 1]:
						have[b] += got
						want[b] += w
		for b in bands:
			var k: float = have[b] / want[b] if want[b] > 0.0 else 1.0
			minimum[b] = minf(minimum[b], k)
			mean[b] += k / samples.size()
		if side_want > 0.0:
			side_min = minf(side_min, side_have / side_want)
	appear.sort()
	var line := "СКОРОСТЬ %d м/с (%.0f кадров/с, худшая подгрузка %.1f мс, очередь ковра до %d, склейка до %.0f мс, упреждение %.0f м):" % [
		roundi(speed), fps, worst_frame, max_backlog, carpet.max_job_ms, carpet.stream.lead().length()]
	print(line)
	print("  склейка, максимум по частям (мс): %s" % str(carpet.job_parts_max))
	print("  выкладка: %d квадратов, %.3f мс на квадрат (обе формы)" % [carpet.present_sectors, carpet.present_us / 1000.0 / maxf(1.0, carpet.present_sectors)])
	carpet.present_us = 0
	carpet.present_sectors = 0
	carpet.job_parts_max.clear()
	carpet.max_job_ms = 0.0
	print("  рядом (−6…6 м, ±12 м вбок): минимум %d %%" % roundi(side_min * 100.0))
	for b in bands:
		print("  впереди %2d–%2d м: среднее %3d %%, минимум %3d %%" % [BANDS[b], BANDS[b + 1], roundi(mean[b] * 100.0), roundi(minimum[b] * 100.0)])
	if not appear.is_empty():
		print("  ковёр появлялся впереди на: ближе всего %.0f м, медиана %.0f м (%d плиток)" % [appear[0], appear[appear.size() / 2], appear.size()])


func _load_road() -> void:
	var best: Array = []
	var best_n := 0.0
	for tr in game.world.trails:
		if tr.kind == "road" and Dev.path_length(tr.pts) > best_n:
			best_n = Dev.path_length(tr.pts)
			best = tr.pts
	var acc := 0.0
	for k in best.size():
		var p := Vector3((best[k].x + 0.5) * Dev.TILE, 0.0, (best[k].y + 0.5) * Dev.TILE)
		if k > 0:
			acc += Vector2(p.x - road[k - 1].x, p.z - road[k - 1].z).length()
		road.append(p)
		road_len.append(acc)
	print("дорога %.0f м" % acc)


func _road_eye(s: float) -> Vector3:
	var total := road_len[road_len.size() - 1]
	s = fmod(s, 2.0 * total)
	if s > total:
		s = 2.0 * total - s
	var k := 1
	while k < road_len.size() - 1 and road_len[k] < s:
		k += 1
	var p := road[k - 1].lerp(road[k], clampf((s - road_len[k - 1]) / maxf(0.001, road_len[k] - road_len[k - 1]), 0.0, 1.0))
	var hf := game.heights
	p.y = maxf(hf.surface_at(p.x, p.z, INF), hf.ground_at(p.x, p.z) + hf.depth_at(p.x, p.z)) + GameConfig.EYE
	return p


## Цена плитки ковра и её частей (отладка)
func _bench(carpet: GroundCarpet) -> void:
	var eye := _road_eye(1200.0)
	var hf := game.heights
	var refine = hf.road_refinement
	var W := game.world.W
	var n := 3000
	var parts := {}
	var t := Time.get_ticks_usec()
	for k in n: hf.ground_at(eye.x + k * 0.37, eye.z + k * 0.11)
	parts.ground_at = (Time.get_ticks_usec() - t) / float(n)
	t = Time.get_ticks_usec()
	for k in n: hf.depth_at(eye.x + k * 0.37, eye.z + k * 0.11)
	parts.depth_at = (Time.get_ticks_usec() - t) / float(n)
	t = Time.get_ticks_usec()
	for k in n: refine.edge_at(eye.x + k * 0.37, eye.z + k * 0.11, W)
	parts.edge_at = (Time.get_ticks_usec() - t) / float(n)
	t = Time.get_ticks_usec()
	for k in n: refine.sample(eye.x + k * 0.37, eye.z + k * 0.11, W)
	parts.sample = (Time.get_ticks_usec() - t) / float(n)
	t = Time.get_ticks_usec()
	for k in n: refine.weight_at(eye.x + k * 0.37, eye.z + k * 0.11, W)
	parts.weight_at = (Time.get_ticks_usec() - t) / float(n)
	t = Time.get_ticks_usec()
	for k in n: VegetationLayer._value_noise(eye.x + k * 0.37, eye.z + k * 0.11, 229)
	parts.value_noise = (Time.get_ticks_usec() - t) / float(n)
	print("мкс на вызов: ", parts, " refine=", refine.get_class() if refine is Object else typeof(refine), " native_ride=", hf.native_ride)
	var keys: Array[Vector2i] = []
	var c := Vector2i(floori(eye.x / GameConfig.TILE), floori(eye.z / GameConfig.TILE))
	for j in range(-4, 4):
		for i in range(-4, 4):
			keys.append(c + Vector2i(i, j))
	t = Time.get_ticks_usec()
	var grass_us := 0
	var stones_us := 0
	for key in keys:
		var ys := [Vector2.ZERO]
		var a := Time.get_ticks_usec()
		carpet._grass_tile(key.x, key.y, ys)
		var b := Time.get_ticks_usec()
		carpet._road_stones(key.x, key.y, ys)
		grass_us += b - a
		stones_us += Time.get_ticks_usec() - b
	print("плитка подряд: %.2f мс (трава %.2f, россыпь %.2f) на %d плиток" % [(Time.get_ticks_usec() - t) / 1000.0 / keys.size(), grass_us / 1000.0 / keys.size(), stones_us / 1000.0 / keys.size(), keys.size()])
	for threads in [1, 2, 3, 4, 6]:
		var built: Array = []
		built.resize(keys.size())
		t = Time.get_ticks_usec()
		var group := WorkerThreadPool.add_group_task(func(index: int) -> void: built[index] = carpet._build_tile(keys[index].x, keys[index].y), keys.size(), threads, true, "bench")
		WorkerThreadPool.wait_for_group_task_completion(group)
		print("плитка группой на %d потоках: %.2f мс на плитку" % [threads, (Time.get_ticks_usec() - t) / 1000.0 / keys.size()])
