shader_type spatial;
// Провода парковых гирлянд: camera-facing ribbon с prefiltering против мерцания на MSAA.
render_mode blend_mix, depth_draw_never, cull_disabled;

#include "res://resources/depth_tone.gdshaderinc"

global uniform float vegetation_clock;
global uniform float vegetation_night;
uniform float max_distance = 105.0;
uniform float fade_width = 36.0;

varying float v_dist;
varying float v_edge;
varying float v_cov;

void vertex() {
	vec3 center = VERTEX;
	vec3 dir = normalize(NORMAL);
	float side_sign = UV.x;
	float sag_t = UV.y;
	float half_w = COLOR.r;
	float phase = COLOR.g * 6.2831853;
	float sway_scale = COLOR.b;

	// На стволах (sag_t = 0 и 1) смещение строго нулевое; середина пролёта слегка качается на ветру.
	float sag_w = 4.0 * sag_t * (1.0 - sag_t);
	vec2 wind_dir = vec2(0.82, 0.57);
	float wave = sin(vegetation_clock * 1.65 + phase) + 0.35 * sin(vegetation_clock * 3.1 + phase * 1.7);
	float amp = 0.042 * sway_scale * sag_w * wave;
	center.xz += wind_dir * amp;
	center.y -= abs(amp) * 0.14;

	vec3 cam_pos = INV_VIEW_MATRIX[3].xyz;
	vec3 world_pos = (MODEL_MATRIX * vec4(center, 1.0)).xyz;
	vec3 world_dir = normalize((MODEL_MATRIX * vec4(dir, 0.0)).xyz);
	vec3 to_cam = cam_pos - world_pos;
	float dist = length(to_cam);
	v_dist = dist;

	vec3 view_vec = dist > 1e-4 ? to_cam / dist : vec3(0.0, 0.0, 1.0);
	vec3 side = cross(view_vec, world_dir);
	float side_len = length(side);
	side = side_len > 1e-4 ? side / side_len : vec3(1.0, 0.0, 0.0);

	// Не даём проводу стать тоньше ~1.2 px, пропорционально смягчая альфу (без пунктира вдали).
	float persp = (PROJECTION_MATRIX[3][3] == 0.0) ? dist : 1.0;
	float px_world = (2.0 * persp) / max(VIEWPORT_SIZE.y * abs(PROJECTION_MATRIX[1][1]), 1.0);
	float min_half = px_world * 0.60;
	float final_half = max(half_w, min_half);
	v_cov = clamp(half_w / final_half, 0.16, 1.0);
	v_edge = side_sign;

	VERTEX = center + side * (side_sign * final_half);
	NORMAL = view_vec;
}

void fragment() {
	float end_d = min(max_distance, 105.0);
	float fade = 1.0 - smoothstep(end_d - fade_width, end_d, v_dist);
	if (fade <= 0.01) {
		discard;
	}
	float cross_profile = 1.0 - smoothstep(0.58, 1.0, abs(v_edge));
	vec3 day_wire = vec3(0.050, 0.047, 0.044);
	vec3 night_wire = vec3(0.030, 0.026, 0.024);
	vec3 base = mix(day_wire, night_wire, vegetation_night);
	ALBEDO = depth_tone(base, v_dist);
	ROUGHNESS = 0.88;
	METALLIC = 0.0;
	ALPHA = fade * v_cov * cross_profile * 0.94;
}
