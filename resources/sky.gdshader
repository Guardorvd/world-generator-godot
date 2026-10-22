// Стилизованное небо (с 7.8): градиент зенит — горизонт, мягкое гало солнца, диск луны, звёзды ночью
// и облака. Цвета и направления каждый кадр задаёт DayCycle (scripts/render/day_cycle.gd).
// Ниже горизонта небо — цвет горизонта: он же цвет тумана, иначе на краю земли виден шов.
// В проходе карты отражений (AT_CUBEMAP_PASS) только градиент и гало: звёзды, облака и диски там не нужны.
// 7.9: облака в два слоя — кучевые (искажённый шум, покрытие плавает по небу, объём: сторона к солнцу
// светлее, низ темнее и холоднее, тонкие края у солнца светятся) и высокие перистые полосы.
// Солнце и гало просвечивают сквозь тонкие края.
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
uniform float cloud_time = 0.0;
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
	vec3 col = mix(horizon_color, zenith_color, smoothstep(0.0, 1.0, sqrt(h)));
	float sd = max(dot(d, normalize(sun_dir)), 0.0);
	float above = smoothstep(-0.15, 0.05, sun_dir.y);   // гало гаснет, когда солнце глубоко под горизонтом
	col += sun_color * (pow(sd, 6.0) * 0.35 + pow(sd, 48.0) * 0.5) * halo * above;
	if (!AT_CUBEMAP_PASS) {
		// солнце: диск, днём не ярче, чем выдержит тоновая кривая
		float sun_disc = smoothstep(0.9993, 0.9996, sd) * smoothstep(-0.05, 0.02, sun_dir.y);
		col += sun_color * sun_disc * 3.0;
		if (night > 0.001) {
			col += night_sky(d, sd) * night;
		}

		// облака лежат на плоскости над головой; к горизонту тают в дымке
		vec2 uv = d.xz / (d.y + 0.12);
		vec2 wind = vec2(cloud_time * 0.012, cloud_time * 0.004);
		float fade = smoothstep(0.03, 0.3, d.y);
		// перистые: вытянутые полосы высоко, движутся быстрее
		vec2 cq = mat2(vec2(0.8, 0.6), vec2(-0.6, 0.8)) * (uv * 0.9 + wind * 1.6);
		float cirrus = smoothstep(0.5, 0.85, fbm(cq * vec2(0.6, 5.0))) * smoothstep(0.35, 0.65, noise(uv * 0.3 + 3.3));
		vec3 cirrus_col = mix(cloud_color, sun_color * 1.2, pow(sd, 3.0) * halo);
		col = mix(col, cirrus_col, cirrus * 0.25 * fade);
		// кучевые: покрытие меняется по небу (где-то ясно, где-то гряда), форма — искажённый шум
		vec2 q = uv * 1.7 + wind;
		q += (vec2(noise(q * 0.6 + 1.3), noise(q * 0.6 + 7.1)) - 0.5) * 0.5;
		float cover = cloud_cover + (noise(uv * 0.4 + wind * 0.3 + 11.0) - 0.5) * 0.3;
		float n = fbm(q);
		float edge = 1.0 - cover;
		float dens = smoothstep(edge - 0.02, edge + 0.09, n);
		if (dens > 0.001) {
			// объём: шум чуть ближе к солнцу меньше — значит, эта сторона облака освещена
			vec2 to_sun = normalize(sun_dir.xz + vec2(1e-4)) * 0.09;
			float lit = clamp((n - fbm(q + to_sun)) * 7.0 + 0.55, 0.0, 1.0);
			lit = mix(lit, 0.75, smoothstep(0.6, 0.95, sun_dir.y));   // солнце в зените: свет сверху ровнее
			vec3 base = mix(cloud_color * vec3(0.62, 0.66, 0.78), zenith_color, 0.25);  // низ облака в тени
			vec3 ccol = mix(base, cloud_color * 1.08, lit);
			// свет сквозь облака: тонкие края у солнца светятся, толща закрывает солнце и гало
			float thin = 1.0 - smoothstep(0.0, 0.7, dens);
			ccol += sun_color * pow(sd, 10.0) * thin * halo * above * 2.2;
			col = mix(col, ccol, dens * 0.95 * fade);
		}
	}
	COLOR = col;
}
