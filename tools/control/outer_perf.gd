extends SceneTree
## Отрисовка внешнего мира: одинаковые камеры, полная подгрузка до замера, без фоновых задач.
## godot --path . --script res://tools/control/outer_perf.gd -- --out <папка>

const Dev := preload("res://tools/control/control.gd")
const Perf := preload("res://tools/control/perf.gd")
var main: Node
var phase := "menu"
var frames := 0
var started := 0
var elapsed := 0.0
var last_us := 0
var view := 0
var samples := PackedFloat32Array()
var draws := 0.0
var primitives := 0.0
var position := Vector3.ZERO
var result := {views = []}
var out := ""


func _initialize() -> void:
	out = Dev.out_dir()
	view = int(Dev.arg("view", "0"))
	main = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)


func _process(delta: float) -> bool:
	frames += 1
	if phase == "menu":
		if frames == 1:
			DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
			DisplayServer.window_set_size(Dev.WINDOW_SIZE)
			DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
			Engine.max_fps = 0
		if frames == 30:
			started = Time.get_ticks_msec()
			main.start_game("Север-1234", 512)
			phase = "loading"
		return false
	var game: GameWorld = main.game
	if phase == "loading":
		if game == null or game.player == null:
			if Time.get_ticks_msec() - started > 180000:
				quit(1)
			return false
		result.load_s = (Time.get_ticks_msec() - started) / 1000.0
		game.paused = true
		main.hud.hide()
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		_setup_view(game)
		return false
	if phase == "warmup":
		elapsed += delta
		if elapsed >= 2.0:
			var image := root.get_texture().get_image()
			image.save_png(out.path_join("view_%d.png" % view))
			phase = "measure"
			elapsed = 0.0
			last_us = Time.get_ticks_usec()
		return false
	if phase == "measure":
		var now := Time.get_ticks_usec()
		samples.append((now - last_us) / 1000.0)
		last_us = now
		draws += Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)
		primitives += Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME)
		elapsed += delta
		var seconds := float(Dev.arg("seconds", "8"))
		game.camera.rotation = Vector3(-0.18, -PI / 2.0 + TAU * elapsed / seconds, 0.0)
		if elapsed >= seconds:
			var stats := Perf._frame_stats(samples)
			stats.draw_calls = draws / samples.size()
			stats.primitives = primitives / samples.size()
			stats.chunks = game.outer._nodes.size()
			stats.video_mb = Performance.get_monitor(Performance.RENDER_BUFFER_MEM_USED) / 1048576.0
			result.views.append(stats)
			view += 1
			if view < 2:
				_setup_view(game)
			else:
				result.version = Dev.version()
				result.viewport = str(root.size)
				Dev.save_json(out.path_join("outer_perf.json"), result)
				print(JSON.stringify(result))
				quit()
	return false


func _setup_view(game: GameWorld) -> void:
	var edge := game.world.W * GameConfig.TILE
	position = Vector3(edge + (640.0 if view == 1 else -80.0), 0.0, edge * 0.5)
	game.outer.finish()
	game.outer.preload_around(position.x, position.z)
	game.outer.update(position.x, position.z)
	if Dev.arg("no-range", "0") == "1":
		for node in game.outer.get_children():
			node.visibility_range_end = 0.0
	if Dev.arg("no-lod", "0") == "1":
		root.mesh_lod_threshold = 0.0
	if Dev.arg("lod-bias", "1") != "1":
		for node in game.outer.get_children():
			node.lod_bias = float(Dev.arg("lod-bias", "1"))
	if Dev.arg("hide-outer", "0") == "1":
		game.outer.hide()
	game.vegetation.update(position.x, position.z, true)
	position.y = game.heights.ground_at(position.x, position.z) + (180.0 if view == 1 else GameConfig.EYE)
	game.camera.position = position
	game.camera.rotation = Vector3(-0.18, -PI / 2.0, 0.0)
	game.camera.fov = 70.0
	game._ocean.position = Vector3(position.x, 0.0, position.z)
	samples.clear()
	draws = 0.0
	primitives = 0.0
	elapsed = 0.0
	phase = "warmup"
