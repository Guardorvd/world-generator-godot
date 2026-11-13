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
// Сдвиг меша от мировых координат, м: у сохранённого участка Trail Lab (WorldData.world_origin), у мира ноль.
// Деталь и кочки полотна остаются на своих мировых местах, как у колёс.
uniform vec2 world_offset = vec2(0.0);
uniform vec3 rock_color : source_color = vec3(0.56, 0.54, 0.51);
// 6.6+: полог, доля хвойных, влажность и каменистость из готового леса.
uniform sampler2D forest_tex : hint_default_black, filter_linear_mipmap, repeat_disable;
uniform bool forest_enabled = false;
uniform vec3 leaf_soil : source_color = vec3(0.32, 0.26, 0.16);
// 7.8: доля солнечного света (DayCycle): ночью и в сумерках солнечных просветов под пологом нет.
uniform float sunlight = 1.0;
global uniform vec4 distant_vegetation;
uniform vec3 needle_soil : source_color = vec3(0.27, 0.24, 0.17);
uniform vec3 floor_moss : source_color = vec3(0.27, 0.36, 0.17);
uniform vec3 dry_litter : source_color = vec3(0.44, 0.34, 0.19);

const float DETAIL_FAR = 110.0;   // м: дальше мелкой детали нет
const float EDGE_JITTER = 0.9;    // в пикселях карты: насколько рваный край между биомами
const float ROCK_FROM = 0.30;     // 1 - нормаль.y: с какого уклона (около 45°) проступает скала
const float ROCK_TO = 0.46;

#include "res://resources/cloud_shadow.gdshaderinc"
#include "res://resources/depth_tone.gdshaderinc"

varying float surface_cloud;
varying vec3 wpos;
varying vec3 wnormal;
varying vec3 road_detail;
varying vec4 road_bump_p;
varying float road_bump_weight;
varying float road_crack;
varying float singletrack;

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

// 12.11.2026: тон растительных сообществ открытых мест. Тот же хеш (WGRandom.hash2) и плавный шум
// (VegetationLayer._vnoise), что у раскладки подлеска: пятна высокотравья, разнотравья, кустарника и иван-чая
// на земле совпадают с ближними куртинами и продолжаются вдаль, где самих растений уже нет.
global uniform ivec4 veg_seeds; // (сид ^ 8803) для шума ~144 м, ~44 м, ~12 м и ~24 м (иван-чай)
float wg_hash2(ivec2 c, int seed) {
	uint h = (uint(c.x) * 374761393u + uint(c.y) * 668265263u) ^ uint(seed);
	h = (h ^ (h >> 13u)) * 1274126177u;
	return float(h ^ (h >> 16u)) * (1.0 / 4294967296.0);
}
// cell — непрерывные координаты клетки (м / 4); как _vnoise(i, j, scale, seed) в центре клетки i, j
float wg_vnoise(vec2 cell, float scale, int seed) {
	vec2 f = cell / scale;
	vec2 i0 = floor(f);
	vec2 t = f - i0;
	t = t * t * (3.0 - 2.0 * t);
	ivec2 c = ivec2(i0);
	float a = mix(wg_hash2(c, seed), wg_hash2(c + ivec2(1, 0), seed), t.x);
	float b = mix(wg_hash2(c + ivec2(0, 1), seed), wg_hash2(c + ivec2(1, 1), seed), t.x);
	return mix(a, b, t.y);
}

