// 6.7: общий материал растительности вместо StandardMaterial3D — тот же цвет вершин/экземпляра
// и текстура, плюс ветер и свет под кронами. Обёртки задают только отсечение и вырез:
// vegetation.gdshader (двусторонний), vegetation_trunk.gdshader, vegetation_cutout.gdshader.
//
// Ветер: медленный наклон всего растения, растущий к верхушке (общий для ствола и кроны,
// поэтому листва не отрывается от веток), и мелкая дрожь листвы. Порывы идут волной по лесу.
// Свет: снизу и внутри кроны меньше рассеянного света неба (AO), листья просвечивают
// против солнца (BACKLIGHT). Альфа цвета экземпляра травы и подлеска — открытость неба над ним.

uniform sampler2D albedo_tex : source_color, hint_default_white, filter_linear_mipmap, repeat_enable;
uniform vec4 albedo_color : source_color = vec4(1.0);
uniform bool use_vertex_color = true;
uniform float height = 1.0;        // м в модели: высота, где наклон полный
uniform float sway = 0.0;          // м на верхушке при обычном ветре
uniform float flutter = 0.0;       // м: дрожь листьев и травинок
uniform float sway_speed = 1.0;    // крупные и жёсткие растения качаются медленнее
uniform float ao_low = 1.0;        // доля света неба у основания / в глубине кроны
uniform float translucency = 0.0;  // просвечивание листвы против солнца
uniform float shelter_ao = 0.8;    // свет неба под сомкнутым пологом (по альфе экземпляра; 9.4: светлее)
// 16.11: прямой свет солнца у основания куртины (1 — без затенения). Трава теней не отбрасывает (дорого: ~1 млн
// треугольников ковра и травы), поэтому низ пучка — там, где травинки заслоняют друг друга, — затеняется здесь.
uniform float base_shade = 1.0;
// 16.11: камни — затемнение света неба у линии контакта с землёй (сила; 0 — нет), полоса в метрах вдоль оси камня
uniform float rock_contact = 0.0;
// 9.9+: растворение у края дальности прорисовки. Растение целиком (по своему основанию) редеет
// точками экрана от fade_far - fade_len до fade_far от игрока (veg_center, ставит VegetationLayer.update).
// Дальше fade_far его не видно, поэтому чанк или новая раскладка травы за этой границей появляются незаметно.
uniform float fade_far = 1.0e9;
uniform float fade_len = 1.0;
global uniform vec2 veg_center;
global uniform float vegetation_clock;
global uniform float vegetation_night;
// All vegetation carries its fade timestamp in MultiMesh custom data. Per-node
// instance uniforms exhaust the shared hardware buffer in a streamed forest.
// Поредение травы и подлеска дальше thin_full (м, 0 — нет): остаётся доля (thin_full / расстояние)²;
// экземпляр с порогом INSTANCE_CUSTOM.x гаснет, когда доля опускается от 1,3 порога до порога.
// Считается по нынешнему расстоянию, а не по раскладке: новая раскладка ничего не включает рывком.
// thin_grow — пучки за thin_full крупнее, тоже по нынешнему расстоянию.
uniform float thin_full = 0.0;
uniform float thin_grow = 0.0;
uniform float thin_spread = 0.0; // 17.11.2026: 0 — как прежде; иначе наибольшее раздвижение групповой формы в стороны
// 17.11.2026: ближняя граница (x — от, y — полоса, м; y = 0 — нет): дерновины средних дистанций не видны у игрока
uniform vec2 near_fade = vec2(0.0);
// 17.11.2026: смена ближней формы подлеска на упрощённую по нынешнему расстоянию до игрока (x — граница, y — полоса, м;
// z: 0 — нет, 1 — ближняя форма, 2 — упрощённая). Только у пар (INSTANCE_CUSTOM.z >= 1.5, VegetationLayer._put_twin):
// пиксель берёт ровно одну форму той же сеткой порогов, что уровни LOD деревьев.
uniform vec3 form_switch = vec3(0.0);
// У дальнего меша куртин UV2.y отмечает группу кочек. x/y — середина и ширина второго перехода, z — высота кочек для ветра.
uniform vec3 form_group_lod = vec3(0.0);
// Только общий меш травы: лёгкий индивидуальный наклон каждого листа.
uniform bool grass_variation = false;
// 14.11.2026: дернина расступается у игрока (veg_center): м отклонения кончиков в полуметре от него, 0 — нет.
uniform float trample = 0.0;
// Семантическое поредение листьев в UV2.x. Стебли имеют ранг 0 и сохраняются.
// Решается для каждого растения, без копий буферов MultiMesh на каждый LOD.
uniform float detail_full = 0.0;
uniform float detail_far = 1.0;
uniform float detail_keep = 1.0;
uniform bool directional_carpet = false;
#include "res://resources/ground_carpet.gdshaderinc"
// 9.9+: уровень детализации дерева у материала (-1 — без смены уровней; у каждого уровня своя копия материала). Соседние уровни смешиваются той же сеткой
// порогов на полосах LOD1_* и LOD2_*: пиксель берёт ровно один уровень, без дыр и двойной листвы.
// Расстояния — VegetationLayer.LOD_STEPS (там же диапазоны видимости узлов).
uniform int lod_level = -1;
// 19.11.2026: тень только вблизи игрока (м; 0 — без ограничения). Подлесок — один MultiMesh на весь круг 300 м и
// попадал во все 4 каскада теней (~72 % теневых треугольников леса); дальше shadow_far его тень в 6–8 м
// от растения не различить. В полосе SHADOW_FAR_BAND тень сжимается к основанию, а не исчезает разом.
uniform float shadow_far = 0.0;
const float SHADOW_FAR_BAND = 15.0;
const float LOD1_D = 72.0;
const float LOD1_BAND = 20.0;
const float LOD2_D = 165.0;
const float LOD2_BAND = 40.0;

