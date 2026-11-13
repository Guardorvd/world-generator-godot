shader_type spatial;
render_mode cull_back, specular_disabled, shadows_disabled;
global uniform vec2 veg_center;
global uniform vec4 distant_vegetation; // near end, near fade band, far end, enabled
#include "res://resources/cloud_shadow.gdshaderinc"
#include "res://resources/depth_tone.gdshaderinc"
varying float distance_to_player;
varying float canopy_light;
varying float crown_height;
void vertex() {
	vec3 origin = MODEL_MATRIX[3].xyz;
	distance_to_player = length(origin.xz - veg_center);
	canopy_light = cloud_light(origin.xz);
	crown_height = VERTEX.y;
	// COLOR.a is the conifer share: conifers become narrower, taller cones; broadleaf crowns get a lumpy outline.
	float conifer = COLOR.a;
	float up = clamp(VERTEX.y + 0.5, 0.0, 1.0);
	float lump = fract(sin(dot(origin.xz * 0.37 + VERTEX.xz * 5.3 + VERTEX.y * 3.1, vec2(12.9898, 78.233))) * 43758.5453) - 0.5;
	float cone = mix(1.1, 0.18, up);
	VERTEX.xz *= mix(1.0 + lump * 0.34, cone, conifer);
	VERTEX.y *= 1.0 + conifer * 0.55;
}
void fragment() {
	float dither = fract(52.9829189 * fract(dot(FRAGCOORD.xy, vec2(0.06711056, 0.00583715))));
	float near_keep = clamp((distant_vegetation.x - distance_to_player) / distant_vegetation.y, 0.0, 1.0);
	float far_keep = 1.0 - smoothstep(distant_vegetation.z - 180.0, distant_vegetation.z, distance_to_player);
	if (distant_vegetation.w < 0.5 || dither < near_keep || dither >= far_keep) discard;
	// Mean leaf-texture reflectance: plain instance tint alone makes solid crowns too bright.
	ALBEDO = depth_tone(COLOR.rgb * 0.5 * canopy_light * mix(0.62, 1.0, smoothstep(-1.0, 0.8, crown_height)), length(VERTEX));
	ROUGHNESS = 1.0;
	AO = mix(0.65, 1.0, smoothstep(-0.8, 0.6, crown_height));
}
