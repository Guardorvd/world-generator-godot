shader_type spatial;
// Шейдер следов торможения, сноса и прорезанных колей на земле и настилах.
// Лента строится в мировых координатах (ImmediateMesh):
//   UV.x      — поперечная координата (0..1, 0.5 — середина шины),
//   UV.y      — метры вдоль следа (для шашек протектора и продольной зернистости),
//   UV2.x     — нормированный возраст точки (0 — свежий, 1 — исчез),
//   UV2.y     — код покрытия + дробная часть = сила юза/борозды (floor(UV2.y) = kind, fract(UV2.y) = intensity),
//   COLOR.rgb — базовый цвет следа в точке, COLOR.a — прозрачность контакта (0 на разрывах).
render_mode blend_mix, depth_draw_never, cull_disabled, shadows_disabled;

varying vec3 world_pos;

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

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	float age = clamp(UV2.x, 0.0, 1.0);
	float kind = floor(UV2.y + 0.001);
	float power = clamp(fract(UV2.y) * 1.05, 0.0, 1.0);
	float across = UV.x * 2.0 - 1.0; // -1..1
	float abs_x = abs(across);

	// 1. Рваная кромка следа по мировому шуму
	float edge_n = noise2d(world_pos.xz * 14.0 + vec2(kind * 3.7, UV.y * 2.5));
	float fine_n = noise2d(world_pos.xz * 42.0);
	float rim_warp = abs_x + (edge_n - 0.5) * 0.24 * (0.4 + 0.6 * power);
	float mask = 1.0 - smoothstep(0.66, 0.98, rim_warp);

	// 2. Двухрядный протектор шины (соответствует двум рядам шашек в tools/build_bike.gd)
	float lug_row = smoothstep(0.10, 0.26, abs_x) * (1.0 - smoothstep(0.64, 0.86, abs_x));
	float lug_step = sin(UV.y * 56.0 + sign(across) * 1.57);
	// При сильном юзе (power -> 1) шашки сливаются в сплошную продольную полосу скольжения
	float tread = mix(smoothstep(-0.2, 0.55, lug_step) * lug_row + 0.35 * (1.0 - abs_x), 1.0, power * 0.72);

	// 3. Поперечный профиль борозды: темнее в середине, светлый выдавленный валик по краям на рыхлом грунте
	float loose = (kind < 3.5 || (kind > 4.5 && kind < 8.5)) ? 1.0 : 0.0; // гравий, грунт, песок, лес, трава, снег
	float center_trough = 1.0 - smoothstep(0.0, 0.62, abs_x);
	float side_berm = smoothstep(0.42, 0.72, abs_x) * (1.0 - smoothstep(0.72, 0.96, abs_x)) * loose * power;

	vec3 col = COLOR.rgb;
	// Вдавленное дно колеи чуть темнее и влажнее, буртик по краям — светлее
	col *= mix(1.0, 0.70 + 0.15 * fine_n, center_trough * (0.45 + 0.55 * power));
	col = mix(col, col * 1.32 + vec3(0.05), side_berm * 0.65);

	// На камне (kind == 4) и досках (kind == 9) — продольные тёмные нити стёртой резины и светлые царапины
	if (abs(kind - 4.0) < 0.4 || abs(kind - 9.0) < 0.4) {
		float streak = noise2d(vec2(across * 9.0, UV.y * 6.0));
		col = mix(col, col * (0.65 + 0.6 * streak), 0.6);
	}

	// Затухание со временем: края тают раньше середины
	float fade = (1.0 - age * age) * smoothstep(1.0, 0.72, age + abs_x * 0.22);
	float alpha = COLOR.a * mask * clamp(tread * 0.75 + side_berm * 0.5, 0.0, 1.0) * fade;

	ALBEDO = col;
	ROUGHNESS = ( abs(kind - 8.0) < 0.4 ) ? 0.35 : 0.92; // мокрый след блестит сильнее
	SPECULAR = ( abs(kind - 8.0) < 0.4 ) ? 0.55 : 0.12;
	ALPHA = clamp(alpha, 0.0, 0.88);
}
