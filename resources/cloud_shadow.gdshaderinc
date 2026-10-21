// 7.9: тени облаков на земле — крупные мягкие пятна, которые ветер гонит по рельефу и лесу
// в ту же сторону, что облака на небе. Общий параметр задаёт DayCycle (global uniform, project.godot):
// xy — сдвиг ветром (м), z — сила тени (ночью и в сумерках ноль), w — покрытие неба облаками.
// Тень темнит цвет поверхности: прямой свет в стилизованной картинке важнее рассеянного.

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
	vec2 p = (xz - cloud_shadow.xy) * (1.0 / 150.0);
	float n = cloud_shadow_noise(p) * 0.65 + cloud_shadow_noise(p * 2.3 + 4.1) * 0.35;
	// у двух октав разброс меньше, чем у облаков неба: порог ниже, чтобы доля тени была похожей
	float edge = 0.86 - cloud_shadow.w;
	return 1.0 - smoothstep(edge - 0.06, edge + 0.1, n) * cloud_shadow.z;
}
