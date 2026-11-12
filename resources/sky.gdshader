// Стилизованное небо (с 7.8): градиент зенит — горизонт, мягкое гало солнца, диск луны, звёзды ночью
// и облака. Цвета и направления каждый кадр задаёт DayCycle (scripts/render/day_cycle.gd).
// Ниже горизонта небо — цвет горизонта: он же цвет тумана, иначе на краю земли виден шов.
// В проходе карты отражений (AT_CUBEMAP_PASS) только градиент и гало: звёзды, облака и диски там не нужны.
// 7.9 / 15.0: живые объёмные облака в три яруса на сферическом куполе атмосферы:
// 1) высокие перистые «когти/перья» (cirrus uncinus) с ветровым изгибом и перисто-кучевая рябь («барашки»);
// 2) средний ярус — высококучевые гряды и волны (altocumulus), дольше удерживающие закатный свет;
// 3) нижний объёмный ярус (марш сквозь толщу) — разнообразные кучевые облака от лёгких плоских
//    облаков хорошей погоды (humilis) и ветровых валов (stratocumulus) до мощных клубящихся башен (congestus)
//    с ровной тёмной подошвой конденсации, кудрявыми вершинами, рваными краями (fractus), живой конвекцией,
//    фазовым рассеянием Ми (серебристая кромка у солнца и луны), законом Бугера — Порошка и подсветкой снизу на заре.
// 8.3: ночное небо. Звёзды разной яркости и цвета и Млечный Путь с пылевыми прожилками и цветными туманностями
// вращаются вокруг полюса мира вместе с часом (star_rot). Луна с морями и фазой (moon_phase, меняется по ночам).
// Редкие явления задаёт DayCycle по сиду мира: полярное сияние на севере, комета (неподвижна среди звёзд),
// метеоры (по одному изредка, в «звездопад» чаще). Всё ночное считается только при night > 0.
shader_type sky;

uniform vec3 zenith_color : source_color = vec3(0.32, 0.52, 0.82);
uniform vec3 horizon_color : source_color = vec3(0.62, 0.74, 0.88);
uniform vec3 sun_dir = vec3(0.0, 0.7, 0.7);      // к солнцу
uniform vec3 sun_color : source_color = vec3(1.0, 0.93, 0.8);
uniform float halo = 0.3;                        // сила гало вокруг солнца (на закате больше)
uniform vec3 moon_dir = vec3(0.0, -0.7, -0.7);
uniform float night = 0.0;                       // 0 днём, 1 ночью: звёзды и луна
uniform vec3 cloud_color : source_color = vec3(1.0);
uniform float cloud_cover = 0.4;                 // доля неба под кучевыми облаками, примерно
uniform int cumulus_steps : hint_range(2, 5) = 5;
uniform float cloud_time = 0.0;
uniform float cloud_seed = 0.0;                  // сид погоды мира: разнообразие форм и гряд
uniform float star_rot = 0.0;                    // поворот звёздного неба вокруг полюса, рад
uniform float moon_phase = 0.5;                  // 0 — новолуние, 0.5 — полнолуние
uniform float aurora = 0.0;                      // сила полярного сияния, 0..1
uniform float aurora_seed = 0.0;
uniform float comet = 0.0;                       // яркость кометы, 0..1
uniform vec3 comet_dir = vec3(0.0, 0.6, 0.8);    // голова кометы в системе звёзд
uniform vec3 comet_tail = vec3(1.0, 0.0, 0.0);   // куда смотрит хвост (касательная к небу)
uniform float meteor_rate = 0.0;                 // доля слотов по 2,5 с, в которых пролетает метеор

const vec3 POLE = vec3(0.0, 0.5736, -0.8192);    // ось мира: 35° над севером (путь солнца наклонён на 35° к югу)
const vec3 GALAXY = vec3(0.958, 0.266, 0.105);   // полюс Млечного Пути: под прямым углом к оси мира, поэтому полоса
                                                 // всегда проходит через полюс над севером и за ночь поворачивается
const mat2 OCT_ROT = mat2(vec2(0.80, 0.60), vec2(-0.60, 0.80));

float hash(vec2 p) {
	vec3 q = fract(vec3(p.xyx) * 0.1031);
	q += dot(q, q.yzx + 33.33);
	return fract((q.x + q.y) * q.z);
}

float hash3(vec3 p) {
	p = fract(p * 0.1031);
	p += dot(p, p.zyx + 31.32);
	return fract((p.x + p.y) * p.z);
}

float noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash(i), hash(i + vec2(1.0, 0.0)), u.x),
		mix(hash(i + vec2(0.0, 1.0)), hash(i + vec2(1.0, 1.0)), u.x), u.y);
}

float fbm(vec2 p) {
	return noise(p) * 0.5 + noise(p * 2.13 + 4.1) * 0.28 + noise(p * 4.37 - 2.7) * 0.14 + noise(p * 8.9 + 9.2) * 0.08;
}

// Бесшовный 3x3 ячеистый шум Уорли (Worley / Cellular): создаёт выпуклые сферические клубы («кудрявые шапки»)
// кучевых облаков со складками-ложбинками между соседними ячейками и живым вращением во времени.
// Предвычисленные sin/cos для morph избавляют от 9 вызовов тригонометрии на одну выборку.
float worley_puff(vec2 p, float morph) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	float min_d2 = 4.0;
	vec2 m_cs = vec2(cos(morph * 0.78), sin(morph * 0.78));
	for (int y = -1; y <= 1; y++) {
		for (int x = -1; x <= 1; x++) {
			vec2 nb = vec2(float(x), float(y));
			vec2 cell = i + nb;
			float h1 = hash(cell);
			float h2 = hash(cell + vec2(17.3, 31.7));
			vec2 dir = normalize(vec2(h1 - 0.5, h2 - 0.5) + vec2(1e-4));
			vec2 rot_dir = vec2(dir.x * m_cs.x - dir.y * m_cs.y, dir.x * m_cs.y + dir.y * m_cs.x);
			vec2 jitter = 0.5 + (vec2(h1, h2) - 0.5) * 0.46 + rot_dir * 0.14;
			vec2 diff = nb + jitter - f;
			min_d2 = min(min_d2, dot(diff, diff));
		}
	}
	float w = clamp(1.0 - min_d2 * 1.25, 0.0, 1.0);
	return w * w * (3.0 - 2.0 * w);
}

// Вращающийся многооктавный шум с живым течением мелких деталей во времени
float fbm_flow(vec2 p, float morph) {
	vec2 d1 = vec2(morph * 0.18, -morph * 0.12);
	float s = noise(p + d1) * 0.50;
	p = OCT_ROT * p * 2.07 + vec2(4.7, -3.1) - d1 * 1.4;
	s += noise(p) * 0.27;
	p = OCT_ROT * p * 2.13 + vec2(-6.2, 8.3) + d1 * 2.1;
	s += noise(p) * 0.15;
	p = OCT_ROT * p * 2.09 + vec2(3.1, 5.9) - d1 * 2.8;
	s += noise(p) * 0.08;
	return s;
}

// Проекция луча на плавно изогнутый купол неба на высоте слоя (d.y + curve):
// без гиперболического сжатия у горизонта и без радиального растяжения в зените
vec2 sky_uv(vec3 d, float curve) {
	return d.xz / (max(d.y, 0.0) + curve);
}

// Двухлепестковая фазовая функция Хеньи — Гринштейна: яркая серебристая кромка вперёд и мягкое обратное рассеяние
float cloud_phase(float cos_theta) {
	float g1 = 0.65;
	float g2 = -0.28;
	float f1 = (1.0 - g1 * g1) / pow(max(1.0 + g1 * g1 - 2.0 * g1 * cos_theta, 0.05), 1.5);
	float f2 = (1.0 - g2 * g2) / pow(max(1.0 + g2 * g2 - 2.0 * g2 * cos_theta, 0.05), 1.5);
	return mix(f2, f1, 0.74) * 0.24;
}

