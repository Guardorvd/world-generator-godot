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
// 11.5: кочки полотна из RoadBump.LIST; та же форма трясёт велосипед.
// 12.3: высота кочек (м), длина волны (м), глубина колеи (м), доля клеток с ямой; трещины — RoadBump.CRACKS.
uniform vec4 surface_bump[8];
uniform float surface_crack[8];
uniform vec3 rock_color : source_color = vec3(0.56, 0.54, 0.51);
// 6.6+: полог, доля хвойных, влажность и каменистость из готового леса.
uniform sampler2D forest_tex : hint_default_black, filter_linear_mipmap, repeat_disable;
uniform bool forest_enabled = false;
uniform vec3 leaf_soil : source_color = vec3(0.32, 0.26, 0.16);
// 7.8: доля солнечного света (DayCycle): ночью и в сумерках солнечных просветов под пологом нет.
uniform float sunlight = 1.0;
uniform vec3 needle_soil : source_color = vec3(0.27, 0.24, 0.17);
uniform vec3 floor_moss : source_color = vec3(0.27, 0.36, 0.17);
uniform vec3 dry_litter : source_color = vec3(0.44, 0.34, 0.19);

const float DETAIL_FAR = 110.0;   // м: дальше мелкой детали нет
const float EDGE_JITTER = 0.9;    // в пикселях карты: насколько рваный край между биомами
const float ROCK_FROM = 0.30;     // 1 - нормаль.y: с какого уклона (около 45°) проступает скала
const float ROCK_TO = 0.46;

#include "res://resources/cloud_shadow.gdshaderinc"

varying vec3 wpos;
varying vec3 wnormal;
varying vec3 road_detail;
varying vec4 road_bump_p;
varying float road_crack;

// 11.5: волна RoadBump.shape и её наклон: x — высота 0..1, yz — производные по x и z мира.
vec3 road_wave(vec2 p, float wave) {
	float k = 6.2831853 / wave;
	vec2 q = vec2(0.8 * p.x + 0.6 * p.y, -0.6 * p.x + 0.8 * p.y) * k;
	float u = q.x + 1.3 * sin(q.y * 0.37);
	float w = q.y * 0.71 + q.x * 0.29 + 2.1;
	float n = 0.6 * sin(u) + 0.4 * sin(w * 1.9);
	float cu = 0.6 * cos(u);
	float cw = 0.4 * cos(w * 1.9) * 1.9;
	vec2 dn = vec2(cu + cw * 0.29, cu * 0.481 * cos(q.y * 0.37) + cw * 0.71);
	float m = max(n, 0.0);
	vec2 g = 2.0 * m * dn * k;
	return vec3(m * m, 0.8 * g.x - 0.6 * g.y, 0.6 * g.x + 0.8 * g.y);
}

// 12.3: RoadBump.patch — медленные поля участков: x — разбитость, y — где колеи.
vec2 road_patch(vec2 p) {
	return vec2(0.5 + 0.5 * (0.55 * sin(0.083 * p.x + 0.047 * p.y + 1.7) + 0.45 * sin(-0.039 * p.x + 0.091 * p.y + 4.1)),
		0.5 + 0.5 * (0.6 * sin(0.061 * p.x - 0.037 * p.y + 0.4) + 0.4 * sin(0.027 * p.x + 0.083 * p.y + 2.6)));
}

// RoadBump.cell_hash
uint road_hash(ivec2 c, uint salt) {
	uint h = (uint(c.x) * 73856093u) ^ (uint(c.y) * 19349663u) ^ salt;
	h = (h ^ (h >> 16u)) * 0x45d9f3bu;
	h = (h ^ (h >> 16u)) * 0x45d9f3bu;
	return h ^ (h >> 16u);
}

