shader_type canvas_item;
render_mode unshaded;

void fragment() {
	float dist = length(UV - vec2(0.5));
	float aa = fwidth(dist);
	COLOR.a *= 1.0 - smoothstep(0.5 - aa, 0.5, dist);
}