// 3D-плотность кучевого яруса (крупная форма FBM + скульптурная эрозия Worley-куполами):
// p — координаты в слое, h (0..1) — доля высоты от плоской подошвы до вершин башен,
// cov — базовое покрытие, morph — фаза живой конвекции, shadow_pass — облегчённая выборка для самотени
float cumulus_density(vec2 p, float h, float cov, float morph, bool shadow_pass, out float out_tower, out float out_cauli) {
	vec2 seed_ofs = vec2(cloud_seed * 0.37, cloud_seed * 0.61);
	vec2 mp = p * 0.28 + seed_ofs;
	// Синоптическая карта погоды: чередование чистых небесных окон, кучевых островов, мощных башен и валов
	float syn_group = smoothstep(0.28, 0.72, fbm(mp + vec2(morph * 0.04, -morph * 0.03)));
	float syn_tower = smoothstep(0.30, 0.75, noise(mp * 1.35 + vec2(13.4, -7.8) + morph * 0.05));
	out_tower = mix(0.45, 1.0, syn_tower);

	// Башни сужаются к вершине: широкое основание и рельефные пики наверху
	float taper = mix(0.0, 0.16, (h * h) / max(out_tower, 0.38));
	float eff_cov = clamp(cov * 0.90 - taper, 0.06, 0.74);
	float edge = 1.0 - eff_cov;

	float syn_street = smoothstep(0.45, 0.82, noise(mp * 0.90 + vec2(-9.1, 19.2)));

	// Плавное вихревое искажение области + небольшой ветровой наклон вершин башен
	vec2 w_uv = p * 0.62 + seed_ofs;
	vec2 warp = vec2(
		noise(w_uv + vec2(1.7 + morph * 0.12, 4.3)),
		noise(w_uv + vec2(8.9, 2.1 - morph * 0.12))
	) - 0.5;
	vec2 aniso = mix(vec2(1.0), vec2(0.76, 1.32), syn_street * 0.55);
	vec2 q = (p * aniso + warp * 0.45 + vec2(h * 0.08, h * 0.03)) * 1.55;

	// Макро-острова облаков с нормализованным диапазоном 0..1 (чистое синее небо между грядами)
	float macro_fbm = smoothstep(0.30, 0.73, fbm_flow(q * 0.88, morph));
	float base_island = mix(macro_fbm, syn_group, 0.28);

	// Ранний выход в чистом небе до тяжёлых 3x3 выборок Уорли
	if (base_island * 0.68 + 0.32 <= edge - 0.04) {
		out_cauli = 0.0;
		return 0.0;
	}

	float puff_main = worley_puff(q * 1.30 + vec2(h * 0.16, 0.0), morph);
	float bottom_flat = smoothstep(0.0, 0.14, h);

	if (shadow_pass) {
		// Для оптической глубины самотени достаточно крупного купола без высокочастотной кудрявой ряби
		out_cauli = puff_main * 0.82 + 0.10;
		float dome_sh = out_tower * (0.62 + 0.52 * puff_main);
		float vert_sh = bottom_flat * smoothstep(dome_sh, dome_sh * 0.20, h);
		float comb_sh = base_island * 0.68 + out_cauli * 0.32;
		float core_sh = clamp((comb_sh - edge) / max(1.0 - edge, 0.18), 0.0, 1.0);
		float ero_sh = (1.0 - out_cauli) * (0.22 + 0.22 * h) * (1.0 - core_sh * 0.75);
		return clamp((core_sh - ero_sh) * 1.95, 0.0, 1.0) * vert_sh;
	}

	// Многомасштабные сферические клубы Worley + кудрявая детализация шапок (чёткая и в зените, и у горизонта)
	float puff_mid = worley_puff(OCT_ROT * q * 2.85 + vec2(-2.7, 4.1 - h * 0.2), -morph * 1.3);
	float puff_fine = smoothstep(0.26, 0.74, fbm_flow(q * 5.2 + vec2(3.4, -5.1), morph * 1.7));
	float cauli = puff_main * 0.48 + puff_mid * 0.32 + puff_fine * 0.20;
	out_cauli = cauli;

	// Каждый клуб поднимает свою шапку выше соседних: пышные округлые купола вместо плоских пятен
	float dome_h = out_tower * (0.62 + 0.62 * puff_main * (0.6 + 0.4 * puff_mid));
	float top_round = smoothstep(dome_h, dome_h * 0.20, h);
	float vert_profile = bottom_flat * top_round;

	// Формируем плотное ядро облака и скульптурно вырезаем кудрявые купола по краям и на шапках
	float combined = base_island * 0.68 + cauli * 0.32;
	float core = clamp((combined - edge) / max(1.0 - edge, 0.18), 0.0, 1.0);
	float erosion = (1.0 - cauli) * (0.22 + 0.22 * h) * (1.0 - core * 0.75);
	float dens = clamp((core - erosion) * 1.95, 0.0, 1.0) * vert_profile;

	// Лёгкие рваные клочья (fractus) у самой подошвы крупных облаков
	float fractus = smoothstep(0.66, 0.88, puff_fine) * smoothstep(edge - 0.05, edge + 0.03, base_island)
		* smoothstep(0.32, 0.06, h) * bottom_flat * 0.18;
	return clamp(dens + fractus, 0.0, 1.0);
}

vec3 rotate(vec3 v, vec3 k, float a) {
	return v * cos(a) + cross(k, v) * sin(a) + k * dot(k, v) * (1.0 - cos(a));
}