// RoadBump.hole: x — глубина в долях 0..1, yz — её наклон по x и z мира (1/м), w — радиус ямы (0 — нет).
vec4 road_hole(vec2 p, float chance) {
	const float CELL = 2.5;
	ivec2 c = ivec2(floor(p / CELL));
	uint h = road_hash(c, 12301u);
	if (float(h & 0xFFFFu) / 65536.0 >= chance) {
		return vec4(0.0);
	}
	uint g = road_hash(c, 4517u);
	vec2 center = (vec2(c) + 0.25 + 0.5 * vec2(float(g & 0xFFFFu), float((g >> 16u) & 0xFFFFu)) / 65536.0) * CELL;
	float r = 0.25 + 0.3 * float((h >> 16u) & 0xFFFFu) / 65536.0;
	vec2 d = p - center;
	float q = dot(d, d) / (r * r);
	if (q >= 1.0) {
		return vec4(0.0);
	}
	return vec4((1.0 - q) * (1.0 - q), -4.0 * (1.0 - q) * d / (r * r), r);
}

// RoadBump.height целиком (м) и его наклон по x и z мира; ga — наклон поперечной координаты в мире.
vec3 road_field(vec2 p, vec4 b, float grade, float across, vec2 ga) {
	vec2 pt = road_patch(p);
	float rough = mix(0.35, 1.6, smoothstep(0.25, 0.75, pt.x));
	float amp = b.x * rough * (1.0 + 1.2 * smoothstep(0.06, 0.30, grade));
	vec3 w1 = road_wave(p, b.y);
	vec3 w2 = road_wave(vec2(0.28 * p.x - 0.96 * p.y, 0.96 * p.x + 0.28 * p.y), b.y * 0.57);
	// наклон второй волны — обратно в координаты мира
	w2.yz = vec2(0.28 * w2.y + 0.96 * w2.z, -0.96 * w2.y + 0.28 * w2.z);
	vec3 f = amp * (w1 + 0.7 * smoothstep(0.3, 0.8, 1.0 - pt.y) * w2);
	float a = abs(across);
	if (b.z > 0.0 && a < 1.0) {
		float e = exp(-pow((a - 0.47) / 0.13, 2.0));
		float depth = b.z * smoothstep(0.35, 0.7, pt.y);
		f.x -= depth * e;
		f.yz -= depth * e * (-2.0 * (a - 0.47) / (0.13 * 0.13)) * sign(across) * ga;
	}
	if (b.w > 0.0 && a < 0.75) {
		vec4 pit = road_hole(p, b.w * smoothstep(0.3, 0.8, pt.x) * 1.5);
		f -= vec3(pit.x, pit.yz) * pit.w * 0.09;
	}
	return f;
}

// Разброс зёрен в мировых координатах, без короткого периода текстуры.
vec2 grain_hash(vec2 cell) {
	return fract(sin(vec2(dot(cell, vec2(127.1, 311.7)), dot(cell, vec2(269.5, 183.3)))) * 43758.5453);
}

