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
uniform vec3 rock_color : source_color = vec3(0.56, 0.54, 0.51);

const float DETAIL_FAR = 110.0;   // м: дальше мелкой детали нет
const float EDGE_JITTER = 0.9;    // в пикселях карты: насколько рваный край между биомами
const float ROCK_FROM = 0.30;     // 1 - нормаль.y: с какого уклона (около 45°) проступает скала
const float ROCK_TO = 0.46;

varying vec3 wpos;
varying vec3 wnormal;

void vertex() {
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	wnormal = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
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
	// Пути 4.4: цвет и мягкая маска из локальной сетки, без растровых ступеней карты.
	// Рябь края имеет сантиметровый масштаб и не требует новых вершин.
	float road = 0.0;
	if (!use_vertex_color && COLOR.a > 0.0 && UV2.y > 0.0) {
		float edge_noise = ((n_mid - 0.5) * 0.20 + (n_fine - 0.5) * 0.13) * 4.0 * COLOR.a * (1.0 - COLOR.a);
		road = smoothstep(0.03, 0.92, COLOR.a + edge_noise);
		float grains = texture(detail_tex, p * 3.7).r;
		float pebbles = smoothstep(0.60, 0.78, grains);
		float tracks = exp(-pow((abs(UV2.x) - 0.48) * 6.0, 2.0));
		vec3 soil = COLOR.rgb * (0.89 + n_mid * 0.19 + (grains - 0.5) * 0.28 * near);
		soil *= 1.0 - tracks * 0.10 * near;
		soil += vec3(pebbles * 0.035 * near);
		col = mix(col, soil, road);
		// Мелкое зерно — только свет, бугорки метрового масштаба находятся в геометрии.
		if (road * near > 0.0) {
			detail_n = mix(detail_n, texture(detail_normal, p * 2.1).rgb, road * 0.72);
		}
	}
	ALBEDO = col * (1.0 + v);
	ROUGHNESS = 1.0;
	SPECULAR = 0.3;
	NORMAL_MAP = detail_n;
	NORMAL_MAP_DEPTH = mix(0.6 + 0.6 * rock, 0.3 + UV2.y * 0.5, road) * near;
}
