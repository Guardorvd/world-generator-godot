extends RefCounted
## One quality policy for the game and capture tools. Medium is the baseline GPU budget.
const SKY_SHADER := preload("res://resources/sky.gdshader")

static func apply(env: Environment, sun: DirectionalLight3D, level: int, shadows: bool, fog_quality := -1) -> void:
	level = clampi(level, 0, 2)
	# Capture tools without a fog preset still use their single quality argument.
	var fog_level := level if fog_quality == -1 else clampi(fog_quality, 0, 2)
	if env.sky != null:
		var material := env.sky.sky_material as ShaderMaterial
		if material != null and material.shader == SKY_SHADER:
			material.set_shader_parameter("cumulus_steps", 5 if level == 2 else 2)
	var forward_plus := RenderingServer.get_current_rendering_method() == "forward_plus"
	sun.shadow_enabled = shadows
	apply_shadows(sun, level)
	env.ssao_enabled = forward_plus and level >= 1
	# 15.1: SSAO стоит около 1,5 мс кадра в лесу (стресс-тест), но качество выборок почти ни при чём:
	# «очень низкое» снимает лишь 0,2–0,3 мс — основная цена в обязательных проходах. Качество не трогаем.
	env.ssao_radius = 0.75
	env.ssao_intensity = 0.65
	env.ssao_detail = 0.2
	env.ssao_light_affect = 0.0
	env.ssil_enabled = forward_plus and level == 2
	env.ssil_radius = 3.0
	env.ssil_intensity = 0.3
	env.ssil_normal_rejection = 0.8
	# Ordinary fog covers distances beyond the volumetric range.
	env.volumetric_fog_enabled = forward_plus and fog_level >= 1
	env.volumetric_fog_length = 160.0 if fog_level < 2 else 190.0
	env.volumetric_fog_detail_spread = 0.65
	env.volumetric_fog_anisotropy = 0.65
	env.volumetric_fog_ambient_inject = 0.35
	env.volumetric_fog_sky_affect = 0.0
	env.volumetric_fog_temporal_reprojection_enabled = true
	env.volumetric_fog_temporal_reprojection_amount = 0.75
	if env.volumetric_fog_enabled:
		RenderingServer.environment_set_volumetric_fog_volume_size(96 if fog_level == 1 else 128, 64 if fog_level == 1 else 96)
	env.sdfgi_enabled = false


## Каскады теней солнца по уровню качества (отдельно — для стендов без окружения, tools/stress)
static func apply_shadows(sun: DirectionalLight3D, level: int) -> void:
	level = clampi(level, 0, 2)
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS if level == 0 else DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS
	sun.directional_shadow_max_distance = 110.0 if level == 0 else 190.0
	sun.directional_shadow_split_1 = 0.18 if level == 0 else 0.09
	sun.directional_shadow_split_2 = 0.26
	sun.directional_shadow_split_3 = 0.55
	sun.directional_shadow_blend_splits = true
	sun.directional_shadow_fade_start = 0.7
	sun.shadow_bias = 0.04
	sun.shadow_normal_bias = 1.2
	sun.shadow_blur = 1.25