void vertex() {
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	wnormal = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
	// Выбираем свойства в вершине: в пикселях смешиваются свойства, а не номера материалов.
	road_detail = surface_detail[clamp(int(round(UV2.y)), 0, 7)];
	road_bump_p = surface_bump[clamp(int(round(UV2.y)), 0, 7)];
	road_crack = surface_crack[clamp(int(round(UV2.y)), 0, 7)];
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
	float sky = 1.0;
	if (forest_enabled && !use_vertex_color) {
		vec4 forest = texture(forest_tex, UV);
		float cover = smoothstep(0.03, 0.8, forest.r) * (1.0 - snow);
		float patch = smoothstep(0.32, 0.72, n_mid + (n_big - 0.5) * 0.4);
		vec3 soil = mix(leaf_soil, needle_soil, forest.g);
		soil *= mix(1.12, 0.72, forest.b);
		float moss = smoothstep(0.48, 0.85, forest.b) * patch * (0.35 + forest.r * 0.65);
		soil = mix(soil, floor_moss, moss * 0.7);
		// Светлые сухие россыпи и обнажения проходят сквозь подстилку.
		float stones = forest.a * smoothstep(0.38, 0.70, n_big + (n_mid - 0.5) * 0.6);
		soil = mix(soil, rock_color * 0.72, stones * 0.75);
		if (near > 0.0) {
			// Листья/иголки читаются вблизи, с производными для гашения мерцания.
			vec2 cells = p * 5.7;
			vec2 scatter = grain_hash(floor(cells));
			vec2 local = fract(cells) - vec2(0.25) - scatter * 0.5;
			float angle = scatter.x * 6.28318;
			local = mat2(vec2(cos(angle), sin(angle)), vec2(-sin(angle), cos(angle))) * local;
			float shape = mix(abs(local.x) * 0.75 + abs(local.y) * 1.5,
				max(abs(local.x) * 0.55, abs(local.y) * 5.0), forest.g);
			float aa = max(length(fwidth(cells)), 0.015);
			float litter = (1.0 - smoothstep(0.13 - aa, 0.13 + aa, shape));
			litter *= step(0.28, scatter.y) * (1.0 - smoothstep(0.25, 0.9, aa));
			soil = mix(soil, dry_litter * mix(0.85, 1.2, scatter.x), litter * near * (0.55 - moss * 0.25));
		}
		col = mix(col, soil, cover * (0.62 + patch * 0.25));
		// 6.7: под пологом меньше света неба. Хвойный плотнее и холоднее; в лиственном
		// медленно плывут тёплые просветы — как солнце сквозь качающуюся листву.
		// 6.8: на опушке тень набирается медленнее, под ельником светлее, просветы заметнее.
		float shade = smoothstep(0.12, 1.0, forest.r) * (1.0 - snow);
		sky = 1.0 - shade * mix(0.32, 0.42, forest.g);
		col *= mix(vec3(1.0), vec3(0.95, 0.98, 1.0), shade * forest.g);
		if (near > 0.0 && sunlight > 0.0) {
			float sun = texture(detail_tex, p * (1.0 / 3.1) + vec2(TIME * 0.006, TIME * 0.004)).r;
			col *= 1.0 + smoothstep(0.55, 0.75, sun) * cover * (1.0 - forest.g) * near * sunlight * vec3(0.22, 0.18, 0.1);
		}
	}
	col = mix(col, rock_color * (0.8 + 0.4 * n_big), rock * (0.75 - 0.45 * snow));
	// пятна яркости: крупные видны всегда, мелкие только вблизи
	float v = (n_big - 0.5) * 0.14 + ((n_mid - 0.5) * 0.18 + (n_fine - 0.5) * 0.24) * near;
	// Маска метровой сетки задаёт общий силуэт, мелкая кромка считается в пикселях.
	float road = 0.0;
	float road_rough = road_detail.z;
	// Производные — до ветвления: на краю маски соседние пиксели квада вне ветки, и fwidth внутри
	// неё даёт мусор (тёмный пунктир по рёбрам сетки).
	float mask_w = fwidth(COLOR.a);
	float pixel_m = length(fwidth(p));
	// 12.3: наклон поперечной координаты полотна в мире (для колей): из экранных производных UV2.x и p.
	vec2 dpx = dFdx(p);
	vec2 dpy = dFdy(p);
	vec2 dax = vec2(dFdx(UV2.x), dFdy(UV2.x));
	float jdet = dpx.x * dpy.y - dpx.y * dpy.x;
	vec2 across_grad = abs(jdet) > 1e-8 ? vec2(dax.x * dpy.y - dax.y * dpx.y, dax.y * dpx.x - dax.x * dpy.x) / jdet : vec2(0.0);
	if (!use_vertex_color && COLOR.a > 0.0 && UV2.y > 0.0) {
		float grain = road_detail.x;
		float organic = road_detail.y;
		// Поворот, два несоизмеримых масштаба и сдвиг снимают короткий период шумовой текстуры.
		vec2 rp = mat2(vec2(0.8, 0.6), vec2(-0.6, 0.8)) * p;
		// 11.3: сдвиг в основном от крупного шума — мелкий сдвиг давал разводы «как масло» на подстилке.
		rp += vec2(n_mid, n_big) * 0.25 + vec2(n_big * 2.3, n_big * 1.7);
		float fine = texture(detail_tex, rp * 2.31).r;
		float fleck = texture(detail_tex, rp * 0.73 + vec2(0.21, 0.67)).r;
		// 11.3: кромка — тот же метровый силуэт, но переход уже и рвётся тремя масштабами шума,
		// поэтому ломаная треугольников сетки и размытая полоса вдоль края больше не читаются.
		// Ширина сглаживания — производная маски плюс оценка крутизны шума (около 2,5 на метр) на размер пикселя.
		float edge_noise = ((n_mid - 0.5) * 0.34 + (fleck - 0.5) * 0.30 + (fine - 0.5) * 0.16 * near) * (1.0 + organic * 0.5);
		float edge_amp = 4.0 * COLOR.a * (1.0 - COLOR.a);
		edge_noise *= edge_amp;
		float edge_v = COLOR.a + edge_noise;
		float soft = mix(0.16, 0.32, organic);
		float aa = clamp(mask_w + pixel_m * 2.5 * edge_amp, 0.004, 0.3);
		road = smoothstep(0.5 - soft - aa, 0.5 + soft + aa, edge_v);
		// 11.4: обочина — полоса снаружи кромки, до конца маски вершин (около метра). У полотна сухой ободок.
		float verge = smoothstep(0.02, 0.30, edge_v) * (1.0 - road);
		float lip = road * (1.0 - smoothstep(0.55, 0.85, edge_v));
		// Поперечная координата полотна: 0 — ось, 1 — половина ширины (по ближайшему отрезку пути).
		float across = abs(UV2.x + (n_mid - 0.5) * 0.18);
		// 11.5: кочки полотна — то же поле, что у колёс (RoadBump): по покрытию, на крутом выше.
		// 12.3: с участками, колеями и ямами. Видны светом и тоном; гаснут, когда волна меньше нескольких пикселей.
		float grade = length(wnormal.xz) / max(wnormal.y, 0.2);
		float bump_wave = max(road_bump_p.y, 0.1);
		vec3 bump = road_field(p, road_bump_p, grade, UV2.x, across_grad);
		float bump_fade = (1.0 - smoothstep(0.06, 0.2, pixel_m / bump_wave)) * near;
		// 14.5: волны кочек правильные (две синусоиды), и в тоне и свете они читались ровным узором
		// тёмных «змеек» через равный шаг, особенно под фарой. Видимая сила теперь пятнами по крупному
		// шуму, тон и наклон слабее; сами кочки (тряска, RoadBump) не меняются.
		float bump_vis = bump_fade * mix(0.3, 1.0, smoothstep(0.3, 0.75, n_big + (n_mid - 0.5) * 0.6));
		vec2 ruts_patch = road_patch(p);
		// Гравий и камень читаются отдельным зерном; песок и укатанная земля — мелкой фактурой.
		// Камешки — купола со светлой макушкой и тёмным краем; гаснут раньше, чем начнут мерцать.
		float grain_scale = mix(22.0, 9.7, grain);
		vec2 cells = rp * grain_scale;
		vec2 scatter = grain_hash(floor(cells));
		vec2 stone = fract(cells) - (vec2(0.3) + scatter * 0.4);
		float radius = 0.10 + scatter.x * 0.13;
		float grain_aa = max(pixel_m * grain_scale * 0.5, 0.01);
		float grain_fade = 1.0 - smoothstep(0.25, 0.6, grain_aa);
		float pebbles = (1.0 - smoothstep(radius - grain_aa, radius + grain_aa, length(stone))) * step(0.25, scatter.y) * grain * grain_fade;
		float dome = clamp(1.0 - length(stone) / radius, 0.0, 1.0);
		// Редкие крупные камни на гравии и камне, по краям полотна чаще, чем на колее; на обочине — у любого покрытия.
		vec2 big_cells = rp * 2.9 + vec2(13.1, 7.7);
		vec2 big_scatter = grain_hash(floor(big_cells));
		vec2 rock_at = fract(big_cells) - (vec2(0.35) + big_scatter * 0.3);
		float rock_r = 0.08 + big_scatter.y * 0.07;
		float big_aa = max(pixel_m * 2.9 * 0.5, 0.01);
		float big_rocks = (1.0 - smoothstep(rock_r - big_aa, rock_r + big_aa, length(rock_at)))
			* step(0.86 - grain * 0.10 - smoothstep(0.55, 0.95, across) * 0.08, big_scatter.x)
			* max(smoothstep(0.25, 0.7, grain), verge * (0.6 - organic * 0.3)) * (1.0 - smoothstep(0.2, 0.6, big_aa));
		float big_dome = clamp(1.0 - length(rock_at) / rock_r, 0.0, 1.0);
		// Обочина: трава гуще и темнее, с сухими пятнами; просветы почвы, разнесённой с полотна;
		// на них — выкатившийся гравий; камни. Цвет почвы — смесь покрытия и травы, без новых данных.
		vec3 verge_col = col;
		if (verge > 0.0) {
			float dry_grass = smoothstep(0.42, 0.72, fine * 0.5 + fleck * 0.5);
			verge_col *= mix(vec3(0.93, 0.97, 0.88), vec3(1.08, 1.03, 0.78), dry_grass);
			float bare = smoothstep(0.56, 0.76, fleck * 0.55 + (1.0 - n_mid) * 0.35 + verge * 0.25 - organic * 0.1) * near;
			vec3 earth = mix(COLOR.rgb * (0.9 + (fine - 0.5) * 0.12), col * 0.7, 0.22 + organic * 0.3);
			earth *= 1.0 + vec3(pebbles * (dome * 1.2 - 0.3) * 0.4 * near);
			verge_col = mix(verge_col, earth, bare * 0.8);
			vec3 verge_rock = rock_color * 0.78 * (0.8 + big_dome * 0.28) * mix(0.9, 1.06, big_scatter.y);
			verge_col = mix(verge_col, verge_rock, big_rocks * near);
		}
		float soil_detail = (fine - 0.5) * mix(0.05, 0.10, grain) + (fleck - 0.5) * 0.08;
		vec3 soil = COLOR.rgb * (0.95 + (n_mid - 0.5) * 0.14 + soil_detail * near);
		// Крупные пятна: суше и светлее / сырее, темнее и холоднее, чтобы полотно не было одного тона.
		float dry = n_big + (n_mid - 0.5) * 0.25;
		soil *= mix(vec3(0.92, 0.94, 0.97), vec3(1.06, 1.03, 0.97), smoothstep(0.3, 0.7, dry));
		soil *= 1.0 + vec3(pebbles * (dome * 1.1 - 0.3) * (0.20 + scatter.x * 0.12) * near);
		vec3 rock_tone = mix(soil, rock_color * 0.8, 0.55) * (0.82 + big_dome * 0.22) * mix(0.92, 1.05, big_scatter.y);
		soil = mix(soil, rock_tone, big_rocks * near);
		// Нерегулярная подстилка и просветы к траве, без одинаковых пар колей на каждом покрытии.
		float litter = smoothstep(0.38, 0.72, fleck + (fine - 0.5) * 0.3);
		soil *= 1.0 + (litter - 0.5) * organic * 0.22 * near;
		road *= 1.0 - organic * smoothstep(0.55, 0.8, fleck) * 0.25 * near;
		// Накатанные колеи: местами, с разрывами, плотнее и темнее, мелкий камень с них выбит.
		// 12.3: там же, где колея RoadBump (её участки), а глубокие колеи на мягком ещё темнее.
		float rut_on = smoothstep(0.35, 0.7, ruts_patch.y);
		float tracks = exp(-pow((abs(UV2.x) - 0.47) / 0.13, 2.0)) * max(rut_on * smoothstep(0.0, 0.02, road_bump_p.z),
			smoothstep(0.35, 0.65, n_big + (fleck - 0.5) * 0.5) * 0.6)
			* (1.0 - organic * 0.4) * (1.0 - smoothstep(0.6, 1.0, grain) * 0.5) * near;
		soil *= 1.0 - tracks * (0.07 + fine * 0.05 + road_bump_p.z * 2.5);
		// На заросшей колее в колеях проступает земля.
		road = max(road, tracks * organic * 0.7 * smoothstep(0.0, 0.02, road_bump_p.z));
		// Ямы: дно темнее и влажнее.
		float pit = clamp(-bump.x / 0.03, 0.0, 1.0) * (1.0 - tracks) * near;
		soil *= 1.0 - pit * 0.28;
		// 12.3: трещины — сетка ячеек ~0,9 м (Вороной по повёрнутым координатам), местами, тонкие тёмные линии.
		if (road_crack > 0.0 && near > 0.0 && pixel_m < 0.06) {
			vec2 cp = rp * 1.1;
			vec2 base_c = floor(cp);
			float f1 = 8.0;
			float f2 = 8.0;
			for (int cy = -1; cy <= 1; cy++) {
				for (int cx = -1; cx <= 1; cx++) {
					vec2 o = base_c + vec2(float(cx), float(cy));
					float dd = length(cp - o - grain_hash(o));
					if (dd < f1) {
						f2 = f1;
						f1 = dd;
					} else if (dd < f2) {
						f2 = dd;
					}
				}
			}
			float edge_m = (f2 - f1) * 0.5 / 1.1;
			float crack_w = 0.012 + 0.02 * fine;
			float lines = 1.0 - smoothstep(crack_w, crack_w + pixel_m, edge_m);
			float zone = smoothstep(0.42, 0.62, n_big + (fleck - 0.5) * 0.5) * road_crack;
			soil *= 1.0 - lines * zone * (1.0 - smoothstep(0.02, 0.06, pixel_m)) * (1.0 - tracks * 0.6) * 0.4;
		}
		float wear = exp(-pow((UV2.x + (n_mid - 0.5) * 0.35) * 1.7, 2.0));
		soil *= 1.0 - wear * (1.0 - grain) * (1.0 - organic) * (0.02 + fleck * 0.04) * near;
		// Трава пробивается между колеями и у краёв заросших троп и грунтовок.
		float middle = exp(-pow(across * 2.6, 2.0)) * smoothstep(0.35, 0.9, 1.0 - grain) + smoothstep(0.65, 1.0, across) * 0.5;
		float tufts = smoothstep(0.58, 0.78, fine * 0.45 + fleck * 0.55 + (n_mid - 0.5) * 0.3) * middle * (0.25 + organic * 0.5) * near;
		soil = mix(soil, col * 0.92, tufts * 0.6);
		soil *= 1.0 - lip * 0.06;
		soil *= 1.0 + clamp(bump.x * 3.5, -0.06, 0.07) * bump_vis;
		col = mix(mix(col, verge_col, verge), soil, road);
		// Шум биомов на полотне слабее: покрытие читается собственной фактурой.
		v *= 1.0 - road * 0.6;
		float relief = max(road, verge * big_rocks);
		if (relief * near > 0.0) {
			// Свет следует отдельным зёрнам и камням; на середине полотна нет контуров карты нормалей биома,
			// вместо них — мелкий рельеф по повёрнутым координатам полотна.
			vec3 grit = texture(detail_normal, rp * 1.37).rgb * 2.0 - 1.0;
			vec2 tilt = stone / radius * pebbles * 0.9 + rock_at / rock_r * big_rocks * 0.6 + grit.xy * (0.25 + grain * 0.35) * (1.0 - tracks)
				- bump.yz * bump_vis * 2.2 * road; // глубина карты нормалей на полотне ~0,3 (14.5: было 4,0 — узор)
			vec3 road_normal = normalize(vec3(tilt, 1.0)) * 0.5 + 0.5;
			detail_n = mix(detail_n, road_normal, relief);
		}
	}
	ALBEDO = col * (1.0 + v) * cloud_light(p);
	ROUGHNESS = 1.0;
	SPECULAR = 0.3;
	AO = sky;
	AO_LIGHT_AFFECT = 0.0;
	NORMAL_MAP = detail_n;
	NORMAL_MAP_DEPTH = mix(0.6 + 0.6 * rock, 0.2 + road_rough * 0.4, road) * near;
}
