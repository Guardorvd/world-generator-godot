shader_type fog;
uniform float density = 0.0;
uniform float clock = 0.0;
uniform vec3 tint : source_color = vec3(0.86, 0.90, 0.95);
void fog() {
	// World coordinates keep the pattern stable through camera changes.
	vec3 p = (WORLD_POSITION - OBJECT_POSITION) / (SIZE * 0.5);
	float edge = 1.0 - smoothstep(0.35, 1.0, length(p));
	vec2 wind = vec2(-1.92, -0.64) * clock * 0.08;
	vec2 q = (WORLD_POSITION.xz - wind) * 0.045;
	float variation = 0.8 + 0.2 * sin(q.x + sin(q.y * 0.7)) * sin(q.y);
	DENSITY = density * edge * variation;
	ALBEDO = tint;
}
