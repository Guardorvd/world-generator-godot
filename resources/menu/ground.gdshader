shader_type spatial;

// Привал: только природная поверхность. Карта биомов, полог и шум — из игровых данных.
uniform sampler2D base_tex : source_color, filter_linear_mipmap, repeat_disable;
uniform sampler2D forest_tex : filter_linear_mipmap, repeat_disable;
uniform sampler2D detail_tex : hint_default_white, filter_linear_mipmap, repeat_enable;
uniform sampler2D detail_normal : hint_normal, filter_linear_mipmap, repeat_enable;
uniform bool ridge = false;

#include "res://resources/cloud_shadow.gdshaderinc"
#include "res://resources/depth_tone.gdshaderinc"

varying vec3 ground_pos;
varying float cloud_visibility;

void vertex() {
	ground_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	cloud_visibility = cloud_light(ground_pos.xz);
}

void fragment() {
	float dist = length(VERTEX);
	vec3 albedo = COLOR.rgb;
	if (!ridge) {
		albedo = texture(base_tex, UV).rgb;
		vec4 forest = texture(forest_tex, UV);
		float detail = 1.0 - smoothstep(9.0, 64.0, dist);
		float broad = texture(detail_tex, ground_pos.xz / 17.0).r;
		float fine = texture(detail_tex, ground_pos.xz / 2.6).r;
		vec3 litter = mix(vec3(0.15, 0.12, 0.075), vec3(0.095, 0.09, 0.06), forest.g);
		albedo = mix(albedo, litter, forest.r * (0.36 + broad * 0.18));
		albedo *= (0.81 + broad * 0.33 + (fine - 0.5) * detail * 0.24) * mix(1.06, 0.89, forest.b);
		if (detail > 0.0) {
			NORMAL_MAP = texture(detail_normal, ground_pos.xz / 2.6).rgb;
			NORMAL_MAP_DEPTH = detail * 0.38;
		}
		AO = 1.0 - forest.r * 0.18;
	} else {
		float strata = texture(detail_tex, vec2(ground_pos.x * 0.73 + ground_pos.y * 0.36, ground_pos.z) / 168.0).r;
		albedo *= 0.84 + strata * 0.30;
	}
	ALBEDO = depth_tone(albedo, dist);
	ROUGHNESS = 0.96;
	SPECULAR = 0.15;
}

void light() {
	float visibility = ATTENUATION * (LIGHT_IS_DIRECTIONAL ? cloud_visibility : 1.0);
	DIFFUSE_LIGHT += LIGHT_COLOR * max(dot(NORMAL, LIGHT), 0.0) * visibility / PI;
}
