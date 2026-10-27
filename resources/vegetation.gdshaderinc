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
// 9.9+: растворение у края дальности прорисовки. Растение целиком (по своему основанию) редеет
// точками экрана от fade_far - fade_len до fade_far от игрока (veg_center, ставит VegetationLayer.update).
// Дальше fade_far его не видно, поэтому чанк или новая раскладка травы за этой границей появляются незаметно.
uniform float fade_far = 1.0e9;
uniform float fade_len = 1.0;
global uniform vec2 veg_center;
global uniform float vegetation_clock;
uniform bool stream_instances = false;
uniform float stream_birth = 0.0;
// Поредение травы и подлеска дальше thin_full (м, 0 — нет): остаётся доля (thin_full / расстояние)²;
// экземпляр с порогом INSTANCE_CUSTOM.x гаснет, когда доля опускается от 1,3 порога до порога.
// Считается по нынешнему расстоянию, а не по раскладке: новая раскладка ничего не включает рывком.
// thin_grow — пучки за thin_full крупнее, тоже по нынешнему расстоянию.
uniform float thin_full = 0.0;
uniform float thin_grow = 0.0;
// Только общий меш травы: лёгкий индивидуальный наклон каждого листа.
uniform bool grass_variation = false;
// Семантическое поредение листьев в UV2.x. Стебли имеют ранг 0 и сохраняются.
// Решается для каждого растения, без копий буферов MultiMesh на каждый LOD.
uniform float detail_full = 0.0;
uniform float detail_far = 1.0;
uniform float detail_keep = 1.0;
// 9.9+: уровень детализации дерева у материала (-1 — без смены уровней; у каждого уровня своя копия материала). Соседние уровни смешиваются той же сеткой
// порогов на полосах LOD1_* и LOD2_*: пиксель берёт ровно один уровень, без дыр и двойной листвы.
// Расстояния — VegetationLayer.LOD_STEPS (там же диапазоны видимости узлов).
uniform int lod_level = -1;
const float LOD1_D = 70.0;
const float LOD1_BAND = 24.0;
const float LOD2_D = 160.0;
const float LOD2_BAND = 48.0;

#include "res://resources/cloud_shadow.gdshaderinc"

const vec2 WIND_DIR = vec2(0.82, 0.57);

varying float v_ao;
varying float v_cloud;   // 7.9: тень облака на растении (одна на экземпляр)
varying float v_fade;    // 9.9+: 1 — видно целиком, 0 — растворилось
varying vec2 v_lod;      // 9.9+: порог пикселя должен быть в [x, y), иначе этот уровень его не рисует