#include "res://resources/cloud_shadow.gdshaderinc"
#include "res://resources/depth_tone.gdshaderinc"

const vec2 WIND_DIR = vec2(0.82, 0.57);

varying float v_ao;
varying float v_cloud;   // 7.9: тень облака на растении (одна на экземпляр)
varying float v_fade;    // 9.9+: 1 — видно целиком, 0 — растворилось
varying vec2 v_lod;      // 9.9+: порог пикселя должен быть в [x, y), иначе этот уровень его не рисует
#ifdef ROCK_DETAIL
varying vec3 rock_local;
varying vec3 rock_world_normal;
varying float rock_contact_v;
#endif
#ifdef BARK
// 11.11.2026: кора. 0 — нет (кусты, кактусы, тростник), 1 — пластины с бороздами (дуб, сосна, ель, пальма),
// 2 — берёза: гладкая кора с тёмными чечевичками, у комля — грубая. Ставит VegetationLayer по породе.
// Рисунок — в координатах модели (по окружности ствола и высоте), цвет породы остаётся из вершин и материала.
// У комля ствол темнее, с северной стороны — мох. Рельеф — светом, гаснет по размеру пикселя.
uniform float bark_detail = 0.0;
varying vec3 bark_local;
varying vec3 bark_local_nrm;
varying float bark_north;
#endif

