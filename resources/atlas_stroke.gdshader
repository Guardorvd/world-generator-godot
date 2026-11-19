shader_type canvas_item;
render_mode unshaded;

uniform vec4 ink : source_color;
uniform float half_width = 1.0;
uniform float fringe = 1.0;

void vertex() {
	// Each quad starts on the centreline. UV carries the flattened normal angle and side.
	vec2 across = vec2(cos(UV.x), sin(UV.x));
	VERTEX += across * UV.y * (half_width + fringe);
}

void fragment() {
	float edge = abs(UV.y) * (half_width + fringe);
	float coverage = 1.0 - smoothstep(max(0.0, half_width - fringe), half_width + fringe, edge);
	COLOR = vec4(ink.rgb, ink.a * coverage);
}
