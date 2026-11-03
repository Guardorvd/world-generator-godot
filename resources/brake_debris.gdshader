shader_type spatial;
// Шейдер твёрдых частиц из-под колёс: камешки гравия, комья земли и дёрна, песчинки,
// хвоинки/листья, травинки, комочки снега, капли воды и раскалённые искры тормозов/камня.
// INSTANCE_CUSTOM:
//   x — возраст (0..1),
//   y — вид частицы (0: камень/ком земли, 1: травинка/лист/хвоя, 2: снежинка/капля, 3: искра),
//   z — случайное зерно (0..1),
//   w — яркость свечения (для искр, > 0).
render_mode blend_mix, depth_draw_opaque, cull_disabled;

varying vec4 v_custom;
varying vec4 v_color;
varying vec3 v_local;

void vertex() {
	v_custom = INSTANCE_CUSTOM;
	v_color = COLOR;
	v_local = VERTEX;
}

void fragment() {
	float age = clamp(v_custom.x, 0.0, 1.0);
	float kind = v_custom.y;
	float seed = v_custom.z;
	float glow = v_custom.w;

	// Гранёная вариация оттенка по нормали и зерну, чтобы камешки и комья не выглядели одинаковыми
	float facet = fract(sin(dot( floor(v_local * 40.0), vec3(12.9898, 78.233, 37.719) ) + seed * 17.0) * 43758.5453);
	vec3 col = v_color.rgb * (0.84 + 0.30 * facet);

	if (glow > 0.01) {
		// Раскалённая искра от ротора или удара по камню: от бело-жёлтого ядра к оранжево-красному
		float cool = clamp(age * 1.15, 0.0, 1.0);
		vec3 hot_col = mix(vec3(1.0, 0.92, 0.55), vec3(1.0, 0.28, 0.04), cool);
		ALBEDO = hot_col;
		EMISSION = hot_col * (3.8 * glow * (1.0 - age * 0.75));
		ROUGHNESS = 0.2;
	} else {
		ALBEDO = col;
		EMISSION = vec3(0.0);
		ROUGHNESS = (abs(kind - 2.0) < 0.4) ? 0.25 : 0.88;
		SPECULAR = (abs(kind - 2.0) < 0.4) ? 0.65 : 0.18;
	}
}
