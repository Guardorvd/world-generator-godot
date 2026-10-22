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
// Поредение травы и подлеска дальше thin_full (м, 0 — нет): остаётся доля (thin_full / расстояние)²;
// экземпляр с порогом INSTANCE_CUSTOM.x гаснет, когда доля опускается от 1,3 порога до порога.
// Считается по нынешнему расстоянию, а не по раскладке: новая раскладка ничего не включает рывком.
// thin_grow — пучки за thin_full крупнее, тоже по нынешнему расстоянию.
uniform float thin_full = 0.0;
uniform float thin_grow = 0.0;

#include "res://resources/cloud_shadow.gdshaderinc"

const vec2 WIND_DIR = vec2(0.82, 0.57);

varying float v_ao;
varying float v_cloud;   // 7.9: тень облака на растении (одна на экземпляр)
varying float v_fade;    // 9.9+: 1 — видно целиком, 0 — растворилось

void vertex() {
	float h = clamp(VERTEX.y / height, 0.0, 1.0);
	vec3 origin = MODEL_MATRIX[3].xyz;
	float sheltered = 1.0 - COLOR.a;
	float dist = distance(origin.xz, veg_center);
	v_fade = clamp((fade_far - dist) / fade_len, 0.0, 1.0);
	if (thin_full > 0.0) {
		float keep = min(1.0, thin_full * thin_full / max(dist * dist, 1.0));
		float rank = INSTANCE_CUSTOM.x;
		if (rank > 0.0) {
			v_fade *= clamp((keep - rank) / max(min(1.0, rank * 1.3) - rank, 1e-4), 0.0, 1.0);
		}
		VERTEX *= 1.0 + thin_grow * (1.0 - keep);
	}
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
		world += vec3(leaf, leaf * 0.5, -leaf * 0.7) * flutter * gust * h;
		// В локальные координаты экземпляра: поворот и масштаб из MODEL_MATRIX.
		mat3 basis = mat3(MODEL_MATRIX);
		float scale2 = max(dot(basis[0], basis[0]), 1e-4);
		VERTEX += transpose(basis) * world * (sqrt(scale2) / scale2);
	}
	v_cloud = cloud_light(origin.xz);
	v_ao = mix(ao_low, 1.0, h) * mix(1.0, shelter_ao, sheltered);
	if (use_vertex_color) {
		// как vertex_color_is_srgb у StandardMaterial3D
		COLOR.rgb = mix(pow((COLOR.rgb + vec3(0.055)) * (1.0 / 1.055), vec3(2.4)), COLOR.rgb * (1.0 / 12.92), lessThan(COLOR.rgb, vec3(0.04045)));
	}
}

void fragment() {
	// Сетка порогов (interleaved gradient noise): без прозрачности и сортировки, тени редеют так же.
	if (v_fade < 1.0 && v_fade <= fract(52.9829189 * fract(dot(FRAGCOORD.xy, vec2(0.06711056, 0.00583715))))) {
		discard;
	}
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
	ALPHA = tex.a;
	ALPHA_SCISSOR_THRESHOLD = 0.35; // 9.4: полнее крона вдали
#endif
}
