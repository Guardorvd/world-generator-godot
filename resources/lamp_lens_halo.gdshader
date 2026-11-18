shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, cull_disabled, shadows_disabled;

global uniform float vegetation_night;
uniform vec3 tint : source_color = vec3(1.0, 0.9, 0.74);

varying float view_fade;

void vertex() {
	vec3 center = MODELVIEW_MATRIX[3].xyz;
	vec3 lens_forward = -normalize(MODELVIEW_MATRIX[2].xyz);
	float facing = dot(lens_forward, normalize(-center));
	view_fade = smoothstep(-0.35, 0.35, facing) * smoothstep(0.2, 0.6, length(center));
	MODELVIEW_MATRIX = mat4(vec4(1.0, 0.0, 0.0, 0.0), vec4(0.0, 1.0, 0.0, 0.0),
		vec4(0.0, 0.0, 1.0, 0.0), vec4(center, 1.0));
}

void fragment() {
	vec2 p = UV * 2.0 - 1.0;
	float falloff = max(0.0, 1.0 - dot(p, p));
	ALBEDO = tint;
	ALPHA = 0.44 * falloff * falloff * falloff * view_fade * smoothstep(0.2, 0.8, vegetation_night);
}
