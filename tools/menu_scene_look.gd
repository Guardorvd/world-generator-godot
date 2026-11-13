extends SceneTree
## Стенд привала. --quality 0|1|2, --poster перезаписывает resources/menu/poster.jpg.

const Backdrop := preload("res://scripts/ui/menu_backdrop.gd")
const FarForest := preload("res://scripts/render/distant_forest.gd")
const OUT := "res://.godot/menu_scene_look"
const POSTER := "res://resources/menu/poster.jpg"
const FRAMES := 60
const CHECK_GLOBALS := """
shader_type canvas_item;
global uniform vec4 cloud_shadow;
global uniform vec3 sun_dir;
global uniform float vegetation_night;
global uniform vec3 style_haze;
global uniform vec4 style_depth;
global uniform vec2 veg_center;
global uniform float vegetation_clock;
global uniform ivec4 veg_seeds;
global uniform vec4 distant_vegetation;

void fragment() {
	bool clean = length(cloud_shadow) < 0.001 && distance(sun_dir, vec3(0, 1, 0)) < 0.001
		&& abs(vegetation_night) < 0.001 && distance(style_haze, vec3(0.62, 0.74, 0.88)) < 0.001
		&& length(style_depth) < 0.001 && length(veg_center) < 0.001 && abs(vegetation_clock - 1.0) < 0.001
		&& all(equal(veg_seeds, ivec4(0))) && distance(distant_vegetation, vec4(450, 90, 1400, 1)) < 0.001;
	COLOR = clean ? vec4(0, 1, 0, 1) : vec4(1, 0, 0, 1);
}
"""

var _backdrop: Node
var _failure := ""
var _checks_failed := false


func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 120)
	_run.call_deferred()


func _run() -> void:
	if DisplayServer.get_name() == "headless":
		push_error("Для съёмки привала требуется окно.")
		quit(1)
		return
	var args := OS.get_cmdline_user_args()
	var quality := Backdrop.recommended_quality()
	var quality_arg := args.find("--quality")
	if quality_arg != -1:
		if quality_arg + 1 >= args.size() or args[quality_arg + 1] not in ["0", "1", "2"]:
			push_error("--quality: укажите 0, 1 или 2")
			quit(1)
			return
		quality = int(args[quality_arg + 1])
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT))
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	root.msaa_3d = Viewport.MSAA_DISABLED
	root.size = Vector2i(1280, 720)
	var picture := TextureRect.new()
	picture.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	picture.stretch_mode = TextureRect.STRETCH_SCALE
	root.add_child(picture)
	picture.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var settings := GameSettings.new()
	var forest_before := Vector3(float(FarForest.active), FarForest.near_begin, FarForest.far_end)
	var style_before := [VisualStyle.on.duplicate(), VisualStyle.amount.duplicate()]
	_backdrop = Backdrop.new()
	root.add_child(_backdrop)
	_backdrop.failed.connect(func(reason: String) -> void: _failure = reason)
	var cancelled: bool = _backdrop.start(root.size, settings, quality)
	_check(cancelled, "начата прерываемая сборка")
	await process_frame
	await RenderingServer.frame_post_draw
	_check(_backdrop.freeze() == null, "отмена оставляет афишу")
	_check_released(forest_before, style_before)
	if not _backdrop.start(root.size, settings, quality):
		push_error("Не удалось начать сборку привала.")
		quit(1)
		return
	var view: SubViewport = _backdrop.viewport()
	picture.texture = view.get_texture()
	RenderingServer.viewport_set_measure_render_time(view.get_viewport_rid(), true)
	while not _backdrop.is_prepared and _failure.is_empty():
		await process_frame
	if not _failure.is_empty():
		push_error(_failure)
		quit(1)
		return
	print("MENU_BUILD quality=", quality, " viewport=", view.size, " ms=", _backdrop.build_ms,
		" steps=", JSON.stringify(_backdrop.step_ms))
	print("MENU_FRAME ", JSON.stringify(await _measure(view)))
	var wide := await _capture(Vector2i(1280, 720))
	var narrow := await _capture(Vector2i(960, 720))
	_save(wide, OUT.path_join("scene_16x9.png"))
	_save(narrow, OUT.path_join("scene_4x3.png"))
	if "--poster" in args and wide != null:
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(POSTER.get_base_dir()))
		_check(wide.save_jpg(ProjectSettings.globalize_path(POSTER), 0.93) == OK, POSTER)
	picture.texture = null
	var frozen: Image = _backdrop.freeze()
	_check(frozen != null and not frozen.is_empty() and frozen.get_size() == Vector2i(960, 720), "заморозка готового кадра")
	_check_released(forest_before, style_before)
	await _check_shader_globals()
	quit(int(_checks_failed))


