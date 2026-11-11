extends RefCounted
## One quality policy for the game and capture tools. No changes to vegetation
## density, shadow proxies or LOD ranges. Medium is the baseline GPU budget.
static func apply(env: Environment, sun: DirectionalLight3D, level: int, shadows: bool) -> void:
	level = clampi(level, 0, 2)
	var forward_plus := RenderingServer.get_current_rendering_method() == "forward_plus"
	sun.shadow_enabled = shadows
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
	env.ssao_enabled = forward_plus and level >= 1
	env.ssao_radius = 0.75
	env.ssao_intensity = 0.65
	env.ssao_detail = 0.2
	env.ssao_light_affect = 0.0
	env.ssil_enabled = forward_plus and level == 2
	env.ssil_radius = 3.0
	env.ssil_intensity = 0.3
	env.ssil_normal_rejection = 0.8
	# Fast rides and a moving headlamp: no temporal volumetric trails or GI
	# cascade updates. Height/distance fog supplies atmosphere on every tier.
	env.volumetric_fog_enabled = false
	env.sdfgi_enabled = false
