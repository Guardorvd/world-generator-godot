shader_type spatial;
render_mode unshaded, blend_mix, cull_front, depth_draw_never, depth_test_disabled, fog_disabled, shadows_disabled;

uniform sampler2D scene_depth : hint_depth_texture, repeat_disable, filter_nearest;
instance uniform float density = 0.0;
global uniform vec4 mist_weather;
global uniform vec4 mist_tint;

varying vec3 local_surface;
varying flat vec3 local_eye;

void vertex() {
	// The proxy box is [-1, 1] on each axis. Its transform sets the ellipsoid radii.
	local_surface = VERTEX;
	local_eye = (inverse(MODELVIEW_MATRIX) * vec4(0.0, 0.0, 0.0, 1.0)).xyz;
}

void fragment() {
	vec3 ray = local_surface - local_eye;
	float local_length = length(ray);
	vec3 direction = ray / max(local_length, 0.0001);
	float center = -dot(local_eye, direction);
	vec3 closest = local_eye + direction * center;
	float peak = 1.0 - dot(closest, closest);
	if (peak <= 0.0) {
		discard;
	}
	float half_chord = sqrt(peak);
	float depth = textureLod(scene_depth, SCREEN_UV, 0.0).r;
	float ndc_z = mix(CLIP_SPACE_FAR, 1.0, depth);
	vec4 scene = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, ndc_z, 1.0);
	float scene_z = scene.z / scene.w;
	float start = max(-half_chord, -center);
	float end = min(half_chord, local_length * scene_z / VERTEX.z - center);
	if (end <= start) {
		discard;
	}
	// Exact integral of the quadratic density along the visible segment, in metres.
	float integral = (end - start) * (peak - (end * end + end * start + start * start) / 3.0);
	float metres = integral * length(VERTEX) / local_length;
	ALBEDO = mist_tint.rgb;
	ALPHA = 1.0 - exp(-metres * density * mix(0.12, 1.0, mist_weather.z));
}
