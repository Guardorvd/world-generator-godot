shader_type fog;
uniform float density = 0.0;
global uniform vec4 mist_weather;
global uniform vec4 mist_tint;
void fog() {
	// World coordinates keep the pattern stable through camera changes.
	vec3 p = (WORLD_POSITION - OBJECT_POSITION) / (SIZE * 0.5);
	float edge = 1.0 - smoothstep(0.25, 1.0, length(p));
	// Keep the denser part low and dissolve the top without a horizontal hard edge.
	float layer = 1.0 - smoothstep(-0.15, 0.9, p.y);
	vec2 q = (WORLD_POSITION.xz - mist_weather.xy) * 0.045;
	float broad = sin(q.x + sin(q.y * 0.7)) * sin(q.y);
	float detail = sin(dot(q, vec2(1.73, -1.21)) + broad);
	float variation = 0.76 + 0.16 * broad + 0.08 * detail;
	DENSITY = density * (0.12 + mist_weather.z * 0.88) * edge * layer * variation;
	ALBEDO = mist_tint.rgb;
}