void vertex() {
	wpos =(MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	wnormal = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
	// 12.11: тень облаков — в вершине (сетка 4 м, пятна 160 м; ошибка линейной интерполяции < 1 %), а не 20 хэшей на пиксель.
	surface_cloud = cloud_light(wpos.xz + world_offset);
	// Выбираем свойства в вершине: в пикселях смешиваются свойства, а не номера материалов.
	road_detail = surface_detail[clamp(int(round(UV2.y)), 0, 7)];
	road_bump_p = surface_bump[clamp(int(round(UV2.y)), 0, 7)];
	road_bump_weight = UV2.y > 0.0 ? 1.0 : 0.0;
	road_crack = surface_crack[clamp(int(round(UV2.y)), 0, 7)];
	// Fractional channel preserves the material ID and the physical across coordinate.
	singletrack = clamp(fract(UV2.y) * 4.0, 0.0, 1.0);
	if (use_vertex_color && !OUTPUT_IS_SRGB) {
		// цвета вершин записаны в sRGB (как vertex_color_is_srgb у StandardMaterial3D): в Compatibility, как и
		// текстура карты плана, остаются в sRGB, иначе край плана на HD 4600 даёт шов по яркости
		COLOR.rgb = mix(pow((COLOR.rgb + vec3(0.055)) * (1.0 / 1.055), vec3(2.4)), COLOR.rgb * (1.0 / 12.92), lessThan(COLOR.rgb, vec3(0.04045)));
	}
}

void fragment() {
	vec2 p = wpos.xz + world_offset;
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
	float exposure = use_vertex_color ? COLOR.a : 0.0;
	// Snow rests on shoulders and ledges. A white biome texel stretched down
	// a cliff must not paint a vertical snow streak over the bedrock face.
	float snow_biome = smoothstep(0.55, 0.8, min(col.r, min(col.g, col.b)));
	float snow_hold = 1.0 - smoothstep(0.18, 0.48, slope);
	float snow = snow_biome * snow_hold;
	col = mix(col, rock_color, snow_biome * (1.0 - snow_hold));
	float sky = 1.0;
	vec3 base_col = col;
	float canopy = 0.0;
	float wet = use_vertex_color ? UV.x : 0.45; // за краем влажность почвы передаёт меш
	if (forest_enabled && !use_vertex_color) {
		vec4 forest = texture(forest_tex, UV);
		wet = forest.b;
		exposure = forest.a;
		float cover = smoothstep(0.03, 0.8, forest.r) * (1.0 - snow);
		canopy = cover;
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
			// первые опавшие листья: в лиственном лесу часть листьев подстилки жёлтая
				vec3 leaf_c = mix(dry_litter * mix(0.85, 1.2, scatter.x), vec3(0.50, 0.33, 0.05), step(0.74, scatter.x) * (1.0 - forest.g) * 0.85);
				soil = mix(soil, leaf_c, litter * near * (0.55 - moss * 0.25));
		}
		col = mix(col, soil, cover * (0.62 + patch * 0.25));
		// 6.7: под пологом меньше света неба. Хвойный плотнее и холоднее; в лиственном
		// медленно плывут тёплые просветы — как солнце сквозь качающуюся листву.
		// 6.8: на опушке тень набирается медленнее, под ельником светлее, просветы заметнее.
		float shade = smoothstep(0.12, 1.0, forest.r) * (1.0 - snow);
		sky = 1.0 - shade * mix(0.28, 0.37, forest.g);
		col *= mix(vec3(1.0), vec3(0.95, 0.98, 1.0), shade * forest.g);
		// Sun patches come from actual crown shadows.
	}
	// Distant plant communities use the existing masks/noise, not extra geometry/textures.
	float nature_far = smoothstep(120.0, 360.0, length(wpos - CAMERA_POSITION_WORLD)) * distant_vegetation.w;
	float distant_canopy = use_vertex_color ? UV.y : canopy;
	distant_canopy *= (1.0 - snow) * (1.0 - smoothstep(0.18, 0.42, slope)) * (1.0 - road_bump_weight);
	vec3 crown_ground = mix(vec3(0.13, 0.21, 0.065), vec3(0.075, 0.15, 0.085), clamp(0.55 - wet, 0.0, 1.0));
	col = mix(col, crown_ground * (0.8 + n_big * 0.4), distant_canopy * nature_far * 0.55);
	// 07.11.2026: горная порода. Тот же канал открытости (forest.a / COLOR.a), уклон и серые скальные
	// биомы (по цвету карты, как снег) дают три характера: коренную породу (плиты, уступы, трещины),
	// осыпи (щебень на склонах 25–40°) и пятна грунта с дёрном в сырых местах. Крупные различия
	// (тела породы и осыпи в сотню метров, осыпи, грунт, пласты, тон отдельных блоков) — только цвет и ALU, они видны
	// и за DETAIL_FAR и гаснут по размеру пикселя, а не по расстоянию. Одна новая выборка текстуры.
	float broken = smoothstep(0.25,0.75,n_big + (n_mid-0.5)*0.25);
	float sat = max(base_col.r, max(base_col.g, base_col.b)) - min(base_col.r, min(base_col.g, base_col.b));
	float grey = (1.0 - smoothstep(0.05, 0.09, sat)) * smoothstep(0.09, 0.15, dot(base_col, vec3(0.333))) * (1.0 - snow);
	rock = max(max(rock, exposure * mix(0.65,1.0,broken)), grey * 0.96);
	// Выборка и производные — до ветвления (см. маску полотна ниже): на краю ветки они не определены.
	float n_macro = texture(detail_tex, p * (1.0 / 600.0) + vec2(0.13, 0.57)).r;
	float px3 = max(length(fwidth(wpos)), 1e-4);
	// 11.11.2026: открытая земля. Раньше луг, степь, песок и снег были одним цветом карты с пятнами яркости.
	// Теперь у каждого свой характер, по цвету карты биомов (как снег и серая порода), без новых данных:
	//   дёрн — сухие и сочные поляны в десятки и сотни метров (видны и вдали), куртины, вблизи волокна травы,
	//          светлые сухие стебли, проплешины земли с камешками и редкие цветы на сочной траве;
	//   песок — светлые гребни и тёмные ложбины, ветровая рябь (тон и свет), редкие камешки и ракушки;
	//   снег — голубые тени между застругами, заструги светом, искры вблизи.
	// Под пологом леса остаётся лесная подстилка, на скале — порода, на полотне — покрытие (они ниже).
	// Вдали (near = 0) — только арифметика; вблизи две новые выборки шума для волокон травы.
	// Участки (вторая волна, 11.11): внутри одного биома земля разная не цветом, а характером. Поле участков
	// ~100 м (своя выборка шума, повёрнутая) вместе с уклоном и влажностью даёт каменистые сухие места
	// (на склонах чаще: больше голой земли и камней, трава реже и суше) и сырые низины (трава гуще и темнее,
	// больше цветов, песок темнее и плотнее, снег — наст). Оттенок остаётся в семье биома.
	vec2 ground_tilt = vec2(0.0);
	float ground_relief = 0.0;
	float ground_lumps = 0.0;
	float ground_w = (1.0 - rock) * (1.0 - canopy * 0.85);
	float n_zone = texture(detail_tex, vec2(dot(p, vec2(0.78, -0.62)), dot(p, vec2(0.62, 0.78))) * (1.0 / 97.0) + vec2(0.71, 0.29)).r;
	if (ground_w > 0.01) {
		float stony = smoothstep(0.54, 0.68, n_zone + (n_mid - 0.5) * 0.14 + slope * 0.9);
		float damp = smoothstep(0.54, 0.68, (1.0 - n_zone) + (n_mid - 0.5) * 0.14 + (wet - 0.45) * 0.6 - slope * 0.8);
		float water_tone = smoothstep(0.02, 0.10, base_col.b - max(base_col.r, base_col.g));
		float sand = smoothstep(0.52, 0.66, base_col.r) * smoothstep(0.12, 0.26, base_col.r - base_col.b) * (1.0 - snow_biome);
		float veg = (1.0 - sand) * (1.0 - snow_biome) * (1.0 - water_tone);
		float lush = smoothstep(-0.02, 0.14, base_col.g - base_col.r);
		float drift = smoothstep(0.28, 0.72, n_macro * 0.55 + n_big * 0.45);
		vec3 c0 = col;
		if (veg > 0.01) {
			// 12.11.2026: конец лета. Тёплая зелень умеренных биомов (луг, лиственный лес, степь, тундра; по цвету
			// карты: красного больше синего) зрелая: тон глуше и оливковее, сухие поляны выгорают в солому и охру.
			// Сочная зелень остаётся в сырых низинах и у воды. Тайга и джунгли (холодная зелень) — как были.
			float season = smoothstep(-0.005, 0.03, base_col.r - base_col.b);
			float dryness = clamp(mix(0.72, 0.22, lush) + (0.5 - wet) * 0.5 + (drift - 0.5) * 0.8 + stony * 0.28 - damp * 0.3 + season * 0.08, 0.0, 1.0);
			vec3 turf = c0 * mix(vec3(0.80, 0.97, 0.84), vec3(1.20, 1.07, 0.74), dryness);
			float turf_l = dot(turf, vec3(0.3, 0.55, 0.15));
			turf = mix(turf, turf_l * vec3(1.06, 0.98, 0.62), season * mix(0.36, 0.5, dryness) * (1.0 - damp * 0.6));
			float ripe = smoothstep(0.30, 0.82, dryness + (n_mid - 0.5) * 0.22 + (n_zone - 0.5) * 0.3) * season * (1.0 - damp * 0.85);
			turf = mix(turf, turf_l * vec3(1.42, 1.20, 0.40), ripe * 0.42);
			float clump = smoothstep(0.34, 0.70, n_mid * 0.6 + n_fine * 0.4);
			turf *= mix(0.88, 1.09, clump);
			// участки видны и вдали: каменистый — реже и землистее, сырой — гуще и темнее
			vec3 soil_far = mix(vec3(0.20, 0.15, 0.095), vec3(0.34, 0.27, 0.17), dryness);
			turf = mix(turf, soil_far, stony * mix(0.16, 0.30, clump));
			turf *= mix(vec3(1.0), vec3(0.84, 0.95, 0.80), damp);
			ground_lumps = veg;
			if (near > 0.0) {
				vec2 gp = p + (vec2(n_mid, n_big) - 0.5) * 1.6;
				float blades = texture(detail_tex, vec2(dot(gp, vec2(0.92, 0.39)) * 2.9, dot(gp, vec2(-0.39, 0.92)) * 0.55)).r;
				float blades2 = texture(detail_tex, vec2(dot(gp, vec2(0.31, 0.95)) * 2.3, dot(gp, vec2(-0.95, 0.31)) * 0.47) + vec2(0.41, 0.13)).r;
				turf *= 1.0 + (blades + blades2 - 1.0) * 0.42 * near;
				turf = mix(turf, turf * vec3(1.30, 1.20, 0.82), smoothstep(0.60, 0.78, blades) * dryness * 0.55 * near);
				// проплешины: на сухом чаще; земля с камешками
				float bare = smoothstep(0.66, 0.78, (1.0 - n_mid) * 0.45 + (1.0 - n_big) * 0.2 + n_fine * 0.2 + blades2 * 0.15 + dryness * 0.09 + stony * 0.17 - damp * 0.08);
				// впадины между куртинами темнее: трава читается объёмом, а не плоской краской
				turf *= mix(0.74, 1.07, smoothstep(0.22, 0.62, n_fine * 0.55 + blades * 0.45));
				vec2 pc = p * 6.3 + vec2(3.7, 9.1);
				vec2 ph = grain_hash(floor(pc));
				vec2 pl = fract(pc) - (vec2(0.3) + ph * 0.4);
				float pr = 0.10 + ph.x * 0.14;
				float paa = max(px3 * 6.3 * 0.5, 0.01);
				float pebble = (1.0 - smoothstep(pr - paa, pr + paa, length(pl))) * step(0.45 - stony * 0.2, ph.y) * (1.0 - smoothstep(0.25, 0.6, paa));
				vec3 earth = mix(vec3(0.17, 0.12, 0.075), vec3(0.33, 0.26, 0.16), dryness) * (0.85 + n_fine * 0.3);
				earth = mix(earth, rock_color * mix(0.6, 0.95, ph.x), pebble * 0.8);
				turf = mix(turf, earth, bare * 0.72 * near);
				// на каменистом участке камни лежат и в траве
				float loose = pebble * max(bare, stony * 0.7);
				turf = mix(turf, rock_color * mix(0.6, 0.95, ph.x) * (0.8 + 0.3 * clamp(1.0 - length(pl) / pr, 0.0, 1.0)), (loose - pebble * bare) * 0.8 * near);
				ground_tilt += pl / pr * loose * 0.7;
				ground_relief = max(ground_relief, loose);
				// цветы: редкие точки на сочных полянах
				vec2 fc = p * 4.1 + vec2(11.3, 2.9);
				vec2 fh = grain_hash(floor(fc));
				vec2 fl = fract(fc) - (vec2(0.2) + fh * 0.6);
				float faa = max(px3 * 4.1 * 0.5, 0.008);
				float flower = (1.0 - smoothstep(0.075 - faa, 0.075 + faa, length(fl))) * step(0.90, fh.x)
					* smoothstep(0.45, 0.65, n_big + (n_mid - 0.5) * 0.5 + damp * 0.25) * lush * (1.0 - bare) * (1.0 - stony * 0.7) * (1.0 - smoothstep(0.12, 0.4, faa));
				vec3 petal = fh.y < 0.45 ? vec3(0.92, 0.90, 0.80) : (fh.y < 0.8 ? vec3(0.93, 0.72, 0.10) : vec3(0.50, 0.36, 0.72));
				turf = mix(turf, petal, flower * 0.85 * near);
			}
			// 12.11.2026: сообщества открытых мест (Understory.communities) — по тем же полям и шуму, что ближняя
			// раскладка. Вблизи тон слабый (там стоят сами куртины), вдаль усиливается: массивы высокотравья
			// гуще и темнее, разнотравье светлое с дымкой цветов, кустарник оливково-тёмный, сырые места
			// сизо-зелёные, горная дернина сероватая, ковыль серебрится, иван-чай — розово-лиловые пятна.
			float view_d = length(wpos - CAMERA_POSITION_WORLD);
			float open_w = mix(0.35, 1.0, smoothstep(30.0, 160.0, view_d)) * (1.0 - (use_vertex_color ? UV.y : canopy)) * distant_vegetation.w;
			if (open_w > 0.01) {
				vec2 cell = p * 0.25;
				float big = wg_vnoise(cell, 36.0, veg_seeds.x);
				float mid = wg_vnoise(cell, 11.0, veg_seeds.y);
				vec3 wn = normalize(wnormal);
				float sl = sqrt(max(1.0 - wn.y * wn.y, 0.0)) / max(wn.y, 0.05) * 0.46; // уклон в единицах WorldData.slope
				float alt = wpos.y / 260.0;
				float light = clamp(0.5 + 0.5 * wn.z, 0.0, 1.0);
				float dry_b = 1.0 - smoothstep(0.0, 0.08, base_col.g - base_col.r);
				float flat_g = 1.0 - smoothstep(0.35, 0.95, sl);
				float foothill = smoothstep(0.16, 0.3, alt) * (1.0 - smoothstep(0.42, 0.55, alt));
				float high = smoothstep(0.3, 0.44, alt);
				float wet_c = smoothstep(0.55, 0.85, wet);
				float c_tall = smoothstep(0.42, 0.72, big * 0.65 + mid * 0.35 + (wet - 0.5) * 0.45) * flat_g * (1.0 - 0.7 * dry_b);
				float c_forbs = smoothstep(0.4, 0.7, (1.0 - big) * 0.55 + mid * 0.45 + (light - 0.5) * 0.35) * (1.0 - 0.6 * wet_c) * (1.0 - 0.5 * high);
				float c_shrub = (foothill * smoothstep(0.5, 0.8, mid) * 0.65
					+ smoothstep(0.1, 0.4, sl) * smoothstep(0.48, 0.7, mid * 0.6 + (1.0 - big) * 0.4) * (1.0 - 0.7 * smoothstep(0.6, 0.85, wet)) * 1.1) * (1.0 - 0.4 * dry_b);
				float c_wet = smoothstep(0.78, 0.95, wet) * flat_g * (1.0 - smoothstep(0.1, 0.3, alt)) * 0.48;
				float c_turf = high * (1.0 - 0.5 * exposure) + exposure * 0.5;
				float c_lawn = (0.45 + 0.4 * (1.0 - mid) + dry_b * 0.5) * 0.55;
				vec3 ca = vec3(c_lawn, c_tall, c_forbs);
				vec3 cb = vec3(c_shrub, c_wet, c_turf);
				ca = ca * ca * ca + 0.001;
				cb = cb * cb * cb + 0.001;
				float total = ca.x + ca.y + ca.z + cb.x + cb.y + cb.z;
				ca /= total;
				cb /= total;
				float parch = clamp((0.55 - wet) * 1.6 + dry_b * 0.35 + alt * 0.4, 0.0, 1.0);
				float steppe = clamp(max(dry_b, smoothstep(0.45, 0.8, parch) * light * 1.3), 0.0, 1.0);
				vec3 tone = vec3(ca.x)
					+ ca.y * mix(vec3(0.72, 0.88, 0.60), vec3(1.12, 1.0, 0.64), parch)
					+ ca.z * mix(vec3(1.12, 1.08, 0.90), vec3(1.15, 1.02, 1.04), smoothstep(0.4, 0.7, big))
					+ cb.x * vec3(0.58, 0.70, 0.52)
					+ cb.y * vec3(0.74, 0.92, 0.84)
					+ cb.z * vec3(1.0, 0.94, 0.82);
				vec3 open_col = turf * tone;
				// ковыль: серебристо-соломенный блеск в высокотравье и газоне степи
				float lum = dot(open_col, vec3(0.3, 0.55, 0.15));
				open_col = mix(open_col, vec3(lum) * vec3(1.12, 1.08, 0.92), steppe * (ca.x + ca.y) * 0.45);
				// иван-чай — своими пятнами (~24 м) на опушках, в разнотравье и кустарнике
				float bloom = smoothstep(0.58, 0.82, wg_vnoise(cell, 6.0, veg_seeds.w)) * (1.0 - steppe) * clamp(ca.y * 0.3 + ca.z * 0.6 + cb.x * 1.2, 0.0, 1.0);
				open_col = mix(open_col, vec3(lum) * vec3(1.35, 0.78, 1.15), bloom * 0.42);
				turf = mix(turf, open_col, open_w);
			}
			col = mix(col, turf, veg * ground_w);
		}
		if (sand > 0.01) {
			vec3 dune = c0 * mix(vec3(0.86, 0.84, 0.82), vec3(1.08, 1.06, 1.01), drift) * mix(1.0, 0.82, smoothstep(0.55, 0.9, wet));
			// сырой плотный песок темнее и без ряби; каменистый участок — галька и щебень
			dune *= mix(vec3(1.0), vec3(0.80, 0.79, 0.76), damp);
			dune = mix(dune, rock_color * 0.82, stony * mix(0.10, 0.26, smoothstep(0.35, 0.7, n_mid)));
			// 12.11.2026: морской берег по высоте над уровнем моря (0 м): полоса прибоя — тёмный мокрый песок
			// с рваным краем; линия выброса — прерывистая тёмная кромка водорослей и щепы; береговой вал
			// гальки — на части берегов узкой полосой, на других (свой шум ~600 м) галечный пляж целиком;
			// выше — дюны с пятнами серо-зелёной песчаной травы. Озёрные берега темнит влажность, как раньше.
			float coast = (1.0 - smoothstep(3.5, 6.5, wpos.y)) * step(-0.5, wpos.y);
			float swash = 0.0;
			if (coast > 0.01) {
				float shore_y = wpos.y + (n_mid - 0.5) * 0.45 + (n_big - 0.5) * 0.35;
				swash = (1.0 - smoothstep(0.3, 0.85, shore_y)) * coast;
				float wrack_at = 1.05 + (n_big - 0.5) * 0.5;
				float wrack = (1.0 - smoothstep(0.04, 0.16, abs(shore_y - wrack_at))) * smoothstep(0.35, 0.6, n_mid * 0.7 + n_fine * 0.3) * coast;
				float shingle_coast = smoothstep(0.58, 0.72, n_macro + (n_big - 0.5) * 0.25);
				float berm = smoothstep(0.75, 1.0, shore_y) * (1.0 - smoothstep(1.6, 2.4, shore_y)) * smoothstep(0.3, 0.6, n_big + (n_mid - 0.5) * 0.4);
				float shingle = max(shingle_coast * (1.0 - smoothstep(2.6, 4.0, shore_y)), berm * 0.8) * coast;
				vec3 pebbles = rock_color * mix(0.58, 0.98, n_mid) * mix(vec3(1.0), vec3(1.06, 1.0, 0.92), n_big);
				if (near > 0.0) {
					// гальки разного тона вблизи (две ячейки на метр)
					vec2 gc = p * 2.3 + vec2(5.1, 1.7);
					vec2 gh = grain_hash(floor(gc));
					float gr = length(fract(gc) - 0.5 - (gh - 0.5) * 0.3);
					pebbles *= mix(1.0, mix(0.7, 1.18, gh.x) * (1.0 - smoothstep(0.32, 0.48, gr) * 0.35), near);
				}
				dune = mix(dune, pebbles, shingle * 0.85);
				dune *= mix(1.0, 0.6, swash * (1.0 - shingle * 0.4));
				dune = mix(dune, vec3(0.16, 0.15, 0.11), wrack * 0.55 * (1.0 - shingle));
				float marram = smoothstep(2.2, 3.4, shore_y) * smoothstep(0.48, 0.7, n_mid * 0.6 + n_big * 0.4) * (1.0 - shingle);
				dune = mix(dune, vec3(0.30, 0.33, 0.20) * (0.9 + n_fine * 0.2), marram * 0.4);
				stony = max(stony, shingle);
				damp = max(damp, swash);
			}
			float warp = (n_mid - 0.5) * 9.0 + (n_big - 0.5) * 16.0;
			float phase = dot(p, vec2(0.83, 0.56)) * (6.2831853 / 0.42) + warp;
			float ripple_vis = (1.0 - smoothstep(0.05, 0.16, px3 / 0.42)) * smoothstep(0.25, 0.6, n_big + (n_mid - 0.5) * 0.4) * (1.0 - damp * 0.8) * (1.0 - stony * 0.6);
			float crest = sin(phase);
			dune *= 1.0 + crest * 0.10 * ripple_vis;
			if (near > 0.0) {
				vec2 sc = p * 5.2 + vec2(1.9, 6.4);
				vec2 sh = grain_hash(floor(sc));
				vec2 sl = fract(sc) - (vec2(0.25) + sh * 0.5);
				float saa = max(px3 * 5.2 * 0.5, 0.01);
				float speck = (1.0 - smoothstep(0.09 - saa, 0.09 + saa, length(sl))) * step(0.9 - stony * 0.45, sh.x) * (1.0 - smoothstep(0.2, 0.5, saa));
				ground_tilt += sl / 0.09 * speck * 0.5;
				ground_relief = max(ground_relief, speck * sand);
				dune = mix(dune, sh.y < 0.5 ? rock_color * 0.6 : vec3(0.93, 0.90, 0.84), speck * 0.8 * near);
				dune *= 1.0 + (n_fine - 0.5) * 0.10 * near;
			}
			col = mix(col, dune, sand * ground_w);
			ground_tilt += vec2(0.83, 0.56) * cos(phase) * 0.55 * ripple_vis * sand;
			ground_relief = max(ground_relief, ripple_vis * sand);
		}
		if (snow > 0.01) {
			float hollow = smoothstep(0.30, 0.72, n_big * 0.6 + n_mid * 0.4);
			vec3 drift_c = c0 * mix(vec3(0.87, 0.92, 1.0), vec3(1.0), hollow);
			// выдутый наст: плотнее, чуть серо-голубой, проступают камни; в затишье — рыхлый белый снег
			drift_c *= mix(vec3(1.0), vec3(0.86, 0.90, 0.95), stony);
			drift_c = mix(drift_c, rock_color * 0.7, stony * smoothstep(0.62, 0.74, n_mid * 0.6 + n_fine * 0.4) * 0.8);
			float sphase = dot(p, vec2(0.56, -0.83)) * (6.2831853 / 1.7) + (n_mid - 0.5) * 7.0 + (n_big - 0.5) * 11.0;
			float sas_vis = 1.0 - smoothstep(0.05, 0.18, px3 / 1.7);
			drift_c *= 1.0 + sin(sphase) * 0.035 * sas_vis;
			if (near > 0.0) {
				vec2 kc = p * 37.0;
				float spark = step(0.985, grain_hash(floor(kc)).x) * (1.0 - smoothstep(0.15, 0.5, px3 * 37.0));
				drift_c += vec3(0.5) * spark * near;
			}
			col = mix(col, drift_c, snow * ground_w);
			ground_tilt += vec2(0.56, -0.83) * cos(sphase) * 0.35 * sas_vis * snow;
			ground_relief = max(ground_relief, sas_vis * snow * 0.8);
		}
		ground_relief *= ground_w;
	}
	if (rock > 0.01) {
		float cliff = smoothstep(0.20, 0.40, slope + (n_big - 0.5) * 0.10);
		// Осыпи — на склонах угла естественного откоса и пятнами по крупному шуму, не сплошным поясом.
		float band = smoothstep(0.05, 0.11, slope) * (1.0 - smoothstep(0.24, 0.34, slope));
		float scree = band * smoothstep(0.34, 0.66, n_macro * 0.75 + n_big * 0.25 + (n_mid - 0.5) * 0.1);
		scree = max(scree, (1.0 - band) * smoothstep(0.45, 0.8, n_big * 0.5 + n_macro * 0.5 + (n_mid - 0.5) * 0.2) * 0.4);
		scree *= 1.0 - cliff;
		// Грунт и дёрн — пологие сырые ложбины; на открытом сухом склоне его почти нет.
		float soil = (1.0 - smoothstep(0.05, 0.16, slope)) * smoothstep(0.6, 0.85, wet + (0.5 - n_macro) * 0.25 + (n_mid - 0.5) * 0.2);
		soil *= (1.0 - cliff) * (1.0 - exposure * 0.6);
		// 09.11.2026: пологие серые вершины без открытой породы (канал открытости мал) — не сплошная
		// коренная плита, а каменистая тундра: щебень и дерновина пятнами. Плиты и уступы остаются там,
		// где их объясняет форма: круча, открытая порода, скальные массивы (RockMassif) — геометрией.
		float fell = grey * (1.0 - cliff) * (1.0 - smoothstep(0.2, 0.55, exposure));
		scree = max(scree, fell * smoothstep(0.3, 0.62, n_big * 0.6 + n_macro * 0.4 + (n_mid - 0.5) * 0.3));
		soil = max(soil, fell * 0.75 * smoothstep(0.35, 0.65, wet + (n_mid - 0.5) * 0.35 + (0.5 - n_big) * 0.3) * (1.0 - snow));
		scree *= 1.0 - soil;
		// Тела породы: светлая тёплая и тёмная холодная, полосы в сотни метров.
		float litho = smoothstep(0.3, 0.7, n_macro + (n_big - 0.5) * 0.12);
		vec3 lith = mix(rock_color * vec3(0.58, 0.60, 0.65), rock_color * vec3(1.16, 1.10, 1.0), litho);
		// Пласты (по высоте, с падением) и швы отдельности: блоки 3–4 м, мощность пласта 1,6–3,2 м.
		vec3 q = vec3(p.x, wpos.y + dot(p, vec2(0.11, -0.07)) + (n_big - 0.5) * 2.5, p.y);
		// Joint directions follow the rock body, without a world-axis checkerboard.
		q.xz = vec2(dot(p, vec2(0.83, 0.56)), dot(p, vec2(-0.56, 0.83)));
		q.xz += (vec2(n_mid, n_big) - 0.5) * 3.2;
		float layer_h = mix(2.2, 4.4, n_macro);
		// Столбы отдельности 4,3 × 3,7 м, у каждого свой сдвиг пластов: уступы обрываются на швах
		// ступеньками, а не тянутся по склону сплошными горизонталями.
		vec2 cell = q.xz / vec2(4.3, 3.7);
		vec2 cell_i = floor(cell);
		vec2 fxz = cell - cell_i;
		float row = q.y / layer_h + grain_hash(cell_i).x;
		float row_i = floor(row);
		float fy = row - row_i;
		vec2 blk = grain_hash(cell_i + vec2(row_i * 17.0, row_i * 5.0));
		// Тон блоков меняется на границах пластов; на округлом склоне это кольца горизонталей, поэтому там слабо.
		float block_vis = (1.0 - smoothstep(0.6, 1.6, px3)) * mix(0.04, 0.40, cliff);
		float ledge_vis = (1.0 - smoothstep(layer_h * 0.04, layer_h * 0.14, px3)) * smoothstep(0.18, 0.36, slope);
		float crack_vis = 1.0 - smoothstep(0.06, 0.22, px3);
		float d_joint = min(min(fxz.x, 1.0 - fxz.x) * 4.3, min(fxz.y, 1.0 - fxz.y) * 3.7);
		float crack_w = 0.035 + 0.04 * blk.y;
		float joint = (1.0 - smoothstep(crack_w, crack_w + px3, d_joint)) * crack_vis;
		// Швы — короткие отрезки внутри пласта (отдельность смещена от пласта к пласту). Сплошные швы
		// по границам пластов на гладком меше рельефа читались как горизонтали карты — их нет.
		float crack = joint * mix(step(0.6, blk.x) * 0.55, step(0.18, blk.x), cliff) * smoothstep(0.08, 0.3, min(fy, 1.0 - fy) * layer_h);
		// Только у части блоков и только на круче: на округлом склоне сплошные пласты читались как горизонтали.
		ledge_vis *= cliff * step(0.62, blk.y) * 0.55;
		float ledge = mix(mix(0.93, 1.03, smoothstep(0.0, 0.4, fy)), 1.0, 1.0 - ledge_vis);
		vec3 bed = lith * mix(1.0, 0.86 + 0.26 * blk.x, block_vis) * ledge;
		// Лишайник на открытых плитах (пятна 7 м, вблизи — мелкие) и мох в трещинах сырых склонов.
		float lichen = smoothstep(0.60, 0.74, mix(n_mid, n_mid * 0.55 + n_fine * 0.45, near)) * (0.35 + 0.65 * near) * (1.0 - snow);
		bed = mix(bed, mix(vec3(0.30, 0.29, 0.15), lith * 0.55, smoothstep(0.4, 0.6, n_big)), lichen * 0.3);
		bed = mix(bed, mix(lith * 0.38, vec3(0.06, 0.09, 0.035), smoothstep(0.5, 0.75, wet) * (1.0 - snow)), crack * 0.7);
		// Щебень: светлее и мельче, с отдельными камнями вблизи; дальше — только тон.
		vec3 talus = mix(lith, rock_color * 1.15, 0.5) * (0.95 + 0.1 * n_mid);
		if (near > 0.0) {
			vec2 sc = p * 3.1 + vec2(n_big * 2.3, n_mid * 1.7);
			vec2 sh = grain_hash(floor(sc));
			vec2 sl = fract(sc) - (vec2(0.3) + sh * 0.4);
			float sr = 0.12 + sh.x * 0.16;
			float saa = max(px3 * 3.1 * 0.5, 0.01);
			float stone = (1.0 - smoothstep(sr - saa, sr + saa, length(sl))) * step(0.3, sh.y) * (1.0 - smoothstep(0.25, 0.6, saa));
			float dome = clamp(1.0 - length(sl) / sr, 0.0, 1.0);
			talus *= 1.0 + stone * (dome * 0.45 - 0.22) * near;
			talus = mix(talus, lith * mix(0.85, 1.12, sh.x), stone * 0.5 * near);
		}
		vec3 turf = mix(vec3(0.115, 0.095, 0.065), vec3(0.13, 0.16, 0.065), smoothstep(0.5, 0.8, wet + (n_mid - 0.5) * 0.4));
		turf = mix(turf, talus * 0.8, smoothstep(0.55, 0.75, n_fine) * 0.35 * near);
		vec3 geo = mix(mix(bed, talus, scree), turf, soil);
		col = mix(col, geo, rock * (0.92 - 0.7 * snow));
		// Уступы и швы видны и светом: нормаль верха пласта к небу, подрез вниз (мировые координаты).
		float relief_w = rock * (1.0 - scree) * (1.0 - soil) * (1.0 - snow * 0.6);
		vec3 dn = vec3(0.0, 1.0, 0.0) * (smoothstep(0.62, 0.95, fy) * 0.30 - (1.0 - smoothstep(0.0, 0.14, fy)) * 0.25) * ledge_vis * cliff;
		dn += vec3(blk.x - 0.5, 0.0, blk.y - 0.5) * 0.12 * block_vis * cliff;
		NORMAL = normalize(NORMAL + (VIEW_MATRIX * vec4(dn * relief_w, 0.0)).xyz);
	}
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
		// The mesh alpha also controls vegetation. Keep that boundary: fine noise belongs
		// to the litter/grit inside it, not a second repeating torn silhouette.
		float edge_v = COLOR.a;
		float soft = mix(0.12, 0.24, organic * (0.55 + wet * 0.45));
		soft = mix(soft, 0.10, rock * (1.0 - organic));
		float aa = clamp(mask_w * 0.5, 0.004, 0.18);
		road = smoothstep(0.5 - soft - aa, 0.5 + soft + aa, edge_v);
		// 11.4: обочина — полоса снаружи кромки, до конца маски вершин (около метра). У полотна сухой ободок.
		float verge = smoothstep(0.02, 0.30, edge_v) * (1.0 - road);
		float lip = road * (1.0 - smoothstep(0.55, 0.85, edge_v));
		// Поперечная координата полотна: 0 — ось, 1 — половина ширины (по ближайшему отрезку пути).
		float across = abs(UV2.x + (n_mid - 0.5) * 0.18);
		float tread = 1.0 - smoothstep(0.12, mix(0.78, 0.60, singletrack), across);
		float meadow = smoothstep(0.75, 0.98, organic);
		// 11.5: кочки полотна — то же поле, что у колёс (RoadBump): по покрытию, на крутом выше.
		// 12.3: с участками, колеями и ямами. Видны светом и тоном; гаснут, когда волна меньше нескольких пикселей.
		float grade = length(wnormal.xz) / max(wnormal.y, 0.2);
		// NONE contributes no wavelength. Preserve frequency while amplitude fades at the edge.
		vec4 bump_params = road_bump_p;
		if (road_bump_weight > 0.0) bump_params.y /= road_bump_weight;
		bump_params.y = max(bump_params.y, 0.1);
		float bump_wave = bump_params.y;
		vec3 bump = road_field(p, bump_params, grade, UV2.x, across_grad);
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
		// Не одинаковые круглые точки: у каждого камешка своя вытянутость и поворот.
		float stone_angle = scatter.y * 6.2831853;
		mat2 stone_rotation = mat2(vec2(cos(stone_angle), sin(stone_angle)), vec2(-sin(stone_angle), cos(stone_angle)));
		float stone_aspect = mix(0.65, 1.0, scatter.x);
		vec2 stone_local = stone_rotation * stone;
		stone_local.x /= stone_aspect;
		float radius = 0.10 + scatter.x * 0.13;
		float grain_aa = max(pixel_m * grain_scale * 0.5, 0.01);
		float grain_fade = 1.0 - smoothstep(0.25, 0.6, grain_aa);
		float pebbles = (1.0 - smoothstep(radius - grain_aa, radius + grain_aa, length(stone_local))) * step(0.25, scatter.y) * grain * grain_fade;
		float dome = clamp(1.0 - length(stone_local) / radius, 0.0, 1.0);
		// Редкие крупные камни на гравии и камне, по краям полотна чаще, чем на колее; на обочине — у любого покрытия.
		vec2 big_cells = rp * 2.9 + vec2(13.1, 7.7);
		vec2 big_scatter = grain_hash(floor(big_cells));
		vec2 rock_at = fract(big_cells) - (vec2(0.35) + big_scatter * 0.3);
		float rock_r = 0.08 + big_scatter.y * 0.07;
		float big_aa = max(pixel_m * 2.9 * 0.5, 0.01);
		float big_rocks = (1.0 - smoothstep(rock_r - big_aa, rock_r + big_aa, length(rock_at)))
			* step(0.86 - grain * 0.10 - smoothstep(0.55, 0.95, across) * 0.08, big_scatter.x)
			* max(smoothstep(0.25, 0.7, grain), verge * (0.6 - organic * 0.3)) * (1.0 - smoothstep(0.2, 0.6, big_aa));
		// Traffic sorts fines onto the tread; coarser scree remains at its sides.
		big_rocks *= 1.0 - tread * 0.85;
		float big_dome = clamp(1.0 - length(rock_at) / rock_r, 0.0, 1.0);
		// Обочина: трава гуще и темнее, с сухими пятнами; просветы почвы, разнесённой с полотна;
		// на них — выкатившийся гравий; камни. Цвет почвы — смесь покрытия и травы, без новых данных.
		vec3 verge_col = col;
		if (verge > 0.0) {
			float dry_grass = smoothstep(0.42, 0.72, fine * 0.5 + fleck * 0.5);
			verge_col *= mix(vec3(0.93, 0.97, 0.88), vec3(1.08, 1.03, 0.78), dry_grass);
			// Sparse dust/litter follows the shared shoulder, rather than drawing a
			// second bright, noise-cut outline (particularly conspicuous on sand).
			float bare = smoothstep(0.12, 0.48, edge_v) * (0.20 + (1.0 - organic) * 0.22)
				* (0.75 + fleck * 0.25) * near;
			vec3 earth = mix(COLOR.rgb * (0.9 + (fine - 0.5) * 0.12), col * 0.7, 0.22 + organic * 0.3);
			earth *= 1.0 + vec3(pebbles * (dome * 1.2 - 0.3) * 0.4 * near);
			verge_col = mix(verge_col, earth, bare * 0.8);
			vec3 verge_rock = rock_color * 0.78 * (0.8 + big_dome * 0.28) * mix(0.9, 1.06, big_scatter.y);
			verge_col = mix(verge_col, verge_rock, big_rocks * near);
		}
		float soil_detail = (fine - 0.5) * mix(0.05, 0.10, grain) + (fleck - 0.5) * 0.08;
		vec3 soil = COLOR.rgb * (0.95 + (n_mid - 0.5) * 0.14 + soil_detail * near);
		// Крупные пятна: суше и светлее / сырее, темнее и холоднее, чтобы полотно не было одного тона.
		float dry = (1.0 - wet) * 0.8 + n_big * 0.2;
		soil *= mix(vec3(0.92, 0.94, 0.96), vec3(1.04, 1.02, 0.98), smoothstep(0.2, 0.8, dry));
		soil *= 1.0 + vec3(pebbles * (dome * 1.1 - 0.3) * (0.20 + scatter.x * 0.12) * near);
		vec3 rock_tone = mix(soil, rock_color * 0.8, 0.55) * (0.82 + big_dome * 0.22) * mix(0.92, 1.05, big_scatter.y);
		soil = mix(soil, rock_tone, big_rocks * near);
		// Нерегулярная подстилка и просветы к траве, без одинаковых пар колей на каждом покрытии.
		float litter = smoothstep(0.38, 0.72, fleck + (fine - 0.5) * 0.3);
		soil *= 1.0 + (litter - 0.5) * organic * 0.22 * near;
		if (organic > 0.01 && near > 0.0) {
			// Редкие обрывки листьев и хвои лежат в материале тропы, а не повторяют шум почвы.
			vec2 litter_cells = p * 3.2 + vec2(19.7, 8.3);
			vec2 litter_scatter = grain_hash(floor(litter_cells));
			vec2 litter_local = fract(litter_cells) - (vec2(0.25) + litter_scatter * 0.5);
			float litter_angle = litter_scatter.x * 6.2831853;
			litter_local = mat2(vec2(cos(litter_angle), sin(litter_angle)), vec2(-sin(litter_angle), cos(litter_angle))) * litter_local;
			float litter_shape = abs(litter_local.x) * 0.8 + abs(litter_local.y) * 2.3;
			float litter_aa = max(pixel_m * 3.2, 0.015);
			float leaf = (1.0 - smoothstep(0.12 - litter_aa, 0.12 + litter_aa, litter_shape))
				* step(0.55, litter_scatter.y) * (1.0 - smoothstep(0.18, 0.55, litter_aa)) * organic * near;
			soil = mix(soil, dry_litter * mix(0.65, 1.0, litter_scatter.x), leaf * 0.35);
		}
		// Forest litter approaches from the sides without erasing the compacted centre.
		soil = mix(soil, col, organic * (1.0 - tread) * 0.24);
		// Накатанные колеи: местами, с разрывами, плотнее и темнее, мелкий камень с них выбит.
		// 12.3: там же, где колея RoadBump (её участки), а глубокие колеи на мягком ещё темнее.
		float rut_on = smoothstep(0.35, 0.7, ruts_patch.y);
		float tracks = exp(-pow((abs(UV2.x) - 0.47) / 0.13, 2.0)) * max(rut_on * smoothstep(0.0, 0.02, road_bump_p.z),
			smoothstep(0.35, 0.65, n_big + (fleck - 0.5) * 0.5) * 0.6)
			* (1.0 - organic * 0.4) * (1.0 - smoothstep(0.6, 1.0, grain) * 0.5) * near;
		tracks *= mix(1.0, meadow, singletrack);
		float foot_wear = tread * singletrack * (1.0 - meadow);
		soil *= 1.0 - foot_wear * (0.035 + wet * 0.035);
		soil *= 1.0 - tracks * (0.07 + fine * 0.05 + road_bump_p.z * 2.5);
		// Разбитая светлая кромка колеи и разная плотность грунта придают дороге глубину.
		float rut_edge = exp(-pow((abs(UV2.x) - 0.62) / 0.09, 2.0)) * rut_on * mix(1.0, meadow, singletrack);
		soil *= 1.0 + rut_edge * (0.025 + 0.025 * fleck) * (1.0 - organic * 0.5) * near;
		float compacted = smoothstep(0.38, 0.72, n_mid * 0.65 + fleck * 0.35);
		soil = mix(soil, soil * vec3(1.035, 1.02, 0.99), compacted * (1.0 - grain * 0.5) * near);
		// На заросшей колее в колеях проступает земля.
		// Meadow cart tracks expose soil, with a grass centre. Never expand beyond the
		// shared mask at a junction or into grass/rocks placed outside the tread.
		float meadow_wear = 1.0 - exp(-pow(across / 0.24, 2.0)) * 0.72;
		road *= mix(1.0, meadow_wear, meadow);
		// Ямы: дно темнее и влажнее.
		float pit = clamp(-bump.x / 0.03, 0.0, 1.0) * (1.0 - tracks) * near;
		soil *= 1.0 - pit * 0.12;
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
			// A compacted stony tread is fines, not a sheet of cracked bedrock/concrete.
			float zone = smoothstep(0.42, 0.62, n_big + (fleck - 0.5) * 0.5) * road_crack
				* (1.0 - grain * 0.9) * (1.0 - wet * 0.65);
			soil *= 1.0 - lines * zone * (1.0 - smoothstep(0.02, 0.06, pixel_m)) * (1.0 - tracks * 0.6) * 0.4;
		}
		float wear = exp(-pow((UV2.x + (n_mid - 0.5) * 0.35) * 1.7, 2.0));
		soil *= 1.0 - wear * (1.0 - grain) * (1.0 - organic) * (0.02 + fleck * 0.04) * near;
		// Трава пробивается между колеями и у краёв заросших троп и грунтовок.
		float middle = exp(-pow(across * 2.6, 2.0)) * smoothstep(0.35, 0.9, 1.0 - grain) * mix(1.0, meadow, singletrack) + smoothstep(0.65, 1.0, across) * 0.5;
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
			vec2 stone_gradient = transpose(stone_rotation) * vec2(stone_local.x / stone_aspect, stone_local.y);
			vec2 tilt = stone_gradient / radius * pebbles * 0.9 + rock_at / rock_r * big_rocks * 0.6 + grit.xy * (0.25 + grain * 0.35) * (1.0 - tracks)
				- bump.yz * bump_vis * 2.2 * road; // глубина карты нормалей на полотне ~0,3 (14.5: было 4,0 — узор)
			vec3 road_normal = normalize(vec3(tilt, 1.0)) * 0.5 + 0.5;
			detail_n = mix(detail_n, road_normal, relief);
		}
	}
	// рябь песка, заструги и камешки проплешин — своим светом (вне полотна)
	float ground_n = ground_relief * (1.0 - road) * near;
	// объём: к общей карте нормалей добавляется вторая, мелкая (кочки и куртины 0,6 м) — трава лежит буграми
	float lumps = ground_lumps * ground_w * (1.0 - road) * near;
	if (lumps > 0.0) {
		vec3 n2 = texture(detail_normal, p * (1.0 / 0.61) + vec2(0.31, 0.63)).rgb;
		detail_n.xy += (n2.xy - 0.5) * 0.9 * lumps;
	}
	if (ground_n > 0.0) {
		detail_n = mix(detail_n, normalize(vec3(ground_tilt, 1.0)) * 0.5 + 0.5, ground_n * 0.8);
	}
	ALBEDO = depth_tone(col * (1.0 + v), length(VERTEX));
	ROUGHNESS = 1.0;
	SPECULAR = 0.3;
	AO = sky;
	AO_LIGHT_AFFECT = 0.0;
	NORMAL_MAP = detail_n;
	NORMAL_MAP_DEPTH = mix(0.6 + 0.6 * rock + 0.5 * ground_n + 0.55 * lumps, 0.2 + road_rough * 0.4, road) * near;
}

// Clouds attenuate the directional source, never sky light or bicycle lamps.
void light() {
	float visibility = ATTENUATION * (LIGHT_IS_DIRECTIONAL ? surface_cloud : 1.0);
	float ndl = dot(NORMAL, LIGHT);
	vec3 diffuse = vec3(max(ndl, 0.0));
	DIFFUSE_LIGHT += diffuse * LIGHT_COLOR * visibility / PI;
}
