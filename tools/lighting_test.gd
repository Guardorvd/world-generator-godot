extends SceneTree
## State/quality regression without reading or writing the player's profile.
const Quality := preload("res://scripts/render/lighting_quality.gd")
var failures := 0

func check(value: bool, label: String) -> void:
	if not value:
		failures += 1
		printerr(label)

func _initialize() -> void:
	var settings := GameSettings.new()
	var cfg := ConfigFile.new()
	cfg.set_value("view", "lighting", NAN)
	settings._apply_config(cfg)
	check(settings.lighting == 1, "invalid quality fallback")
	cfg.set_value("view", "lighting", 20)
	settings._apply_config(cfg)
	check(settings.lighting == 2, "quality clamp")
	settings.settings_path = "res://.godot/lighting_test.cfg"
	check(settings.save_settings() == OK, "save isolated settings")
	var restored := GameSettings.new()
	restored.settings_path = settings.settings_path
	restored.load_settings()
	check(restored.lighting == 2, "quality survives save/load")
	restored.reset_defaults()
	check(restored.lighting == 1, "balanced default")
	var env := Environment.new()
	var sun := DirectionalLight3D.new()
	var cycle := DayCycle.new(env, sun)
	for level in 3:
		Quality.apply(env, sun, level, false)
		check(cycle.sky_mat.get_shader_parameter("cumulus_steps") == (5 if level == 2 else 2), "cumulus steps follow lighting quality")
		check(not sun.shadow_enabled, "independent shadow toggle")
		check(not env.volumetric_fog_enabled and not env.sdfgi_enabled, "no streaming GI or temporal fog")
		Quality.apply(env, sun, level, true)
		check(sun.shadow_enabled, "shadows restored")
		check(sun.directional_shadow_max_distance <= 190.0, "preserve distant caster budget")
	Quality.apply(env, sun, 1, true)
	check(cycle.sky_mat.get_shader_parameter("cumulus_steps") == 2, "cumulus steps return to medium from high")
	for i in 1441:
		var hour := i / 60.0
		cycle.apply(hour, 0.0)
		check(is_finite(sun.light_energy) and sun.light_energy >= 0.0, "finite light through day")
		check(env.fog_height == DayCycle.MIST_TOP, "world anchored mist")
	cycle.cloud_cover_override = 0.1
	cycle.apply(12.0, 0.0)
	var clear_direct := sun.light_energy
	var clear_ambient := env.ambient_light_energy
	cycle.cloud_cover_override = 0.8
	cycle.apply(12.0, 0.0)
	check(sun.light_energy < clear_direct * 0.5, "overcast softens direct light")
	check(env.ambient_light_energy > clear_ambient, "overcast preserves sky fill")
	for hour in [0.0, 6.0, 18.0, 24.0]:
		cycle.apply(hour - 0.0001, 0.0)
		var before := sun.light_energy
		cycle.apply(hour + 0.0001, 0.0)
		check(absf(sun.light_energy - before) < 0.001, "horizon/midnight continuity")
	sun.free()
	print("lighting_test: %d failures" % failures)
	quit(1 if failures else 0)
