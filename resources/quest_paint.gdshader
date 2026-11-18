shader_type spatial;
render_mode cull_back, depth_draw_opaque;

uniform bool highlight = false;
uniform bool rock = false;
uniform float stripe_height = 1.22;
uniform float stripe_width = 0.135;
uniform float offset_m = 0.016;
varying vec3 relative_position;

void vertex() {
	mat3 basis = mat3(MODEL_MATRIX);
	relative_position = basis * VERTEX;
	// Совпадающие вершины граней камня смещаются вместе.
	vec3 outward = vec3(VERTEX.x, rock ? VERTEX.y - 0.18 : 0.0, VERTEX.z);
	VERTEX += outward * (offset_m / max(length(basis * outward), 0.001));
}

void fragment() {
	float h = relative_position.y - stripe_height;
	if (highlight) {
		if (abs(abs(h) - stripe_width * 1.35) > 0.035) {
			discard;
		}
		ALBEDO = vec3(1.0, 0.74, 0.24);
		EMISSION = ALBEDO * (0.48 + 0.20 * sin(TIME * 4.0));
	} else {
		float edge = sin(relative_position.x * 16.0 + relative_position.z * 19.0) * 0.011
			+ sin(relative_position.x * 57.0 - relative_position.z * 51.0) * 0.004;
		if (abs(h + edge) > stripe_width) {
			discard;
		}
		float brush = sin(h * 110.0 + relative_position.x * 21.0) * 0.026;
		ALBEDO = vec3(0.86, 0.22 + brush, 0.048);
		ROUGHNESS = 0.94;
	}
}
