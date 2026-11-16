extends SceneTree
## Изолированная проба неба (16.11.2026), без генерации мира, нужно окно, ~40 с:
## 1) рисует ли текущий рендер проход неба в половинном разрешении (в Compatibility — нет);
## 2) GPU-время неба: простое / настоящее по пикселям (2 и 5 шагов) / купол облаков (sky_cloud_dome.gd),
##    при открытом небе и при «лесе» (85 % экрана закрыто);
## 3) сверка купола с облаками по пикселям: средняя и наибольшая разница, листы .godot/sky_probe/cmp_*.png.
## Запуск: godot --path . --rendering-method gl_compatibility --script res://tools/sky_dome_probe.gd

const HALF_SH := """
shader_type sky;
render_mode use_half_res_pass;
void sky() {
	if (AT_HALF_RES_PASS) {
		COLOR = vec3(1.0, 0.0, 0.0);
	} else if (AT_CUBEMAP_PASS) {
		COLOR = vec3(0.0, 1.0, 0.0);
	} else {
		COLOR = HALF_RES_COLOR.rgb + vec3(0.0, 0.0, 0.25);
	}
}
"""

const PLAIN_SH := """
shader_type sky;
uniform vec3 zenith_color : source_color = vec3(0.32, 0.52, 0.82);
uniform vec3 horizon_color : source_color = vec3(0.62, 0.74, 0.88);
uniform float cloud_time = 0.0;
void sky() {
	float h = max(EYEDIR.y, 0.0);
	COLOR = mix(horizon_color, zenith_color, smoothstep(0.0, 1.0, pow(h, 0.54))) + vec3(cloud_time * 0.0);
}
"""

var day: DayCycle
var camera: Camera3D
var cover: MeshInstance3D
var env: Environment
var real_shader: Shader
var dome: Node


func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 120)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://.godot/sky_probe"))
	root.size = Vector2i(1280, 720)
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	print("renderer=", RenderingServer.get_current_rendering_method(), " gpu=", RenderingServer.get_video_adapter_name())
	var we := WorldEnvironment.new()
	env = Environment.new()
	env.background_mode = Environment.BG_SKY
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.tonemap_mode = Environment.TONE_MAPPER_ACES
	we.environment = env
	root.add_child(we)
	var sun := DirectionalLight3D.new()
	root.add_child(sun)
	day = DayCycle.new(env, sun)
	day.world_seed = 42
	real_shader = day.sky_mat.shader
	dome = day.make_cloud_dome()
	root.add_child(dome)
	day.sky_mat.set_meta("cloud_dome", false)
	camera = Camera3D.new()
	camera.fov = 72.0
	root.add_child(camera)
	camera.make_current()
	day.camera = camera
	# «лес»: непрозрачная стена закрывает нижние 85 % кадра
	var q := QuadMesh.new()
	q.size = Vector2(12.0, 4.02)
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.albedo_color = Color(0.1, 0.2, 0.1)
	cover = MeshInstance3D.new()
	cover.mesh = q
	cover.material_override = m
	cover.position = Vector3(0.0, -0.993, -2.0)
	camera.add_child(cover)
	_run.call_deferred()


func _frames(n: int) -> void:
	for i in n:
		await process_frame


func _half_res_test() -> void:
	var sh := Shader.new()
	sh.code = HALF_SH
	var mat := ShaderMaterial.new()
	mat.shader = sh
	var old: Material = env.sky.sky_material
	env.sky.sky_material = mat
	cover.visible = false
	camera.rotation = Vector3(0.4, 0.0, 0.0)
	await _frames(6)
	await RenderingServer.frame_post_draw
	var img := root.get_texture().get_image()
	var c := img.get_pixel(img.get_width() / 2, img.get_height() / 2)
	print("HALF_RES center pixel = ", c, "  -> ", "ПОДДЕРЖИВАЕТСЯ" if c.r > 0.5 else "НЕ поддерживается (проход не рисуется)")
	env.sky.sky_material = old


