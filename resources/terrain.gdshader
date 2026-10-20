// Поверхность рельефа (с 2.5). Цвет — запечённая карта биомов (стартовая область) или цвета вершин
// (рельеф за краем). Текстура карты — 2–4 пикселя на клетку 4 м, вблизи она размыта, поэтому поверх
// в мировых координатах накладывается мелкая деталь из одной бесшовной текстуры шума:
// пятна яркости в трёх масштабах, неровный край между биомами (сдвиг выборки карты на долю пикселя),
// микрорельеф для света (карта нормалей) и скальная порода на крутых склонах.
// Деталь гаснет с расстоянием (DETAIL_FAR), вдали поверхность как раньше.
shader_type spatial;

uniform sampler2D base_tex : source_color, filter_linear_mipmap_anisotropic, repeat_disable;
uniform bool use_vertex_color = false;
uniform vec2 base_texel = vec2(0.001);   // 1 / размер base_tex
uniform sampler2D detail_tex : hint_default_white, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D detail_normal : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
// Зерно, органическая примесь и шероховатость из RoadSurface.LIST.
uniform vec3 surface_detail[8];
uniform vec3 rock_color : source_color = vec3(0.56, 0.54, 0.51);

const float DETAIL_FAR = 110.0;   // м: дальше мелкой детали нет
const float EDGE_JITTER = 0.9;    // в пикселях карты: насколько рваный край между биомами
const float ROCK_FROM = 0.30;     // 1 - нормаль.y: с какого уклона (около 45°) проступает скала
const float ROCK_TO = 0.46;

varying vec3 wpos;
varying vec3 wnormal;
varying vec3 road_detail;

// Разброс зёрен в мировых координатах, без короткого периода текстуры.
vec2 grain_hash(vec2 cell) {
	return fract(sin(vec2(dot(cell, vec2(127.1, 311.7)), dot(cell, vec2(269.5, 183.3)))) * 43758.5453);
}

void vertex() {
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	wnormal = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
	// Выбираем свойства в вершине: в пикселях смешиваются свойства, а не номера материалов.
	road_detail = surface_detail[clamp(int(round(UV2.y)), 0, 7)];
	if (use_vertex_color) {
		// цвета вершин записаны в sRGB (как vertex_color_is_srgb у StandardMaterial3D)
		COLOR.rgb = mix(pow((COLOR.rgb + vec3(0.055)) * (1.0 / 1.055), vec3(2.4)), COLOR.rgb * (1.0 / 12.92), lessThan(COLOR.rgb, vec3(0.04045)));
	}
}