void vertex() {
	float h = clamp(VERTEX.y / height, 0.0, 1.0);
	if (grass_variation) {
		float seed = INSTANCE_CUSTOM.y * 6.2831853 + UV.x * 17.0;
		VERTEX.xz += vec2(cos(seed), sin(seed)) * (0.035 + INSTANCE_CUSTOM.z * 0.065) * UV.y;
		VERTEX.y *= mix(0.9, 1.1, fract(seed * 0.381966));
	}
	vec3 origin = MODEL_MATRIX[3].xyz;
	float sheltered = 1.0 - COLOR.a;
	float dist = distance(origin.xz, veg_center);
	v_fade = clamp((fade_far - dist) / fade_len, 0.0, 1.0);
	float stamp = stream_instances ? INSTANCE_CUSTOM.w : stream_birth;
	if (stamp > 0.0) {
		v_fade *= clamp((vegetation_clock - stamp) / 0.5, 0.0, 1.0);
	} else if (stamp < 0.0) {
		v_fade *= 1.0 - clamp((vegetation_clock + stamp) / 0.5, 0.0, 1.0);
	}
	v_lod = vec2(0.0, 2.0);
	if (lod_level >= 0) {
		float s1 = smoothstep(LOD1_D - LOD1_BAND * 0.5, LOD1_D + LOD1_BAND * 0.5, dist);
		float s2 = smoothstep(LOD2_D - LOD2_BAND * 0.5, LOD2_D + LOD2_BAND * 0.5, dist);
		v_lod = lod_level == 0 ? vec2(s1, 2.0) : (lod_level == 1 ? vec2(s2, s1) : vec2(0.0, s2));
	}
	if (thin_full > 0.0) {
		float keep = min(1.0, thin_full * thin_full / max(dist * dist, 1.0));
		float rank = INSTANCE_CUSTOM.x;
		if (rank > 0.0) {
			v_fade *= clamp((keep - rank) / max(min(1.0, rank * 1.3) - rank, 1e-4), 0.0, 1.0);
		}
		VERTEX *= 1.0 + thin_grow * (1.0 - keep);
	}
	if (detail_full > 0.0) {
		float keep_detail = mix(1.0, detail_keep, smoothstep(detail_full, detail_far, dist));
		v_fade *= clamp((keep_detail - UV2.x) * 10.0 + 1.0, 0.0, 1.0);
	}
	// Скрытый LOD не тратит вычисления на ветер, цвет и облака.
	if (v_fade <= 0.0 || v_lod.x >= min(v_lod.y, 1.0)) {
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
			// Дрожь: своя фаза у каждой вершины, сильнее к концам.
			float leaf = sin(TIME * 4.1 + dot(VERTEX, vec3(3.1, 2.3, 2.7)) + phase);
			float leaf_motion = 1.0 - smoothstep(LOD1_D, LOD2_D, dist) * 0.75;
			world += vec3(leaf, leaf * 0.5, -leaf * 0.7) * flutter * gust * h * leaf_motion;
			// В локальные координаты экземпляра: поворот и масштаб из MODEL_MATRIX.
			mat3 basis = mat3(MODEL_MATRIX);
			float scale2 = max(dot(basis[0], basis[0]), 1e-4);
			VERTEX += transpose(basis) * world * (sqrt(scale2) / scale2);
		}
		v_cloud = cloud_light(origin.xz);
		v_ao = mix(ao_low, 1.0, h) * mix(1.0, shelter_ao, sheltered);
		if (use_vertex_color && !OUTPUT_IS_SRGB) {
			// как vertex_color_is_srgb у StandardMaterial3D
			COLOR.rgb = mix(pow((COLOR.rgb + vec3(0.055)) * (1.0 / 1.055), vec3(2.4)), COLOR.rgb * (1.0 / 12.92), lessThan(COLOR.rgb, vec3(0.04045)));
		}
	}
}

void fragment() {
	// Сетка порогов (interleaved gradient noise): без прозрачности и сортировки, тени редеют так же.
	float dither = fract(52.9829189 * fract(dot(FRAGCOORD.xy, vec2(0.06711056, 0.00583715))));
	if (v_fade < 1.0 && v_fade <= dither || dither < v_lod.x || dither >= v_lod.y) {
		discard;
	}
#ifdef CUTOUT
	// Край объёма сохраняет силуэт даже на мелких mip-уровнях; углы карточки не рисуются и не отбрасывают тень.
	float cluster_radius = length((UV - vec2(0.5)) * 2.0);
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
	if (use_vertex_color) {
		col *= COLOR.rgb;
	}
	ALBEDO = col * v_cloud;
	ROUGHNESS = 1.0;
	AO = v_ao;
	AO_LIGHT_AFFECT = 0.15;
	BACKLIGHT = col * translucency;
#ifdef CUTOUT
	ALPHA = tex.a * (1.0 - smoothstep(0.86, 1.0, cluster_radius));
	// Немного компенсируем усреднение альфы в mipmaps, сохраняя внешний контур объёма.
	ALPHA_SCISSOR_THRESHOLD = lod_level == 2 ? 0.29 : (lod_level == 1 ? 0.32 : 0.35);
#endif
}
