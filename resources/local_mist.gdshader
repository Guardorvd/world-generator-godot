shader_type fog;
uniform float density = 0.0;
global uniform vec4 mist_weather;
global uniform vec4 mist_tint;
void fog() {
	vec3 p = (WORLD_POSITION - OBJECT_POSITION) / (SIZE * 0.5);
	float edge = max(1.0 - dot(p, p), 0.0);
	vec2 q = (WORLD_POSITION.xz - mist_weather.xy) * 0.045;
	float variation = 0.88 + 0.12 * sin(q.x) * sin(q.y);
	DENSITY = density * mix(0.12, 1.0, mist_weather.z) * edge * variation;
	ALBEDO = mist_tint.rgb;
}