func _measure(view: SubViewport) -> Dictionary:
	var frames := PackedFloat64Array()
	var renders := 0
	var calls := 0
	var triangles := 0
	var gpu_ms := 0.0
	var cpu_ms := 0.0
	var previous := Time.get_ticks_usec()
	var previous_render: int = _backdrop.render_count()
	var elapsed_ms := 0.0
	for frame in FRAMES:
		await RenderingServer.frame_post_draw
		var now := Time.get_ticks_usec()
		var frame_ms := (now - previous) / 1000.0
		frames.append(frame_ms)
		elapsed_ms += frame_ms
		previous = now
		# На экономном уровне только каждый второй кадр меняет 3D-изображение.
		var render: int = _backdrop.render_count()
		if render != previous_render:
			previous_render = render
			calls += view.get_render_info(Viewport.RENDER_INFO_TYPE_VISIBLE, Viewport.RENDER_INFO_DRAW_CALLS_IN_FRAME)
			triangles += view.get_render_info(Viewport.RENDER_INFO_TYPE_VISIBLE, Viewport.RENDER_INFO_PRIMITIVES_IN_FRAME)
			gpu_ms += RenderingServer.viewport_get_measured_render_time_gpu(view.get_viewport_rid())
			cpu_ms += RenderingServer.viewport_get_measured_render_time_cpu(view.get_viewport_rid())
			renders += 1
	frames.sort()
	return {adapter = RenderingServer.get_video_adapter_name(), renderer = RenderingServer.get_current_rendering_method(),
		mean_ms = elapsed_ms / FRAMES, p95_ms = frames[ceili(FRAMES * 0.95) - 1],
		gpu_ms = gpu_ms / maxi(1, renders), cpu_ms = cpu_ms / maxi(1, renders),
		draw_calls = float(calls) / maxi(1, renders), primitives = float(triangles) / maxi(1, renders)}


func _capture(dimensions: Vector2i) -> Image:
	_backdrop.resize(dimensions, true)
	for frame in 5:
		await RenderingServer.frame_post_draw
	return _backdrop.viewport().get_texture().get_image()


func _save(image: Image, path: String) -> void:
	_check(image != null and not image.is_empty() and image.save_png(ProjectSettings.globalize_path(path)) == OK, path)


func _check_released(forest: Vector3, style: Array) -> void:
	_check(_backdrop.get_child_count() == 0 and _backdrop.viewport() == null, "окно и узлы освобождены")
	_check(not VisualStyle.is_bound() and VisualStyle.on == style[0] and VisualStyle.amount == style[1], "стиль освобождён")
	_check(forest == Vector3(float(FarForest.active), FarForest.near_begin, FarForest.far_end), "настройки дальнего леса сохранены")


## В игре RenderingServer запрещает читать параметры напрямую. Проверяем значения на GPU.
func _check_shader_globals() -> void:
	var view := SubViewport.new()
	view.size = Vector2i(4, 4)
	view.disable_3d = true
	view.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(view)
	var rect := ColorRect.new()
	rect.size = Vector2(4, 4)
	var shader := Shader.new()
	shader.code = CHECK_GLOBALS
	var material := ShaderMaterial.new()
	material.shader = shader
	rect.material = material
	view.add_child(rect)
	await RenderingServer.frame_post_draw
	var image := view.get_texture().get_image()
	_check(image != null and not image.is_empty() and image.get_pixel(1, 1).is_equal_approx(Color.GREEN),
		"общие параметры шейдеров сброшены")
	view.free()


func _check(ok: bool, label: String) -> void:
	print(("OK " if ok else "FAIL ") + label)
	_checks_failed = _checks_failed or not ok
