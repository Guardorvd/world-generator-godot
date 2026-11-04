// 7.9 / 15.0: тени облаков на земле — живые кучевые пятна с мягкой полутенью по краям и плотным ядром,
// которые ветер гонит по рельефу и лесу и которые медленно меняют форму по мере движения.
// Общий параметр задаёт DayCycle (global uniform, project.godot):
// xy — сдвиг ветром (м), z — сила тени (ночью и в сумерках ноль), w — покрытие неба облаками.

global uniform vec4 cloud_shadow;

float cloud_shadow_hash(vec2 p) {
	vec3 q = fract(vec3(p.xyx) * 0.1031);
	q += dot(q, q.yzx + 33.33);
	return fract((q.x + q.y) * q.z);
}

float cloud_shadow_noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	return mix(mix(cloud_shadow_hash(i), cloud_shadow_hash(i + vec2(1.0, 0.0)), u.x),
		mix(cloud_shadow_hash(i + vec2(0.0, 1.0)), cloud_shadow_hash(i + vec2(1.0, 1.0)), u.x), u.y);
}

// Множитель освещённости 0..1 в точке xz мира
float cloud_light(vec2 xz) {
	if (cloud_shadow.z <= 0.0) {
		return 1.0;
	}
	vec2 p = (xz - cloud_shadow.xy) * (1.0 / 160.0);
	float morph = dot(cloud_shadow.xy, vec2(-0.0016, -0.0006));
	vec2 warp = vec2(
		cloud_shadow_noise(p * 0.65 + vec2(1.7 + morph * 0.2, 4.3)),
		cloud_shadow_noise(p * 0.65 + vec2(8.9, 2.1 - morph * 0.2))
	) - 0.5;
	vec2 q = p + warp * 0.42;
	float n = cloud_shadow_noise(q) * 0.52
		+ cloud_shadow_noise(mat2(vec2(0.8, 0.6), vec2(-0.6, 0.8)) * q * 2.13 + vec2(4.1 - morph * 0.35, 1.7)) * 0.31
		+ cloud_shadow_noise(q * 4.35 + vec2(-2.7, 6.2 + morph * 0.5)) * 0.17;
	float edge = 0.85 - cloud_shadow.w;
	// Мягкая полутень на кудрявых краях и глубокая тень под плотным центром кучевого облака
	float penumbra = smoothstep(edge - 0.08, edge + 0.08, n);
	float umbra = smoothstep(edge + 0.02, edge + 0.16, n);
	return 1.0 - (penumbra * 0.58 + umbra * 0.42) * cloud_shadow.z;
}