void vertex() {
	vec3 origin = MODEL_MATRIX[3].xyz;
	float dist = distance(origin.xz, veg_center);
	bool form_twin = form_switch.z > 0.5 && INSTANCE_CUSTOM.z >= 1.5;
	bool has_group_lod = form_group_lod.y > 0.0;
	bool coarse_form = has_group_lod && UV2.y > 0.5;
	v_lod = vec2(0.0, 2.0);
	if (form_twin || has_group_lod) {
		float s = form_twin ? smoothstep(form_switch.x - form_switch.y * 0.5, form_switch.x + form_switch.y * 0.5, dist) : 1.0;
		float s2 = has_group_lod ? min(s, smoothstep(form_group_lod.x - form_group_lod.y * 0.5, form_group_lod.x + form_group_lod.y * 0.5, dist)) : 0.0;
		v_lod = form_switch.z < 1.5 ? vec2(s, 2.0) : (coarse_form ? vec2(0.0, s2) : vec2(s2, s));
	} else if (lod_level >= 0) {
		float s1 = smoothstep(LOD1_D - LOD1_BAND * 0.5, LOD1_D + LOD1_BAND * 0.5, dist);
		float s2 = smoothstep(LOD2_D - LOD2_BAND * 0.5, LOD2_D + LOD2_BAND * 0.5, dist);
		v_lod = lod_level == 0 ? vec2(s1, 2.0) : (lod_level == 1 ? vec2(s2, s1) : vec2(0.0, s2));
	}
	bool lod_hidden = v_lod.x >= min(v_lod.y, 1.0);
#ifdef BARK
	bark_local = VERTEX;
	bark_local_nrm = NORMAL;
	bark_north = dot(normalize(mat3(MODEL_MATRIX) * NORMAL), vec3(-0.45, 0.0, -0.89));
#endif
	float h = clamp(VERTEX.y / (coarse_form ? form_group_lod.z : height), 0.0, 1.0);
	float custom_z = form_twin ? INSTANCE_CUSTOM.z - 2.0 : INSTANCE_CUSTOM.z;
	if (grass_variation && !lod_hidden) {
		float seed = INSTANCE_CUSTOM.y * 6.2831853 + UV.x * 17.0;
		float bend = UV.y * (0.35 + 0.65 * UV.y);
		VERTEX.xz = VERTEX.xz * mix(1.16, 0.92, custom_z) + vec2(cos(seed), sin(seed)) * (0.04 + custom_z * 0.08) * bend;
		VERTEX.y *= mix(0.84, 1.18, fract(seed * 0.381966 + custom_z * 0.5));
	}
	float sheltered = 1.0 - COLOR.a;
	float fade_dist = directional_carpet ? carpet_fade_distance(origin.xz - veg_center) : dist;
	v_fade = clamp((fade_far - fade_dist) / fade_len, 0.0, 1.0);
	if (near_fade.y > 0.0) {
		v_fade *= clamp((dist - near_fade.x) / near_fade.y, 0.0, 1.0);
	}
#ifdef ROCK_DETAIL
	rock_local = VERTEX;
	float rock_scale = length(MODEL_MATRIX[0].xyz);
	float rock_far = min(fade_far, mix(55.0, fade_far, smoothstep(0.18, 0.85, rock_scale)));
	// 09.11.2026: крупные скалы и массивы — силуэт дальнего склона: целиком до самого края дальности,
	// короткая полоса растворения вместо сотни метров точечного узора на вершинах.
	float rock_band = min(fade_len, max(10.0, rock_far * 0.22));
	v_fade = clamp((rock_far - dist) / mix(rock_band, min(rock_band, 18.0), smoothstep(0.9, 1.3, rock_scale)), 0.0, 1.0);
#endif
	float stamp = INSTANCE_CUSTOM.w;
	if (stamp > 0.0) {
		v_fade *= clamp((vegetation_clock - stamp) / 0.5, 0.0, 1.0);
	} else if (stamp < 0.0) {
		v_fade *= 1.0 - clamp((vegetation_clock + stamp) / 0.5, 0.0, 1.0);
	}
	if (thin_full > 0.0 && !lod_hidden) {
		float keep = min(1.0, thin_full * thin_full / max(dist * dist, 1.0));
		float rank = INSTANCE_CUSTOM.x;
		if (rank > 0.0) {
			v_fade *= clamp((keep - rank) / max(min(1.0, rank * 1.3) - rank, 1e-4), 0.0, 1.0);
		}
		float grow = 1.0 + thin_grow * (1.0 - keep);
		// 17.11.2026: групповые формы раздвигаются в стороны как 1/√keep (покрытие земли не падает), до thin_spread раз
		float spread = thin_spread > 0.0 ? max(grow, min(inversesqrt(max(keep, 1e-4)), thin_spread)) : grow;
		VERTEX *= vec3(spread, grow, spread);
	}
	if (detail_full > 0.0 && !lod_hidden) {
		float detail_dist = directional_carpet ? carpet_detail_distance(origin.xz - veg_center) : dist;
		float keep_detail = mix(1.0, detail_keep, smoothstep(detail_full, detail_far, detail_dist));
		v_fade *= clamp((keep_detail - UV2.x) * 10.0 + 1.0, 0.0, 1.0);
	}
	// Проход теней солнца — ортогональная проекция (у камеры игры — перспективная).
	if (shadow_far > 0.0 && PROJECTION_MATRIX[3][3] > 0.5) {
		float shadow_keep = 1.0 - smoothstep(shadow_far - SHADOW_FAR_BAND, shadow_far, dist);
		if (shadow_keep <= 0.0) {
			v_fade = 0.0;
		} else {
			VERTEX *= shadow_keep;
		}
	}
	// Скрытый LOD не тратит вычисления на ветер, цвет и облака.
	if (v_fade <= 0.0 || lod_hidden) {
		VERTEX = vec3(0.0);
		v_cloud = 1.0;
		v_ao = 1.0;
	} else {
		if (sway > 0.0 || flutter > 0.0) {
			// Порыв: медленная волна вдоль ветра и вторая, поперёк, чтобы соседние деревья не качались строем.
			float along = dot(origin.xz, WIND_DIR);
			float gust = 0.55 + 0.3 * sin(TIME * 0.31 - along * 0.035) + 0.15 * sin(TIME * 0.83 + origin.x * 0.11 + origin.z * 0.07);
			float phase = fract(sin(dot(origin.xz, vec2(12.99, 78.23))) * 437.58) * 6.28318;
			float swing = gust * (0.7 + 0.3 * sin(TIME * 1.3 * sway_speed + phase));
			// Под пологом ветер слабее.
			swing *= 1.0 - sheltered * 0.6;
			vec3 world = vec3(WIND_DIR.x, 0.0, WIND_DIR.y) * swing * sway * h * h;
			// Дрожь: своя фаза у каждой вершины, сильнее к концам; не считается для стволов и дальнего LOD2.
			if (flutter > 0.0 && dist < LOD2_D) {
				float leaf = sin(TIME * 4.1 + dot(VERTEX, vec3(3.1, 2.3, 2.7)) + phase);
				float leaf_motion = 1.0 - smoothstep(LOD1_D, LOD2_D, dist) * 0.75;
				world += vec3(leaf, leaf * 0.5, -leaf * 0.7) * flutter * gust * h * leaf_motion;
			}
			if (trample > 0.0 && dist < 3.0) {
				// Травинки у колёс и ног ложатся от игрока и прижимаются к земле
				vec2 away = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xz - veg_center;
				float push = (1.0 - smoothstep(0.25, 1.25, length(away))) * trample * h;
				world += vec3(away.x, 0.0, away.y) / max(length(away), 0.05) * push - vec3(0.0, push * 0.55, 0.0);
			}
			// В локальные координаты экземпляра: поворот и масштаб из MODEL_MATRIX.
			mat3 basis = mat3(MODEL_MATRIX);
			float scale2 = max(dot(basis[0], basis[0]), 1e-4);
			VERTEX += transpose(basis) * world * (sqrt(scale2) / scale2);
		}
		v_cloud = cloud_light(origin.xz);
		float shelter = shelter_ao;
		v_ao = max(0.30, mix(ao_low, 1.0, h) * mix(1.0, shelter, sheltered));
		// v_cloud читает только light() и только для солнца: туда же — затенение низа куртины (без лишней переменной)
		v_cloud *= mix(base_shade, 1.0, smoothstep(0.0, 0.55, h));
#ifdef ROCK_DETAIL
		// Основание камня: модель стоит на опоре (локальная y = 0), опущена в землю на 8–12 % размера, ось — по нормали
		// склона (у выходов — между вертикалью и склоном). Метры над основанием вдоль оси; у земли меньше света неба —
		// щель, куда не заглядывает небо. Полоса — от линии погружения на 0,1–0,45 м (у мелких камней короче).
		float axis_m = length(MODEL_MATRIX[1].xyz);
		float h_rock = clamp(height, 0.16, 1.0);
		float up_m = VERTEX.y * axis_m - (0.1 * h_rock) * axis_m;
		float band = clamp(axis_m * 0.35 * h_rock, 0.06, 0.45);
		rock_contact_v = (1.0 - smoothstep(0.0, band, up_m)) * rock_contact;
		v_ao *= 1.0 - rock_contact_v;
		rock_world_normal = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
#endif
		if (use_vertex_color && !OUTPUT_IS_SRGB) {
			// как vertex_color_is_srgb у StandardMaterial3D
			COLOR.rgb = mix(pow((COLOR.rgb + vec3(0.055)) * (1.0 / 1.055), vec3(2.4)), COLOR.rgb * (1.0 / 12.92), lessThan(COLOR.rgb, vec3(0.04045)));
		}
	}
}