// точечные звёзды: по одной в редкой ячейке сетки направлений; scale — сколько ячеек на радиан
vec3 stars(vec3 ds, float scale, float rare, float size, float bright) {
	vec3 p = ds * scale;
	vec3 cell = floor(p);
	float r = hash3(cell);
	if (r < rare) return vec3(0.0);
	vec3 star = cell + 0.5 + (vec3(hash3(cell + 7.1), hash3(cell + 3.7), hash3(cell + 9.3)) - 0.5) * 0.6;
	float k = (r - rare) / (1.0 - rare);
	float twinkle = 0.75 + 0.25 * sin(TIME * (1.5 + k * 3.0) + k * 40.0);
	float t = hash3(cell + 2.9);   // цвет: от голубых через белые к жёлтым и оранжевым
	vec3 tint = t < 0.25 ? vec3(0.75, 0.85, 1.0) : (t < 0.8 ? vec3(1.0) : (t < 0.94 ? vec3(1.0, 0.9, 0.7) : vec3(1.0, 0.7, 0.5)));
	return tint * smoothstep(size, 0.0, length(p - star)) * twinkle * bright * (0.35 + 0.65 * k * k);
}

// ночное небо в направлении d: звёзды, Млечный Путь, туманности, комета, метеоры, луна и сияние
vec3 night_sky(vec3 d, float sd) {
	float up = smoothstep(0.0, 0.08, d.y);
	vec3 md = normalize(moon_dir);
	float mc = dot(d, md);
	float illum = 0.5 - 0.5 * cos(moon_phase * 6.2832);
	vec3 ds = rotate(d, POLE, -star_rot);
	// Млечный Путь: полоса вдоль большого круга, клочковатая, с тёмными пылевыми прожилками
	vec3 gu = normalize(cross(GALAXY, vec3(0.0, 1.0, 0.0)));
	vec3 gw = cross(GALAXY, gu);
	float lat = dot(ds, GALAXY);
	vec2 gp = vec2(dot(ds, gu), dot(ds, gw)) * 4.0 + lat * vec2(2.5, -1.5);
	float band = exp(-lat * lat / 0.014);
	float clumps = fbm(gp);
	float dust = smoothstep(0.45, 0.7, fbm(gp * 2.3 + 5.0)) * exp(-lat * lat / 0.0025);
	float milky = band * (0.15 + 1.4 * clumps * clumps) * (1.0 - 0.7 * dust);
	vec3 col = vec3(0.55, 0.6, 0.85) * milky * 0.13;
	// туманности: редкие цветные облачка у Млечного Пути
	float neb = smoothstep(0.62, 0.85, fbm(gp * 0.7 + 21.0)) * exp(-lat * lat / 0.05);
	vec3 neb_col = mix(vec3(0.85, 0.3, 0.55), vec3(0.3, 0.55, 0.9), noise(gp * 0.4 + 3.0));
	col += neb_col * neb * 0.2;
	// звёзды: в полосе Млечного Пути их больше
	vec3 st = stars(ds, 170.0, mix(0.975, 0.93, band), 0.3, 1.1) + stars(ds, 62.0, 0.993, 0.2, 2.2);
	col += st;
	// комета: голова и два хвоста — пылевой желтоватый и прямой голубой ионный
	if (comet > 0.001) {
		vec3 hd = normalize(comet_dir);
		vec3 v = ds - hd;
		float near = dot(ds, hd);
		if (near > 0.9) {
			vec3 tl = normalize(comet_tail);
			float along = dot(v, tl);
			float across = length(v - tl * along - hd * dot(v, hd));
			float w = 0.004 + max(along, 0.0) * 0.07;
			float fall = 1.0 - clamp(along / 0.3, 0.0, 1.0);
			float dusty = step(0.0, along) * exp(-across * across / (w * w)) * fall * fall;
			vec3 ion_dir = normalize(tl + cross(hd, tl) * 0.18);
			float a2 = dot(v, ion_dir);
			float c2 = length(v - ion_dir * a2 - hd * dot(v, hd));
			float ion = step(0.0, a2) * exp(-c2 * c2 / 0.000004) * smoothstep(0.42, 0.0, a2);
			float head = exp(-dot(v, v) / 0.000012);
			col += (vec3(1.0, 0.95, 0.8) * (dusty * 0.8 + head * 2.5) + vec3(0.5, 0.75, 1.0) * ion * 0.5) * comet;
		}
	}
	col *= up * (1.0 - 0.6 * pow(max(mc, 0.0), 8.0) * illum);   // у яркой луны звёзды бледнеют
	// метеоры: короткий росчерк в верхней части неба
	if (meteor_rate > 0.0) {
		float slot = floor(TIME / 2.5);
		float ph = fract(TIME / 2.5) / 0.3;
		if (ph < 1.0 && hash(vec2(slot, 1.7)) < meteor_rate) {
			vec3 s0 = normalize(vec3(hash(vec2(slot, 2.1)) * 2.0 - 1.0, 0.5 + hash(vec2(slot, 3.3)) * 0.6, hash(vec2(slot, 4.7)) * 2.0 - 1.0));
			vec3 dm = normalize(cross(s0, normalize(vec3(hash(vec2(slot, 5.9)) - 0.5, 0.15, hash(vec2(slot, 6.3)) - 0.5))));
			vec3 head = normalize(s0 + dm * ph * 0.35);
			vec3 v = d - head;
			float along = dot(v, -dm);
			float across = length(v + dm * along - head * dot(v, head));
			col += vec3(0.95, 0.97, 1.0) * step(0.0, along) * smoothstep(0.09, 0.0, along) * exp(-across * across / 0.0000016) * sin(ph * 3.1416) * 1.5 * up;
		}
	}
	// луна: диск с тёмными морями; неосвещённая часть по фазе едва видна
	float disc = smoothstep(0.99955, 0.9997, mc);
	if (disc > 0.0) {
		vec3 mu = normalize(cross(md, vec3(0.0, 1.0, 0.0) + vec3(1e-4)));
		vec3 mv = cross(mu, md);
		vec2 l = vec2(dot(d, mu), dot(d, mv)) / 0.0275;
		vec3 n = vec3(l, sqrt(max(1.0 - dot(l, l), 0.0)));
		float ang = moon_phase * 6.2832;
		float lit = smoothstep(-0.06, 0.06, dot(n, vec3(sin(ang), 0.0, -cos(ang))));
		float maria = 1.0 - 0.32 * smoothstep(0.45, 0.65, fbm(l * 1.6 + 4.0));
		col += vec3(0.92, 0.94, 1.0) * disc * 1.6 * (maria * lit + 0.06);
	}
	col += vec3(0.35, 0.42, 0.6) * pow(max(mc, 0.0), 60.0) * 0.25 * (0.3 + 0.7 * illum);
	col *= smoothstep(-0.02, 0.03, d.y);
	// полярное сияние: волнистые занавеси над северным горизонтом (север — −z), зелёные внизу, сиреневые вверху
	if (aurora > 0.001) {
		float az = atan(d.x, -d.z);
		float span = smoothstep(1.9, 0.6, abs(az + (aurora_seed - 0.5) * 0.8));
		if (span > 0.0) {
			float t = TIME * 0.05 + aurora_seed * 37.0;
			float base = 0.05 + 0.05 * noise(vec2(az * 2.0 + t, aurora_seed * 9.0)) + 0.03 * sin(az * 5.0 + t * 3.0);
			float v = d.y - base;
			float curtain = smoothstep(0.3, 0.75, fbm(vec2(az * 3.0 - t * 0.6, t * 0.4 + aurora_seed * 5.0)));
			float rays = 0.55 + 0.45 * noise(vec2(az * 70.0 + sin(t * 2.0 + az * 4.0) * 3.0, t * 2.0));
			float prof = smoothstep(-0.005, 0.02, v) * exp(-max(v, 0.0) * 5.5);
			vec3 ac = mix(vec3(0.15, 1.0, 0.55), vec3(0.65, 0.3, 0.95), smoothstep(0.02, 0.3, v));
			col += ac * curtain * rays * prof * span * aurora * 0.9;
		}
	}
	return col;
}

