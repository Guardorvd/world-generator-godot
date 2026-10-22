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

#include "res://resources/cloud_shadow.gdshaderinc"

const vec2 WIND_DIR = vec2(0.82, 0.57);

varying float v_ao;
varying float v_cloud;   // 7.9: тень облака на растении (одна на экземпляр)

void vertex() {
	float h = clamp(VERTEX.y / height, 0.0, 1.0);
	vec3 origin = MODEL_MATRIX[3].xyz;
	float sheltered = 1.0 - COLOR.a;
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
