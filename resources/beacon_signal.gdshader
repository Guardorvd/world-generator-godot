shader_type spatial;

uniform vec4 signal_color : source_color;
varying float phase;

void vertex() {
	phase = dot(MODEL_MATRIX[3].xz, vec2(0.13, 0.17));
}

void fragment() {
	ALBEDO = signal_color.rgb;
	ROUGHNESS = 0.55;
	EMISSION = signal_color.rgb * (0.85 + 0.25 * sin(TIME * 2.8 + phase));
}