func _measure(label: String, shader: Shader, steps: int, forest: bool, use_dome := false) -> void:
	day.sky_mat.shader = shader
	day.sky_mat.set_meta("cloud_dome", use_dome)
	day.sky_mat.set_shader_parameter("cumulus_steps", steps)
	cover.visible = forest
	camera.rotation = Vector3(0.12, 0.6, 0.0)
	var rid := root.get_viewport_rid()
	var t := 100.0
	for i in 20:
		t += 0.05
		day.apply(13.2, t)
		await process_frame
	var gpu := 0.0
	var cpu_ms := 0.0
	var n := 90
	var t0 := Time.get_ticks_usec()
	for i in n:
		t += 0.05
		day.apply(13.2, t)
		await process_frame
		gpu += RenderingServer.viewport_get_measured_render_time_gpu(rid) + (RenderingServer.viewport_get_measured_render_time_gpu(dome.get_child(0).get_viewport_rid()) if use_dome else 0.0)
	cpu_ms = float(Time.get_ticks_usec() - t0) / 1000.0 / n
	print("%-28s gpu %.2f ms   frame %.2f ms" % [label, gpu / n, cpu_ms])


func _shot(hour: float, use_dome: bool) -> Image:
	day.sky_mat.set_meta("cloud_dome", use_dome)
	for i in 6:
		day.apply(hour, 140.0)
		await process_frame
	await RenderingServer.frame_post_draw
	var img := root.get_texture().get_image()
	img.convert(Image.FORMAT_RGB8)
	return img


func _compare(label: String, hour: float, dir: Vector3) -> void:
	cover.visible = false
	day.sky_mat.set_shader_parameter("cumulus_steps", 2)
	camera.look_at_from_position(Vector3(0, 3, 0), Vector3(0, 3, 0) + dir * 100.0)
	var a := await _shot(hour, false)
	var b := await _shot(hour, true)
	var diff := 0.0
	var mx := 0.0
	var n := 0
	for y in range(0, a.get_height(), 4):
		for x in range(0, a.get_width(), 4):
			var ca := a.get_pixel(x, y)
			var cb := b.get_pixel(x, y)
			var dd := (absf(ca.r - cb.r) + absf(ca.g - cb.g) + absf(ca.b - cb.b)) / 3.0
			diff += dd
			mx = maxf(mx, dd)
			n += 1
	print("сравнение %s: средняя разница %.4f, наибольшая %.3f (в долях 0..1)" % [label, diff / n, mx])
	var sheet := Image.create(a.get_width() * 2, a.get_height(), false, Image.FORMAT_RGB8)
	sheet.blit_rect(a, Rect2i(Vector2i.ZERO, a.get_size()), Vector2i.ZERO)
	sheet.blit_rect(b, Rect2i(Vector2i.ZERO, b.get_size()), Vector2i(a.get_width(), 0))
	sheet.save_png(ProjectSettings.globalize_path("res://.godot/sky_probe/cmp_%s.png" % label))


func _run() -> void:
	RenderingServer.viewport_set_measure_render_time(root.get_viewport_rid(), true)
	RenderingServer.viewport_set_measure_render_time(dome.get_child(0).get_viewport_rid(), true)
	await _half_res_test()
	var plain := Shader.new()
	plain.code = PLAIN_SH
	for forest in [false, true]:
		var where := "лес " if forest else "небо"
		await _measure(where + " простое", plain, 2, forest)
		await _measure(where + " настоящее 2 шага", real_shader, 2, forest)
		await _measure(where + " настоящее 5 шагов", real_shader, 5, forest)
		await _measure(where + " купол 2 шага", real_shader, 2, forest, true)
		await _measure(where + " купол 5 шагов", real_shader, 5, forest, true)
	day.sky_mat.shader = real_shader
	await _compare("noon", 13.2, Vector3(0.35, 0.42, 0.85))
	await _compare("sunset", 17.55, Vector3(-0.85, 0.28, 0.42))
	await _compare("night", 0.8, Vector3(-0.3, 0.48, -0.82))
	quit(0)