void fragment() {
	// Сетка порогов (interleaved gradient noise): без прозрачности и сортировки, тени редеют так же.
	float dither = fract(52.9829189 * fract(dot(FRAGCOORD.xy, vec2(0.06711056, 0.00583715))));
	if (dither < v_lod.x || dither >= v_lod.y) {
		discard;
	}
	// Each form reveals its own share of pixels during a snapshot fade.
	float reveal_dither = form_switch.z > 0.5 ? (dither - v_lod.x) / max(min(1.0, v_lod.y) - v_lod.x, 1e-4) : dither;
	if (v_fade < 1.0 && v_fade <= reveal_dither) {
		discard;
	}
#ifdef CUTOUT
	// Край объёма сохраняет силуэт даже на мелких mip-уровнях; углы карточки не рисуются и не отбрасывают тень.
	// Рябина (LOD0): UV.x > 1.5 отмечает карточки гроздьев ягод на той же поверхности кроны без доп. материалов и проходов.
	bool is_berry = UV.x > 1.5;
	vec2 cluster_uv = is_berry ? vec2(UV.x - 2.0, UV.y) : UV;
	float cluster_radius = length((cluster_uv - vec2(0.5)) * 2.0);
	if (cluster_radius >= 1.0) {
		discard;
	}
#endif
	// 9.4: у двусторонней листвы движок разворачивает нормаль обратной стороны вниз и внутрь кроны —
	// из-за этого половина листьев и травинок была почти чёрной. Возвращаем заданную нормаль модели.
	if (!FRONT_FACING) {
		NORMAL = -NORMAL;
	}
	vec4 tex = texture(albedo_tex, UV);
	vec3 col = albedo_color.rgb * tex.rgb;
#ifdef CUTOUT
	float berry_alpha = 1.0;
	if (is_berry) {
		vec2 p = cluster_uv;
		float bd = 9.0;
		bd = min(bd, length(p - vec2(0.50, 0.44)) / 0.16);
		bd = min(bd, length(p - vec2(0.32, 0.45)) / 0.15);
		bd = min(bd, length(p - vec2(0.68, 0.46)) / 0.15);
		bd = min(bd, length(p - vec2(0.40, 0.62)) / 0.15);
		bd = min(bd, length(p - vec2(0.60, 0.61)) / 0.15);
		bd = min(bd, length(p - vec2(0.50, 0.28)) / 0.14);
		bd = min(bd, length(p - vec2(0.51, 0.74)) / 0.13);
		berry_alpha = 1.0 - smoothstep(0.76, 1.0, bd);
		col = mix(vec3(0.96, 0.30, 0.045), vec3(0.58, 0.07, 0.012), clamp(bd * bd, 0.0, 1.0));
	}
#endif
	if (use_vertex_color) {
		col *= COLOR.rgb;
	}
	if (translucency > 0.0) {
		float neutral = dot(col, vec3(0.2126, 0.7152, 0.0722));
		col = mix(col, vec3(neutral), vegetation_night * 0.32);
	}
	ALBEDO = col;
	ROUGHNESS = 1.0;
#ifdef ROCK_DETAIL
	// Мелкое зерно и крап гранита затухают по производным: не мерцают на дальнем LOD.
	float footprint = max(length(dFdx(rock_local)), length(dFdy(rock_local)));
	float moss_rock = clamp((ALBEDO.g - ALBEDO.r) * 7.0, 0.0, 1.0);
	vec3 grain_cell = floor(rock_local * 145.0);
	float grain = fract(sin(dot(grain_cell, vec3(127.1, 311.7, 74.7))) * 43758.5453) * 2.0 - 1.0;
	vec3 speck_cell = floor(rock_local * 36.0);
	float speck = fract(sin(dot(speck_cell, vec3(269.5, 183.3, 419.2))) * 43758.5453) * 2.0 - 1.0;
	float strata = sin(dot(rock_local, vec3(2.4, 8.0, 3.7)) + sin(rock_local.x * 5.0) * 0.8 + sin(rock_local.z * 7.0) * 0.5);
	float vein = (1.0 - smoothstep(0.02, 0.07, abs(strata))) * (1.0 - smoothstep(0.015, 0.06, footprint)) * (1.0 - moss_rock * 0.8);
	float micro_f = 1.0 - smoothstep(0.0025, 0.014, footprint);
	ALBEDO *= 0.94 + (grain * 0.055 + speck * 0.04 * (1.0 - moss_rock * 0.6)) * micro_f;
	ALBEDO = mix(ALBEDO, ALBEDO * 1.2, vein * 0.13);
	float up_face = smoothstep(0.62, 0.88, normalize(rock_world_normal).y);
	float moss_blotch = smoothstep(-0.15, 0.45, sin(rock_local.x * 4.3 + sin(rock_local.z * 3.1) * 1.4) * cos(rock_local.z * 3.7 + rock_local.y * 2.2));
	float top_moss = up_face * moss_blotch * (1.0 - smoothstep(0.02, 0.08, footprint)) * 0.36;
	ALBEDO = mix(ALBEDO, ALBEDO * vec3(0.58, 0.78, 0.44), top_moss);
	ALBEDO = mix(ALBEDO, vec3(0.16, 0.14, 0.10), clamp(rock_contact_v * 0.42, 0.0, 0.5));
	float rock_vis = 1.0 - smoothstep(0.012, 0.065, footprint);
	float facet_n = sin(dot(rock_local, vec3(7.3, 4.1, 6.2)) + sin(rock_local.y * 11.0) * 0.6) * 0.35;
	float strata_h = (smoothstep(-0.25, 0.25, strata) - 0.5) * (1.0 - moss_rock * 0.7);
	float hh = (grain * 0.22 * micro_f + speck * 0.28 * micro_f + strata_h * 0.45 + facet_n * 0.35) * rock_vis * 0.018;
	vec3 dpx = dFdx(VERTEX);
	vec3 dpy = dFdy(VERTEX);
	vec3 r1 = cross(dpy, NORMAL);
	vec3 r2 = cross(NORMAL, dpx);
	float det = dot(dpx, r1);
	float dhx = clamp(dFdx(hh), -0.02, 0.02);
	float dhy = clamp(dFdy(hh), -0.02, 0.02);
	if (abs(det) > 1e-10) {
		NORMAL = normalize(abs(det) * NORMAL - sign(det) * (dhx * r1 + dhy * r2));
	}
	ROUGHNESS = mix(0.80, 0.96, max(max(moss_rock, top_moss), rock_contact_v * 0.7));
#endif
#ifdef BARK
	if (bark_detail > 2.5) {
		// Валежник, пни, сухостой и ветки: планарно-цилиндрическая проекция без полярных полос и швов на корнях.
		float fp = max(length(dFdx(bark_local)), length(dFdy(bark_local)));
		float vis = 1.0 - smoothstep(0.012, 0.055, fp);
		if (vis > 0.001) {
			float moss_w = clamp((ALBEDO.g - max(ALBEDO.r, ALBEDO.b)) * 7.0, 0.0, 1.0);
			float heart_w = clamp((ALBEDO.r - ALBEDO.b * 1.32 - 0.06) * 5.5 * smoothstep(0.26, 0.38, ALBEDO.r), 0.0, 1.0) * (1.0 - moss_w);
			bool upright = bark_detail >= 3.5;
			float ax = upright ? bark_local.y : bark_local.x;
			vec3 an = normalize(abs(bark_local_nrm) + vec3(0.001));
			float ua = upright ? bark_local.x : bark_local.z;
			float ub = upright ? bark_local.z : bark_local.y;
			float wa = upright ? an.z : an.y;
			float wb = upright ? an.x : an.z;
			float blend_w = (wa * wa) / max(wa * wa + wb * wb, 1e-4);
			float groove_damp = upright ? (1.0 - smoothstep(0.62, 0.90, an.y)) : 1.0;

			float pua = ua / 0.048 + sin(ax * 2.1 + ua * 4.5) * 0.42 + sin(ax * 6.8 - ua * 12.0) * 0.20;
			float fa = fract(pua);
			float plates_a = smoothstep(0.04, 0.30, min(fa, 1.0 - fa));
			float tone_a = 0.89 + 0.22 * fract(sin((floor(pua) + floor(ax * 1.65) * 7.0) * 78.233) * 43758.5453);

			float pub = ub / 0.048 + sin(ax * 2.1 + ub * 4.5 + 1.3) * 0.42 + sin(ax * 6.8 - ub * 12.0) * 0.20;
			float fb = fract(pub);
			float plates_b = smoothstep(0.04, 0.30, min(fb, 1.0 - fb));
			float tone_b = 0.89 + 0.22 * fract(sin((floor(pub) + floor(ax * 1.65) * 7.0) * 78.233) * 43758.5453);

			float plates = mix(plates_b, plates_a, blend_w);
			float plate_tone = mix(tone_b, tone_a, blend_w);
			plates = mix(0.68, plates, groove_damp);
			float micro_fib = 0.5 + 0.5 * sin((ua + ub) * 34.0 + sin(ax * 3.1) * 2.0) * cos(ax * 19.0 + sin(ua * 14.0));
			float moss_grain = 0.5 + 0.5 * sin(bark_local.x * 58.0 + sin(bark_local.z * 43.0) * 2.0) * cos(bark_local.z * 52.0 + bark_local.y * 41.0);
			vec3 bark_col = ALBEDO * mix(1.0, mix(0.66, 1.10, plates) * plate_tone * (0.94 + 0.12 * micro_fib), vis);
			vec3 heart_col = ALBEDO * mix(1.0, mix(0.84, 1.08, micro_fib), vis);
			vec3 moss_col = ALBEDO * mix(1.0, mix(0.86, 1.12, moss_grain), vis);
			ALBEDO = mix(mix(bark_col, heart_col, heart_w), moss_col, moss_w);
			float relief = mix(mix(plates * groove_damp + micro_fib * (1.0 - groove_damp) * 0.4, micro_fib * 0.45, heart_w), moss_grain * 0.65, moss_w);
			float hh = relief * vis * 0.013;
			vec3 dpx = dFdx(VERTEX);
			vec3 dpy = dFdy(VERTEX);
			vec3 r1 = cross(dpy, NORMAL);
			vec3 r2 = cross(NORMAL, dpx);
			float det = dot(dpx, r1);
			NORMAL = normalize(abs(det) * NORMAL - sign(det) * (dFdx(hh) * r1 + dFdy(hh) * r2));
			ROUGHNESS = mix(0.92, 0.98, moss_w);
		}
	} else if (bark_detail > 0.0) {
		float fp = max(length(dFdx(bark_local)), length(dFdy(bark_local)));
		float vis = 1.0 - smoothstep(0.012, 0.05, fp);
		float y = bark_local.y;
		vec3 bark = ALBEDO;
		if (vis > 0.001) {
			float r = max(length(bark_local.xz), 0.03);
			float u = atan(bark_local.z, bark_local.x) * r;
			// пластины шириной ~5,5 см, борозды извилистые; поперечные трещины у каждой пластины на своей высоте
			float pu = u / 0.055 + sin(y * 2.1 + u * 3.0) * 0.34 + sin(y * 5.3 + u * 9.0) * 0.16 + sin(y * 13.0 - u * 21.0) * 0.06;
			float plate = floor(pu);
			float f = fract(pu);
			float furrow = min(f, 1.0 - f);
			float row = y * 1.3 + sin(u * 17.0) * 0.12 + fract(sin(plate * 12.9898) * 43758.5453) * 5.0;
			float fr = fract(row);
			float cross_gap = min(fr, 1.0 - fr);
			float plates = smoothstep(0.03, 0.26, furrow) * mix(0.72, 1.0, smoothstep(0.0, 0.035, cross_gap));
			float plate_tone = 0.88 + 0.24 * fract(sin((plate + floor(row) * 7.0) * 78.233) * 43758.5453);
			float relief = plates;
			if (bark_detail < 1.5) {
				bark *= mix(0.9, mix(0.42, 1.10, plates) * plate_tone, vis);
			} else {
				// берёза: у комля грубая тёмная кора, выше — белая с чечевичками (короткие тёмные штрихи поперёк ствола)
				float rough = 1.0 - smoothstep(0.4, 2.2, y + sin(u * 31.0) * 0.25);
				vec2 lc = vec2(u / 0.11, y / 0.028);
				vec2 lh = fract(sin(vec2(dot(floor(lc), vec2(127.1, 311.7)), dot(floor(lc), vec2(269.5, 183.3)))) * 43758.5453);
				vec2 ll = fract(lc) - 0.5;
				float dash = (1.0 - smoothstep(0.30 + lh.y * 0.15, 0.48, abs(ll.x))) * (1.0 - smoothstep(0.18, 0.42, abs(ll.y))) * step(0.86, lh.x);
				vec3 smooth_bark = mix(bark, bark * 0.16, dash * vis * 0.9) * mix(1.0, 0.92 + 0.12 * lh.y, vis);
				vec3 rough_bark = bark * mix(0.55, mix(0.14, 0.62, plates) * plate_tone, vis);
				bark = mix(smooth_bark, rough_bark, rough);
				relief = mix(1.0 - dash * 0.5, plates, rough);
			}
			// комель темнее (сырость, брызги земли), с севера — мох пятнами
			bark *= mix(0.72, 1.0, smoothstep(0.0, 0.6, y));
			float moss = (1.0 - smoothstep(0.2, 1.9, y)) * smoothstep(-0.1, 0.6, bark_north)
				* smoothstep(0.35, 0.65, 0.5 + 0.5 * sin(u * 23.0 + sin(y * 5.0) * 2.0) * sin(y * 4.1 + plate));
			bark = mix(bark, vec3(0.105, 0.15, 0.045) * (0.7 + 0.6 * plates), moss * 0.75 * vis);
			// рельеф пластин светом
			float hh = relief * vis * 0.016;
			vec3 dpx = dFdx(VERTEX);
			vec3 dpy = dFdy(VERTEX);
			vec3 r1 = cross(dpy, NORMAL);
			vec3 r2 = cross(NORMAL, dpx);
			float det = dot(dpx, r1);
			NORMAL = normalize(abs(det) * NORMAL - sign(det) * (dFdx(hh) * r1 + dFdy(hh) * r2));
		} else {
			if (bark_detail < 1.5) {
				bark *= 0.9;
			} else {
				bark *= mix(1.0, 0.55, 1.0 - smoothstep(0.4, 2.2, y));
			}
			bark *= mix(0.72, 1.0, smoothstep(0.0, 0.6, y));
		}
		ALBEDO = bark;
	}
#endif
	// Визуальный стиль: тот же тон по расстоянию, что у рельефа и дальнего леса (resources/depth_tone.gdshaderinc).
	ALBEDO = depth_tone(ALBEDO, length(VERTEX));
	AO = v_ao;
	AO_LIGHT_AFFECT = 0.0;
	BACKLIGHT = col * translucency * mix(1.0, 0.28, vegetation_night);
#ifdef CUTOUT
	// The merged clusters cover fewer layers. Fill small gaps and recover the
	// interior shade where overlapping leaves and the last shadow cascade drop out.
	float simplification = lod_level == 2 ? 1.0 : (lod_level == 1 ? 0.45 : 0.0);
	float inner_shade = mix(1.0, mix(0.66, 0.94, smoothstep(0.55, 0.98, v_ao)), simplification);
	// Interior occlusion belongs to sky light, not a second albedo shadow.
	AO *= inner_shade;
	BACKLIGHT *= mix(1.0, 0.60, simplification);
	ALPHA = (is_berry ? berry_alpha : tex.a) * (1.0 - smoothstep(mix(0.86, 0.92, simplification), 1.0, cluster_radius));
	ALPHA_SCISSOR_THRESHOLD = mix(0.35, 0.24, simplification);
#endif
}

// Clouds attenuate the directional source, never sky light or bicycle lamps.
void light() {
	float visibility = ATTENUATION * (LIGHT_IS_DIRECTIONAL ? v_cloud : 1.0);
	float ndl = dot(NORMAL, LIGHT);
	vec3 diffuse = vec3(max(ndl, 0.0));
	diffuse += BACKLIGHT * max(-ndl, 0.0);
	DIFFUSE_LIGHT += diffuse * LIGHT_COLOR * visibility / PI;
}
