extends SceneTree
## Изолированная сцена неба и облаков (DayCycle + resources/sky.gdshader + тени облаков на земле)
## без генерации мира. Снимает полдень, закат, утро в разных ракурсах и лунную ночь,
## а также проверяет работу шейдера, разнообразие яркости облачного купола и живую эволюцию во времени.
## Запуск: godot --path . --script res://tools/sky_look.gd -- [--out <папка>] [--shader <файл>] [--tag <суффикс>]

var out := ""
var tag := ""
var fails := 0
var day: DayCycle
var camera: Camera3D


func _check(ok: bool, label: String) -> void:
	print(("OK " if ok else "FAIL ") + label)
	fails += int(not ok)


func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 60)
	var args := OS.get_cmdline_user_args()
	out = _arg(args, "--out", "res://.godot/sky_look")
	tag = _arg(args, "--tag", "")
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(out))
	root.size = Vector2i(1280, 720)
	_build(_arg(args, "--shader", ""))
	_run.call_deferred()


static func _arg(args: PackedStringArray, key: String, def: String) -> String:
	var at := args.find(key)
	return args[at + 1] if at >= 0 and at + 1 < args.size() else def


func _build(shader_path: String) -> void:
	var world_env := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_sky_contribution = 0.6
	env.tonemap_mode = Environment.TONE_MAPPER_ACES
	env.tonemap_exposure = 0.92
	env.tonemap_white = 6.0
	env.glow_enabled = true
	env.glow_intensity = 0.35
	env.glow_bloom = 0.04
	env.glow_blend_mode = Environment.GLOW_BLEND_MODE_SOFTLIGHT
	env.fog_enabled = true
	env.fog_aerial_perspective = 0.15
	env.fog_sky_affect = 0.0
	env.adjustment_enabled = true
	world_env.environment = env
	root.add_child(world_env)

	var sun := DirectionalLight3D.new()
	sun.shadow_enabled = true
	root.add_child(sun)

	day = DayCycle.new(env, sun)
	day.world_seed = 42
	if shader_path != "":
		var sh := Shader.new()
		sh.code = FileAccess.get_file_as_string(shader_path)
		day.sky_mat.shader = sh

	# Холмистая земля с шейдером теней облаков, чтобы было видно и линию горизонта, и бегущие тени
	var ground_sh := Shader.new()
	ground_sh.code = """
shader_type spatial;
#include "res://resources/cloud_shadow.gdshaderinc"
varying vec3 v_world;
void vertex() {
	v_world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}
void fragment() {
	float cl = cloud_light(v_world.xz);
	ALBEDO = vec3(0.32, 0.42, 0.24) * cl;
	ROUGHNESS = 0.92;
}
"""
	var ground_mat := ShaderMaterial.new()
	ground_mat.shader = ground_sh
	var plane := PlaneMesh.new()
	plane.size = Vector2(1200.0, 1200.0)
	plane.subdivide_width = 64
	plane.subdivide_depth = 64
	var ground := MeshInstance3D.new()
	ground.mesh = plane
	ground.material_override = ground_mat
	root.add_child(ground)

	camera = Camera3D.new()
	camera.fov = 72.0
	camera.far = 2000.0
	root.add_child(camera)
	camera.make_current()
	day.camera = camera


func _capture(name: String, hour: float, time_sec: float, from: Vector3, dir: Vector3) -> Image:
	day.apply(hour, time_sec)
	camera.look_at_from_position(from, from + dir.normalized() * 100.0)
	for i in 4:
		await process_frame
	await RenderingServer.frame_post_draw
	var img := root.get_texture().get_image()
	if img != null and not img.is_empty():
		var file_path := ProjectSettings.globalize_path(out).path_join(name + tag + ".png")
		_check(img.save_png(file_path) == OK, "снимок " + name + tag + ".png")
	return img


func _run() -> void:
	day.apply(13.5, 120.0)
	var cov: float = day.sky_mat.get_shader_parameter("cloud_cover")
	_check(cov > 0.1 and cov < 0.9, "покрытие облаками активно днём: %.3f" % cov)

	var img_noon := await _capture("sky_noon_cumulus", 13.2, 85.0, Vector3(0.0, 3.0, 0.0), Vector3(0.35, 0.42, 0.85))
	var img_noon_t2 := await _capture("sky_noon_evolved", 13.2, 195.0, Vector3(0.0, 3.0, 0.0), Vector3(0.35, 0.42, 0.85))
	var img_sunset := await _capture("sky_sunset_gold", 17.55, 140.0, Vector3(0.0, 3.0, 0.0), Vector3(-0.85, 0.28, 0.42))
	var img_morning := await _capture("sky_morning_layers", 7.3, 45.0, Vector3(0.0, 3.0, 0.0), Vector3(0.82, 0.34, 0.45))
	var img_night := await _capture("sky_night_moon", 0.8, 210.0, Vector3(0.0, 3.0, 0.0), Vector3(-0.3, 0.48, -0.82))

	if img_noon != null and not img_noon.is_empty():
		var min_l := 1.0
		var max_l := 0.0
		var diff_t := 0.0
		var w := img_noon.get_width()
		var h := int(img_noon.get_height() * 0.55)
		for y in range(20, h, 8):
			for x in range(20, w - 20, 8):
				var c := img_noon.get_pixel(x, y)
				var l := c.get_luminance()
				min_l = minf(min_l, l)
				max_l = maxf(max_l, l)
				if img_noon_t2 != null:
					var c2 := img_noon_t2.get_pixel(x, y)
					diff_t += absf(c.r - c2.r) + absf(c.g - c2.g) + absf(c.b - c2.b)
		_check(max_l - min_l > 0.22, "контраст облаков и неба днём: %.3f" % (max_l - min_l))
		_check(diff_t > 10.0, "облака живут и движутся во времени: %.1f" % diff_t)

	if img_sunset != null and not img_sunset.is_empty():
		var warm_pixels := 0
		for y in range(30, int(img_sunset.get_height() * 0.6), 10):
			for x in range(30, img_sunset.get_width() - 30, 10):
				var c := img_sunset.get_pixel(x, y)
				if c.r > c.b * 1.15 and c.r > 0.45:
					warm_pixels += 1
		_check(warm_pixels > 25, "тёплая закатная подсветка облачных ярусов: %d" % warm_pixels)

	print("SKY_LOOK failures=", fails)
	quit(1 if fails else 0)
