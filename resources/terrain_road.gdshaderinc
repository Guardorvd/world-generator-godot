// Дорожное полотно для terrain.gdshader (15.11.2026: вынесено из общего файла).
// 1. Поле RoadBump — те же формулы, что трясут велосипед (scripts/game/road_bump.gd): волны, колеи, ямы.
// 2. road_fabric — фактура покрытия из общей микроструктуры земли (micro_tex / micro_n уже прочитаны
//    шейдером рельефа): щебень, комья, зерно, сколы, хвоя, рябь песка. Новых выборок текстур нет.
// Подключается после объявления rock_color и dry_litter.

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
		// колея RoadBump.RUT_AT / RUT_W — uniform road_rut шейдера рельефа (16.11.2026)
		float e = exp(-pow((a - road_rut.x) / road_rut.y, 2.0));
		float depth = b.z * smoothstep(0.35, 0.7, pt.y);
		f.x -= depth * e;
		f.yz -= depth * e * (-2.0 * (a - road_rut.x) / (road_rut.y * road_rut.y)) * sign(across) * ga;
	}
	if (b.w > 0.0 && a < 0.75) {
		vec4 pit = road_hole(p, b.w * smoothstep(0.3, 0.8, pt.x) * 1.5);
		f -= vec3(pit.x, pit.yz) * pit.w * 0.09;
	}
	return f;
}

// Фактура покрытия. mh — высоты микроструктуры (R — пряди, G — галька и комья, B — зерно, A — трещины), mn — её нормали.
// look (RoadBump.LOOK): x — комья земли, y — рябь песка, z — отклик на влагу, w — угловатость щебня.
// tread — накатанная полоса (камень с неё выбит, грунт уплотнён), compact — плотные участки, crack — сила трещин здесь.
// tilt — наклон нормали от фактуры (в осях мира x, z).
vec3 road_fabric(vec3 soil, vec4 mh, vec4 mn, vec4 look, float grain, float organic, float crack, float tread,
		float compact, vec2 p, float pixel_m, float warp, float near, out vec2 tilt) {
	float st = mh.g - 0.5;
	float loose = 1.0 - tread * 0.55;
	float stones = grain * loose;
	float clods = look.x * (1.0 - compact * 0.6) * loose;
	// камни и комья: макушки светлее, щели темнее; зерно — на гладких покрытиях заметнее
	soil *= 1.0 + (st * (0.62 * stones + 0.30 * clods) + (mh.b - 0.5) * (0.20 - 0.10 * grain)) * near;
	// отдельные камни — цвета местной породы, а не краски полотна
	soil = mix(soil, rock_color * mix(0.62, 1.02, mh.b), smoothstep(0.55, 0.85, mh.g) * stones * 0.42 * near);
	// сколы угловатого щебня и трещины сухой земли — один канал
	soil *= 1.0 - mh.a * min(look.w * 0.26 + crack * 0.5, 0.7) * near;
	// хвоя и сухие стебли лежат по краям тропы, середина утоптана
	float fibre = smoothstep(0.45, 0.8, mh.r) * organic * (1.0 - tread * 0.6);
	soil = mix(soil, dry_litter * mix(0.7, 1.05, mh.b), fibre * 0.32 * near);
	tilt = (mn.zw - vec2(0.5)) * (1.9 * stones * (1.0 + look.w * 0.6) + 1.1 * clods) + (mn.xy - vec2(0.5)) * 0.7 * fibre;
	if (look.y > 0.01) {
		// ветровая рябь песка; на накатанной полосе её нет
		float vis = (1.0 - smoothstep(0.05, 0.16, pixel_m / 0.34)) * look.y * (1.0 - tread * 0.75);
		float phase = dot(p, vec2(0.83, 0.56)) * (6.2831853 / 0.34) + warp;
		soil *= 1.0 + sin(phase) * 0.07 * vis;
		tilt += vec2(0.83, 0.56) * cos(phase) * 0.5 * vis;
	}
	return soil;
}
