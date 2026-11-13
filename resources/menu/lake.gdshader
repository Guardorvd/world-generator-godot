shader_type spatial;

// Уровень и берег задаёт тот же меш, что у игровых озёр. Для спокойной воды
// достаточно длинной ряби и отражённого цвета неба на скользящем угле.
uniform float ripple_time = 0.0;
uniform vec3 deep_color : source_color = vec3(0.10, 0.24, 0.28);
uniform vec3 sky_reflection : source_color = vec3(0.37, 0.54, 0.64);

#include "res://resources/cloud_shadow.gdshaderinc"

varying vec3 lake_pos;
varying float cloud_visibility;

void vertex() {
	lake_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	cloud_visibility = cloud_light(lake_pos.xz);
}

void fragment() {
	vec2 pos = lake_pos.xz;
	float a = dot(pos, vec2(0.39, 0.87)) * 1.72 - ripple_time * 0.42;
	float b = dot(pos, vec2(-0.83, 0.56)) * 0.78 - ripple_time * 0.28;
	float fade = 1.0 - smoothstep(140.0, 440.0, length(VERTEX));
	vec2 ripples = vec2(cos(a) * 0.013 + cos(b) * 0.010, cos(a) * 0.022 + cos(b) * 0.006) * fade;
	vec3 world_normal = normalize(vec3(ripples.x, 1.0, ripples.y));
	NORMAL = normalize((VIEW_MATRIX * vec4(world_normal, 0.0)).xyz);
	float grazing = pow(1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0), 3.0);
	float broad = 0.05 * sin(dot(pos, vec2(0.021, -0.008)) - ripple_time * 0.06);
	float shimmer = broad + (sin(a + cos(b) * 0.55) * 0.026 + sin(b) * 0.045) * fade;
	ALBEDO = deep_color * (0.87 + cloud_visibility * 0.13);
	EMISSION = sky_reflection * (grazing * (0.28 + shimmer) + 0.045);
	ROUGHNESS = 0.40;
	SPECULAR = 0.42;
}
