shader_type spatial;
// Трёхзонная парковая лампочка в 1 draw call: подвес+патрон, матовая колба и горящая нить накала.
render_mode cull_back, depth_draw_opaque;

#include "res://resources/depth_tone.gdshaderinc"

global uniform float vegetation_clock;
global uniform float vegetation_night;
uniform float max_distance = 175.0;

varying vec2 v_uv;
varying vec4 v_inst;
varying float v_dist;
varying float v_vis;

void vertex() {
	v_uv = UV;
	v_inst = INSTANCE_CUSTOM;

	float span_phase = INSTANCE_CUSTOM.r * 6.2831853;
	float bulb_seed = fract(INSTANCE_CUSTOM.g * 17.31);
	float sag_w = INSTANCE_CUSTOM.a;

	vec2 wind_dir = vec2(0.82, 0.57);
	float wire_wave = sin(vegetation_clock * 1.65 + span_phase) + 0.35 * sin(vegetation_clock * 3.1 + span_phase * 1.7);
	float wire_amp = 0.042 * sag_w * wire_wave;

	// Расстояние до камеры и плавное уменьшение масштаба у границы прорисовки (без резкого щелчка LOD).
	vec3 anchor_world = (MODEL_MATRIX * vec4(0.0, -0.15, 0.0, 1.0)).xyz;
	float dist = length(INV_VIEW_MATRIX[3].xyz - anchor_world);
	v_dist = dist;
	float end_d = max(48.0, max_distance);
	float fade = 1.0 - smoothstep(end_d - 28.0, end_d, dist);
	v_vis = fade;

	// Лёгкое маятниковое качание подвеса вокруг точки крепления на проводе (0, 0, 0).
	float pend_phase = bulb_seed * 6.2831853;
	float swing = 0.045 * (0.4 + 0.6 * sag_w) * sin(vegetation_clock * 2.15 + pend_phase);
	float cross_swing = 0.025 * (0.4 + 0.6 * sag_w) * cos(vegetation_clock * 1.7 + pend_phase * 1.4);

	vec3 p = VERTEX * fade;
	vec3 axis_perp = vec3(-wind_dir.y, 0.0, wind_dir.x);
	float ca = cos(swing);
	float sa = sin(swing);
	float along = dot(p.xz, wind_dir);
	vec2 perp_part = p.xz - wind_dir * along;
	float ny = p.y * ca - along * sa;
	float n_along = p.y * sa + along * ca;
	p.y = ny;
	p.xz = perp_part + wind_dir * n_along + axis_perp.xz * (cross_swing * (-p.y));

	// Синхронное сдвижение с проводом.
	p.xz += wind_dir * wire_amp;
	p.y -= abs(wire_amp) * 0.14;
	VERTEX = p;

	vec3 n = NORMAL;
	float na = dot(n.xz, wind_dir);
	vec2 np = n.xz - wind_dir * na;
	n.xz = np + wind_dir * (n.y * sa + na * ca);
	n.y = n.y * ca - na * sa;
	NORMAL = normalize(n);
}

void fragment() {
	if (v_vis <= 0.01) {
		discard;
	}
	if (v_uv.x < 0.5) {
		vec3 cap = depth_tone(vec3(0.072, 0.068, 0.064), v_dist);
		ALBEDO = cap;
		ROUGHNESS = 0.84;
		METALLIC = 0.05;
		EMISSION = vec3(0.0);
	} else {
		float bulb_g = v_inst.g;
		bool dim_bulb = bulb_g < 0.03;
		float warmth = clamp((bulb_g - 0.03) / 0.97, 0.0, 1.0);
		float thr = v_inst.b;
		float lit = smoothstep(thr, thr + 0.22, vegetation_night);
		float bulb_phase = fract(bulb_g * 17.31) * 6.2831853;
		float shimmer = 1.0 + 0.025 * sin(vegetation_clock * 2.7 + bulb_phase);
		float power = (dim_bulb ? 0.34 : 1.0) * shimmer * v_vis;

		float ndotv = clamp(abs(dot(normalize(NORMAL), normalize(VIEW))), 0.0, 1.0);
		float core = pow(ndotv, 2.0) * (0.45 + 0.55 * v_uv.y);

		vec3 day_glass = depth_tone(vec3(0.88, 0.83, 0.72), v_dist);
		vec3 edge_amber = mix(vec3(1.0, 0.46, 0.13), vec3(1.0, 0.66, 0.27), warmth);
		vec3 hot_filament = mix(vec3(1.0, 0.86, 0.50), vec3(1.0, 0.95, 0.78), warmth);

		ALBEDO = mix(day_glass, edge_amber * 0.72, lit * 0.65);
		ROUGHNESS = mix(0.24, 0.18, lit);
		METALLIC = 0.0;
		EMISSION = mix(edge_amber * 1.25, hot_filament * 3.3, core) * lit * power;
	}
}
