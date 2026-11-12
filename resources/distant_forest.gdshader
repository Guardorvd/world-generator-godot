shader_type spatial;
render_mode cull_back;
global uniform vec2 veg_center;
global uniform vec4 distant_vegetation; // near end, near fade band, far end, enabled
#include "res://resources/cloud_shadow.gdshaderinc"
varying float distance_to_player;
varying float canopy_light;
varying float crown_height;
void vertex() {
	vec3 origin = MODEL_MATRIX[3].xyz;
	distance_to_player = length(origin.xz - veg_center);
	canopy_light = cloud_light(origin.xz);
	crown_height = VERTEX.y;
}
void fragment() {
	float dither = fract(52.9829189 * fract(dot(FRAGCOORD.xy, vec2(0.06711056, 0.00583715))));
	float near_keep = clamp((distant_vegetation.x - distance_to_player) / distant_vegetation.y, 0.0, 1.0);
	float far_keep = 1.0 - smoothstep(distant_vegetation.z - 180.0, distant_vegetation.z, distance_to_player);
	if (distant_vegetation.w < 0.5 || dither < near_keep || dither >= far_keep) discard;
	// Mean leaf-texture reflectance: plain instance tint alone makes solid crowns too bright.
	ALBEDO = COLOR.rgb * 0.5 * canopy_light * mix(0.62, 1.0, smoothstep(-1.0, 0.8, crown_height));
	ROUGHNESS = 1.0;
	AO = mix(0.65, 1.0, smoothstep(-0.8, 0.6, crown_height));
}
