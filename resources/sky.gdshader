// Стилизованное небо (с 7.8): градиент зенит — горизонт, мягкое гало солнца, диск луны, звёзды ночью
// и облака. Цвета и направления каждый кадр задаёт DayCycle (scripts/render/day_cycle.gd).
// Ниже горизонта небо — цвет горизонта: он же цвет тумана, иначе на краю земли виден шов.
// В проходе карты отражений (AT_CUBEMAP_PASS) только градиент и гало: звёзды, облака и диски там не нужны.
// 7.9: облака в два слоя — кучевые (искажённый шум, покрытие плавает по небу, объём: сторона к солнцу
// светлее, низ темнее и холоднее, тонкие края у солнца светятся) и высокие перистые полосы.
// Солнце и гало просвечивают сквозь тонкие края.
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

void sky() {
	vec3 d = EYEDIR;
	float h = max(d.y, 0.0);
	vec3 col = mix(horizon_color, zenith_color, smoothstep(0.0, 1.0, sqrt(h)));
	float sd = max(dot(d, normalize(sun_dir)), 0.0);
	float above = smoothstep(-0.15, 0.05, sun_dir.y);   // гало гаснет, когда солнце глубоко под горизонтом
	col += sun_color * (pow(sd, 6.0) * 0.35 + pow(sd, 48.0) * 0.5) * halo * above;
	if (!AT_CUBEMAP_PASS) {
		float up = smoothstep(0.0, 0.08, d.y);
		// звёзды: по одной точке на ячейку сетки направлений, в редких ячейках
		vec3 p = d * 110.0;
		vec3 cell = floor(p);
		float r = hash3(cell);
		vec3 star = cell + 0.5 + (vec3(hash3(cell + 7.1), hash3(cell + 3.7), hash3(cell + 9.3)) - 0.5) * 0.6;
		float twinkle = 0.75 + 0.25 * sin(TIME * (1.5 + r * 3.0) + r * 40.0);
		float stars = step(0.985, r) * smoothstep(0.22, 0.0, length(p - star)) * twinkle;
		// луна: плоский бледный диск с мягким гало
		vec3 md = normalize(moon_dir);
		float mc = dot(d, md);
		float disc = smoothstep(0.99955, 0.9997, mc);
		vec3 moon = vec3(0.92, 0.94, 1.0) * disc * 1.6 + vec3(0.35, 0.42, 0.6) * pow(max(mc, 0.0), 60.0) * 0.25;
		// солнце: диск, днём не ярче, чем выдержит тоновая кривая
		float sun_disc = smoothstep(0.9993, 0.9996, sd) * smoothstep(-0.05, 0.02, sun_dir.y);
		col += sun_color * sun_disc * 3.0;
		col += (stars * vec3(0.9, 0.95, 1.0) * 1.4 * up + moon * smoothstep(-0.02, 0.03, d.y)) * night;

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
