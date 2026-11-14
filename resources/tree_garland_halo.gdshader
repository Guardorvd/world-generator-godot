shader_type spatial;
// Ночной оптический ореол вокруг лампочки: не зависит от порядка отрисовки (blend_add) и учитывает туман.
render_mode unshaded, blend_add, fog_disabled, depth_draw_never, cull_disabled, shadows_disabled;

global uniform float vegetation_clock;
global uniform float vegetation_night;
global uniform vec4 mist_weather;
uniform float max_distance = 200.0;

varying vec3 v_color;
varying float v_dist;

void vertex() {
	float span_phase = INSTANCE_CUSTOM.r * 6.2831853;
	float bulb_g = INSTANCE_CUSTOM.g;
	float thr = INSTANCE_CUSTOM.b;
	float sag_w = INSTANCE_CUSTOM.a;

	bool dim_bulb = bulb_g < 0.03;
	float warmth = clamp((bulb_g - 0.03) / 0.97, 0.0, 1.0);
	float bulb_phase = fract(bulb_g * 17.31) * 6.2831853;
	float lit = smoothstep(thr, thr + 0.22, vegetation_night);

	vec2 wind_dir = vec2(0.82, 0.57);
	float wire_wave = sin(vegetation_clock * 1.65 + span_phase) + 0.35 * sin(vegetation_clock * 3.1 + span_phase * 1.7);
	float wire_amp = 0.042 * sag_w * wire_wave;
	float swing = 0.045 * (0.4 + 0.6 * sag_w) * sin(vegetation_clock * 2.15 + bulb_phase);

	vec3 sway_local = vec3(
		wind_dir.x * (wire_amp + 0.165 * swing),
		-abs(wire_amp) * 0.14,
		wind_dir.y * (wire_amp + 0.165 * swing)
	);

	vec3 cam_pos = INV_VIEW_MATRIX[3].xyz;
	vec3 world_center = (MODEL_MATRIX * vec4(sway_local, 1.0)).xyz;
	float dist = length(cam_pos - world_center);
	v_dist = dist;

	float end_d = max(56.0, max_distance);
	float near_fade = smoothstep(0.85, 2.35, dist);
	float far_fade = 1.0 - smoothstep(end_d - 42.0, end_d, dist);
	float vis = lit * near_fade * far_fade * (dim_bulb ? 0.30 : 1.0);

	float shimmer = 1.0 + 0.025 * sin(vegetation_clock * 2.7 + bulb_phase);
	float radius = mix(0.62, 1.38, clamp((dist - 5.0) / 140.0, 0.0, 1.0));
	if (vis <= 0.002) {
		radius = 0.0;
	}

	vec3 to_cam = dist > 1e-4 ? (cam_pos - world_center) / dist : vec3(0.0, 0.0, 1.0);
	vec3 right_w = INV_VIEW_MATRIX[0].xyz;
	vec3 up_w = INV_VIEW_MATRIX[1].xyz;
	VERTEX = sway_local + to_cam * 0.05 + (right_w * VERTEX.x + up_w * VERTEX.y) * radius;

	vec3 halo_tint = mix(vec3(1.0, 0.54, 0.16), vec3(1.0, 0.74, 0.34), warmth);
	// Мягкий золотистый ореол вокруг нити накаливания и тёплое пятно света в лесной темноте.
	float dist_boost = mix(0.48, 0.65, clamp(dist / 120.0, 0.0, 1.0));
	v_color = halo_tint * (vis * shimmer * dist_boost);
}

void fragment() {
	vec2 q = UV * 2.0 - 1.0;
	float r2 = dot(q, q);
	if (r2 >= 1.0) {
		discard;
	}
	float window_fade = pow(clamp(1.0 - r2, 0.0, 1.0), 2.0);
	float aura = (exp(-r2 * 4.0) * 0.55 + exp(-r2 * 13.0) * 0.45) * window_fade;
	float mist_k = mix(0.0028, 0.0085, clamp(mist_weather.z, 0.0, 1.0));
	float fog_trans = exp(-v_dist * mist_k);
	ALBEDO = v_color * aura * fog_trans;
}
