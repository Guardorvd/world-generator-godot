shader_type spatial;
// Шейдер тормозного диска (FrontWheel/BrakeRotor, RearWheel/BrakeRotor).
// Стальной диск с перфорацией, концентрическими дорожками колодок и тепловым накалом:
// при затяжном или экстремальном торможении рабочая дорожка раскаляется сильнее всего
// на выходе из калипера и остывает по ходу вращения и обдува.
render_mode blend_mix, depth_draw_opaque, cull_disabled;

uniform float heat : hint_range(0.0, 1.0) = 0.0;
uniform float wheel_angle = 0.0;
uniform float caliper_angle = 2.35; // угол положения калипера в плоскости колеса

varying vec3 local_pos;

void vertex() {
	local_pos = VERTEX;
}

void fragment() {
	// TorusMesh в build_bike.gd лежит в плоскости XZ до поворота sideways (Basis(FORWARD, PI/2))
	vec2 ring_p = local_pos.xz;
	float r = length(ring_p);
	float angle = atan(ring_p.y, ring_p.x);

	// Концентрические борозды от тормозных колодок и косые вентиляционные прорези ротора
	float grooves = sin(r * 950.0) * 0.5 + 0.5;
	float slots = sin(angle * 12.0 + r * 85.0);
	float slot_mask = smoothstep(-0.55, -0.35, slots);

	vec3 steel = mix(vec3(0.56, 0.59, 0.60), vec3(0.76, 0.79, 0.80), grooves * 0.6 + slot_mask * 0.4);
	// Рабочая дорожка колодок (внешняя часть кольца ротора 0.047..0.083)
	float pad_band = smoothstep(0.047, 0.054, r) * (1.0 - smoothstep(0.079, 0.084, r));
	steel = mix(steel, vec3(0.26, 0.22, 0.20), pad_band * clamp(heat * 0.75, 0.0, 0.6));

	// Угол точки диска в отсчёте вилки (с учётом вращения колеса wheel_angle)
	float world_ang = angle - wheel_angle;
	float trail = mod(world_ang - caliper_angle + 6.2831853, 6.2831853) / 6.2831853;
	float angular_hot = mix(1.0, 0.52 + 0.48 * (1.0 - trail), smoothstep(0.0, 0.65, heat));
	float local_heat = clamp(heat * (0.35 + 0.65 * pad_band) * angular_hot * (0.85 + 0.15 * grooves), 0.0, 1.0);

	// Цветовая шкала каления стали: вишнёво-красный -> ярко-оранжевый -> золотисто-жёлтый у калипера
	vec3 glow_col = mix(vec3(0.90, 0.12, 0.02), vec3(1.0, 0.48, 0.05), smoothstep(0.15, 0.65, local_heat));
	glow_col = mix(glow_col, vec3(1.0, 0.88, 0.42), smoothstep(0.65, 1.0, local_heat));

	ALBEDO = mix(steel, glow_col * 0.65, smoothstep(0.28, 0.88, local_heat));
	METALLIC = 0.78 * (1.0 - smoothstep(0.25, 0.90, local_heat) * 0.45);
	ROUGHNESS = mix(0.28 + (1.0 - slot_mask) * 0.18, 0.42, local_heat);
	EMISSION = glow_col * (smoothstep(0.30, 0.96, local_heat) * 4.5);
}
