extends SceneTree
## Без генерации мира: геометрия для разных мониторов, масштабирование UI, подтверждение и откат.
const Config = preload("res://scripts/game/display_config.gd")
const Options = preload("res://scripts/ui/display_options.gd")
const Main = preload("res://scripts/ui/main.gd")
var fails := 0

func check(ok: bool, label: String) -> void:
	print(("OK " if ok else "FAIL ") + label)
	if not ok:
		fails += 1

func _initialize() -> void:
	call_deferred("run")

func settle() -> void:
	for i in 4:
		await process_frame
	if DisplayServer.get_name() != "headless":
		await RenderingServer.frame_post_draw

func run() -> void:
	GameSettings.settings_path = "res://.godot/display_test/settings.cfg"
	DirAccess.make_dir_recursive_absolute("res://.godot/display_test")
	GameSettings.reset_defaults()
	var cfg := ConfigFile.new()
	cfg.set_value("view", "fullscreen", true)
	cfg.set_value("display", "resolution", "bad")
	cfg.set_value("display", "render_scale", NAN)
	cfg.set_value("display", "vsync", 1)
	GameSettings._apply_config(cfg)
	check(GameSettings.fullscreen and GameSettings.resolution == Config.BASE and GameSettings.render_scale == 1.0 and GameSettings.vsync, "old fullscreen migrates; malformed fields ignored")
	cfg.set_value("display", "resolution", Vector2i(-1, 900))
	cfg.set_value("display", "msaa", 999)
	GameSettings._apply_config(cfg)
	check(GameSettings.resolution == Config.BASE and GameSettings.msaa == 2, "invalid dimensions and AA guarded")
	var legacy := ConfigFile.new()
	legacy.set_value("view", "fullscreen", true)
	GameSettings._apply_config(legacy)
	check(GameSettings.resolution == Vector2i.ZERO, "legacy fullscreen keeps native resolution")
	for size: Vector2i in [Vector2i(800, 600), Vector2i(1366, 768), Vector2i(1920, 1080), Vector2i(3840, 2160)]:
		var fit := Config.fit_window(Vector2i(3840, 2160), size)
		check(fit.x <= size.x - 32 and fit.y <= size.y - 64 and fit.x > 0 and fit.y > 0, "window fits usable screen %s" % size)
	var sizes := Config.resolutions(Vector2i(1366, 768), Vector2i(1234, 700))
	check(sizes.has(Vector2i(1234, 700)) and not sizes.has(Vector2i(3840, 2160)), "presets filtered; custom size retained")
	var state := {fullscreen = true, resolution = Vector2i(1920, 1080), render_scale = 1.0, msaa = 0, vsync = true}
	check(is_equal_approx(Config.render_factor(state, Vector2i(3840, 2160)), 0.5), "4K screen can render 3D at 1080p")
	check(is_equal_approx(Config.render_factor(state, Vector2i(3440, 1440)), 1920.0 / 3440.0), "ultrawide keeps aspect and pixel budget")
	GameSettings.reset_defaults()
	var main: Node = load("res://scenes/main.tscn").instantiate()
	main.set_script(null)
	root.add_child(main)
	main.set_script(Main)
	main.set_process(false)
	main.hud = main.get_node("%Hud")
	main.seed_edit = main.get_node("%SeedEdit")
	main.screens = {back = main.get_node("%Back"), menu = main.get_node("%Menu"), loading = main.get_node("%Loading"),
		pause = main.get_node("%Pause"), settings = main.get_node("%Settings")}
	main._setup_save_controls()
	var options := Options.new()
	options.setup(main)
	main.display_options = options
	main._sync_settings_controls()
	main.seed_edit.text = "Север-1234"
	main._show_seed_tab("saved")
	var camera := Camera3D.new()
	main.add_child(camera)
	camera.current = true
	var world := WorldData.new()
	world.W = 64
	world.H = 64
	world.N = 4096
	var map := Image.create(128, 128, false, Image.FORMAT_RGB8)
	map.fill(Color(0.2, 0.3, 0.2))
	main.hud.set_world(world, map)
	main.hud.set_player(128, 128, 0.0)
	var out := "res://.godot/display_test"
	DirAccess.make_dir_recursive_absolute(out)
	for size: Vector2i in [Vector2i(640, 360), Vector2i(1024, 768), Vector2i(1280, 720), Vector2i(1920, 1080), Vector2i(3440, 1440), Vector2i(3840, 2160)]:
		root.size = size
		await settle()
		for screen: String in ["menu", "pause", "settings"]:
			main._show(screen)
			await settle()
			var panel: Control = main.screens[screen].get_node("Panel")
			var rect := panel.get_global_rect()
			var visible := root.get_visible_rect().grow(1.0)
			check(visible.encloses(rect), "%s fits %s (UI %s)" % [screen, size, visible.size])
			if DisplayServer.get_name() != "headless" and size in [Vector2i(1280, 720), Vector2i(3840, 2160)]:
				root.get_texture().get_image().save_png(out.path_join("%s_%dx%d.png" % [screen, size.x, size.y]))
		options.tabs.current_tab = 1
		await settle()
		var graphics: ScrollContainer = options.tabs.get_child(1)
		check(graphics.get_v_scroll_bar().max_value <= graphics.size.y + 1, "graphics fits without scrolling %s" % size)
		if DisplayServer.get_name() != "headless" and size == Vector2i(1280, 720):
			root.get_texture().get_image().save_png(out.path_join("graphics_1280x720.png"))
		options.tabs.current_tab = 0
		main._show("")
		main.hud.show()
		main.hud.set_map_visible(false)
		await settle()
		check(root.get_visible_rect().grow(1.0).encloses(main.hud.minimap.get_global_rect()), "HUD remains inside viewport %s" % size)
		var projected := camera.unproject_position(Vector3(0, 0, -10))
		check(projected.distance_to(root.get_visible_rect().get_center()) < 1.0, "3D names and photo aim align with UI %s" % size)
		main.hud.set_map_visible(true)
		await settle()
		var frame: Array = main.hud.big_map._frame()
		var click := InputEventMouseButton.new()
		click.button_index = MOUSE_BUTTON_LEFT
		click.pressed = true
		click.position = frame[0] + Vector2(12, 16) * float(frame[2])
		main.hud.big_map._gui_input(click)
		check(main.hud.goal.get("kind") == "marker" and absf(main.hud.goal.x - 12.0) < 0.1, "map picking matches scaled UI %s" % size)
		main.hud.set_goal({})
		main.hud.set_map_visible(false)
		main.hud.hide()
	root.size = Vector2i(1024, 768)
	main._show("settings")
	await settle()
	var original := GameSettings.display_state()
	options.scale.select(0)
	options.preview()
	check(options.pending() and GameSettings.display_state() == original and is_equal_approx(root.scaling_3d_scale, 0.5), "preview changes 3D without committing settings")
	options._deadline = Time.get_ticks_msec() - 1
	options.tick()
	await settle()
	check(not options.pending() and GameSettings.display_state() == original and root.scaling_3d_scale == 1.0, "timeout restores original")
	options.scale.select(2)
	options.preview()
	options.keep()
	GameSettings.reset_defaults()
	GameSettings.load_settings()
	check(GameSettings.render_scale == 0.75, "confirmed settings survive reload")
	options.sync()
	options.scale.select(0)
	options.preview()
	main._close_settings()
	check(not options.pending() and GameSettings.render_scale == 0.75, "closing settings cancels unconfirmed preview")
	main._on_reset_settings()
	check(GameSettings.render_scale == 0.75 and options.selected_state().render_scale == 1.0, "reset stages display defaults without unsafe switch")
	options.sync()
	main.get_node("%Shadows").set_pressed(true)
	main.get_node("%DrawOption").select(0)
	options.preview()
	options.keep()
	check(GameSettings.draw == 0, "graphics quality commits with display settings")
	if DisplayServer.get_name() != "headless":
		options.sync()
		options.mode.select(1)
		options.preview()
		await settle()
		check(root.mode == Window.MODE_FULLSCREEN, "native fullscreen applied")
		options.revert()
		await settle()
		check(root.mode == Window.MODE_WINDOWED and not root.borderless, "cancel returns decorated window")
	var saved_bytes := FileAccess.get_file_as_bytes(GameSettings.settings_path)
	var committed := GameSettings.display_state()
	# Только отдельный файл теста: каталог на месте cfg имитирует ошибку записи.
	DirAccess.remove_absolute(GameSettings.settings_path)
	DirAccess.make_dir_absolute(GameSettings.settings_path)
	options.scale.select(0)
	options.preview()
	options.keep()
	check(not options.pending() and GameSettings.display_state() == committed, "write failure restores confirmed display state")
	DirAccess.remove_absolute(GameSettings.settings_path)
	var settings_file := FileAccess.open(GameSettings.settings_path, FileAccess.WRITE)
	settings_file.store_buffer(saved_bytes)
	settings_file.close()
	main.queue_free()
	await process_frame
	print("DISPLAY TEST failures: ", fails)
	quit(1 if fails else 0)
