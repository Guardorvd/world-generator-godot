// 11.11.2026: частицы окружения (AmbientParticles): пылинки, пух, листья, мошки, светлячки, снег, песок.
// Частицы без состояния: один меш из четырёхугольников на слой, место каждой считается в вершинном шейдере
// из её зерна и времени и заворачивается в объём вокруг камеры. Поэтому слой — один вызов отрисовки,
// процессор на кадр ничего не считает, а поле частиц бесконечно и стоит в мире (при езде они проносятся мимо).
// Зерно — CUSTOM0 (xyz — место в объёме 0..1, w — доля для плотности), COLOR — разброс скорости, фазы, цвета и размера.
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, world_vertex_coords, shadows_disabled;

uniform vec3 box = vec3(40.0, 12.0, 40.0); // м: объём вокруг камеры
uniform float lift = 2.0;                  // м: середина объёма выше камеры
uniform float amount = 0.0;                // 0..1: доля видимых частиц
uniform vec3 drift = vec3(0.0);            // м/с: ветер и падение
uniform float sway = 0.0;                  // м: плавное покачивание в стороны
uniform float sway_speed = 1.0;
uniform float wander = 0.0;                // м: беспорядочное движение (мошки, светлячки)
uniform float size = 0.02;                 // м: половина стороны
uniform float tumble = 0.0;                // рад/с: вращение и переворот (листья)
uniform int shape = 0;                     // 0 — мягкая точка, 1 — лист, 2 — плотная точка
uniform vec4 color_a : source_color = vec4(1.0);
uniform vec4 color_b : source_color = vec4(1.0);
uniform vec3 light : source_color = vec3(1.0); // свет дня: ночью частицы темнее
uniform float glow = 0.0;                  // собственное свечение (светлячки)
uniform float blink = 0.0;                 // частота мерцания
uniform float near_fade = 1.2;
uniform float visibility = 0.5;            // общий множитель заметности (11.11: вдвое тише)             // м: ближе к камере частица гаснет

varying vec4 v_col;

void vertex() {
	vec3 seed = CUSTOM0.xyz;
	float phase = COLOR.g * 6.2831853;
	float t = TIME;
	vec3 centre = CAMERA_POSITION_WORLD + vec3(0.0, lift, 0.0);
	vec3 p = seed * box + drift * t * (0.7 + 0.6 * COLOR.r);
	p.x += sin(t * sway_speed * (0.6 + COLOR.b) + phase) * sway;
	p.z += cos(t * sway_speed * 0.8 * (0.6 + COLOR.r) + phase * 1.7) * sway;
	p += wander * vec3(sin(t * 2.3 + phase * 3.0), sin(t * 1.7 + phase * 5.0) * 0.6, cos(t * 2.9 + phase * 2.0));
	vec3 rel = fract((p - centre) / box + 0.5) - 0.5;
	vec3 world = centre + rel * box;
	float edge = 1.0 - smoothstep(0.38, 0.5, max(abs(rel.x), max(abs(rel.y), abs(rel.z))));
	float dist = length(world - CAMERA_POSITION_WORLD);
	float fade = edge * smoothstep(near_fade * 0.5, near_fade, dist) * step(CUSTOM0.w, amount);
	vec2 corner = VERTEX.xy;
	if (tumble > 0.0) {
		float spin = t * tumble * (0.5 + COLOR.r) + phase;
		corner = mat2(vec2(cos(spin), sin(spin)), vec2(-sin(spin), cos(spin))) * corner;
		corner.x *= cos(spin * 1.7 + phase);
	}
	float s = size * (0.6 + 0.8 * COLOR.a) * (fade > 0.0 ? 1.0 : 0.0);
	VERTEX = world + (INV_VIEW_MATRIX[0].xyz * corner.x + INV_VIEW_MATRIX[1].xyz * corner.y) * s;
	float flick = blink > 0.0 ? smoothstep(0.2, 0.9, sin(t * blink * (0.5 + COLOR.b) + phase * 4.0)) : 1.0;
	v_col = mix(color_a, color_b, COLOR.b);
	v_col.a *= fade * flick;
}

void fragment() {
	vec2 q = UV * 2.0 - 1.0;
	float r = length(q);
	float a;
	vec3 col = v_col.rgb;
	if (shape == 0) {
		a = 1.0 - smoothstep(0.0, 1.0, r);
		a *= a;
	} else if (shape == 1) {
		a = 1.0 - smoothstep(0.8, 1.0, length(q * vec2(1.0, 1.9)));
		col *= 1.0 - 0.3 * (1.0 - smoothstep(0.0, 0.12, abs(q.y)));
	} else {
		a = 1.0 - smoothstep(0.45, 1.0, r);
	}
	ALBEDO = col * mix(light, vec3(1.0), clamp(glow, 0.0, 1.0)) * (1.0 + glow * 1.5);
	ALPHA = v_col.a * a * visibility;
}