void sky() {
	vec3 d = EYEDIR;
	float h = max(d.y, 0.0);
	vec3 col = mix(horizon_color, zenith_color, smoothstep(0.0, 1.0, pow(h, 0.54)));
	vec3 s_dir = normalize(sun_dir);
	vec3 m_dir = normalize(moon_dir);
	float sd = max(dot(d, s_dir), 0.0);
	float md = max(dot(d, m_dir), 0.0);
	float above = smoothstep(-0.15, 0.05, s_dir.y);   // гало гаснет, когда солнце глубоко под горизонтом
	float low_sun = smoothstep(0.32, -0.02, s_dir.y) * smoothstep(-0.16, -0.01, s_dir.y);
	// Двухзонное рассеяние Ми и мягкое зарево вдоль горизонта со стороны солнца
	float horizon_band = exp(-h * 5.2) * (0.35 + 0.65 * pow(sd, 3.0)) * low_sun * above;
	col += mix(sun_color, vec3(1.0, 0.48, 0.28), low_sun * 0.55) * horizon_band * 0.24;
	col += sun_color * (pow(sd, 6.0) * 0.34 + pow(sd, 48.0) * 0.48) * halo * above;
	if (!AT_CUBEMAP_PASS) {
		// солнце: диск, днём не ярче, чем выдержит тоновая кривая
		float sun_disc = smoothstep(0.9993, 0.9996, sd) * smoothstep(-0.05, 0.02, s_dir.y);
		col += sun_color * sun_disc * 2.8;
		if (night > 0.001) {
			col += night_sky(d, sd) * night;
		}

		if (d.y > 0.005) {
			float fade = smoothstep(0.012, 0.24, d.y);
			float horizon_haze = 1.0 - smoothstep(0.02, 0.36, d.y);
			vec2 wind = vec2(cloud_time * 0.012, cloud_time * 0.004);
			float morph = cloud_time * 0.022;
			vec2 seed_ofs = vec2(cloud_seed * 0.37, cloud_seed * 0.61);

			// Активное светило (днём солнце, ночью луна с учётом фазы)
			float moon_illum = 0.35 + 0.65 * (0.5 - 0.5 * cos(moon_phase * 6.2832));
			vec3 active_dir = s_dir.y >= -0.04 ? s_dir : m_dir;
			float active_dot = dot(d, active_dir);
			vec3 active_light_col = mix(sun_color, vec3(0.72, 0.82, 1.0) * moon_illum * 0.55, night);
			vec3 warm_sunset = mix(sun_color, vec3(1.0, 0.48, 0.30), low_sun * 0.58);

			// 1. Высокий ярус: перистые «когти/перья» (cirrus uncinus) и перисто-кучевые «барашки» (cirrocumulus)
			vec2 uv_high = sky_uv(d, 0.16);
			float cirrus_band = smoothstep(0.52, 0.80, noise(uv_high * 0.28 + seed_ofs + vec2(3.3, -1.9) + wind * 0.25));
			if (cirrus_band > 0.002) {
				vec2 cq = OCT_ROT * (uv_high * 0.85 + wind * 1.65 + seed_ofs);
				float hook = sin(cq.x * 1.35 + noise(cq * 0.45 + morph * 0.15) * 3.2) * 0.42;
				vec2 streak_uv = vec2(cq.x * 0.55, (cq.y + hook) * 4.8);
				float wisps = smoothstep(0.50, 0.84, fbm(streak_uv + vec2(morph * 0.2, 0.0)));
				// Мелкая перисто-кучевая рябь («барашки») по краям перистых потоков
				float mackerel_mask = smoothstep(0.52, 0.78, noise(cq * 0.8 + 7.1));
				float mackerel = mackerel_mask > 0.002 ? smoothstep(0.55, 0.88, worley_puff(cq * 3.8, morph * 0.8)) * mackerel_mask : 0.0;
				float cirrus = clamp((wisps * 0.78 + mackerel * 0.52) * cirrus_band, 0.0, 1.0);
				if (cirrus > 0.002) {
					// Высокие облака дольше ловят малиново-золотой свет зари после захода солнца у земли
					float high_twilight = smoothstep(-0.22, 0.04, s_dir.y) * smoothstep(0.28, -0.04, s_dir.y);
					vec3 c_high = mix(cloud_color * 1.03, mix(sun_color * 1.18, vec3(1.0, 0.52, 0.44), high_twilight * 0.62),
						clamp(pow(sd, 2.5) * halo * 0.80 + high_twilight * 0.72, 0.0, 1.0));
					c_high += active_light_col * pow(max(active_dot, 0.0), 8.0) * 0.45;
					c_high = mix(c_high, horizon_color, horizon_haze * 0.55);
					col = mix(col, c_high, cirrus * 0.36 * fade);
				}
			}

			// 2. Средний ярус: высококучевые гряды и слоистые волны (altocumulus)
			vec2 uv_mid = sky_uv(d, 0.13);
			float mid_patch = smoothstep(0.54, 0.80, noise(uv_mid * 0.34 - seed_ofs + vec2(9.2, 4.1) + wind * 0.4));
			if (mid_patch > 0.002) {
				vec2 mq = mat2(vec2(0.92, -0.39), vec2(0.39, 0.92)) * (uv_mid * 1.15 + wind * 1.18 - seed_ofs * 0.7);
				float mid_wave = worley_puff(mq * vec2(1.4, 2.2), morph * 0.6) * 0.62
					+ smoothstep(0.28, 0.72, fbm_flow(mq * 2.8, -morph * 0.8)) * 0.38;
				float altocum = smoothstep(0.54 - cloud_cover * 0.14, 0.78 - cloud_cover * 0.10, mid_wave) * mid_patch;
				if (altocum > 0.002) {
					vec2 mid_sun_step = normalize(active_dir.xz + vec2(1e-4)) * 0.08;
					float mid_n2 = worley_puff((mq + mid_sun_step) * vec2(1.4, 2.2), morph * 0.6);
					float mid_lit = clamp((mid_wave - mid_n2) * 3.5 + 0.62, 0.0, 1.0);
					vec3 mid_shadow = mix(cloud_color * vec3(0.58, 0.64, 0.78), zenith_color, 0.28);
					vec3 mid_lit_col = mix(cloud_color * 1.06, warm_sunset * 1.14, low_sun * 0.64);
					vec3 mid_col = mix(mid_shadow, mid_lit_col, mid_lit);
					mid_col += active_light_col * pow(max(active_dot, 0.0), 10.0) * (1.0 - altocum * 0.6) * 0.60;
					mid_col = mix(mid_col, horizon_color, horizon_haze * 0.62);
					col = mix(col, mid_col, altocum * 0.46 * fade);
				}
			}

			// 3. Нижний объёмный ярус: живые кучевые облака (humilis, mediocris, congestus) и валы (stratocumulus)
			// При меньшем числе выборок каждый шаг покрывает большую часть слоя.
			vec2 uv_base = sky_uv(d, 0.11);
			int steps = clamp(cumulus_steps, 2, 5);
			float step_height = 1.0 / float(steps);
			float trans = 1.0;
			vec3 accum = vec3(0.0);
			float phase = cloud_phase(active_dot);
			float silver = pow(max(active_dot, 0.0), 12.0) * (0.82 + halo * 1.35) * (above + night * 0.45);
			vec2 light_horiz = normalize(active_dir.xz + vec2(1e-4)) * 0.075;
			float light_vert = clamp(active_dir.y, 0.14, 0.85) * 0.24;

			// Цветовая палитра объёма: глубокая сизо-синяя тень на плоской подошве и чисто-белые освещённые купола
			vec3 base_ambient = mix(cloud_color * vec3(0.45, 0.53, 0.68), zenith_color * 0.76, 0.32);
			base_ambient = mix(base_ambient, horizon_color * 0.76, low_sun * 0.35);
			vec3 top_ambient = mix(cloud_color * 0.96, zenith_color * 1.04, 0.16);
			vec3 direct_tint = mix(cloud_color * 1.15, warm_sunset * 1.20, low_sun * 0.70);

			for (int i = 0; i < steps; i++) {
				float lh = (float(i) + 0.5) * step_height;
				// По мере подъёма луча сквозь облачный слой точка пересечения плавно уходит вперёд по взгляду
				vec2 p_step = uv_base * (1.0 + 0.065 * lh * (1.0 - h * 0.82)) + wind * (1.0 + 0.08 * lh);
				float tower_h = 0.6;
				float cauli_rel = 0.5;
				float dens = cumulus_density(p_step, lh, cloud_cover, morph, false, tower_h, cauli_rel);
				if (dens > 0.002) {
					// Шаг к светилу для настоящей объёмной самотени и просвечивания краёв (облегчённая выборка shadow_pass = true)
					float dummy_t = 0.0;
					float sh_c = 0.5;
					float sh_h = clamp(lh + light_vert, 0.05, 0.98);
					float sh_dens = cumulus_density(p_step + light_horiz, sh_h, cloud_cover, morph, true, dummy_t, sh_c);
					// Вторая выборка тени заменена оценкой: втрое меньше обращений к плотности на пиксель
					float sh_dens2 = sh_dens * 0.62;
					float opt_depth = sh_dens * 3.0 + sh_dens2 * 1.7;

					// Локальный градиент сферических клубов к солнцу + окклюзия в ложбинках между шапками
					float puff_slope = clamp((cauli_rel - sh_c) * 3.4 + 0.52, 0.0, 1.0);
					float cavity = smoothstep(0.14, 0.78, cauli_rel);

					// Закон Бугера — Ламберта и эффект «порошка» (Beer-Powder): пухлые складки и светящийся контур
					float light_trans = exp(-opt_depth);
					float powder = 1.0 - 0.52 * exp(-dens * 6.5);
					float direct = light_trans * (0.36 + 0.64 * powder) * (0.58 + 0.42 * puff_slope) * (0.78 + phase * 1.6);
					// При высоком солнце купола облаков ярко белеют сверху, а складки и подошва сохраняют рельефную тень
					float top_sun = smoothstep(0.55, 0.95, s_dir.y) * (1.0 - night);
					direct = mix(direct, clamp(light_trans * 0.76 + lh * 0.34 * cavity, 0.0, 1.0), top_sun * 0.48);

					// Рассеянный свет внутри облака: снизу темнее и холоднее, к куполам башен светлее
					float h_norm = clamp(lh / max(tower_h, 0.4), 0.0, 1.0);
					vec3 amb = mix(base_ambient, top_ambient, smoothstep(0.0, 0.80, h_norm) * (0.50 + 0.50 * cavity));
					// Многократное рассеяние внутри толщи (мягкое внутреннее свечение)
					amb += direct_tint * exp(-opt_depth * 0.48) * (0.28 + 0.72 * cavity) * 0.18;
					// На закате и рассвете низкие лучи подсвечивают плоскую подошву и бока облаков золотом и багрянцем
					amb += warm_sunset * low_sun * (1.0 - lh * 0.60) * exp(-sh_dens * 1.3) * 0.40;

					vec3 step_col = mix(amb, direct_tint, clamp(direct, 0.0, 1.0));
					// Серебристая и золотая кромка (Ми-рассеяние сквозь тонкие края у солнца или луны)
					float thin_edge = exp(-dens * 2.5) * exp(-opt_depth * 0.65);
					step_col += active_light_col * silver * thin_edge * 2.2;

					float absorb = (1.55 + 0.85 * (1.0 - lh)) * 0.82;
					float alpha = 1.0 - exp(-dens * absorb * (15.0 * step_height));
					accum += trans * step_col * alpha;
					trans *= 1.0 - alpha;
					if (trans < 0.02) {
						break;
					}
				}
			}
			float cloud_alpha = clamp((1.0 - trans) * 1.08, 0.0, 1.0) * fade;
			if (cloud_alpha > 0.001) {
				vec3 c_final = accum / max(1.0 - trans, 1e-4);
				// Воздушная перспектива у горизонта: далёкие гряды мягко уходят в солнечную дымку
				vec3 haze_tint = mix(horizon_color, sun_color * 0.95, pow(sd, 4.0) * halo * above * 0.45);
				c_final = mix(c_final, haze_tint, horizon_haze * 0.58);
				// Облака сильнее гасят точечные звёзды позади себя
				col = mix(col, c_final, smoothstep(0.0, 0.92, cloud_alpha));
			}
			// Лучи света сквозь просветы в облаках (crepuscular rays): веера из-за краёв облаков у солнца или луны
			if (active_dot > 0.55 && cloud_cover > 0.12) {
				vec3 ru = normalize(cross(active_dir, vec3(0.0, 1.0, 0.0)) + vec3(1e-4));
				vec3 rv = cross(ru, active_dir);
				float ang = atan(dot(d, rv), dot(d, ru));
				float streaks = noise(vec2(ang * 11.0, cloud_time * 0.015 + cloud_seed)) * 0.6
					+ noise(vec2(ang * 27.0 + 5.0, -cloud_time * 0.011)) * 0.4;
				float shaft = smoothstep(0.42, 0.85, streaks) * pow(active_dot, 5.0) * trans;
				float low_boost = 1.0 + low_sun * 1.2;
				float lit_time = max(above, night * 0.3);
				col += active_light_col * shaft * smoothstep(0.12, 0.5, cloud_cover) * low_boost * lit_time * 0.22 * fade;
			}
		}
	} else if (d.y > 0.02) {
		// В карте отражений (AT_CUBEMAP_PASS) — согласованный по времени суток отсвет облачного покрова для воды и поверхностей
		vec2 uv_c = sky_uv(d, 0.12) + vec2(cloud_time * 0.012, cloud_time * 0.004) + vec2(cloud_seed * 0.37, cloud_seed * 0.61);
		float cn = smoothstep(0.62 - cloud_cover * 0.45, 0.82 - cloud_cover * 0.35, noise(uv_c * 1.4));
		vec3 refl_cloud = mix(cloud_color * 0.92, mix(sun_color, vec3(1.0, 0.52, 0.34), low_sun * 0.5) * 0.95, low_sun * 0.55);
		refl_cloud = mix(refl_cloud, mix(zenith_color, horizon_color, 0.5) * 1.15, night * 0.65);
		col = mix(col, refl_cloud, cn * smoothstep(0.02, 0.35, d.y) * 0.45);
	}
	COLOR = col;
}