void fragment() {
	vec2 p = wpos.xz;
	float near = 1.0 - smoothstep(DETAIL_FAR * 0.35, DETAIL_FAR, length(wpos - CAMERA_POSITION_WORLD));
	float n_big = texture(detail_tex, p * (1.0 / 37.0)).r;
	float n_mid = texture(detail_tex, p * (1.0 / 7.3)).r;
	float n_fine = 0.5;
	vec3 detail_n = vec3(0.5, 0.5, 1.0);
	// Вдали вес этих деталей нулевой: не читать две текстуры для невидимой детали.
	if (near > 0.0) {
		n_fine = texture(detail_tex, p * (1.0 / 1.9)).r;
		detail_n = texture(detail_normal, p * (1.0 / 2.3)).rgb;
	}
	vec3 col;
	if (use_vertex_color) {
		col = COLOR.rgb;
	} else {
		float n_off = texture(detail_tex, p * (1.0 / 5.1) + vec2(0.37, 0.71)).r;
		vec2 jitter = (vec2(n_mid, n_off) - 0.5) * (EDGE_JITTER * 2.0) * base_texel * near;
		col = texture(base_tex, UV + jitter).rgb;
	}
	// скала там, где склон круче; граница рваная от шума
	float slope = 1.0 - normalize(wnormal).y;
	float rock = smoothstep(ROCK_FROM, ROCK_TO, slope + (n_mid - 0.5) * 0.12);
	// на снегу скала проступает слабее, чтобы вершины оставались белыми
	float snow = smoothstep(0.55, 0.8, min(col.r, min(col.g, col.b)));
	col = mix(col, rock_color * (0.8 + 0.4 * n_big), rock * (0.75 - 0.45 * snow));
	// пятна яркости: крупные видны всегда, мелкие только вблизи
	float v = (n_big - 0.5) * 0.14 + ((n_mid - 0.5) * 0.18 + (n_fine - 0.5) * 0.24) * near;
	// Маска метровой сетки задаёт общий силуэт, мелкая кромка считается в пикселях.
	float road = 0.0;
	float road_rough = road_detail.z;
	if (!use_vertex_color && COLOR.a > 0.0 && UV2.y > 0.0) {
		float grain = road_detail.x;
		float organic = road_detail.y;
		// Поворот, два несоизмеримых масштаба и сдвиг снимают короткий период шумовой текстуры.
		vec2 rp = mat2(vec2(0.8, 0.6), vec2(-0.6, 0.8)) * p;
		rp += vec2(n_mid, n_big) * 0.9;
		float fine = texture(detail_tex, rp * 2.31).r;
		float fleck = texture(detail_tex, rp * 0.73 + vec2(0.21, 0.67)).r;
		float edge_noise = ((n_mid - 0.5) * 0.30 + (fleck - 0.5) * 0.25) * (1.0 + organic * 0.6);
		edge_noise *= 4.0 * COLOR.a * (1.0 - COLOR.a);
		float aa = max(fwidth(COLOR.a), 0.01);
		road = smoothstep(0.02 - aa, 0.96 + aa, COLOR.a + edge_noise);
		// Гравий и камень читаются отдельным зерном; песок и укатанная земля — мелкой фактурой.
		vec2 cells = rp * mix(22.0, 9.7, grain);
		vec2 scatter = grain_hash(floor(cells));
		vec2 stone = fract(cells) - (vec2(0.3) + scatter * 0.4);
		float radius = 0.10 + scatter.x * 0.13;
		float grain_aa = max(length(fwidth(cells)) * 0.5, 0.01);
		float pebbles = (1.0 - smoothstep(radius - grain_aa, radius + grain_aa, length(stone))) * step(0.25, scatter.y) * grain * (1.0 - smoothstep(0.35, 1.0, grain_aa));
		float soil_detail = (fine - 0.5) * mix(0.04, 0.09, grain) + (fleck - 0.5) * 0.07;
		vec3 soil = COLOR.rgb * (0.95 + (n_mid - 0.5) * 0.12 + soil_detail * near);
		soil += vec3(pebbles * (0.035 + scatter.x * 0.045) * near);
		// Нерегулярная подстилка и просветы к траве, без одинаковых пар колей на каждом покрытии.
		float litter = smoothstep(0.38, 0.72, fleck + (fine - 0.5) * 0.3);
		soil *= 1.0 + (litter - 0.5) * organic * 0.22 * near;
		road *= 1.0 - organic * smoothstep(0.55, 0.8, fleck) * 0.25 * near;
		float wear = exp(-pow((UV2.x + (n_mid - 0.5) * 0.35) * 1.7, 2.0));
		soil *= 1.0 - wear * (1.0 - grain) * (1.0 - organic) * (0.02 + fleck * 0.04) * near;
		col = mix(col, soil, road);
		// Шум биомов на полотне слабее: покрытие читается собственной фактурой.
		v *= 1.0 - road * 0.6;
		if (road * near > 0.0) {
			// Свет следует отдельным зёрнам; на середине полотна нет контуров карты нормалей биома.
			vec3 road_normal = normalize(vec3(stone * pebbles * 2.0, 1.0)) * 0.5 + 0.5;
			detail_n = mix(detail_n, road_normal, road);
		}
	}
	ALBEDO = col * (1.0 + v);
	ROUGHNESS = 1.0;
	SPECULAR = 0.3;
	NORMAL_MAP = detail_n;
	NORMAL_MAP_DEPTH = mix(0.6 + 0.6 * rock, 0.2 + road_rough * 0.4, road) * near;
}
