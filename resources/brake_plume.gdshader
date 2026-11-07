shader_type spatial;
// Шейдер клубов пыли, дыма из-под покрышек, снежной пудры и водяного тумана при торможении.
// Каждый экземпляр MultiMesh поворачивается к камере (billboard_keep_scale), а внутри плоскости
// вращается и клубится процедурным FBM-шумом с мягким растворением у земли (soft particles).
// INSTANCE_CUSTOM:
//   x — фаза жизни (0 — только родился, 1 — растворился),
//   y — вид (0: пыль/песок, 1: дым резины/камня, 2: снежная пудра, 3: водяная взвесь),
//   z — случайное зерно и угол вращения,
//   w — плотность/интенсивность.
render_mode blend_mix, depth_draw_never, cull_disabled, shadows_disabled;

uniform sampler2D depth_tex : hint_depth_texture, filter_nearest;

#include "res://resources/cloud_shadow.gdshaderinc"

varying vec4 v_custom;
varying vec4 v_color;
varying float v_cloud;

float hash12(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}

float noise2d(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	float a = hash12(i);
	float b = hash12(i + vec2(1.0, 0.0));
	float c = hash12(i + vec2(0.0, 1.0));
	float d = hash12(i + vec2(1.0, 1.0));
	return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

float fbm(vec2 p) {
	float v = 0.0;
	v += 0.52 * noise2d(p);
	v += 0.31 * noise2d(p * 2.15 + vec2(17.3, 9.1));
	v += 0.17 * noise2d(p * 4.4 - vec2(5.7, 21.4));
	return v;
}

void vertex() {
	v_custom = INSTANCE_CUSTOM;
	v_color = COLOR;
	v_cloud = cloud_light(MODEL_MATRIX[3].xz);
	MODELVIEW_MATRIX = VIEW_MATRIX * mat4(
		vec4(normalize(INV_VIEW_MATRIX[0].xyz) * length(MODEL_MATRIX[0].xyz), 0.0),
		vec4(normalize(INV_VIEW_MATRIX[1].xyz) * length(MODEL_MATRIX[1].xyz), 0.0),
		vec4(normalize(INV_VIEW_MATRIX[2].xyz) * length(MODEL_MATRIX[2].xyz), 0.0),
		MODEL_MATRIX[3]
	);
	NORMAL = vec3(0.0, 0.85, 0.52);
}

void fragment() {
	float age = clamp(v_custom.x, 0.0, 1.0);
	float kind = v_custom.y;
	float seed = v_custom.z;
	float density = clamp(v_custom.w, 0.0, 1.5);

	vec2 p = UV * 2.0 - 1.0;
	// Вращение клуба в экранной плоскости по мере подъёма
	float spin = seed * 6.2831853 + age * ((seed > 0.5) ? 1.65 : -1.65);
	float cs = cos(spin);
	float sn = sin(spin);
	vec2 rp = vec2(p.x * cs - p.y * sn, p.x * sn + p.y * cs);

	// Искажение контура шумом, чтобы клуб не выглядел ровным кругом
	vec2 warp_uv = rp * 2.1 + vec2(seed * 19.3, seed * 31.7 - age * 1.1);
	float n = fbm(warp_uv);
	float n2 = fbm(rp * 3.8 - vec2(age * 1.4, seed * 11.0));
	float dist = length(p) + (n - 0.5) * 0.42 + (n2 - 0.5) * 0.22;
	if (dist > 1.02) {
		discard;
	}

	// Мягкое ядро и рваные клубящиеся края, тающие с возрастом
	float shape = 1.0 - smoothstep(0.18, 0.96, dist);
	float erosion = smoothstep(age * 0.55, age * 0.55 + 0.45, shape * (0.65 + 0.55 * n));
	float life_curve = smoothstep(0.0, 0.10, age) * (1.0 - age) * (1.0 - age * 0.45);

	// Мягкое пересечение с землёй и колёсами (soft particles)
	float depth = texture(depth_tex, SCREEN_UV).r;
	#if CURRENT_RENDERER == RENDERER_COMPATIBILITY
		vec3 ndc = vec3(SCREEN_UV, depth) * 2.0 - 1.0;
	#else
		vec3 ndc = vec3(SCREEN_UV * 2.0 - 1.0, depth);
	#endif
	vec4 scene = INV_PROJECTION_MATRIX * vec4(ndc, 1.0);
	float scene_z = -scene.z / scene.w;
	float frag_z = -VERTEX.z;
	float soft = clamp((scene_z - frag_z) / 0.22, 0.0, 1.0);
	soft *= clamp((frag_z - 0.25) / 0.45, 0.0, 1.0);

	// Объёмная светотень внутри облачка пыли/дыма и мягкое просвечивание тонких краёв на просвет
	float billow = clamp(0.52 - p.y * 0.35 + (n - 0.48) * 0.45, 0.0, 1.0);
	vec3 col = v_color.rgb * mix(0.76, 1.18, billow) * v_cloud;
	if (abs(kind - 2.0) < 0.4 || abs(kind - 3.0) < 0.4) {
		col += vec3(0.08, 0.10, 0.12) * smoothstep(0.58, 0.82, n2) * v_cloud;
	}

	ALBEDO = col;
	BACKLIGHT = col * 0.42;
	ROUGHNESS = (abs(kind - 3.0) < 0.4) ? 0.35 : 0.95;
	ALPHA = clamp(erosion * life_curve * v_color.a * density * soft, 0.0, 0.85);
}
